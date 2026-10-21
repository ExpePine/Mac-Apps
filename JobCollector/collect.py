#!/usr/bin/env python3
"""
ResumeForge job collector — runs on GitHub Actions on a schedule.

Collects job postings for the roles × locations in config.json from:
  • Adzuna API        (secrets ADZUNA_APP_ID, ADZUNA_APP_KEY)
  • Jooble API        (secret  JOOBLE_KEY)
  • JSearch/RapidAPI  (secret  RAPIDAPI_KEY)  — Google-for-Jobs results, often incl. Naukri/LinkedIn listings
  • Job-alert emails  (secrets IMAP_HOST, IMAP_USER, IMAP_PASSWORD) — Naukri / Wellfound / LinkedIn alerts in your inbox
  • RSS/Atom feeds    (urls in config.json) — for any site that publishes one

It does NOT crawl Naukri or Wellfound pages (both sites prohibit/block automated access).
Output: jobs.json (+ state.json) uploaded to the "job-feed" release, which the ResumeForge app reads.
Only job listing fields are published — never your stories, profile or email contents beyond the job listing.
"""
from __future__ import annotations

import email
import email.header
import hashlib
import html
import imaplib
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("OUT_DIR", os.path.join(HERE, "out"))
UA = "ResumeForge-JobCollector/1.0 (+https://github.com/ExpePine/Mac-Apps)"
NOW = datetime.now(timezone.utc)


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- helpers

def clean(s) -> str:
    if s is None:
        return ""
    s = html.unescape(str(s))
    s = re.sub(r"<[^>]+>", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()


def url_key(u: str) -> str:
    try:
        p = urllib.parse.urlsplit(u)
    except ValueError:
        return ""
    if not p.netloc:
        return ""
    keep = {"job_listing_slug", "jobid", "currentjobid", "jk", "jid", "id"}
    q = sorted(f"{k.lower()}={v}" for k, v in urllib.parse.parse_qsl(p.query) if k.lower() in keep and v)
    host = p.netloc.lower().removeprefix("www.")
    return (host + p.path.rstrip("/") + ("?" + "&".join(q) if q else "")).lower()


def keys_for(item: dict) -> list[str]:
    ks = []
    u = url_key(item.get("url", ""))
    if u:
        ks.append("u:" + u)
    t, c = norm(item.get("title", "")), norm(item.get("company", ""))
    if t and c:
        ks.append("t:" + t + "|" + c)
    return ks


def make_id(item: dict) -> str:
    base = (keys_for(item) or [item.get("title", "") + item.get("url", "")])[-1]
    return hashlib.sha1(base.encode()).hexdigest()[:16]


def http_json(url: str, *, method="GET", headers=None, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    h = {"User-Agent": UA, "Accept": "application/json"}
    if body is not None:
        h["Content-Type"] = "application/json"
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def item(source, publisher, title, company, location, url, description, posted="", salary="", extra=None) -> dict:
    d = {
        "source": source,
        "publisher": publisher or source,
        "title": clean(title)[:200],
        "company": clean(company)[:120],
        "location": clean(location)[:160],
        "url": (url or "").strip(),
        "description": clean(description)[:12000],
        "posted": posted or "",
        "salary": clean(salary)[:80],
    }
    if extra:
        d.update(extra)
    return d


# ---------------------------------------------------------------- sources

def adzuna(cfg, role, loc):
    app_id, key = os.environ.get("ADZUNA_APP_ID"), os.environ.get("ADZUNA_APP_KEY")
    if not (app_id and key):
        return []
    country = cfg.get("country", "in")
    params = {
        "app_id": app_id, "app_key": key, "what": role, "results_per_page": cfg.get("maxPerQuery", 20),
        "max_days_old": cfg.get("maxAgeDays", 7), "sort_by": "date", "content-type": "application/json",
    }
    if loc and loc.lower() != "remote":
        params["where"] = loc
    elif loc:
        params["what"] = f"{role} remote"
    url = f"https://api.adzuna.com/v1/api/jobs/{country}/search/1?" + urllib.parse.urlencode(params)
    out = []
    for r in http_json(url).get("results", []):
        sal = ""
        if r.get("salary_min"):
            sal = f"{int(r['salary_min'])}" + (f"–{int(r['salary_max'])}" if r.get("salary_max") else "")
        out.append(item("adzuna", "Adzuna", r.get("title"), (r.get("company") or {}).get("display_name"),
                        (r.get("location") or {}).get("display_name"), r.get("redirect_url"),
                        r.get("description"), r.get("created", ""), sal, {"snippet": True}))
    return out


def jooble(cfg, role, loc, state):
    key = os.environ.get("JOOBLE_KEY")
    if not key:
        return []
    # Jooble keys come with a limited number of requests — keep a running count and stop at the budget.
    month = NOW.strftime("%Y-%m")
    used = state.setdefault("joobleUsed", {}).get(month, 0)
    total = state.get("joobleTotal", 0)
    if used >= cfg.get("joobleMonthlyBudget", 120) or total >= cfg.get("joobleTotalBudget", 480):
        log(f"  jooble: budget reached (this month {used}, all-time {total})")
        return []
    state["joobleUsed"][month] = used + 1
    state["joobleTotal"] = total + 1
    body = {"keywords": role, "location": "" if (loc or "").lower() == "remote" else (loc or ""), "page": "1"}
    if (loc or "").lower() == "remote":
        body["keywords"] = f"{role} remote"
    data = http_json(f"https://jooble.org/api/{key}", method="POST", body=body)
    out = []
    max_age = cfg.get("maxAgeDays", 7)
    for r in (data.get("jobs") or [])[: cfg.get("maxPerQuery", 20)]:
        upd = r.get("updated", "")
        try:
            if upd and datetime.fromisoformat(upd.replace("Z", "+00:00")).replace(tzinfo=timezone.utc) < NOW - timedelta(days=max_age):
                continue
        except ValueError:
            pass
        out.append(item("jooble", r.get("source") or "Jooble", r.get("title"), r.get("company"), r.get("location"),
                        r.get("link"), r.get("snippet"), upd, r.get("salary"), {"snippet": True}))
    return out


def jsearch(cfg, role, loc, state):
    key = os.environ.get("RAPIDAPI_KEY")
    if not key:
        return []
    month = NOW.strftime("%Y-%m")
    used = state.setdefault("jsearchUsed", {}).get(month, 0)
    if used >= cfg.get("jsearchMonthlyBudget", 150):
        log(f"  jsearch: monthly budget reached ({used})")
        return []
    q = f"{role} in {loc}" if loc and loc.lower() != "remote" else f"{role} remote"
    age = cfg.get("maxAgeDays", 7)
    date_posted = "today" if age <= 1 else "3days" if age <= 3 else "week" if age <= 7 else "month"
    params = {"query": q, "page": "1", "num_pages": "1", "country": cfg.get("country", "in"), "date_posted": date_posted}
    url = "https://jsearch.p.rapidapi.com/search?" + urllib.parse.urlencode(params)
    data = http_json(url, headers={"x-rapidapi-key": key, "x-rapidapi-host": "jsearch.p.rapidapi.com"})
    state["jsearchUsed"][month] = used + 1
    out = []
    for r in (data.get("data") or [])[: cfg.get("maxPerQuery", 20)]:
        locs = ", ".join(x for x in [r.get("job_city"), r.get("job_state"), r.get("job_country")] if x)
        if r.get("job_is_remote"):
            locs = (locs + " (remote)").strip()
        sal = ""
        if r.get("job_min_salary"):
            sal = f"{r.get('job_min_salary')}–{r.get('job_max_salary') or ''} {r.get('job_salary_currency') or ''} {r.get('job_salary_period') or ''}"
        out.append(item("jsearch", r.get("job_publisher") or "Google Jobs", r.get("job_title"), r.get("employer_name"), locs,
                        r.get("job_apply_link") or r.get("job_google_link"), r.get("job_description"),
                        r.get("job_posted_at_datetime_utc", ""), sal, {"snippet": False}))
    return out


def rss(cfg):
    out = []
    for feed in cfg.get("rss", []):
        url = feed if isinstance(feed, str) else feed.get("url", "")
        if not url:
            continue
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                root = ET.fromstring(r.read())
        except Exception as e:  # noqa: BLE001
            log(f"  rss {url}: {e}")
            continue
        ns = {"a": "http://www.w3.org/2005/Atom"}
        entries = root.findall(".//item") or root.findall(".//a:entry", ns)
        host = urllib.parse.urlsplit(url).netloc.removeprefix("www.")
        for e in entries[:100]:
            def t(tag):
                el = e.find(tag) if not tag.startswith("a:") else e.find(tag, ns)
                return (el.text or "") if el is not None else ""
            link = t("link")
            if not link:
                le = e.find("a:link", ns)
                link = le.get("href", "") if le is not None else ""
            title = t("title") or t("a:title")
            desc = t("description") or t("a:summary") or t("a:content")
            posted = t("pubDate") or t("a:updated")
            company = ""
            m = re.match(r"(.+?)\s+(?:at|@|-|–|\|)\s+(.+)$", clean(title))
            if m:
                title, company = m.group(1), m.group(2)
            out.append(item("rss", host, title, company, "", link, desc, posted, "", {"snippet": True}))
    return out


# ---------------------------------------------------------------- job-alert emails

ALERT_SENDERS = {
    "naukri": ("naukri.com",),
    "wellfound": ("wellfound.com", "angel.co", "angellist.com"),
    "linkedin": ("linkedin.com",),
}
SKIP_TEXT = re.compile(
    r"\bunsubscribe\b|\bview (all|more|similar)\b|\bsee (all|more)\b|^apply( now)?$|\blog ?in\b|\bsign ?(in|up)\b|"
    r"\bsettings\b|\bprivacy\b|^help\b|\bdownload\b|\bapp store\b|\bgoogle play\b|\bterms\b|"
    r"\bmanage (your |notification|alert|email|preferences)|\bpreferences\b|recommended jobs$|\bclick here\b|"
    r"\bupdate (your )?profile\b|^jobs? (for you|alert)|\bfollow us\b|^https?://|^\W*$", re.I)


class _Anchors:
    """Minimal HTML walker: collects <a href> with their text and the surrounding block text."""

    def __init__(self, raw: str):
        from html.parser import HTMLParser

        anchors, blocks = [], []

        class P(HTMLParser):
            def __init__(self):
                super().__init__(convert_charrefs=True)
                self.stack = []          # open anchors: [href, text]
                self.block = []          # text of current block (tr/td/div/p)

            def handle_starttag(self, tag, attrs):
                if tag in ("tr", "table", "div", "p", "li"):
                    if self.block:
                        blocks.append(" ".join(self.block))
                    self.block = []
                if tag == "a":
                    href = dict(attrs).get("href") or ""
                    self.stack.append([href, [], len(blocks)])
                if tag == "br":
                    self.block.append("\n")

            def handle_endtag(self, tag):
                if tag == "a" and self.stack:
                    href, txt, bi = self.stack.pop()
                    anchors.append((href, clean(" ".join(txt)), bi))

            def handle_data(self, data):
                d = data.strip()
                if not d:
                    return
                for a in self.stack:
                    a[1].append(d)
                self.block.append(d)

        p = P()
        p.feed(raw)
        if p.block:
            blocks.append(" ".join(p.block))
        self.anchors, self.blocks = anchors, blocks


def parse_alert_html(raw_html: str, site: str) -> list[dict]:
    """Best effort: alert emails list jobs as links whose text is the job title, with company/location nearby."""
    a = _Anchors(raw_html)
    out, seen = [], set()
    domains = ALERT_SENDERS[site]
    starts = sorted({bi for _, _, bi in a.anchors})
    for href, text, bi in a.anchors:
        if not href or not text or SKIP_TEXT.search(text):
            continue
        if not (8 <= len(text) <= 120) or len(text.split()) > 14:
            continue
        host = urllib.parse.urlsplit(href).netloc.lower()
        # Links must point at the alert's site (directly or via its tracking domain).
        if not any(d in host for d in domains) and not any(d in href for d in domains):
            continue
        k = norm(text) + "|" + href[:120]
        if k in seen:
            continue
        seen.add(k)
        nxt = next((x for x in starts if x > bi), bi + 3)
        context = " · ".join(b for b in a.blocks[bi: min(nxt, bi + 3)] if b)[:600]
        context = clean(context.replace(text, "", 1)).strip(" ·|•-")
        company, location, exp = "", "", ""
        parts = [p.strip() for p in re.split(r"\s*[·|•,]\s*|\s{2,}", context) if p.strip()]
        for p in parts[:6]:
            if not exp and re.search(r"\d+\s*-\s*\d+\s*(yrs|years)|\d+\+?\s*(yrs|years)", p, re.I):
                exp = p
            elif not location and re.search(r"remote|hybrid|bengaluru|bangalore|mumbai|pune|delhi|gurgaon|gurugram|noida|"
                                            r"hyderabad|chennai|ahmedabad|kolkata|india", p, re.I):
                location = p
            elif not company and 2 <= len(p) <= 60 and not re.search(r"\d+\s*(day|hour|week)s? ago|lpa|₹|salary", p, re.I):
                company = p
        out.append(item(f"{site}-alert", site.capitalize(), text, company, location, href, context,
                        "", "", {"snippet": True, "experience": exp}))
    return out


def email_alerts(cfg, state):
    host, user, pw = os.environ.get("IMAP_HOST"), os.environ.get("IMAP_USER"), os.environ.get("IMAP_PASSWORD")
    if not (host and user and pw):
        return []
    seen_ids = set(state.get("emailSeen", []))
    since = (NOW - timedelta(days=max(2, cfg.get("maxAgeDays", 7)))).strftime("%d-%b-%Y")
    folder = cfg.get("imapFolder", "INBOX")
    out = []
    with imaplib.IMAP4_SSL(host) as M:
        M.login(user, pw)
        M.select(folder, readonly=True)
        for site, domains in ALERT_SENDERS.items():
            if not cfg.get("emailSites", {}).get(site, site in ("naukri", "wellfound")):
                continue
            for dom in domains:
                typ, data = M.search(None, "SINCE", since, "FROM", dom)
                if typ != "OK":
                    continue
                for num in (data[0].split() if data and data[0] else [])[-60:]:
                    typ, msg_data = M.fetch(num, "(RFC822)")
                    if typ != "OK" or not msg_data or not isinstance(msg_data[0], tuple):
                        continue
                    msg = email.message_from_bytes(msg_data[0][1])
                    mid = (msg.get("Message-ID") or "").strip() or hashlib.sha1(msg_data[0][1][:2000]).hexdigest()
                    if mid in seen_ids:
                        continue
                    seen_ids.add(mid)
                    body = ""
                    for part in msg.walk():
                        if part.get_content_type() == "text/html":
                            payload = part.get_payload(decode=True) or b""
                            body = payload.decode(part.get_content_charset() or "utf-8", "replace")
                            break
                    if body:
                        found = parse_alert_html(body, site)
                        log(f"  email {site}: {len(found)} jobs in '{email.header.make_header(email.header.decode_header(msg.get('Subject', '')))}'")
                        out += found
    state["emailSeen"] = list(seen_ids)[-2000:]
    return out


# ---------------------------------------------------------------- main

def excluded(it: dict, cfg) -> bool:
    title = norm(it.get("title", ""))
    return any(norm(x) and norm(x) in title for x in cfg.get("exclude", []))


def merge(previous: list[dict], fresh: list[dict], keep_days: int) -> list[dict]:
    by_key: dict[str, dict] = {}
    items: list[dict] = []
    for it in previous:
        items.append(it)
        for k in keys_for(it):
            by_key[k] = it
    now = NOW.isoformat(timespec="seconds")
    added = 0
    for it in fresh:
        if not it.get("title") or not it.get("url"):
            continue
        ks = keys_for(it)
        hit = next((by_key[k] for k in ks if k in by_key), None)
        if hit:
            hit["lastSeen"] = now
            if len(it.get("description", "")) > len(hit.get("description", "")):
                hit["description"] = it["description"]
                hit["snippet"] = it.get("snippet", True)
            continue
        it["id"] = make_id(it)
        it["firstSeen"] = it["lastSeen"] = now
        items.append(it)
        added += 1
        for k in ks:
            by_key[k] = it
    cutoff = (NOW - timedelta(days=keep_days)).isoformat(timespec="seconds")
    items = [i for i in items if i.get("lastSeen", "") >= cutoff]
    items.sort(key=lambda i: i.get("firstSeen", ""), reverse=True)
    log(f"merge: {added} new, {len(items)} total")
    return items


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def main():
    cfg = load_json(os.path.join(HERE, "config.json"), {})
    os.makedirs(OUT, exist_ok=True)
    prev = load_json(os.path.join(OUT, "jobs.json"), {}).get("items", [])
    state = load_json(os.path.join(OUT, "state.json"), {})

    roles = [r for r in cfg.get("roles", []) if r.strip()]
    locs = [l for l in cfg.get("locations", []) if l.strip()] or [""]
    src = cfg.get("sources", {})
    fresh: list[dict] = []
    errors: list[str] = []

    def run(name, fn, *a):
        try:
            got = fn(*a)
            log(f"  {name}: {len(got)}")
            fresh.extend(got)
        except Exception as e:  # noqa: BLE001 — one failing source shouldn't stop the run
            msg = f"{name}: {e}"
            log("  ERROR " + msg)
            errors.append(msg)
        time.sleep(1.2)

    for role in roles:
        for loc in locs:
            log(f"{role} @ {loc or 'anywhere'}")
            if src.get("adzuna", True):
                run("adzuna", adzuna, cfg, role, loc)
            if src.get("jooble", True):
                run("jooble", jooble, cfg, role, loc, state)
            if src.get("jsearch", True):
                run("jsearch", jsearch, cfg, role, loc, state)
    if src.get("email", True):
        run("email alerts", email_alerts, cfg, state)
    if src.get("rss", True) and cfg.get("rss"):
        run("rss", rss, cfg)

    fresh = [i for i in fresh if not excluded(i, cfg)]
    items = merge(prev, fresh, cfg.get("keepDays", 30))
    feed = {
        "generatedAt": NOW.isoformat(timespec="seconds"),
        "count": len(items),
        "config": {k: cfg.get(k) for k in ("roles", "locations", "country", "maxAgeDays")},
        "errors": errors,
        "items": items,
    }
    with open(os.path.join(OUT, "jobs.json"), "w", encoding="utf-8") as f:
        json.dump(feed, f, ensure_ascii=False, indent=1)
    with open(os.path.join(OUT, "state.json"), "w", encoding="utf-8") as f:
        json.dump(state, f)
    configured = [n for n, ok in [("Adzuna", os.environ.get("ADZUNA_APP_ID")), ("Jooble", os.environ.get("JOOBLE_KEY")),
                                  ("JSearch", os.environ.get("RAPIDAPI_KEY")), ("Email", os.environ.get("IMAP_HOST"))] if ok]
    log(f"done: {len(items)} jobs in feed; sources with keys: {', '.join(configured) or 'none'}")


if __name__ == "__main__":
    main()

// ResumeForge Capture — one click on the toolbar icon sends the job on screen to the app.
//
// Badge on the icon:
//   number  = JDs sent today (resets at local midnight)
//   ✓       = just sent (then back to the count)
//   DUP     = this job was already sent before — nothing sent
//   ?       = no job description found on this page
//   ERR     = sending failed — a status page opens with details and a copy-to-clipboard fallback
const api = globalThis.browser ?? globalThis.chrome;

// Safari ignores this identifier and routes to the containing app's extension handler.
const NATIVE_APP_ID = "com.rajmishra.ResumeForge";
const KEEP_DAYS = 365;           // how long a sent job is remembered for duplicate checks
const COLORS = { count: "#2f5d8a", ok: "#2e7d32", dup: "#ef6c00", none: "#757575", err: "#c62828" };

// ---------- date & storage ----------

function today() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

async function loadState() {
  const s = await api.storage.local.get(["day", "count", "seen"]);
  const state = { day: s.day, count: s.count || 0, seen: s.seen || {} };
  if (state.day !== today()) {            // new day → reset the counter
    state.day = today();
    state.count = 0;
    await api.storage.local.set({ day: state.day, count: 0 });
  }
  return state;
}

function prune(seen) {
  const cutoff = Date.now() - KEEP_DAYS * 86400000;
  for (const k of Object.keys(seen)) if (!seen[k] || seen[k].t < cutoff) delete seen[k];
}

// ---------- duplicate keys ----------

// Same job = same page (ignoring tracking parameters) OR same title + company.
function urlKey(u) {
  try {
    const url = new URL(u);
    // Parameters that identify a job on sites that show listings in a side panel.
    const keep = ["job_listing_slug", "jobid", "currentjobid", "jk", "jid"];
    const params = [];
    url.searchParams.forEach((v, k) => { if (keep.includes(k.toLowerCase()) && v) params.push(`${k.toLowerCase()}=${v}`); });
    params.sort();
    return (url.hostname.replace(/^www\./, "") + url.pathname.replace(/\/+$/, "") +
      (params.length ? "?" + params.join("&") : "")).toLowerCase();
  } catch (_) {
    return "";
  }
}

const norm = (s) => (s || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

function jobKeys(job) {
  const keys = [];
  const u = urlKey(job.url);
  if (u) keys.push("u:" + u);
  const t = norm(job.title), c = norm(job.company);
  if (t && c) keys.push("t:" + t + "|" + c);
  return keys;
}

// ---------- badge ----------

async function setBadge(text, color, title) {
  try { await api.action.setBadgeBackgroundColor({ color }); } catch (_) {}
  try { await api.action.setBadgeText({ text }); } catch (_) {}
  if (title) { try { await api.action.setTitle({ title }); } catch (_) {} }
}

async function showCount() {
  const { count } = await loadState();
  await setBadge(count > 0 ? String(count) : "", COLORS.count,
    `ResumeForge — ${count} JD${count === 1 ? "" : "s"} sent today. Click to send this job.`);
}

function flash(text, color, title, ms = 1600) {
  setBadge(text, color, title);
  setTimeout(() => { showCount(); }, ms);
}

// ---------- capture ----------

async function extract(tab) {
  try {
    const r = await api.tabs.sendMessage(tab.id, { type: "RF_EXTRACT" });
    if (r && !r.error) return r;
  } catch (_) { /* content script not on this site yet */ }
  await api.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] });
  const r = await api.tabs.sendMessage(tab.id, { type: "RF_EXTRACT" });
  if (!r || r.error) throw new Error((r && r.error) || "Couldn't read this page");
  return r;
}

function looksLikeJob(job) {
  return (job.description || "").length >= 200 || ((job.rawText || "").length >= 800 && job.title);
}

let busy = false;

api.action.onClicked.addListener(async (tab) => {
  if (busy) return;
  busy = true;
  let job = null;
  try {
    await setBadge("…", COLORS.none);
    job = await extract(tab);

    if (!looksLikeJob(job)) {
      flash("?", COLORS.none, "No job description found on this page — open the job itself and click again.", 2500);
      return;
    }

    const state = await loadState();
    const keys = jobKeys(job);
    const hit = keys.find((k) => state.seen[k]);
    if (hit) {
      flash("DUP", COLORS.dup, `Already sent on ${state.seen[hit].d}: ${job.title || "this job"} — not sent again.`, 2500);
      return;
    }

    const reply = await api.runtime.sendNativeMessage(NATIVE_APP_ID, { action: "saveJob", job });
    if (!reply || !reply.ok) throw new Error((reply && reply.error) || "No reply from ResumeForge");

    const t = Date.now(), d = today();
    for (const k of keys) state.seen[k] = { t, d, title: job.title || "", company: job.company || "" };
    prune(state.seen);
    state.count += 1;
    await api.storage.local.set({ day: d, count: state.count, seen: state.seen, lastError: null });
    flash("✓", COLORS.ok, `Sent: ${job.title || "job"}${job.company ? " — " + job.company : ""}`, 1200);
  } catch (e) {
    await api.storage.local.set({ lastError: String((e && e.message) || e), lastJob: job, lastErrorAt: Date.now() });
    await setBadge("ERR", COLORS.err, "Sending failed — see the status page.");
    try { await api.tabs.create({ url: api.runtime.getURL("status.html") }); } catch (_) {}
  } finally {
    busy = false;
  }
});

// ---------- messages from the status page ----------

api.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  (async () => {
    if (msg?.type === "RF_STATUS") {
      const s = await loadState();
      const extra = await api.storage.local.get(["lastError", "lastJob", "lastErrorAt"]);
      const recent = Object.values(s.seen)
        .filter((v, i, a) => a.findIndex((x) => x.t === v.t) === i)   // one row per job (it has 2 keys)
        .sort((a, b) => b.t - a.t).slice(0, 30);
      sendResponse({ count: s.count, day: s.day, recent, ...extra });
    } else if (msg?.type === "RF_RESET_TODAY") {
      await api.storage.local.set({ day: today(), count: 0 });
      await showCount();
      sendResponse({ ok: true });
    } else if (msg?.type === "RF_FORGET_ALL") {
      await api.storage.local.set({ seen: {} });
      sendResponse({ ok: true });
    } else if (msg?.type === "RF_CLEAR_ERROR") {
      await api.storage.local.set({ lastError: null, lastJob: null });
      await showCount();
      sendResponse({ ok: true });
    }
  })();
  return true;
});

// ---------- keep the badge right across restarts and midnight ----------

api.runtime.onStartup?.addListener(showCount);
api.runtime.onInstalled?.addListener(() => {
  showCount();
  try { api.alarms.create("rf-midnight-check", { periodInMinutes: 10 }); } catch (_) {}
});
try { api.alarms.onAlarm.addListener((a) => { if (a.name === "rf-midnight-check") showCount(); }); } catch (_) {}
api.tabs.onActivated?.addListener(() => { showCount(); });
showCount();

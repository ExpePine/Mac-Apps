// ResumeForge content script: extracts job details from the page you're viewing.
// Strategy (most to least reliable):
//   1. schema.org JobPosting JSON-LD embedded by many job sites
//   2. Site-specific selectors (Naukri / Wellfound / LinkedIn) — best guesses, these sites change their markup
//   3. "Job description" heading heuristics
//   4. Visible page text (the app's AI step cleans it up)
(() => {
  if (window.__resumeForgeLoaded) return;
  window.__resumeForgeLoaded = true;

  const api = globalThis.browser ?? globalThis.chrome;

  const clean = (s) =>
    (s || "")
      .replace(/ /g, " ")
      .replace(/[ \t]+\n/g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();

  const textOf = (el) => (el ? clean(el.innerText || el.textContent) : "");

  const first = (selectors) => {
    for (const sel of selectors) {
      try {
        const el = document.querySelector(sel);
        if (el && textOf(el)) return textOf(el);
      } catch (_) { /* invalid selector on some engines */ }
    }
    return "";
  };

  const all = (selectors) => {
    for (const sel of selectors) {
      try {
        const els = [...document.querySelectorAll(sel)].map(textOf).filter(Boolean);
        if (els.length) return [...new Set(els)].slice(0, 40);
      } catch (_) {}
    }
    return [];
  };

  const htmlToText = (html) => {
    const withBreaks = String(html || "")
      .replace(/<li[^>]*>/gi, "\n• ")
      .replace(/<(br|\/p|\/li|\/h\d|\/div|\/ul|\/ol)[^>]*>/gi, "\n");
    const doc = new DOMParser().parseFromString(withBreaks, "text/html");
    return clean(doc.body ? doc.body.textContent : withBreaks);
  };

  function fromJsonLd() {
    for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
      let data;
      try { data = JSON.parse(s.textContent); } catch (_) { continue; }
      const items = [].concat(data || []);
      for (const d of [...items]) if (d && Array.isArray(d["@graph"])) items.push(...d["@graph"]);
      for (const it of items) {
        if (!it) continue;
        const types = [].concat(it["@type"] || []);
        if (!types.includes("JobPosting")) continue;
        const org = it.hiringOrganization || {};
        const locs = [].concat(it.jobLocation || []).map((l) => {
          const a = (l && l.address) || {};
          return [a.addressLocality, a.addressRegion, a.addressCountry && (a.addressCountry.name || a.addressCountry)]
            .filter((x) => typeof x === "string" && x).join(", ");
        }).filter(Boolean);
        let exp = it.experienceRequirements || "";
        if (exp && typeof exp === "object") {
          const m = exp.monthsOfExperience;
          exp = m ? `${Math.round(m / 12)}+ years` : (exp.description || "");
        }
        let salary = "";
        const bs = it.baseSalary;
        if (bs && bs.value) {
          const v = bs.value;
          salary = [bs.currency, v.minValue, v.maxValue ? "– " + v.maxValue : "", v.unitText].filter(Boolean).join(" ");
        }
        const skills = typeof it.skills === "string"
          ? it.skills.split(/,|\n/).map((x) => x.trim()).filter(Boolean)
          : [].concat(it.skills || []).filter((x) => typeof x === "string");
        return {
          title: clean(it.title),
          company: clean(typeof org === "string" ? org : org.name),
          location: [...new Set(locs)].join(" | "),
          experience: clean(String(exp)),
          salary: clean(salary),
          skills,
          description: htmlToText(it.description),
        };
      }
    }
    return null;
  }

  function sectionByHeading(re) {
    const candidates = [...document.querySelectorAll("h1,h2,h3,h4,h5,strong,b,span,div,p")]
      .filter((e) => e.children.length === 0)
      .filter((e) => { const t = textOf(e); return t.length < 60 && re.test(t); });
    for (const h of candidates) {
      let c = h.parentElement;
      for (let i = 0; i < 5 && c; i++, c = c.parentElement) {
        const t = textOf(c);
        if (t.length > 300 && t.length < 30000) return t;
      }
    }
    return "";
  }

  function detectSource() {
    const h = location.hostname;
    if (h.includes("naukri.com")) return "naukri";
    if (h.includes("wellfound.com")) return "wellfound";
    if (h.includes("linkedin.com")) return "linkedin";
    return "other";
  }

  function siteSpecific(source) {
    if (source === "naukri") {
      return {
        title: first(['h1[class*="jd-header-title"]', 'h1[class*="title"]', "h1"]),
        company: first(['[class*="jd-header-comp-name"] a', '[class*="comp-name"] a', '[class*="comp-name"]']),
        location: first(['[class*="location"] a', '[class*="loc"] a', '[class*="location"]']),
        experience: first(['[class*="exp"] span', '[class*="experience"]']),
        salary: first(['[class*="salary"] span', '[class*="salary"]']),
        skills: all(['[class*="key-skill"] a', '[class*="key-skill"] span', '[class*="chip"]']),
        description: first(['[class*="job-desc"]', 'section[class*="JD"]', '[class*="dang-inner-html"]']),
      };
    }
    if (source === "wellfound") {
      return {
        title: first(["h1", '[class*="title"] h1']),
        company: first(['a[href*="/company/"] h2', 'a[href*="/company/"]']),
        location: first(['[class*="location"]']),
        experience: "",
        salary: first(['[class*="compensation"]', '[class*="salary"]']),
        skills: all(['a[href*="/role/"][href*="skill"]', '[class*="skill"] span']),
        description: first(['[class*="description"]', '[data-test*="description"]']),
      };
    }
    if (source === "linkedin") {
      return {
        title: first(['[class*="job-title"] h1', '[class*="top-card"] h1', "h1"]),
        company: first(['[class*="company-name"] a', '[class*="company-name"]']),
        location: first(['[class*="primary-description"] span', '[class*="bullet"]']),
        experience: "",
        salary: "",
        skills: [],
        description: first(['[class*="jobs-description__content"]', '[class*="description__text"]', "#job-details"]),
      };
    }
    return { title: first(["h1"]), company: "", location: "", experience: "", salary: "", skills: [], description: "" };
  }

  function extract() {
    const source = detectSource();
    const ld = fromJsonLd() || {};
    const site = siteSpecific(source);
    const pick = (k) => (ld[k] && (Array.isArray(ld[k]) ? ld[k].length : String(ld[k]).length)) ? ld[k] : site[k];

    let description = pick("description");
    if (!description || description.length < 200) {
      description = sectionByHeading(/job description|about the (job|role)|responsibilit|what you.?ll do|role overview/i) || description;
    }
    const main = document.querySelector("main") || document.body;
    const rawText = textOf(main).slice(0, 40000);

    return {
      source,
      url: location.href.split("#")[0],
      title: pick("title") || document.title,
      company: pick("company") || "",
      location: pick("location") || "",
      experience: pick("experience") || "",
      salary: pick("salary") || "",
      skills: pick("skills") || [],
      description: description || "",
      rawText,
    };
  }

  window.__resumeForgeExtract = extract;

  api.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg && msg.type === "RF_EXTRACT") {
      try { sendResponse(extract()); } catch (e) { sendResponse({ error: String(e) }); }
    }
  });
})();

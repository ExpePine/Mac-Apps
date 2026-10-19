const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);
let captured = null;

function status(text, cls = "") {
  const el = $("status");
  el.textContent = text;
  el.className = cls;
}

async function activeTab() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function extractFrom(tab) {
  // 1) content script already on the page (Naukri / Wellfound / LinkedIn)
  try {
    const r = await api.tabs.sendMessage(tab.id, { type: "RF_EXTRACT" });
    if (r && !r.error) return r;
  } catch (_) { /* not injected on this site */ }
  // 2) any other site: inject on demand (allowed by activeTab after the toolbar click)
  await api.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] });
  const r = await api.tabs.sendMessage(tab.id, { type: "RF_EXTRACT" });
  if (!r || r.error) throw new Error((r && r.error) || "Could not read this page");
  return r;
}

function currentJob() {
  return {
    ...captured,
    title: $("title").value.trim(),
    company: $("company").value.trim(),
    location: $("location").value.trim(),
    description: $("description").value.trim(),
  };
}

async function init() {
  try {
    const tab = await activeTab();
    captured = await extractFrom(tab);
    $("source").textContent = captured.source;
    $("title").value = captured.title || "";
    $("company").value = captured.company || "";
    $("location").value = captured.location || "";
    $("description").value = captured.description || "";
    const bits = [];
    if (captured.experience) bits.push("Exp: " + captured.experience);
    if (captured.salary) bits.push("Salary: " + captured.salary);
    if (captured.skills && captured.skills.length) bits.push(captured.skills.length + " skills found");
    $("meta").textContent = bits.join(" · ");
    $("send").disabled = false;
    if (!captured.description || captured.description.length < 200) {
      status("Description looks short — the app will also clean it up from the full page text.", "");
    }
  } catch (e) {
    $("source").textContent = "error";
    captured = { source: "other", url: "", rawText: "", skills: [] };
    $("send").disabled = false;
    status("Couldn't read this page automatically (" + e.message + "). Paste the description and send.", "err");
  }
}

$("send").addEventListener("click", async () => {
  const job = currentJob();
  if (!job.description && !job.rawText) { status("Add a job description first.", "err"); return; }
  $("send").disabled = true;
  status("Sending…");
  try {
    const r = await api.runtime.sendMessage({ type: "RF_SAVE", job });
    if (r && r.ok) status("Sent — ResumeForge should come to the front with this job.", "ok");
    else throw new Error((r && r.error) || "Unknown error");
  } catch (e) {
    status("Send failed: " + e.message + " — use 'Copy as JSON' and paste into the app instead.", "err");
    $("send").disabled = false;
  }
});

$("copy").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(JSON.stringify(currentJob(), null, 2));
    status("Copied. In the app: Jobs → Add job manually → paste.", "ok");
  } catch (e) {
    status("Copy failed: " + e.message, "err");
  }
});

init();

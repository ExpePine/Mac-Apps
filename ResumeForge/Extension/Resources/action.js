const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);
const q = new URLSearchParams(location.search);
const tabId = q.get("tab");
const selection = q.get("sel") || "";

$("page").textContent = q.get("title") ? "On: " + q.get("title") : "";
if (selection) { $("sel").hidden = false; $("sel").textContent = "Selected: " + selection; }

async function closeSelf() {
  try { const t = await api.tabs.getCurrent(); if (t) await api.tabs.remove(t.id); } catch (_) { window.close(); }
}

async function save() {
  const text = $("text").value.trim();
  if (!text) { $("status").textContent = "Write what you need to do."; $("status").className = "err"; return; }
  $("save").disabled = true;
  $("status").textContent = "Adding…"; $("status").className = "";
  const r = await api.runtime.sendMessage({ type: "RF_ACTION_CUSTOM", tabId, kind: $("kind").value, text, selection });
  if (r && r.ok) {
    $("status").textContent = "Added. It's in ResumeForge ▸ Actions."; $("status").className = "ok";
    setTimeout(closeSelf, 900);
  } else {
    $("status").textContent = "Couldn't add: " + ((r && r.error) || "unknown error"); $("status").className = "err";
    $("save").disabled = false;
  }
}

$("save").onclick = save;
$("cancel").onclick = closeSelf;
$("text").addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) save(); });

const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);
let lastJob = null;

const send = (type) => api.runtime.sendMessage({ type });

function esc(s) {
  return String(s || "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

async function render() {
  const s = await send("RF_STATUS");
  if (!s) return;
  $("count").textContent = s.count;
  $("countLabel").textContent = `JD${s.count === 1 ? "" : "s"} sent today (${s.day})`;
  const jobs = (s.recent || []).length;
  $("remembered").textContent = jobs ? `Remembering ${jobs >= 30 ? "30+" : jobs} sent job${jobs === 1 ? "" : "s"}.` : "";

  $("autoCapture").checked = !!s.autoCapture;
  lastJob = s.lastJob || null;
  $("errorCard").hidden = !s.lastError;
  $("errorText").textContent = s.lastError || "";
  $("copyJob").hidden = !lastJob;

  $("recent").innerHTML = (s.recent || []).map((r) =>
    `<tr><td class="d">${esc(r.d)}</td><td>${esc(r.title) || "<i>untitled</i>"}${r.company ? " — " + esc(r.company) : ""}</td></tr>`
  ).join("") || `<tr><td class="muted">Nothing sent yet.</td></tr>`;
}

$("autoCapture").onchange = async (e) => { await api.runtime.sendMessage({ type: "RF_SET_AUTO", on: e.target.checked }); };
$("resetToday").onclick = async () => { await send("RF_RESET_TODAY"); render(); };
$("forgetAll").onclick = async () => {
  if (!confirm("Forget all sent jobs? You'll be able to send them again.")) return;
  await send("RF_FORGET_ALL");
  $("msg").textContent = "Done — previously sent jobs can be sent again.";
  render();
};
$("clearError").onclick = async () => { await send("RF_CLEAR_ERROR"); render(); };
$("copyJob").onclick = async () => {
  try {
    await navigator.clipboard.writeText(JSON.stringify(lastJob, null, 2));
    $("copyJob").textContent = "Copied ✓";
  } catch (e) {
    $("copyJob").textContent = "Copy failed: " + e.message;
  }
};

render();

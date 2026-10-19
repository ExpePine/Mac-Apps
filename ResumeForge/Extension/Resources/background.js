// Relays a captured job from the popup to the native app extension
// (SafariWebExtensionHandler.swift), which opens a resumeforge://import link to hand it to the app.
const api = globalThis.browser ?? globalThis.chrome;

// Safari ignores this identifier and routes to the containing app's extension handler.
const NATIVE_APP_ID = "com.rajmishra.ResumeForge";

api.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || msg.type !== "RF_SAVE") return;
  Promise.resolve(api.runtime.sendNativeMessage(NATIVE_APP_ID, { action: "saveJob", job: msg.job }))
    .then((reply) => sendResponse(reply && reply.ok ? { ok: true } : { ok: false, error: (reply && reply.error) || "No reply from app" }))
    .catch((e) => sendResponse({ ok: false, error: String(e) }));
  return true; // keep the channel open for the async reply
});

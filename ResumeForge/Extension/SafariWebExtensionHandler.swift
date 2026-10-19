import AppKit
import SafariServices

/// Receives messages from background.js (browser.runtime.sendNativeMessage)
/// and hands the captured job to ResumeForge.app by opening a resumeforge://import link.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey]

        var reply: [String: Any]
        if let dict = message as? [String: Any],
           (dict["action"] as? String) == "saveJob",
           let jobDict = dict["job"] as? [String: Any] {
            do {
                let url = try SharedConfig.importURL(for: CapturedJob(dictionary: jobDict))
                let opened = NSWorkspace.shared.open(url)
                reply = opened ? ["ok": true] : ["ok": false, "error": "Couldn't open ResumeForge. Launch the app once from Applications, then try again."]
            } catch {
                reply = ["ok": false, "error": error.localizedDescription]
            }
        } else {
            reply = ["ok": false, "error": "Unknown message"]
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}

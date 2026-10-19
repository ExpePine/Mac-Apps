import AppKit
import SafariServices

/// Receives messages from background.js (browser.runtime.sendNativeMessage)
/// and hands the captured job to ResumeForge.app by opening a resumeforge://import link
/// WITHOUT bringing the app to the front, so you can keep browsing.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey]

        guard let dict = message as? [String: Any],
              (dict["action"] as? String) == "saveJob",
              let jobDict = dict["job"] as? [String: Any] else {
            finish(context, ["ok": false, "error": "Unknown message"])
            return
        }

        let url: URL
        do {
            url = try SharedConfig.importURL(for: CapturedJob(dictionary: jobDict))
        } catch {
            finish(context, ["ok": false, "error": error.localizedDescription])
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false          // keep Safari in front
        config.addsToRecentItems = false
        NSWorkspace.shared.open(url, configuration: config) { app, error in
            if let error {
                self.finish(context, ["ok": false,
                                      "error": "Couldn't reach ResumeForge (\(error.localizedDescription)). Open the app once from Applications, then try again."])
            } else {
                _ = app
                self.finish(context, ["ok": true])
            }
        }
    }

    private func finish(_ context: NSExtensionContext, _ reply: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}

import AppKit
import SafariServices

/// Receives messages from background.js (browser.runtime.sendNativeMessage)
/// and hands the captured job to ResumeForge.app by opening a resumeforge://import link
/// WITHOUT bringing the app to the front, so you can keep browsing.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey]

        guard let dict = message as? [String: Any], let action = dict["action"] as? String else {
            finish(context, ["ok": false, "error": "Unknown message"])
            return
        }

        let url: URL
        do {
            switch action {
            case "saveJob":
                guard let jobDict = dict["job"] as? [String: Any] else { throw NSError(domain: "ResumeForge", code: 3) }
                url = try SharedConfig.importURL(for: CapturedJob(dictionary: jobDict))
            case "saveAction":
                guard let a = dict["payload"] as? [String: Any] else { throw NSError(domain: "ResumeForge", code: 3) }
                url = try SharedConfig.actionURL(for: ActionPayload(dictionary: a))
            default:
                throw NSError(domain: "ResumeForge", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown message"])
            }
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

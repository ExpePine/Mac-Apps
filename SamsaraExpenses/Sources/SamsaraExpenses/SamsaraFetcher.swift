import AppKit
import WebKit
import SamsaraCore

/// Opens the Samsara page in a hidden web view, presses its 📥 "Download table as CSV"
/// button and captures the CSV the page generates — the same file you get by clicking it.
///
/// The page builds the CSV in the browser, so there is no fixed CSV URL to download.
/// We catch the file three ways, whichever the page uses:
///   1. a Blob passed to URL.createObjectURL (most common),
///   2. a data: URL on a link that gets clicked,
///   3. a real browser download (WKDownload).
@MainActor
final class SamsaraFetcher: NSObject {

    enum FetchError: LocalizedError {
        case needsSignIn
        case buttonNotFound
        case noData
        case timeout
        case loadFailed(String)

        var errorDescription: String? {
            switch self {
            case .needsSignIn:
                return "Samsara asked for a sign-in. Use “Sign in to Samsara…” once, then sync again."
            case .buttonNotFound:
                return "Couldn't find the 📥 CSV button on the page. Check the page URL in Settings."
            case .noData:
                return "The CSV downloaded but had no rows. If Samsara needs you to be signed in, use “Sign in to Samsara…”."
            case .timeout:
                return "The Samsara page took too long to produce the CSV."
            case .loadFailed(let msg):
                return "Couldn't open the Samsara page: \(msg)"
            }
        }
    }

    static let messageName = "samsaraCSV"

    private var webView: WKWebView?
    private var window: NSWindow?
    private var captured: String?
    private var pageLoaded = false
    private var loadError: Error?
    private var downloadFiles: [ObjectIdentifier: URL] = [:]
    private(set) var isBusy = false

    /// Hook installed before the page's own scripts run.
    static let hookJS = #"""
    (function () {
      if (window.__samsaraHooked) return;
      window.__samsaraHooked = true;
      function send(text, how) {
        try { window.webkit.messageHandlers.samsaraCSV.postMessage({ csv: String(text), how: how }); } catch (e) {}
      }
      function looksCSV(t) { return typeof t === 'string' && t.indexOf(',') >= 0 && t.indexOf('\n') >= 0; }

      var OrigBlob = window.Blob;
      function HookedBlob(parts, opts) {
        var b = new OrigBlob(parts || [], opts);
        try {
          var strs = (parts || []).filter(function (p) { return typeof p === 'string'; });
          if (strs.length) { var t = strs.join(''); if (looksCSV(t)) b.__samsaraText = t; }
        } catch (e) {}
        return b;
      }
      HookedBlob.prototype = OrigBlob.prototype;
      window.Blob = HookedBlob;

      var origCreate = URL.createObjectURL;
      URL.createObjectURL = function (obj) {
        try {
          if (obj && obj.__samsaraText) {
            send(obj.__samsaraText, 'blob');
          } else if (obj instanceof OrigBlob) {
            var fr = new FileReader();
            fr.onload = function () { if (looksCSV(fr.result)) send(fr.result, 'blob-read'); };
            fr.readAsText(obj);
          }
        } catch (e) {}
        return origCreate.apply(this, arguments);
      };

      var origClick = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function () {
        try {
          var h = this.getAttribute('href') || '';
          if (h.indexOf('data:') === 0) {
            var c = h.indexOf(',');
            var meta = h.slice(0, c), body = h.slice(c + 1);
            var text = meta.indexOf(';base64') >= 0 ? decodeURIComponent(escape(atob(body))) : decodeURIComponent(body);
            send(text, 'data-url');
            return;
          }
          if (h.indexOf('blob:') === 0) { return; }   // already captured in createObjectURL
        } catch (e) {}
        return origClick.apply(this, arguments);
      };
    })();
    """#

    /// Presses the CSV button. Returns "clicked", "noButton" or "login".
    static let clickJS = #"""
    (function () {
      var b = document.getElementById('adeCsvDownloadBtn');
      if (!b) {
        var all = Array.prototype.slice.call(document.querySelectorAll('button, a, [role=button]'));
        b = all.find(function (e) {
          var t = (e.title || '') + ' ' + (e.getAttribute('aria-label') || '');
          return /csv/i.test(t) || /download.*csv|csv.*download/i.test(e.textContent || '');
        }) || all.find(function (e) { return (e.textContent || '').trim() === '📥'; });
      }
      if (!b) {
        var pw = document.querySelector('input[type=password]');
        return pw ? 'login' : 'noButton';
      }
      b.click();
      return 'clicked';
    })();
    """#

    func fetch(url: URL, timeout: TimeInterval = 90) async throws -> String {
        guard !isBusy else { throw FetchError.timeout }
        isBusy = true
        defer {
            tearDown()
            isBusy = false
        }
        setUp()
        captured = nil
        pageLoaded = false
        loadError = nil

        webView?.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45))
        let deadline = Date().addingTimeInterval(timeout)

        while !pageLoaded && loadError == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if let err = loadError { throw FetchError.loadFailed(err.localizedDescription) }
        if !pageLoaded { throw FetchError.timeout }
        if let path = webView?.url?.absoluteString.lowercased(), path.contains("wp-login") || path.contains("/login") {
            throw FetchError.needsSignIn
        }

        // Give the page's own data requests time to fill the table.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        var sawButton = false
        var headerOnly = false
        var sawLogin = false
        while Date() < deadline {
            captured = nil
            let result = await evaluate(SamsaraFetcher.clickJS)
            if result == "clicked" { sawButton = true }
            if result == "login" { sawLogin = true }

            let waitUntil = min(deadline, Date().addingTimeInterval(4))
            while captured == nil && Date() < waitUntil {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if let text = captured {
                if SamsaraFetcher.dataRowCount(text) > 0 { return text }
                headerOnly = true   // table not loaded yet, or signed out — try again
            }
            if sawLogin && !sawButton { throw FetchError.needsSignIn }
            try await Task.sleep(nanoseconds: 2_500_000_000)
        }
        if headerOnly { throw FetchError.noData }
        throw sawButton ? FetchError.timeout : FetchError.buttonNotFound
    }

    static func dataRowCount(_ csv: String) -> Int {
        max(0, CSV.parse(csv).count - 1)
    }

    // MARK: - Web view lifecycle

    private func setUp() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // shares sign-in cookies with the Sign-in window
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: SamsaraFetcher.hookJS,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controller.add(WeakMessageHandler(self), name: SamsaraFetcher.messageName)
        config.userContentController = controller

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = SamsaraFetcher.userAgent

        // Pages only run timers and layout reliably inside a window, so use an invisible one.
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 900),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        w.contentView = wv
        w.orderBack(nil)

        webView = wv
        window = w
    }

    private func tearDown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: SamsaraFetcher.messageName)
        window?.orderOut(nil)
        window?.contentView = nil
        webView = nil
        window = nil
        for (_, url) in downloadFiles { try? FileManager.default.removeItem(at: url) }
        downloadFiles.removeAll()
    }

    /// A normal Safari user agent, so the site serves the same page as in a browser.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private func evaluate(_ js: String) async -> String? {
        guard let wv = webView else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            wv.evaluateJavaScript(js) { result, _ in
                cont.resume(returning: result as? String)
            }
        }
    }

    fileprivate func receive(_ text: String) {
        if captured == nil || SamsaraFetcher.dataRowCount(text) > SamsaraFetcher.dataRowCount(captured ?? "") {
            captured = text
        }
    }
}

// MARK: - Navigation & downloads

extension SamsaraFetcher: WKNavigationDelegate, WKDownloadDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        var isAttachment = false
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disp = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() {
            isAttachment = disp.contains("attachment")
        }
        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        let isCSV = mime.contains("csv") || mime == "application/octet-stream"
        if isAttachment || (isCSV && !navigationResponse.isForMainFrame) || !navigationResponse.canShowMIMEType {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        record(error)
    }

    private func record(_ error: Error) {
        let ns = error as NSError
        // Cancelled loads and "frame load interrupted" happen when a navigation turns into a download.
        if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && ns.code == 102) { return }
        if !pageLoaded { loadError = error }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("samsara-\(UUID().uuidString)-\(suggestedFilename)")
        downloadFiles[ObjectIdentifier(download)] = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadFiles[ObjectIdentifier(download)],
              let data = try? Data(contentsOf: url) else { return }
        receive(String(decoding: data, as: UTF8.self))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {}
}

// MARK: - Script messages

/// WKUserContentController keeps a strong reference to its handlers; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: SamsaraFetcher?
    init(_ target: SamsaraFetcher) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let csv = body["csv"] as? String else { return }
        let target = self.target
        Task { @MainActor in
            target?.receive(csv)
        }
    }
}

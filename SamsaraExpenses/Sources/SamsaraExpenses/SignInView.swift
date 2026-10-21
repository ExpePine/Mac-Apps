import SwiftUI
import WebKit

/// A normal, visible browser window for the Samsara page. Sign in here once; the cookies are
/// kept in the app's web data store and reused by the hidden auto-download.
struct SignInView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WebModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                Text(model.urlText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("Sign in if asked, then press Done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Done — Sync now") {
                    dismiss()
                    Task { await store.sync() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            .padding(10)
            Divider()
            WebViewHost(webView: model.webView)
        }
        .frame(minWidth: 900, minHeight: 640)
        .onAppear {
            if let url = URL(string: store.pageURL) { model.webView.load(URLRequest(url: url)) }
        }
    }
}

@MainActor
final class WebModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var canGoBack = false
    @Published var urlText = ""

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = SamsaraFetcher.userAgent
        super.init()
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        canGoBack = webView.canGoBack
        urlText = webView.url?.absoluteString ?? ""
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        urlText = webView.url?.absoluteString ?? ""
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

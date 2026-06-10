import SwiftUI
import WebKit

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

/// Rate sheet WebView — mirrors Android's RatesScreen (mobileapi view_rates.php).
struct RatesWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.load(URLRequest(url: url))
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {}
}

struct RatesSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            RatesWebView(url: url).ignoresSafeArea(edges: .bottom)
                .navigationTitle("Rates")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

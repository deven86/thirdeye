import SwiftUI
import WebKit

/// Upstox login inside the app. The page is Upstox's own; Third Eye never sees your password.
/// When Upstox redirects to `https://127.0.0.1/thirdeye?code=…`, the sheet catches it, cancels the
/// navigation and exchanges the code for today's access token.
struct UpstoxLoginSheet: View {
    @Environment(MarketStore.self) private var market
    @Environment(\.dismiss) private var dismiss
    @State private var state = UUID().uuidString
    @State private var status: Status = .loading

    enum Status: Equatable {
        case loading
        case waitingForUser
        case exchanging
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let key = market.upstoxAPIKey() {
                    UpstoxWebView(url: UpstoxAuth.loginURL(apiKey: key, state: state),
                                  expectedState: state,
                                  onLoaded: { if status == .loading { status = .waitingForUser } },
                                  onResult: handle)
                } else {
                    ContentUnavailableView("Add your Upstox API key first", systemImage: "key")
                }
                switch status {
                case .loading:
                    ProgressView("Opening Upstox…")
                case .exchanging:
                    ProgressView("Signing in…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                case .failed(let message):
                    VStack(spacing: 12) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .multilineTextAlignment(.center)
                        Button("Try again") {
                            state = UUID().uuidString
                            status = .loading
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding()
                case .waitingForUser:
                    EmptyView()
                }
            }
            .navigationTitle("Upstox login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func handle(_ result: UpstoxAuth.CallbackResult) {
        switch result {
        case .notCallback:
            break
        case .error(let message):
            status = .failed(message)
        case .code(let code):
            status = .exchanging
            Task {
                do {
                    try await market.completeUpstoxLogin(code: code)
                    dismiss()
                    Task { await market.loadUniverse() }
                } catch {
                    status = .failed(error.localizedDescription)
                }
            }
        }
    }
}

private struct UpstoxWebView: UIViewRepresentable {
    let url: URL
    let expectedState: String
    let onLoaded: () -> Void
    let onResult: (UpstoxAuth.CallbackResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // nothing from the login is kept on disk
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedURL != url { // "Try again" issues a new state
            context.coordinator.loadedURL = url
            web.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: UpstoxWebView
        var loadedURL: URL?
        init(parent: UpstoxWebView) { self.parent = parent }

        // Async variant: avoids completion-handler signature mismatches across SDK versions.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .allow }
            let result = UpstoxAuth.parseCallback(url, expectedState: parent.expectedState)
            if result == .notCallback { return .allow }
            parent.onResult(result)
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoaded()
        }
    }
}

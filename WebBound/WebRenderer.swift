//
//  WebRenderer.swift
//  WebBound
//

import Foundation
import WebKit
import AppKit

enum RendererError: Error, CustomStringConvertible {
    case cloudflareTimeout
    case navigationTimeout
    case javascriptReturnedNil(String)
    case javascriptTypeMismatch(expected: String, got: String)

    var description: String {
        switch self {
        case .cloudflareTimeout:
            return "Timed out waiting for Cloudflare challenge to resolve."
        case .navigationTimeout:
            return "Timed out waiting for page navigation to finish."
        case .javascriptReturnedNil(let script):
            return "JavaScript returned nil for: \(script.prefix(80))..."
        case .javascriptTypeMismatch(let expected, let got):
            return "JavaScript return type mismatch. Expected \(expected), got \(got)."
        }
    }
}

@MainActor
final class WebRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Create a hidden window so WKWebView has a parent view. Some sites
        // behave differently when the view isn't attached to a window.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0

        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        window.contentView?.addSubview(self.webView)

        super.init()

        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
    }

    /// Load a URL and wait for the initial navigation to finish. Does NOT wait
    /// for Cloudflare challenge resolution; call `waitForCloudflareClearance`
    /// afterwards if the target site is CF-protected.
    func load(_ url: URL, timeout: TimeInterval = 30) async throws {
        try await withNavigationContinuation(timeout: timeout) {
            self.webView.load(URLRequest(url: url))
        }
    }

    private func withNavigationContinuation(
        timeout: TimeInterval,
        _ action: () -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.navigationContinuation = cont
            action()

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                await MainActor.run {
                    if let pending = self.navigationContinuation {
                        self.navigationContinuation = nil
                        pending.resume(throwing: RendererError.navigationTimeout)
                    }
                }
            }
        }
    }

    /// Returns the fully rendered outerHTML of the current page.
    func html() async throws -> String {
        return try await evaluateString("document.documentElement.outerHTML")
    }

    /// Evaluate JS and return a String result.
    func evaluateString(_ script: String) async throws -> String {
        let result = try await webView.evaluateJavaScript(script)
        guard let value = result else {
            throw RendererError.javascriptReturnedNil(script)
        }
        guard let str = value as? String else {
            throw RendererError.javascriptTypeMismatch(expected: "String", got: String(describing: type(of: value)))
        }
        return str
    }

    /// Evaluate JS that returns JSON-serialisable data and decode it into `T`.
    func evaluateJSON<T: Decodable>(_ script: String, as type: T.Type) async throws -> T {
        // Wrap in JSON.stringify so WebKit hands us a String instead of a
        // bridged NSDictionary/NSArray — avoids any decoder quirks.
        let wrapped = "JSON.stringify((function(){ \(script) })())"
        let json = try await evaluateString(wrapped)
        let data = Data(json.utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Polls the current page until it no longer looks like a Cloudflare
    /// interstitial. The CF "Just a moment..." page sets `document.title` to
    /// "Just a moment..." and auto-refreshes once the challenge solves.
    func waitForCloudflareClearance(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let title = (try? await evaluateString("document.title")) ?? ""
            let lowered = title.lowercased()
            let challengeMarkers = ["just a moment", "attention required", "please wait"]
            let looksLikeChallenge = challengeMarkers.contains { lowered.contains($0) } || title.isEmpty
            if !looksLikeChallenge {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw RendererError.cloudflareTimeout
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.resumeNavigation(with: .success(()))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.resumeNavigation(with: .failure(error))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.resumeNavigation(with: .failure(error))
        }
    }

    private func resumeNavigation(with result: Result<Void, Error>) {
        guard let cont = navigationContinuation else { return }
        navigationContinuation = nil
        switch result {
        case .success: cont.resume()
        case .failure(let err): cont.resume(throwing: err)
        }
    }
}

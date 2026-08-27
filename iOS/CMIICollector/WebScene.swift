//
//  WebScene.swift
//  A pinned web page, used as a "free play" scene inside a play.
//
//  Why this exists. On iOS an app can only observe touches delivered to its own
//  windows - there is no getevent. So a session where the participant uses other
//  apps produces no touch ground truth, and (worse) backgrounding this app stops
//  BLEAdvertiser, so the watch stops seeing the beacon entirely. Hosting real web
//  content INSIDE the app keeps both channels alive: TouchRecognizer on the window
//  still sees every touch with coordinates, and the advertiser keeps running
//  because the app stays foreground.
//
//  The page is pinned: no address bar, no back/forward swipe, and main-frame
//  navigation off the starting site is cancelled and logged. A participant cannot
//  wander somewhere unintended, which matters because the touch log is coordinate
//  level and this corpus includes recordings of children.
//
import SwiftUI
import WebKit

struct WebScene: UIViewRepresentable {
    let url: URL
    /// (event, detail) - "load", "blocked", "fail". Scene start is logged by the caller.
    var onEvent: ((String, String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(base: WebScene.baseDomain(of: url), onEvent: onEvent)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []   // a video scene should just play
        // A non-persistent store means nothing the participant does is kept between
        // sessions - no cookies, no history, no cache carried to the next person.
        cfg.websiteDataStore = .nonPersistent()

        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.allowsBackForwardNavigationGestures = false
        v.scrollView.contentInsetAdjustmentBehavior = .never
        v.load(URLRequest(url: url))
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}

    /// Last two labels of the host, so www.youtube.com and m.youtube.com are the
    /// same site but accounts.google.com is not.
    static func baseDomain(of url: URL) -> String {
        let parts = (url.host ?? "").split(separator: ".")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : (url.host ?? "")
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let base: String
        let onEvent: ((String, String) -> Void)?
        init(base: String, onEvent: ((String, String) -> Void)?) {
            self.base = base; self.onEvent = onEvent
        }

        func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Subresources and iframes are not navigation away from the site.
            guard action.targetFrame?.isMainFrame ?? true else { return decisionHandler(.allow) }
            guard let u = action.request.url else { return decisionHandler(.cancel) }
            if u.scheme == "about" || WebScene.baseDomain(of: u) == base {
                decisionHandler(.allow)
            } else {
                onEvent?("blocked", u.absoluteString)
                decisionHandler(.cancel)
            }
        }

        func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
            onEvent?("load", w.url?.absoluteString ?? "")
        }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
            onEvent?("fail", e.localizedDescription)
        }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
            onEvent?("fail", e.localizedDescription)
        }
    }
}

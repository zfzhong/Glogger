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
        // Browser games routinely ask for fullscreen. WKWebView ignores the
        // Fullscreen API unless this is set, and the button then does nothing at
        // all - which looks like a broken game rather than a disabled feature.
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.mediaTypesRequiringUserActionForPlayback = []   // a video scene should just play
        // A non-persistent store means nothing the participant does is kept between
        // sessions - no cookies, no history, no cache carried to the next person.
        cfg.websiteDataStore = .nonPersistent()

        // iPadOS serves WKWebView a desktop-class user agent by default, so sites
        // hand back their desktop layout - the first render check landed on
        // en.wikipedia.org rather than the mobile site. Tap-target size is part of
        // what we are measuring, so ask for the mobile presentation the study is
        // meant to imitate.
        cfg.defaultWebpagePreferences.preferredContentMode = .mobile

        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
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

        /// target="_blank" and window.open. With no UI delegate these taps did
        /// nothing whatsoever - no view, no navigation, not even a log line, so a
        /// game that opens its own window looked broken and an ad click-through
        /// vanished unrecorded. Same site loads in place; anything else is logged
        /// and dropped, which is the same containment rule as a navigation.
        func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = action.request.url {
                if WebScene.baseDomain(of: u) == base {
                    onEvent?("popup", u.absoluteString)
                    w.load(action.request)
                } else {
                    onEvent?("blocked", u.absoluteString)
                }
            }
            return nil
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

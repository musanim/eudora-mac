import SwiftUI
import WebKit
import EudoraStore

/// A locked-down WKWebView for displaying HTML mail — a "dumb" renderer with no
/// active behavior a message can trigger (design-decisions §Guiding principle).
///
/// - JavaScript is off and a strict CSP blocks *every* remote resource; because
///   `BodyRenderer` has already replaced all `<img>` with text boxes, nothing
///   loads at all (`img-src 'none'`).
/// - The message HTML arrives pre-rewritten: remote images are skull boxes,
///   embedded images are `eudora-image:<id>` links, and text links are intact.
/// - Navigation never happens. Clicking a link copies its **true URL**; clicking
///   an `IMAGE [view]` box opens the bytes in a native window. Right-click is
///   trimmed to Copy Link.
struct HTMLMailView: NSViewRepresentable {
    let html: String
    /// eudora-image:<id> → bytes, for the embedded-image viewer.
    let images: [String: EmbeddedImage]
    /// Called (on the main thread) when a link's URL is copied, so the app can
    /// show a brief confirmation.
    var onCopyLink: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        config.websiteDataStore = .nonPersistent()

        let view = TrimmedMenuWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.images = images
        context.coordinator.onCopyLink = onCopyLink
        // Avoid reloading (and flicker) when nothing changed.
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            view.loadHTMLString(Self.wrap(html), baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(images: images, onCopyLink: onCopyLink)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var images: [String: EmbeddedImage]
        var onCopyLink: (String) -> Void
        var loadedHTML: String?

        init(images: [String: EmbeddedImage], onCopyLink: @escaping (String) -> Void) {
            self.images = images
            self.onCopyLink = onCopyLink
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            let scheme = url?.scheme?.lowercased()

            // Whitelist ONLY the initial in-memory document load. `loadHTMLString`
            // with `baseURL: nil` navigates the main frame to about:blank with
            // type `.other`. Everything else is refused by default — so a crafted
            // message can't auto-navigate (meta-refresh, redirects, form submit,
            // data:/file: hops that would escape the CSP).
            if navigationAction.navigationType == .other, scheme == nil || scheme == "about" {
                decisionHandler(.allow)
                return
            }

            // Beyond the initial load, only a *deliberate click* does anything,
            // and even then we never navigate.
            if navigationAction.navigationType == .linkActivated, let url {
                if scheme == "eudora-image" {
                    // Embedded image box → open the bytes natively. Never a fetch.
                    let id = String(url.absoluteString.dropFirst("eudora-image:".count))
                    if let resource = images[id] {
                        Task { @MainActor in ImageViewerController.shared.show(resource) }
                    }
                } else {
                    // Any link (http/https/mailto/… and the skull box): copy its
                    // true destination rather than navigating.
                    copyLink(url.absoluteString)
                }
                decisionHandler(.cancel)
                return
            }

            // Refuse everything else.
            decisionHandler(.cancel)
        }

        private func copyLink(_ url: String) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url, forType: .string)
            onCopyLink(url)
        }
    }

    /// Wrap the (already-rewritten) message HTML with a strict CSP, baseline
    /// styling, and the styling for the image boxes.
    private static func wrap(_ body: String) -> String {
        """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; img-src 'none'; style-src 'unsafe-inline'; font-src 'none';">
        <style>
          body { font: -apple-system-body, -webkit-system-font, sans-serif;
                 margin: 12px; color: #222; word-wrap: break-word; }
          @media (prefers-color-scheme: dark) { body { color: #ddd; } }
          img { max-width: 100%; height: auto; }
          blockquote { border-left: 3px solid #ccc; margin: 0 0 0 8px; padding-left: 8px; color: #888; }
          pre { white-space: pre-wrap; }
          .eu-image, .eu-remote, .eu-broken {
            display: inline-block; padding: 2px 8px; margin: 2px 0;
            border-radius: 5px; font-size: 12px; text-decoration: none;
            border: 1px solid; white-space: nowrap; vertical-align: middle;
          }
          .eu-image  { color: #0a5; border-color: #0a5; background: rgba(0,170,85,0.08); }
          .eu-remote { color: #b30; border-color: #b30; background: rgba(187,51,0,0.08); }
          .eu-broken { color: #888; border-color: #bbb; background: rgba(128,128,128,0.08); }
          @media (prefers-color-scheme: dark) {
            .eu-image  { color: #4d9; border-color: #4d9; }
            .eu-remote { color: #f86; border-color: #f86; }
            .eu-broken { color: #aaa; border-color: #666; }
          }
        </style>
        </head><body>
        \(body)
        </body></html>
        """
    }
}

/// WKWebView that trims the right-click menu to the copy affordances — no
/// "Open Link", "Open in New Window", or "Download" (all of which would
/// navigate or fetch). "Copy Link" is kept because it yields the *true* href.
private final class TrimmedMenuWebView: WKWebView {
    private static let blocked: Set<String> = [
        "WKMenuItemIdentifierOpenLink",
        "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierOpenImageInNewWindow",
        "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierOpenMediaInNewWindow",
        "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierDownloadMedia",
        "WKMenuItemIdentifierReload",
        "WKMenuItemIdentifierGoBack",
        "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierShareMenu",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.items.removeAll { item in
            guard let id = item.identifier?.rawValue else { return false }
            return Self.blocked.contains(id)
        }
        super.willOpenMenu(menu, with: event)
    }
}

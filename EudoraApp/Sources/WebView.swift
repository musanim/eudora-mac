import SwiftUI
import AppKit
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
    /// Forward the message being shown — the body's right-click menu offers it,
    /// since that is where the eye is when the urge strikes.
    var onForward: () -> Void = {}

    /// The default reading font — the same one the composer uses. Sets the
    /// document's base font, which the message's own styling overrides where it
    /// has any. See `ComposeSettings`.
    var fontName: String = "Arial"
    var fontSize: Double = 12
    var antialias: Bool = true

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        config.websiteDataStore = .nonPersistent()

        let view = TrimmedMenuWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.onForward = onForward
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.images = images
        context.coordinator.onCopyLink = onCopyLink
        (view as? TrimmedMenuWebView)?.onForward = onForward
        // Reload when the document *or* the reading font changes — the font is
        // baked into the wrapper's CSS, so a settings change while a message is
        // open has to re-wrap. The key folds both in.
        let doc = Self.wrap(html, fontName: fontName, fontSize: fontSize, antialias: antialias)
        if context.coordinator.loadedDoc != doc {
            context.coordinator.loadedDoc = doc
            view.loadHTMLString(doc, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(images: images, onCopyLink: onCopyLink)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var images: [String: EmbeddedImage]
        var onCopyLink: (String) -> Void
        /// The last document actually loaded — the *wrapped* HTML, so a change to
        /// either the body or the reading font triggers a reload.
        var loadedDoc: String?

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
    ///
    /// The base `font-family`/`font-size` are the reading font — the same
    /// default the composer uses — so unstyled and plain-styled mail reads in it;
    /// a message's own font declarations still override. Size is `px`, matching
    /// the `NSFont` point size the editor and the plain-text view use (macOS
    /// points are pixels at scale 1, which is Stephen's display).
    /// `-webkit-font-smoothing: none` is WebKit's antialiasing-off, the CSS
    /// counterpart to the `NSTextView` draw override.
    private static func wrap(_ body: String, fontName: String, fontSize: Double,
                             antialias: Bool) -> String {
        let family = cssFontFamily(fontName)
        let size = cssNumber(fontSize)
        let smoothing = antialias ? "auto" : "none"
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; img-src 'none'; style-src 'unsafe-inline'; font-src 'none';">
        <style>
          body { font-family: \(family), -apple-system, sans-serif;
                 font-size: \(size)px; -webkit-font-smoothing: \(smoothing);
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

    /// A font family, quoted, for a CSS declaration. Strips the characters that
    /// could end the string or the rule — a real family name has none, but this
    /// value is about to be dropped into a document, so it is not trusted blindly.
    static func cssFontFamily(_ name: String) -> String {
        let cleaned = String(name.filter { !"\"';{}<>\n\r".contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "sans-serif" : "\"\(cleaned)\""
    }

    /// A number without a pointless trailing `.0`.
    static func cssNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// A read-only, selectable plain-text mail body in the reading font.
///
/// An `NSTextView` rather than a SwiftUI `Text` for one reason: the
/// antialiasing toggle. Smoothing is a graphics-context property, and only the
/// `BodyTextView` draw override can turn it off — SwiftUI `Text` always
/// antialiases. Sharing that view type also means plain mail and the composer
/// render through exactly the same path, so "the same font" really is the same.
struct PlainMailView: NSViewRepresentable {
    let text: String
    let fontName: String
    let fontSize: Double
    let antialias: Bool

    func makeNSView(context: Context) -> NSScrollView {
        FontDiagnostics.logResolution(of: fontName, size: fontSize, context: "plain-text reader")
        let textView = BodyTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 8)

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize =
            NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        apply(to: textView)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? BodyTextView else { return }
        apply(to: textView)
    }

    private func apply(to textView: BodyTextView) {
        textView.antialias = antialias
        if textView.string != text { textView.string = text }
        let font = NSFont(name: fontName, size: CGFloat(fontSize))
            ?? NSFont.systemFont(ofSize: CGFloat(fontSize))
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.textStorage?.addAttribute(.font, value: font, range: range)
        textView.textStorage?.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
    }
}

/// WKWebView that trims the right-click menu to the copy affordances — no
/// "Open Link", "Open in New Window", or "Download" (all of which would
/// navigate or fetch) — and adds "Forward" at the top. "Copy Link" is kept
/// because it yields the *true* href.
private final class TrimmedMenuWebView: WKWebView {
    var onForward: (() -> Void)?

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
        // Newer WebKit adds animation controls. Meaningless here — every image
        // has already been replaced with a static text box (img-src 'none'), so
        // nothing animates — and out of place in a mail reader.
        "WKMenuItemIdentifierPlayAllAnimations",
        "WKMenuItemIdentifierPauseAllAnimations",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.items.removeAll { item in
            guard let id = item.identifier?.rawValue else { return false }
            // Substring match on "Animation" as well as the explicit ids, so a
            // future rename of the animation items (they are recent and the
            // exact identifier could shift) doesn't let them creep back in.
            return Self.blocked.contains(id) || id.contains("Animation")
        }

        // Forward at the top, then a separator before whatever survived (Copy,
        // Copy Link, Look Up…). No separator when nothing else is left.
        let forward = NSMenuItem(title: "Forward",
                                 action: #selector(forwardMessage), keyEquivalent: "")
        forward.target = self
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        menu.insertItem(forward, at: 0)

        super.willOpenMenu(menu, with: event)
    }

    @objc private func forwardMessage() { onForward?() }
}

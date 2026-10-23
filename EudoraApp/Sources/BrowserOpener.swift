import AppKit

/// Opens a web link from a message in a **new browser window centred on the
/// primary display** (the one with the menu bar), rather than wherever the
/// browser would put it — usually a tab in whichever window it used last, on
/// whichever display that window happens to be.
///
/// **Chrome only, by AppleScript.** `NSWorkspace.open` hands the URL to the
/// default browser and gives the caller no say over the window. Chrome's
/// scripting dictionary can make a window and set its bounds, so when Chrome is
/// the default browser this asks it to. Any other default browser — which
/// matters for copies of Eudora given to other people — gets the ordinary
/// `NSWorkspace.open`, and so does any failure here, including the user
/// declining the one-time "Eudora wants to control Google Chrome" prompt.
///
/// **What that needs.** Sending Apple Events from a hardened-runtime app takes
/// the `com.apple.security.automation.apple-events` entitlement
/// (`EudoraApp/Eudora.entitlements`) and an `NSAppleEventsUsageDescription`
/// string in Info.plist, which is the sentence macOS shows in that prompt.
/// Without the entitlement the script fails with -1743 *without ever
/// prompting*, which reads as the user having said no.
///
/// **Size.** Chrome's own new-window size is kept; only the position changes.
/// A window larger than the display's visible area is shrunk to fit it.
///
/// **Coordinates.** Chrome's `bounds` are in the AppleScript convention: origin
/// at the top-left of the primary display, y increasing downward. AppKit's are
/// bottom-left, y up, with the primary display's frame at the origin — so the
/// conversion only needs that display's height.
enum BrowserOpener {
    static let chromeBundleID = "com.google.Chrome"

    static func open(_ url: URL) {
        guard isChromeDefault(for: url), let rect = primaryVisibleRect() else {
            NSWorkspace.shared.open(url)
            return
        }
        let source = script(url: url, area: rect)
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            eudoraDiag("[browser] couldn't compile the Chrome script; opening normally")
            NSWorkspace.shared.open(url)
            return
        }
        // Main thread, synchronously: NSAppleScript isn't documented as safe
        // off it. The cost is a short stall when Chrome has to be launched, and
        // once ever while the permission prompt is up.
        script.executeAndReturnError(&error)
        if let error {
            eudoraDiag("[browser] Chrome script failed (\(error[NSAppleScript.errorNumber] ?? "?")): "
                       + "\(error[NSAppleScript.errorMessage] ?? "")  — opening normally")
            NSWorkspace.shared.open(url)
        }
    }

    private static func isChromeDefault(for url: URL) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url),
              let id = Bundle(url: app)?.bundleIdentifier else { return false }
        return id == chromeBundleID
    }

    /// The primary display's visible area (menu bar and Dock excluded), in
    /// AppleScript coordinates, as whole points.
    private static func primaryVisibleRect() -> (x: Int, y: Int, w: Int, h: Int)? {
        // `screens.first` is the primary display by definition — the one with
        // the menu bar — not `NSScreen.main`, which is the one with the key window.
        guard let primary = NSScreen.screens.first else { return nil }
        let visible = primary.visibleFrame
        let top = primary.frame.height - visible.maxY
        return (Int(visible.minX.rounded()), Int(top.rounded()),
                Int(visible.width.rounded()), Int(visible.height.rounded()))
    }

    /// The URL is escaped for an AppleScript string literal: it comes from a
    /// message, so a `"` in it must not be able to end the string and run
    /// whatever follows as script.
    private static func script(url: URL, area: (x: Int, y: Int, w: Int, h: Int)) -> String {
        let literal = url.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application id "\(chromeBundleID)"
            set w to make new window
            set URL of active tab of w to "\(literal)"
            set b to bounds of w
            set ww to (item 3 of b) - (item 1 of b)
            set wh to (item 4 of b) - (item 2 of b)
            if ww > \(area.w) then set ww to \(area.w)
            if wh > \(area.h) then set wh to \(area.h)
            set l to \(area.x) + (\(area.w) - ww) div 2
            set t to \(area.y) + (\(area.h) - wh) div 2
            set bounds of w to {l, t, l + ww, t + wh}
            activate
        end tell
        """
    }
}

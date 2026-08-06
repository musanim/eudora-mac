import AppKit

/// Runs an `NSAlert` positioned at the pointer instead of in the middle of the
/// screen.
///
/// Every caller is a dialog reached from a **right-click** — Delete PERMANENTLY,
/// the blacklist confirmation, and the New Mailbox / Rename prompts. Opening those
/// centre-screen means leaving the place you were working, clicking, and coming
/// back. Same reasoning the mailbox context menu's pointer-centring already
/// carries: the axis that matters is how far the eye and the hand have to travel.
///
/// ## Two attempts that look correct and do nothing
///
/// **Setting the frame before running does nothing** (2026aug05): `alert.layout()`,
/// `setFrameOrigin`, then run — the panel appeared in AppKit's default spot
/// regardless. `NSAlert` positions its own panel when the panel is *shown*, which
/// is after any frame we set, so the assignment is overwritten. That also retired
/// a first version's use of `NSApp.runModal(for:)`, which was there only to bypass
/// a centring it turned out not to bypass; this uses the documented
/// `alert.runModal()`, which also closes the panel for us.
///
/// **A queued main-queue block wasn't enough either.** Still AppKit's default —
/// horizontally centred on the display, about 30% down. The block *does* run
/// during the modal session, but before the panel is displayed, so `NSAlert` still
/// went last. What identified this was *where* the panel landed: the default
/// position means nothing had moved it, as opposed to something having moved it
/// wrongly.
///
/// `didBecomeKeyNotification` fires once the panel is on screen, and therefore
/// after `NSAlert`'s own positioning. That is the hook that works.
///
/// ## Anchoring
///
/// The panel is placed so the centre of an **anchor view** lands on the pointer,
/// defaulting to `alert.buttons.first` — the action button, since
/// `addButton(withTitle:)` adds right to left. For a confirmation that is the only
/// thing anyone came to click.
///
/// **The offset is read from the view, never computed.** Anchoring the panel's
/// centre, and then its lower-right corner, were both slightly off, and
/// necessarily so: a screenshot showed the pointer sitting *outside* the visible
/// rounded panel, so the window frame carries shadow margin beyond what is drawn,
/// on top of `NSAlert`'s own unpublished padding. Converting the view's bounds to
/// window coordinates asks AppKit where it actually put it, which stays exact
/// across a taller message, a wider button, or a localisation.
///
/// The arithmetic: a point in window coordinates plus the window's origin is that
/// point on screen, so putting the anchor's centre at `pointer` means an origin of
/// `pointer - anchorCentreInWindow`. `NSWindow` origins are bottom-left, screen y
/// grows upward, and window coordinates share that convention, so both axes are
/// the same subtraction with no flip.
///
/// **A text-entry prompt should pass its field, not use the default.** The New
/// Mailbox and Rename dialogs make their action button the default and put first
/// responder in the field, so the gesture is *type, Return* — the button is never
/// clicked, and centring it on the pointer would aim at the one control the hand
/// doesn't want. Their field is the thing the eye goes to.
///
/// ## Deliberate non-choices
///
/// Not hidden and un-hidden around the move, which would remove any flash of the
/// default position. If the hook ever failed to fire, an `alphaValue` of 0 would
/// leave an invisible modal dialog and an app that looks hung, where the worst
/// this version does is show the alert somewhere unhelpful. Now that the hook is
/// known to fire, that trick is available if a flash is ever noticed.
///
/// **Not `@MainActor`, and that is load-bearing.** Everything here is main-thread
/// UI, but the two hooks below call into it from a `DispatchQueue.main.async` block
/// and a `NotificationCenter` observer on `.main`. Neither carries actor isolation
/// the Swift 5.7 compiler can see, so annotating this type would make both call
/// sites errors with no clean fix available on this toolchain.
enum PointerAlert {
    /// Off, and intact. It is what would say **which of the two hooks below
    /// actually does the work** — never captured, because the build that added the
    /// trace also fixed the behaviour. So both hooks are kept deliberately rather
    /// than out of neglect: they are idempotent, one is very likely redundant, and
    /// one run with this on would settle which to delete.
    static let traceEnabled = false

    /// - Parameter anchor: the view to centre on the pointer. Defaults to the
    ///   alert's action button; pass a text field for a prompt.
    static func runModal(_ alert: NSAlert, anchor: NSView? = nil) -> NSApplication.ModalResponse {
        // Sampled now, before the loop, not inside the hooks: by the time they run
        // the hand may have moved, and the point is where it was when the menu item
        // was chosen.
        let pointer = NSEvent.mouseLocation
        let window = alert.window

        // Hook 1: the main queue. Kept because if this is the one that runs too
        // early, that is worth being able to see rather than assume.
        DispatchQueue.main.async {
            place(alert, anchor: anchor, near: pointer, via: "queued")
        }

        // Hook 2: after the panel is key, hence after it has been displayed and
        // after `NSAlert` has positioned it. This is the one that sticks.
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in
            place(alert, anchor: anchor, near: pointer, via: "didBecomeKey")
        }
        defer { NotificationCenter.default.removeObserver(token) }

        return alert.runModal()
    }

    private static func place(_ alert: NSAlert, anchor: NSView?,
                              near pointer: NSPoint, via: String) {
        let window = alert.window
        // Forced before any geometry is read: view frames are only meaningful once
        // the alert has laid out, and one of the two hooks runs before the panel is
        // displayed. This also installs the accessory view, which is where a
        // prompt's anchor lives.
        alert.layout()
        let was = window.frame.origin
        let target = origin(for: alert, anchor: anchor, near: pointer)
        window.setFrameOrigin(target)
        guard traceEnabled else { return }
        // `isVisible` is the discriminator: a hook that fires before the panel is on
        // screen is one whose frame `NSAlert` is about to overwrite.
        print("[alertpos] \(via)  visible \(window.isVisible)"
              + "  was \(was)  asked \(target)  now \(window.frame.origin)")
    }

    /// Clamped to the screen the pointer is on, so a right-click near an edge — or
    /// on a second display — can't put the panel where it cannot be reached.
    /// `visibleFrame` rather than `frame`: it excludes the menu bar and the Dock.
    /// Clamping is the one case where the anchor will *not* be under the pointer,
    /// and being reachable matters more.
    private static func origin(for alert: NSAlert, anchor: NSView?,
                               near pointer: NSPoint) -> NSPoint {
        let window = alert.window
        let size = window.frame.size
        var origin: NSPoint

        // `window != nil` is the check that matters, not nil-ness of the view: a
        // view outside the window hierarchy converts to meaningless coordinates,
        // and silently placing the panel by them would look like the padding bugs
        // this whole helper exists to stop guessing at.
        let target = anchor ?? alert.buttons.first
        if let target, target.window != nil {
            let inWindow = target.convert(target.bounds, to: nil)
            origin = NSPoint(x: pointer.x - inWindow.midX, y: pointer.y - inWindow.midY)
        } else {
            // Lower-right corner at the pointer. Not a case `NSAlert` produces here,
            // but it keeps this total rather than crashing or centring.
            origin = NSPoint(x: pointer.x - size.width, y: pointer.y)
        }

        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        }
        return origin
    }
}

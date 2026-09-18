import SwiftUI
import AppKit

/// The contents of one compose window: the editor for a single draft, plus the
/// machinery for closing it.
///
/// Thin on purpose. `ComposeView` is the editor and knows nothing about windows;
/// this wraps it with the two things a *window* needs that a sheet didn't — a
/// title, and a way to intercept the close button.
struct ComposeWindow: View {
    /// Scene id, in one place so the scene and everything that opens it agree.
    static let groupID = "compose"

    @EnvironmentObject var model: AppModel
    let draftID: ComposeDraft.ID?

    var body: some View {
        Group {
            if let draftID, let draft = model.openDrafts[draftID] {
                ComposeView(draftID: draftID, seed: draft)
                    // Ties the editor's `@State` to this draft. Without it,
                    // SwiftUI could reuse one window's view state for a
                    // different draft and you would find yourself typing into
                    // the wrong message.
                    .id(draftID)
                    .navigationTitle(title(for: draft))
            } else {
                // A compose window with no draft behind it. Say so plainly
                // rather than showing an editor bound to nothing.
                //
                // This used to blame state restoration, and that was wrong.
                // 2026sep14: the real source is SwiftUI satisfying an *external
                // event* — a `mailto:` arriving at the running app — by opening
                // a window from a group with no value. It showed up here only
                // while the main group was refusing those events, which is a
                // change that has since been reverted; see the note beside
                // `.commands` in `EudoraApp` and the sep14 entry in
                // EudoraDevelopmentNotes.txt. Not fixed yet, so this
                // placeholder still earns its place.
                VStack(spacing: 8) {
                    Text("This message is no longer open.")
                        .foregroundStyle(.secondary)
                    Text("Unsent messages are kept in Out; "
                            + "double-click one there to go on editing it.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(minWidth: 380, minHeight: 160)
                .padding(24)
            }
        }
        // Puts the window on the same display as the main window when the frame
        // SwiftUI restored lands on a different one. See the type.
        .background(ComposeWindowPlacer())
    }

    /// The saved subject, or "New Message". Doesn't track what's being typed —
    /// the live subject is the editor's own `@State` and this only sees what has
    /// been written back to the model, so the title settles on save.
    private func title(for draft: ComposeDraft) -> String {
        draft.subject.trimmingCharacters(in: .whitespaces).isEmpty
            ? "New Message" : draft.subject
    }
}

/// Runs a check before a window is allowed to close.
///
/// **Why a proxy delegate.** `windowShouldClose` is the only hook that can stop
/// a close, and SwiftUI owns the window's delegate — assigning our own would
/// break whatever SwiftUI does with it. So this installs an object that
/// implements *only* `windowShouldClose` and forwards every other message to
/// SwiftUI's delegate through `forwardingTarget(for:)`, the ObjC runtime's own
/// mechanism for exactly this.
///
/// The check returns false to hold the window open — the compose editor uses
/// that to put up its Save prompt and then closes the window itself once the
/// user has answered.
struct WindowCloseGuard: NSViewRepresentable {
    /// Return true to let the window close, false to stop it.
    let shouldClose: () -> Bool

    /// Handed the window once it's found, so the view can close it the same way
    /// the title-bar button does.
    ///
    /// `dismiss()` is not good enough: `NSWindow.close()` does not consult
    /// `windowShouldClose`, and SwiftUI's dismissal is unconditional. A footer
    /// Close — or Escape, which shares its shortcut — would then skip the Save
    /// prompt entirely and silently discard the edits. Going through
    /// `performClose(_:)` makes every route identical.
    final class WindowHandle {
        weak var window: NSWindow?
    }
    let handle: WindowHandle

    final class Coordinator {
        var shouldClose: () -> Bool = { true }
        weak var view: NSView?
        var guardDelegate: CloseProxy?
        /// The window we installed on, so teardown can put things back.
        weak var installedOn: NSWindow?

        deinit {
            // Restore SwiftUI's delegate. Leaving ours in place on a window
            // that outlived this view would keep answering for a draft that no
            // longer exists.
            if let window = installedOn, window.delegate === guardDelegate {
                window.delegate = guardDelegate?.original
            }
        }
    }

    /// Implements `windowShouldClose` and passes everything else along.
    final class CloseProxy: NSObject, NSWindowDelegate {
        /// Strong, deliberately. `NSWindow.delegate` is a weak reference, so
        /// once we take the slot nothing else retains SwiftUI's delegate — and
        /// if it deallocated, every message we forward would vanish.
        var original: NSWindowDelegate?
        var shouldClose: () -> Bool = { true }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            // Ask SwiftUI's delegate first if it has an opinion, so this only
            // ever adds a veto rather than overriding one.
            if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
               original.windowShouldClose?(sender) == false {
                return false
            }
            return shouldClose()
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if aSelector == #selector(NSWindowDelegate.windowShouldClose(_:)) { return true }
            return super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if original?.responds(to: aSelector) == true { return original }
            return super.forwardingTarget(for: aSelector)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        // Refreshed every pass — the closure captures the editor's current
        // state, and a stale one would answer from whenever it was installed.
        coordinator.shouldClose = shouldClose
        coordinator.guardDelegate?.shouldClose = shouldClose
        coordinator.view = nsView

        // Re-take the slot if something replaced us. SwiftUI reassigns
        // `window.delegate` on some scene updates, and a guard silently dropped
        // means every close prompt silently stops appearing — a failure with no
        // symptom other than lost work.
        if let proxy = coordinator.guardDelegate,
           let window = coordinator.installedOn, window.delegate !== proxy {
            proxy.original = window.delegate
            window.delegate = proxy
            return
        }

        // The window isn't there on the first pass; retry until it is.
        guard coordinator.guardDelegate == nil else { return }
        DispatchQueue.main.async {
            install(coordinator: coordinator, attemptsLeft: 20)
        }
    }

    @MainActor
    private func install(coordinator: Coordinator, attemptsLeft: Int) {
        guard coordinator.guardDelegate == nil else { return }
        guard let window = coordinator.view?.window else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    install(coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }
        let proxy = CloseProxy()
        proxy.original = window.delegate
        proxy.shouldClose = coordinator.shouldClose
        window.delegate = proxy
        coordinator.guardDelegate = proxy
        coordinator.installedOn = window
        handle.window = window
    }
}

/// Opens a compose window on the same display as the main window.
///
/// **Why this is needed.** SwiftUI restores a `WindowGroup`'s remembered frame,
/// and that frame is stored in absolute screen coordinates together with the
/// screen it was saved on, so a compose window that was on another display when
/// it closed reopens there — however far that is from the window being worked
/// in. Confirmed 2026sep18 by reading the saved frame out of the preferences
/// domain:
///
///     "NSWindow Frame compose-AppWindow-1" = "-1342 831 844 1291
///                                             -2056 831 2056 1291"
///
/// The last four numbers are the screen. Origin `-2056, 831` is the built-in
/// display; the main window and every other saved window named the primary,
/// whose frame begins at `0 0`. What puts it there is `night-mode.lua`, which
/// sweeps compose windows onto the built-in as they appear — and AppKit then
/// saves that frame when the window closes, so one night teaches every later
/// reply to open on the wrong display.
///
/// **This does not cure the cause, and is not meant to.** Night mode still
/// sweeps, and AppKit still saves the swept frame, so the bad frame is re-learnt
/// every night and corrected again the next morning. What makes that stable
/// rather than a running battle is that moving the window *rewrites* the
/// autosave — `setFrame` posts `windowDidMove`, SwiftUI saves — so one reply
/// puts the remembered frame back on the right display for the rest of the day.
///
/// **The trade, stated plainly.** Because the policy is unconditional, a
/// compose window deliberately parked on a second display does not stay there:
/// the next reply is pulled to the main window's display, and the autosave
/// rewrite means that choice is gone from disk, not merely from this window.
/// Turn `followsMainWindowDisplay` off if that is ever the preferred behaviour.
/// What *is* preserved: the remembered size, always; and the remembered
/// position whenever it was already on the main window's display, since nothing
/// happens at all in that case. A window moved by hand after it opens is never
/// moved again, because each window is placed once.
struct ComposeWindowPlacer: NSViewRepresentable {
    /// Master switch. With this false the app behaves as it did before — which
    /// is how to tell, if compose windows ever land somewhere surprising,
    /// whether this is the cause.
    static let followsMainWindowDisplay = true

    /// Logs each window it moves, and each one it deliberately leaves alone.
    /// On until the behaviour has been watched across a night-mode cycle, which
    /// is the case it exists for.
    static let diagnoseComposePlacement = true

    /// How many windows have been placed, for the cascade. Never reset: the
    /// modulo keeps the offset bounded.
    private static var placements = 0

    private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    final class Coordinator {
        /// Set only on a decision that is final — moved, or deliberately left
        /// alone. "Couldn't tell yet" must not latch, or the window is stranded.
        var placed = false
        /// A deferred hunt for the window is already running; see `attempt`.
        var hunting = false
        weak var view: NSView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard Self.followsMainWindowDisplay else { return }
        let coordinator = context.coordinator
        coordinator.view = nsView
        guard !coordinator.placed else { return }
        if let window = nsView.window {
            place(window, coordinator: coordinator)
        } else if !coordinator.hunting {
            // One chain at a time: `ComposeView` observes the shared `AppModel`,
            // which publishes constantly, so this runs many times before the
            // view has a window. Same guard as `MainWindowAccessor.updateNSView`
            // — `WindowCloseGuard` below lacks it and starts a chain per pass.
            coordinator.hunting = true
            DispatchQueue.main.async { attempt(coordinator: coordinator, attemptsLeft: 20) }
        }
    }

    /// The deferred half, retried rather than attempted once: `view.window` is
    /// nil on the first pass — recorded three times over in this codebase, at
    /// `WindowCloseGuard.install`, `MainWindowAccessor.retryAttach` and
    /// `RichTextEditor` — so a single missed hop would leave the window where
    /// SwiftUI put it.
    ///
    /// It keeps running while `place` declines to latch, which is what covers
    /// the harder race: a `mailto:` at cold launch can reach here before
    /// `ContentView` has told `MainWindowAccessor` which window is the main one.
    @MainActor
    private func attempt(coordinator: Coordinator, attemptsLeft: Int) {
        guard !coordinator.placed else { coordinator.hunting = false; return }
        if let window = coordinator.view?.window {
            place(window, coordinator: coordinator)
            if coordinator.placed { coordinator.hunting = false; return }
        }
        guard attemptsLeft > 0 else { coordinator.hunting = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            attempt(coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Which physical display a screen is, by `CGDirectDisplayID`.
    ///
    /// **Not `===`.** AppKit rebuilds its `NSScreen` objects across display
    /// reconfiguration and sleep/wake, so instance identity is a statement about
    /// timing rather than about displays. Getting it wrong here is not benign:
    /// a false "different display" re-centres a window that was already right,
    /// discarding a position chosen by hand. `night-mode.lua` already compares
    /// by `id()` and keys saved frames off `getUUID()`, for the same reason.
    private func displayID(_ screen: NSScreen?) -> CGDirectDisplayID? {
        guard let screen else { return nil }
        return (screen.deviceDescription[Self.screenNumberKey] as? NSNumber)?.uint32Value
    }

    @MainActor
    private func place(_ window: NSWindow, coordinator: Coordinator) {
        // No main window yet means "ask again", not "leave it": latching here
        // would strand the window on the wrong display for its whole life.
        guard let home = MainWindowAccessor.resolved?.screen, let homeID = displayID(home) else {
            return
        }
        coordinator.placed = true

        // `window.screen` is nil when the window is off every display, which is
        // a case to move rather than to skip — hence comparing ids, either of
        // which may be nil, rather than requiring a screen.
        if displayID(window.screen) == homeID {
            if Self.diagnoseComposePlacement {
                eudoraDiag("[compose] already on the main window's display; not moved")
            }
            return
        }

        move(window, onto: home)

        // One verification a turn later, in case SwiftUI applies its restored
        // frame *after* this runs. Once, not a loop: if it can win twice it can
        // win forever, and a fight between two frame-setters is worse than a
        // window in the wrong place.
        DispatchQueue.main.async {
            guard displayID(window.screen) != homeID else { return }
            if Self.diagnoseComposePlacement {
                eudoraDiag("[compose] the restored frame came back; placing again")
            }
            move(window, onto: home)
        }
    }

    @MainActor
    private func move(_ window: NSWindow, onto home: NSScreen) {
        let visible = home.visibleFrame
        let was = window.frame
        var frame = was
        frame.size.width  = min(frame.width,  visible.width)
        frame.size.height = min(frame.height, visible.height)

        // Centred, then stepped down and right once per window placed, so two
        // replies opened in a row don't land exactly on top of each other.
        let step = CGFloat(Self.placements % 5) * 26
        Self.placements += 1
        frame.origin = CGPoint(x: visible.midX - frame.width / 2 + step,
                               y: visible.midY - frame.height / 2 - step)
        frame = clamped(frame, to: visible)

        // `display: false`: this can run from inside SwiftUI's own update pass,
        // and forcing a synchronous draw from there is a re-entrancy nobody
        // needs. AppKit redraws on the next pass regardless.
        window.setFrame(frame, display: false)

        // AppKit refuses to go below the window's `contentMinSize` —
        // `ComposeView` sets a 580x540 minimum — so on a display smaller than
        // that the size clamp above is quietly ignored and the origin computed
        // for it is wrong. Re-clamp against what the window actually became.
        let settled = clamped(window.frame, to: visible)
        if settled != window.frame { window.setFrame(settled, display: false) }

        if Self.diagnoseComposePlacement {
            eudoraDiag("[compose] moved from \(NSStringFromRect(was)) "
                       + "to \(NSStringFromRect(window.frame)) "
                       + "on the main window's display \(NSStringFromRect(visible))")
        }
    }

    /// Slides `frame` until it lies inside `visible`, as far as its size allows.
    /// A window wider or taller than the display is left flush with the low
    /// edge, which is the least bad of the available wrong answers.
    private func clamped(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var f = frame
        f.origin.x = max(visible.minX, min(f.minX, visible.maxX - f.width))
        f.origin.y = max(visible.minY, min(f.minY, visible.maxY - f.height))
        return f
    }
}

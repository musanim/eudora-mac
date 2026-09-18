import SwiftUI
import AppKit
import CoreGraphics   // CGDisplayIsBuiltin

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
        // Puts the window on the display it ought to open on, when Stephen's
        // night-mode placement is switched on in Settings. See the type.
        .background(ComposeWindowPlacer(enabled: model.nightModeComposePlacement))
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

/// Opens a compose window on the display it ought to open on.
///
/// **Off unless `AppModel.nightModeComposePlacement` is on**, which it is not by
/// default. With it off this does nothing whatever and SwiftUI's remembered
/// frame stands — stock macOS behaviour, and the right behaviour for anyone
/// running the shared build on one display.
///
/// **The rule, when it is on**, which is Stephen's and is deliberately not
/// "follow the main window":
///
/// - Main window on the **built-in** display — in practice night mode, when
///   `night-mode.lua` has moved it there and blacked out the externals, but the
///   test is the display and not the mode, so an undocked laptop or a window
///   dragged there by hand gets the same answer — the composer opens there too,
///   because that is the only screen he can see.
/// - Main window **anywhere else** — the composer opens centred on the
///   **primary** display, whichever display the main window is on, because the
///   primary is where he edits.
///
/// **Every new compose window, every time** — not only the ones arriving from
/// the wrong display. A remembered frame on the right display is no better than
/// one on the wrong display: it is wherever the last composer happened to be
/// dragged to, and a reply is a transient thing that should appear where the
/// eyes already are.
///
/// A window that is *already open* is a different case, and is never touched: a
/// window is placed once, and `openWindow(id:value:)` brings an existing
/// composer forward rather than opening a second, so a draft being edited in a
/// window moved somewhere deliberately stays exactly where it was put.
///
/// **Why it is needed at all.** SwiftUI restores a `WindowGroup`'s remembered
/// frame, stored in absolute screen coordinates together with the screen it was
/// saved on, so a compose window that was on another display when it closed
/// reopens there. Confirmed 2026sep18 by reading the saved frame out of the
/// preferences domain:
///
///     "NSWindow Frame compose-AppWindow-1" = "-1342 831 844 1291
///                                             -2056 831 2056 1291"
///
/// The last four numbers are the screen. Origin `-2056, 831` is the built-in
/// display; the main window and every other saved window named the primary,
/// whose frame begins at `0 0`. What puts it there is `night-mode.lua`, which
/// sweeps compose windows onto the built-in as they appear — and the move posts
/// `windowDidMove`, on which SwiftUI saves the frame, so one night teaches every
/// later reply to open on the wrong display.
///
/// **This does not cure the cause, and is not meant to.** Night mode still
/// sweeps, and AppKit still saves the swept frame, so the bad frame is re-learnt
/// every night. What makes that stable rather than a running battle is that
/// moving the window *rewrites* the autosave — `setFrame` posts `windowDidMove`,
/// SwiftUI saves — so the first reply of the day puts the remembered frame back
/// where it belongs and the rest of the day is undisturbed. The same mechanism
/// is why the remembered frame is of no use to a new window anyway: it is
/// rewritten by every placement, so it only ever records where the last
/// composer was put.
struct ComposeWindowPlacer: NSViewRepresentable {
    /// `AppModel.nightModeComposePlacement`, handed in by `ComposeWindow`.
    let enabled: Bool

    /// Logs the screen census, every window it places and which of the two rules
    /// decided, and every window it gives up on. On until the behaviour has been
    /// watched across a night-mode cycle, which is the case it exists for.
    static let diagnoseComposePlacement = true

    /// The composers this has placed, weakly, for the cascade.
    ///
    /// Counting the ones still on screen rather than the ones ever placed is
    /// what makes a single reply land *exactly* centred, which is the point of
    /// the feature; the step only appears when a new window would otherwise
    /// cover one that is already up.
    private static var placedWindows: [WeakWindow] = []

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    /// How many placed composers other than `window` are on screen now.
    ///
    /// Only dead entries are removed. `isVisible` is false while a window is
    /// minimised *and* while the whole app is hidden (⌘H), so pruning on it
    /// would strike live windows off the list for good — and nothing ever puts
    /// one back, so the next composer but one would land exactly on top of a
    /// restored window. Filter on it; delete on `nil`.
    @MainActor
    private static func liveCount(excluding window: NSWindow) -> Int {
        placedWindows.removeAll { $0.window == nil }
        return placedWindows.filter { $0.window !== window && $0.window?.isVisible == true }.count
    }

    /// The screen census is written once per run, not once per window.
    private static var loggedScreens = false

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
        let coordinator = context.coordinator
        coordinator.view = nsView
        guard !coordinator.placed else { return }
        // Off is a decision, and it is made once per window. Without the latch,
        // ticking the box in Settings re-evaluates every open composer's body
        // and yanks them all to the primary — including ones deliberately put
        // somewhere, whose positions the autosave rewrite would then erase. The
        // switch is for windows opened after it, not for windows already up.
        guard enabled else { coordinator.placed = true; return }
        if let window = nsView.window {
            place(window, coordinator: coordinator)
        } else if !coordinator.hunting {
            // One chain at a time: `ComposeView` observes the shared `AppModel`,
            // which publishes constantly, so this runs many times before the
            // view has a window. Same guard as `MainWindowAccessor.updateNSView`
            // — `WindowCloseGuard` below lacks it and starts a chain per pass.
            coordinator.hunting = true
            DispatchQueue.main.async { attempt(coordinator: coordinator, attemptsLeft: 40) }
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
        guard attemptsLeft > 0 else {
            // Two seconds without an answer is an answer. `place` deliberately
            // declines to latch while it cannot tell, and the main window has no
            // screen while it is minimised — so without this the chain ends, the
            // next `AppModel` publish starts another, and a composer opened over
            // a minimised main window retries for as long as it is open. Giving
            // up leaves the window where SwiftUI put it, which is the same
            // outcome, said once and logged.
            coordinator.hunting = false
            coordinator.placed = true
            if Self.diagnoseComposePlacement {
                // Two different failures reach here and they are not the same
                // news, so say which. The first is ordinary — SwiftUI builds
                // compose scenes it never shows — and the second is not.
                eudoraDiag(coordinator.view?.window == nil
                    ? "[compose] gave up after ~2 s: this view never got a window, "
                      + "so there was nothing to place"
                    : "[compose] gave up after ~2 s: could not tell which display the "
                      + "main window is on (minimised, or mid-reconfiguration); "
                      + "left where SwiftUI put it")
            }
            return
        }
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

    /// The display that carries the menu bar and the Dock: the one at the origin.
    ///
    /// Not `NSScreen.main`, which is the screen of the *key* window and so moves
    /// about with the focus — it would name whichever display the composer had
    /// just appeared on, which is the question, not the answer. `NSScreen.screens`
    /// is documented to put the origin screen first; the origin test is what is
    /// actually being asked, so it is asked, with the documented order as the
    /// fallback.
    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    /// The display this composer should open on, or nil while that can't be
    /// decided — which is a reason to ask again, never a reason to give up.
    ///
    /// `CGDisplayIsBuiltin`, not the display's name: `night-mode.lua` matches
    /// the string "Built-in Retina Display", which is localized and has changed
    /// across macOS releases. The two could therefore disagree one day, and it
    /// is the Lua that would be wrong.
    @MainActor
    private func target() -> (screen: NSScreen, rule: String)? {
        guard let home = MainWindowAccessor.resolved?.screen else { return nil }
        if let id = displayID(home), CGDisplayIsBuiltin(id) != 0 {
            return (home, "the main window is on the built-in, so the composer follows")
        }
        // The rule is carried out of here rather than re-derived from the answer.
        // Asking "is the target the built-in?" afterwards gets it wrong with the
        // laptop undocked, where the built-in *is* the primary: the placement
        // would be right and the log would name the wrong reason, in exactly the
        // display arrangement the log is on to observe.
        guard let primary = primaryScreen() else { return nil }
        return (primary, "centred on the primary")
    }

    /// Every screen, once per run: id, frame, visible frame, whether Core
    /// Graphics calls it built-in, and its name — plus which one the main window
    /// is on. Without it the log names a display only by its visible frame, and
    /// "centred on the primary" has to be taken on trust — which is one
    /// inference too many when the open question is whether `primaryScreen()`
    /// picks the display Stephen means.
    @MainActor
    private func logScreens() {
        guard Self.diagnoseComposePlacement, !Self.loggedScreens else { return }
        Self.loggedScreens = true
        for screen in NSScreen.screens {
            let id = displayID(screen)
            eudoraDiag("[compose] screen \(id.map(String.init) ?? "?") "
                       + "\u{201C}\(screen.localizedName)\u{201D} "
                       + "frame \(NSStringFromRect(screen.frame)) "
                       + "visible \(NSStringFromRect(screen.visibleFrame)) "
                       + "builtin=\(id.map { CGDisplayIsBuiltin($0) != 0 } ?? false)")
        }
        let primary = displayID(primaryScreen()).map(String.init) ?? "?"
        let home = displayID(MainWindowAccessor.resolved?.screen).map(String.init) ?? "none"
        eudoraDiag("[compose] primary is display \(primary); "
                   + "the main window is on display \(home)")
    }

    @MainActor
    private func place(_ window: NSWindow, coordinator: Coordinator) {
        logScreens()
        // No main window yet, or no screens, means "ask again", not "leave it":
        // latching here would strand the window on the wrong display. `attempt`
        // is what eventually gives up, after two seconds.
        guard let (screen, rule) = target() else { return }
        coordinator.placed = true

        // The cascade slot is taken once, before the move, so the verification
        // below re-asserts the *same* frame rather than sliding the window along.
        let step = CGFloat(Self.liveCount(excluding: window) % 5) * 26
        Self.placedWindows.append(WeakWindow(window))
        let settled = move(window, onto: screen, step: step, rule: rule)

        // One verification a turn later, on the whole frame rather than just
        // the display: the race it exists for — SwiftUI applying the restored
        // frame after this runs — usually moves the window *within* the right
        // display, which a display check would miss entirely.
        //
        // It also fires when SwiftUI merely settles the window's size a turn
        // late, which is not that race at all; re-centring at the size it
        // settled on is the right answer either way, so the guard is left broad
        // and the log says only what it saw. Once, not a loop: if something can
        // win twice it can win forever, and a fight between two frame-setters is
        // worse than a window in the wrong place.
        DispatchQueue.main.async {
            guard window.frame != settled else { return }
            if Self.diagnoseComposePlacement {
                eudoraDiag("[compose] the frame changed after placement "
                           + "(\(NSStringFromRect(settled)) → "
                           + "\(NSStringFromRect(window.frame))); centring again")
            }
            _ = move(window, onto: screen, step: step, rule: rule)
        }
    }

    @MainActor
    /// Returns the frame the window actually ended up with, which is what the
    /// verification in `place` compares against — `setFrame` does not always
    /// grant what it is asked for.
    @discardableResult
    private func move(_ window: NSWindow, onto target: NSScreen,
                      step: CGFloat, rule: String) -> NSRect {
        let visible = target.visibleFrame
        let was = window.frame
        var frame = was
        frame.size.width  = min(frame.width,  visible.width)
        frame.size.height = min(frame.height, visible.height)

        // Centred, then stepped down and right once per window placed, so two
        // replies opened in a row don't land exactly on top of each other.
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
                       + "on \(NSStringFromRect(visible)) — \(rule)"
                       + (step > 0 ? "; stepped \(Int(step)) pt clear of another composer" : ""))
        }
        return window.frame
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

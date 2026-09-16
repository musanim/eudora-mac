import AppKit
import SwiftUI      // MainWindowAccessor, at the bottom of this file

/// The launch splash: Eudora 7's own about-box art, on screen for as long as
/// opening the tree takes (about 6–7 seconds on a large archive).
///
/// It's an `NSWindow` created directly rather than a SwiftUI overlay because of
/// *when* it has to appear. Opening the tree runs synchronously on the main
/// thread, and while it does, SwiftUI can't draw — an overlay inside the main
/// window would only become visible once the wait it's meant to cover had
/// already ended.
///
/// **Timing matters, and getting it wrong is not subtle.** Earlier versions
/// created this window in `App.init`, and then in an `NSApplicationDelegate`'s
/// `applicationDidFinishLaunching` — before or during SwiftUI's scene setup.
/// Both stopped the main window from ever appearing, with no console output at
/// all: SwiftUI never built the scene. Forcing a `CATransaction.flush()` that
/// early is the likely trigger. So nothing here runs at launch except `arm()`,
/// which only registers an observer.
///
/// The sequence is:
///
/// 1. `App.init` calls `arm()`.
/// 2. AppKit creates SwiftUI's window and, before it paints, sends
///    `didUpdate` — `mainWindowDidAppear` hides it (alpha 0) and puts the
///    splash up in its place, centered on it.
/// 3. `ContentView.onAppear` starts the open a beat later.
/// 4. `hide()` reveals the window once the listing is built (AppModel).
///
/// Not `@MainActor`: the notification arrives in a closure that
/// isn't actor-isolated, and hopping to the main actor to handle it would cost
/// the very runloop turn this is trying to save — the window paints during it.
/// Every call site is on the main thread already (App.init, AppModel, the
/// representable, and a notification delivered on `.main`).
enum SplashWindow {
    /// Master switch. With this false nothing here creates a window and
    /// `hide()` is a no-op, so the app behaves exactly as it did before the
    /// splash existed — which is how the window-never-appears bug was pinned on
    /// this file. Worth keeping for the next such question.
    // Ruled out as the cause of the second main window on 2026sep14: with this
    // false, two main windows still appeared. Worth recording, because creating
    // a borderless NSWindow during SwiftUI's own window-creation pass — and
    // hiding the main window with alphaValue — is a fair suspect on its face.
    static let enabled = true

    private static var window: NSWindow?

    /// Watches for SwiftUI's window being created (see `arm`).
    private static var windowWatcher: NSObjectProtocol?

    /// The main window, hidden while the tree opens. It's held rather than
    /// re-found so that whatever `show()` hid is exactly what `hide()` reveals.
    private static weak var hiddenMainWindow: NSWindow?

    /// Starts watching for SwiftUI's window, from `App.init`.
    ///
    /// This is deliberately the *only* thing done at launch, and it touches no
    /// AppKit object: it registers a notification observer, nothing more.
    /// Creating an `NSWindow` this early (an earlier attempt) stopped SwiftUI
    /// from ever building its scene.
    ///
    /// `didUpdateNotification` is the earliest practical sighting of a window.
    /// AppKit sends update messages after processing events and *before* the
    /// run loop sleeps — which is when CoreAnimation commits — so hiding the
    /// window here happens before its first paint reaches the screen. That's the
    /// difference from hiding it in `onAppear`, by which time SwiftUI has
    /// already shown an empty window for a frame.
    static func arm() {
        guard enabled, windowWatcher == nil else { return }
        windowWatcher = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { note in
            guard let candidate = note.object as? NSWindow else { return }
            // Synchronously — see the type's note on isolation.
            mainWindowDidAppear(candidate)
        }
    }

    /// Stop watching, without showing or hiding anything.
    ///
    /// For a duplicate instance, which is about to `exit(0)` and must put nothing
    /// on screen. `arm()` has already run by then — it happens in `App.init`,
    /// before any delegate callback — and the duplicate pumps the run loop while
    /// it waits for a launch URL, which is enough for a window sighting to reach
    /// the observer above and flash a splash up from a process that is leaving.
    /// See `AppDelegate.applicationWillFinishLaunching`.
    ///
    /// Distinct from `hide()`: that one is the end of a splash that was shown, so
    /// it sets `hasRun` and reveals the hidden main window. Here there is no
    /// splash and no hidden window, and nothing should be revealed.
    static func disarm() {
        if let windowWatcher = windowWatcher {
            NotificationCenter.default.removeObserver(windowWatcher)
        }
        windowWatcher = nil
    }

    /// Puts the splash on screen immediately. Safe to call more than once.
    static func show() {
        guard enabled, !hasRun else { return }
        // Loaded as a loose bundle resource (see `project.yml`), not from the
        // asset catalog: the source PNG in `assets/` is copied straight into the
        // bundle, so there is one file and no imageset copy to drift out of sync.
        guard window == nil,
              let url = Bundle.main.url(forResource: "EudoraSplash8", withExtension: "png"),
              let art = NSImage(contentsOf: url) else { return }

        let size = art.size
        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless],
                             backing: .buffered,
                             defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        // Not in the window menu or ⌘` cycling, and it shouldn't keep the app
        // alive or steal focus from the main window as it opens.
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.transient, .ignoresCycle]

        panel.isReleasedWhenClosed = false      // we only ever orderOut

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = art
        imageView.imageScaling = .scaleNone
        imageView.autoresizingMask = [.width, .height]
        // The art is 1x only, so a Retina display upscales it 2x. Nearest-
        // neighbour keeps Eudora's pixels crisp instead of blurring them; a
        // dedicated 2x image would be sharper still, if one can be had.
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest
        panel.contentView = imageView

        window = panel

        // Center over the main window and hide it for the duration. SwiftUI has
        // already put it on screen by now, but it can't be used until the tree
        // is open, so showing a half-built window is worse than showing none.
        //
        // Hiding is done with alphaValue rather than orderOut: the window stays
        // in the window list and keeps its key status, so nothing has to be
        // restored afterwards and SwiftUI's window management isn't disturbed.
        if let main = knownMainWindow {
            center(panel, over: main)
            main.alphaValue = 0
            hiddenMainWindow = main
        } else {
            // The window isn't placed yet; MainWindowAccessor will call
            // mainWindowDidAppear, which hides it and re-centers the splash.
            panel.center()
        }

        panel.orderFrontRegardless()    // no activation, so focus is undisturbed
        panel.display()

        // Backstop: if the open never happens (no scene, an off-screen restore,
        // a failure during setup) the splash would sit there forever. This timer
        // can't fire while the main thread is blocked, so it can never cut a
        // legitimate open short.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { hide() }
    }

    /// The window `MainWindowAccessor` settled on, once it has.
    ///
    /// Held here rather than read from `MainWindowAccessor.resolved` at the
    /// point of use. That type conforms to `NSViewRepresentable`, so it and its
    /// statics are main-actor isolated, and this enum is deliberately not — see
    /// the type's note on isolation. `mainWindowDidAppear(_:resolved:)` is told
    /// instead, from a caller that is already on the main actor.
    private static weak var realMainWindow: NSWindow?

    /// The main window, as reported by `MainWindowAccessor` — never guessed at.
    ///
    /// Scanning `NSApp.windows` was a race: at `onAppear` the real window may
    /// not be placed yet, so the scan found nothing (splash landed in a screen
    /// corner) or found a stand-in that wasn't the window SwiftUI went on to
    /// use (so the wrong window got hidden and the real one appeared underneath
    /// the splash). Which happened varied run to run.
    private static weak var knownMainWindow: NSWindow?

    /// Called by `MainWindowAccessor` as soon as SwiftUI's window exists, and
    /// again whenever it moves or resizes.
    /// - Parameter resolved: `true` only from `MainWindowAccessor.attach`, which
    ///   is where the real main window is identified. It records the window for
    ///   the guard below; every other caller passes `false`.
    static func mainWindowDidAppear(_ main: NSWindow, resolved: Bool = false) {
        if resolved { realMainWindow = main }
        guard enabled, !hasRun else { return }
        // The watcher sees every window, including the splash itself and any
        // panel AppKit puts up; only SwiftUI's real window qualifies.
        guard main !== window, main.styleMask.contains(.titled),
              main.frame.width > 1, main.frame.height > 1 else { return }
        // The watcher armed in `arm()` sees EVERY window in the app, and a
        // `WindowGroup`'s second main window passes the test above. Latching one
        // would hide it at alpha 0 in the real window's place and leave the
        // half-built real window visible beside the splash. So once the accessor
        // has said which window is real, nothing else qualifies.
        //
        // The interval this covers is narrow and real: after `attach` resolves
        // the first window and before `hide()` runs — which
        // `AppModel.splashHeldForRestore` deliberately extends. Before the first
        // `attach` this is inert, which is the cold-launch tie-break noted in
        // `MainWindowAccessor.isExtra`.
        if let real = realMainWindow, main !== real { return }
        knownMainWindow = main

        // First sight of the window is the moment to put the splash up: earlier
        // (from onAppear) there was nothing to center on, so the splash was
        // placed by screen and the bare window was visible beside it until this
        // ran. Creating it here means its first appearance is already correct.
        if window == nil {
            show()
            return
        }

        guard let panel = window else { return }
        if hiddenMainWindow == nil {
            main.alphaValue = 0
            hiddenMainWindow = main
        }
        center(panel, over: main)
    }

    /// True once the splash has been shown and taken down, so a later window
    /// move can't resurrect it.
    private static var hasRun = false

    /// Whether the splash is currently on screen.
    ///
    /// Read by `SettingsWindowState.reopenIfItWasOpen`, which must not open a
    /// window while this is up: the watcher armed in `arm()` treats any new
    /// titled window as the main one, and would either re-centre the splash over
    /// Settings or — if the main window hasn't been identified yet — hide
    /// *Settings* in its place and leave the real main window at alpha 0 for
    /// good.
    static var isShowing: Bool { window != nil }

    private static func center(_ panel: NSWindow, over main: NSWindow) {
        let size = panel.frame.size
        let frame = main.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.midY - size.height / 2))
    }

    /// Takes the splash down and reveals the main window. Safe to call when the
    /// splash was never shown.
    static func hide() {
        hasRun = true
        if let windowWatcher = windowWatcher {
            NotificationCenter.default.removeObserver(windowWatcher)
        }
        windowWatcher = nil
        hiddenMainWindow?.alphaValue = 1
        hiddenMainWindow = nil
        window?.orderOut(nil)
        window = nil
    }
}

/// Reports SwiftUI's own window to `SplashWindow`, rather than having it guess
/// from `NSApp.windows`.
///
/// Attached as a `.background` on ContentView. `view.window` is nil while the
/// view is being made, so the lookup happens on the next runloop turn, and the
/// window's move/resize notifications keep the splash centered if SwiftUI
/// restores a saved frame after the window first appears.
struct MainWindowAccessor: NSViewRepresentable {
    /// The main window, once it exists. Weak: it belongs to AppKit.
    ///
    /// The *first* one also settles which window is real, for `isExtra`.
    static weak var resolved: NSWindow?

    /// Master switch for closing a second main window. With this false the app
    /// behaves exactly as it did before — which is how to tell, if something
    /// odd ever appears around windows, whether this is the cause.
    static let closesExtraWindows = true

    /// Logs each second main window this closes.
    ///
    /// On until the behaviour has been seen working, because "the second window
    /// stopped appearing" is also what a fix that never runs looks like, and
    /// this is what tells the two apart.
    static let diagnoseExtraWindow = true

    /// The extra windows already dismissed, so a second `attach` for one of them
    /// doesn't close it twice.
    ///
    /// A list rather than a single slot: two extra windows at once has not been
    /// observed, but it has not been ruled out either, and one slot would let a
    /// pair ping-pong — each `attach` evicting the other and re-closing it and
    /// re-logging it on every SwiftUI update pass, which would make the
    /// diagnostic below useless exactly when it was needed. Weak boxes rather
    /// than `ObjectIdentifier`, which a later window could reuse the address of.
    private static var dismissed: [WeakWindow] = []

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    /// Records `window` as dismissed, answering whether it was new.
    private static func markDismissed(_ window: NSWindow) -> Bool {
        dismissed.removeAll { $0.window == nil }
        guard !dismissed.contains(where: { $0.window === window }) else { return false }
        dismissed.append(WeakWindow(window))
        return true
    }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    /// Makes the main window's close button quit the app.
    ///
    /// The button is live again (the `.closable` trait it was born with is left
    /// in place, so the red light isn't dimmed), but every route that would
    /// *close* the window — the button, ⌘W, File ▸ Close — is redirected to
    /// `NSApp.terminate`. Closing the mailbox list makes no sense on its own, so
    /// it means Quit; and routing through `terminate` means it goes past the
    /// unsaved-compose-windows review like any other Quit. Non-standard, but
    /// deliberate.
    ///
    /// A `windowShouldClose` delegate, not a dropped trait: the trait would grey
    /// the button out, and we want it to look and act like a real button that
    /// happens to quit. The proxy forwards every other delegate message to
    /// SwiftUI's own delegate, the same pattern `WindowCloseGuard` uses.
    ///
    /// Only this window. `MainWindowAccessor` is attached to `ContentView`
    /// alone; compose and Find windows keep ordinary close behaviour.
    private func installCloseToQuit(_ window: NSWindow, coordinator: Coordinator) {
        if let proxy = coordinator.closeProxy {
            // SwiftUI reassigns the delegate on some scene updates; re-take the
            // slot if it did, so the redirect can't silently fall off.
            if window.delegate !== proxy {
                proxy.original = window.delegate
                window.delegate = proxy
            }
            return
        }
        let proxy = CloseToQuitProxy()
        proxy.original = window.delegate
        window.delegate = proxy
        coordinator.closeProxy = proxy
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Synchronously if the window is already there: an async hop costs a
        // runloop turn, and in that turn the main window is on screen, empty,
        // with the splash still sitting wherever it was first placed. That was
        // visible as a flash of the wrong layout before things corrected.
        if let window = nsView.window {
            attach(window, context: context)
        } else if !context.coordinator.retrying {
            // One chain at a time: SwiftUI updates this representable on every
            // model change, and the shared `AppModel` publishes constantly.
            context.coordinator.retrying = true
            DispatchQueue.main.async {
                retryAttach(nsView, context: context, attemptsLeft: 20)
            }
        }
    }

    /// The deferred half of `updateNSView`, retried rather than attempted once.
    ///
    /// A single hop was enough while this only positioned the splash: if it
    /// missed, the next SwiftUI update tried again and the cost was a misplaced
    /// splash for a moment. It is not enough now that a missed sighting leaves a
    /// second main window on screen until some unrelated model change happens to
    /// drive an update pass. Same shape as `MinimizeKeyStripper.strip` and
    /// `SettingsWindowTracker.attachScrollRecorder`.
    private func retryAttach(_ nsView: NSView, context: Context, attemptsLeft: Int) {
        if let window = nsView.window {
            context.coordinator.retrying = false
            attach(window, context: context)
        } else if attemptsLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                retryAttach(nsView, context: context, attemptsLeft: attemptsLeft - 1)
            }
        } else {
            // Gave up. The next SwiftUI update starts a fresh chain.
            context.coordinator.retrying = false
        }
    }

    private func attach(_ window: NSWindow, context: Context) {
        // Turned away before anything else can take it for the real one.
        if Self.closesExtraWindows, isExtra(window) {
            closeExtra(window)
            return
        }

        // Published for anyone who needs *this* window rather than whichever one
        // AppKit currently considers main. `NSApp.mainWindow` is nil while the
        // app is inactive and during parts of launch — which is exactly when the
        // indexing bar appears and `ContentView` needs to force a relayout.
        Self.resolved = window
        SplashWindow.mainWindowDidAppear(window, resolved: true)
        installCloseToQuit(window, coordinator: context.coordinator)

        guard context.coordinator.observers.isEmpty else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { note in
                guard let moved = note.object as? NSWindow else { return }
                SplashWindow.mainWindowDidAppear(moved)
            }
            context.coordinator.observers.append(token)
        }
    }

    /// Whether SwiftUI has opened a *second* main window.
    ///
    /// It opens one from a `WindowGroup` to satisfy an external event, and a
    /// `mailto:` arriving at a running Eudora is one — the 2026sep03 sighting,
    /// diagnosed 2026sep14. The window exists *before* the URL reaches any
    /// Eudora code, so there is nothing in our own handling to correct, and both
    /// `handlesExternalEvents` spellings were tried and both failed, in opposite
    /// directions. Closing it on sight is what is left. See
    /// EudoraDevelopmentNotes.txt, "The Dock tile, and the mailto: that went
    /// nowhere".
    ///
    /// The test is "we already have one, and it still exists". `resolved` is
    /// weak, but a closed `NSWindow` is deallocated only when
    /// `isReleasedWhenClosed` is set, so a non-nil reference does not by itself
    /// prove the window is alive; `NSApp.windows` holds every window the
    /// application still owns, closed ones included, so this is an existence
    /// test and not a liveness one. That is as much as can be asked for here,
    /// and the asymmetry is what makes it enough: answering `false` wrongly
    /// adopts the new window, which is visible and recoverable, while answering
    /// `true` wrongly would close Eudora's only window and leave the app running
    /// with nothing on screen.
    ///
    /// There is no legitimate second main window to protect: closing the main
    /// window quits the app (`CloseToQuitProxy`), so while the process lives its
    /// window exists. The one shape that would defeat this is SwiftUI destroying
    /// and re-creating the group's window while the old `NSWindow` object is
    /// still retained — impossible while that stays true, and the thing to
    /// re-examine first if it ever stops being.
    ///
    /// **THE COLD-LAUNCH TIE-BREAK, and it is a real hole.** With `resolved`
    /// still nil this answers `false` for everything, so on a launch that builds
    /// more than one window the survivor is simply whichever `attach` ran first.
    /// Nothing checks that it is the window SwiftUI went on to manage — and
    /// `ContentView.onAppear` picks the window whose `openWindow` the model
    /// keeps by a *separate* first-past-the-post race, so the two can disagree
    /// and the disagreement is then permanent. Not fixed because a normal
    /// LaunchServices launch makes exactly one window; the three-window readings
    /// on 2026sep14 were the direct-binary-launch artefact. If a cold launch
    /// ever produces two, fix it here and in `ContentView` together.
    private func isExtra(_ window: NSWindow) -> Bool {
        guard let first = Self.resolved, first !== window else { return false }
        return NSApp.windows.contains { $0 === first }
    }

    /// Takes the second main window off the screen now, and out of existence on
    /// the next run-loop turn.
    ///
    /// Two steps because of who may be calling. `attach` runs either from
    /// `updateNSView` — SwiftUI updating a view that is *inside the window being
    /// closed*, where closing synchronously would tear the hierarchy down
    /// underneath its own caller — or from the deferred hop a turn later, which
    /// is the usual route for a brand-new window. Deferring covers both. The
    /// `orderOut` is what keeps the window from being seen in the meantime; it
    /// will still have been on screen for a turn or so, so expect a flash rather
    /// than a window that never appears.
    ///
    /// `close()`, never `performClose(_:)`: `performClose` consults the window
    /// delegate, and a main window's delegate is `CloseToQuitProxy`, which
    /// answers by quitting Eudora. `close()` asks nobody.
    ///
    /// Note what has deliberately *not* happened by the time this is called:
    /// `resolved` still points at the real window, no `CloseToQuitProxy` was
    /// installed, and no move/resize observers were registered. `SplashWindow`
    /// is not told from here either — though it can still see the window through
    /// the app-wide watcher `arm()` registers, which is why
    /// `mainWindowDidAppear` has its own check against `resolved`.
    private func closeExtra(_ window: NSWindow) {
        // `attach` can run more than once for the same window — SwiftUI updates
        // the representable on every model change, and the shared `AppModel`
        // publishes constantly during the mailto flow. `nsView.window` keeps
        // answering after `close()`, so without this the window is closed twice.
        guard Self.markDismissed(window) else { return }

        if Self.diagnoseExtraWindow {
            eudoraDiag("[windows] second main window closed on sight — "
                       + "key=\(window.isKeyWindow) "
                       + "frame=\(NSStringFromRect(window.frame))")
        }
        window.orderOut(nil)
        // Belt and braces against the same double close: an unbalanced release
        // of a window that was released on close is a crash a long way from
        // here. The splash panel is set the same way, for the same reason. The
        // cost is that the closed window lingers in `NSApp.windows` for the life
        // of the process; nothing reads that list without filtering on
        // `isVisible` or `isMiniaturized`, but the `[windows]` census will count
        // it.
        window.isReleasedWhenClosed = false
        DispatchQueue.main.async { window.close() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: @unchecked Sendable {
        var observers: [NSObjectProtocol] = []
        var closeProxy: CloseToQuitProxy?
        /// A deferred `attach` chain is running; see `retryAttach`.
        var retrying = false
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// Redirects a window's close to `NSApp.terminate`, forwarding every other
/// delegate message to the delegate that was there before.
///
/// `windowShouldClose` returns false — the window never closes on its own; the
/// terminate either takes the whole app down or is cancelled by the unsaved-
/// changes review, in which case the window rightly stays. See
/// `MainWindowAccessor.installCloseToQuit`.
final class CloseToQuitProxy: NSObject, NSWindowDelegate {
    /// Strong, deliberately — the same reasoning as `WindowCloseGuard.CloseProxy`:
    /// `NSWindow.delegate` is a weak reference, so once this proxy takes the slot
    /// nothing else retains SwiftUI's delegate, and a forwarded message would
    /// vanish if it deallocated.
    var original: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
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

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
    static func mainWindowDidAppear(_ main: NSWindow) {
        guard enabled, !hasRun else { return }
        // The watcher sees every window, including the splash itself and any
        // panel AppKit puts up; only SwiftUI's real window qualifies.
        guard main !== window, main.styleMask.contains(.titled),
              main.frame.width > 1, main.frame.height > 1 else { return }
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
    static weak var resolved: NSWindow?

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
        } else {
            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                attach(window, context: context)
            }
        }
    }

    private func attach(_ window: NSWindow, context: Context) {
        // Published for anyone who needs *this* window rather than whichever one
        // AppKit currently considers main. `NSApp.mainWindow` is nil while the
        // app is inactive and during parts of launch — which is exactly when the
        // indexing bar appears and `ContentView` needs to force a relayout.
        Self.resolved = window
        SplashWindow.mainWindowDidAppear(window)
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: @unchecked Sendable {
        var observers: [NSObjectProtocol] = []
        var closeProxy: CloseToQuitProxy?
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

import SwiftUI
import AppKit
import EudoraNet
import EudoraStore

/// A control that opens the Settings scene. On macOS 14+ this uses the
/// sanctioned `SettingsLink` (the selector hack is deprecated there and logs a
/// "Please use SettingsLink" warning); on macOS 13 it falls back to invoking the
/// menu action directly, which also works while a sheet is up.
struct SettingsButton<Label: View>: View {
    @ViewBuilder var label: () -> Label
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink(label: label)
        } else {
            Button(action: openSettingsWindowLegacy, label: label)
        }
    }
}

/// macOS 13 fallback opener. Deferred so it fires after the current menu closes.
@MainActor
func openSettingsWindowLegacy() {
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

/// Whether Settings was open at quit, and where its form was scrolled to.
///
/// The window's *frame* is not here — AppKit's own frame autosave already
/// remembers size and position (see `SettingsView.configureWindow`). This is the
/// two things it doesn't cover.
///
/// It exists for the rebuild-and-retest loop: adjust a setting, quit, rebuild,
/// run, and be put back where you were rather than hunting for the section
/// again.
enum SettingsWindowState {
    private static let openKey = "SettingsWindowWasOpen"
    private static let scrollKey = "SettingsWindowScrollY"

    static var wasOpen: Bool {
        get { UserDefaults.standard.bool(forKey: openKey) }
        set { UserDefaults.standard.set(newValue, forKey: openKey) }
    }

    /// The form's scroll offset, in points from the top. `nil` when nothing has
    /// been recorded — distinct from 0, which legitimately means "at the top".
    static var scrollY: CGFloat? {
        get {
            guard UserDefaults.standard.object(forKey: scrollKey) != nil else { return nil }
            return CGFloat(UserDefaults.standard.double(forKey: scrollKey))
        }
        set {
            if let newValue { UserDefaults.standard.set(Double(newValue), forKey: scrollKey) }
            else { UserDefaults.standard.removeObject(forKey: scrollKey) }
        }
    }

    /// The name AppKit files the Settings window's frame under. Also how the
    /// window is *recognised* at quit — see `recordWhetherOpen`.
    static let frameAutosaveName = "EudoraSettingsWindow"

    /// Record whether Settings is open. Called from `applicationWillTerminate`.
    ///
    /// Asked at quit rather than tracked as it happens, which is the difference
    /// between working and not. SwiftUI's `Settings` scene keeps its window and
    /// its hosting view alive after the window is closed — that is why `@State`
    /// in a Settings pane survives a close and reopen — so a close observer
    /// clears the flag, and the reopen doesn't reliably set it again, because
    /// SwiftUI need not run `updateNSView` for a window it is merely showing
    /// once more. One question at quit has no such edge.
    ///
    /// `isVisible` rather than existence: the window object outlives its closing.
    @MainActor
    static func recordWhetherOpen() {
        let open = NSApp.windows.contains {
            $0.frameAutosaveName == frameAutosaveName && $0.isVisible
        }
        wasOpen = open
        // Forced, because the process is about to `exit()`. UserDefaults writes
        // are asynchronous to disk, and `applicationWillTerminate` is the last
        // moment there is — a write left in the buffer is a write that never
        // happened. Deprecated in the sense that you shouldn't call it *often*,
        // which this doesn't: once, at quit.
        UserDefaults.standard.synchronize()
        if SettingsWindowTracker.diagnose {
            print("Settings diag: at quit, wasOpen=\(open). Windows:")
            for w in NSApp.windows {
                print("   autosave='\(w.frameAutosaveName)' visible=\(w.isVisible) "
                      + "title='\(w.title)' class=\(type(of: w))")
            }
        }
    }

    /// Reopen Settings if it was open when the app last quit.
    ///
    /// Deliberately *not* using `SettingsLink`, which is the sanctioned route on
    /// macOS 14+ but is a `View` — it can only be clicked, never invoked. The
    /// selector is the only programmatic opener there is. It is deprecated on 14+
    /// and logs a "Please use SettingsLink" warning, which is noise rather than
    /// breakage.
    ///
    /// Both spellings are tried because Apple renamed it: `showSettingsWindow:`
    /// is the modern one, `showPreferencesWindow:` the older, and which responds
    /// has moved between releases. `sendAction` reports whether anything handled
    /// it, so this asks rather than assumes.
    ///
    /// **Waits for the splash to come down**, rather than opening on a timer.
    /// Opening a titled window while the splash is up trips the watcher armed in
    /// `SplashWindow.arm()`, which takes any such window for the main one: at
    /// best it re-centres the splash over Settings, at worst it hides Settings in
    /// the main window's place and leaves the real main window invisible. The
    /// tree open blocks the main thread for several seconds, so any fixed delay
    /// short enough to feel responsive would land inside that window.
    @MainActor
    static func reopenIfItWasOpen(attemptsLeft: Int = 40) {
        if SettingsWindowTracker.diagnose, attemptsLeft == 40 {
            print("Settings diag: at launch, wasOpen=\(wasOpen), "
                  + "splash showing=\(SplashWindow.isShowing)")
        }
        guard wasOpen else { return }
        guard !SplashWindow.isShowing else {
            guard attemptsLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                reopenIfItWasOpen(attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.activate(ignoringOtherApps: true)
            // Two routes, tried in order, each *verified by looking for the
            // window* rather than by what it returns.
            //
            // `sendAction`'s answer cannot be trusted here. On macOS 14+ the
            // deprecated selector is still accepted by a responder — which makes
            // `sendAction` return `true` — and then does nothing but log "Please
            // use SettingsLink". Observed on macOS 26: handled=true, no window,
            // `SettingsView` never even evaluated. Believing the return value is
            // what made the first version of this silently fail.
            _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if isOpen {
                    if SettingsWindowTracker.diagnose { print("Settings diag: selector opened it") }
                    return
                }
                // The menu item, performed on its own target rather than sent
                // down the responder chain. This is the route the *user* takes
                // when they pick Settings from the app menu, so whatever SwiftUI
                // wires that item to is by definition still a working opener —
                // which the bare selector no longer is. Finding it by action
                // rather than by title is the house style; see
                // `MinimizeKeyStripper.minimizeItem`.
                if let (menu, index) = settingsMenuItem() {
                    menu.performActionForItem(at: index)
                } else if SettingsWindowTracker.diagnose {
                    print("Settings diag: no ⌘, item found in the app menu")
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if isOpen {
                        if SettingsWindowTracker.diagnose { print("Settings diag: menu opened it") }
                        return
                    }
                    // Last resort, and the most likely to work: click a real
                    // `SettingsLink`. See `HiddenSettingsLink`.
                    let clicked = SettingsLinkOpener.click()
                    if SettingsWindowTracker.diagnose {
                        print("Settings diag: menu route failed; hidden SettingsLink "
                              + (clicked ? "clicked" : "NOT FOUND"))
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if SettingsWindowTracker.diagnose {
                            print("Settings diag: after link route, open=\(isOpen)")
                        }
                        if !isOpen {
                            print("Settings: could not reopen — selector, app-menu item "
                                  + "and SettingsLink all failed.")
                        }
                    }
                }
            }
        }
    }

    /// Whether the Settings window is on screen right now.
    @MainActor
    static var isOpen: Bool {
        NSApp.windows.contains {
            $0.frameAutosaveName == frameAutosaveName && $0.isVisible
        }
    }

    /// The app menu's Settings item.
    ///
    /// Found by its **⌘,** key equivalent, not by its action. Looking for
    /// `showSettingsWindow:`/`showPreferencesWindow:` found nothing on macOS 26 —
    /// SwiftUI wires the item to something of its own now — whereas ⌘, is the
    /// shortcut Apple has published for this item since forever, and unlike the
    /// title it doesn't move with localisation.
    @MainActor
    private static func settingsMenuItem() -> (NSMenu, Int)? {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return nil }
        if SettingsWindowTracker.diagnose {
            print("Settings diag: app menu contents —")
            for item in appMenu.items {
                let action = item.action.map(NSStringFromSelector) ?? "(none)"
                print("   '\(item.title)'  key='\(item.keyEquivalent)'  action=\(action)"
                      + "  enabled=\(item.isEnabled)")
            }
        }
        for (index, item) in appMenu.items.enumerated()
        where item.keyEquivalent == "," && item.keyEquivalentModifierMask.contains(.command) {
            return (appMenu, index)
        }
        return nil
    }
}

/// The one opener Apple hasn't taken away.
///
/// `SettingsLink` is the sanctioned way to open the Settings scene on macOS 14+,
/// and it is a `View`: it can be clicked but not called. So the app keeps one,
/// one point square and effectively invisible, in the main window — and when
/// Settings has to be reopened programmatically, the `NSButton` behind it is
/// found and sent `performClick(_:)`.
///
/// **Measured on macOS 26, 2026jul30, and the reason this exists** — both honest
/// routes are dead there, and each fails in a way that looks like success:
///
/// - `NSApp.sendAction(Selector(("showSettingsWindow:")))` returns **`true`** and
///   does nothing. A responder accepts it, logs "Please use SettingsLink", and
///   no window is created — `SettingsView` isn't even evaluated. Believing that
///   return value is what made the first two attempts at this silently fail.
/// - The app menu's Settings item is no longer wired to `showSettingsWindow:` or
///   `showPreferencesWindow:` at all, so finding it by action returns nil. (It is
///   still findable by its ⌘, key equivalent, which is what `settingsMenuItem`
///   now does.)
///
/// So: never trust an opener's return value — check for the window. All three
/// routes are kept, in ascending order of desperation, because the earlier two
/// are correct on earlier systems and cost nothing to try.
struct HiddenSettingsLink: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Color.clear.frame(width: 1, height: 1) }
                .buttonStyle(.plain)
                .background(SettingsLinkGrabber())
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
        }
    }
}

/// Finds the `NSButton` that `SettingsLink` renders as, and remembers it.
private struct SettingsLinkGrabber: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Deferred: during this layout pass the button may not be in the
        // hierarchy yet. Same reason every other bridge in this app retries.
        DispatchQueue.main.async {
            guard SettingsLinkOpener.button == nil, let parent = nsView.superview else { return }
            SettingsLinkOpener.button = Self.firstButton(in: parent)
        }
    }

    /// The background view is a *sibling* of the link, so the search starts at
    /// their shared parent. That subtree holds nothing else clickable — the link
    /// is one point square with an empty label — so the first button found is it.
    private static func firstButton(in view: NSView) -> NSButton? {
        if let b = view as? NSButton { return b }
        for sub in view.subviews {
            if let found = firstButton(in: sub) { return found }
        }
        return nil
    }
}

@MainActor
enum SettingsLinkOpener {
    static weak var button: NSButton?

    /// Click the hidden link. Returns whether there was one to click.
    @discardableResult
    static func click() -> Bool {
        guard let button else { return false }
        button.performClick(nil)
        return true
    }
}

/// Watches the Settings window so its open/closed state and scroll position
/// survive a quit.
///
/// A class, held by `@StateObject`, because it owns notification tokens that
/// have to outlive a body evaluation and be removed exactly once. Not an
/// `NSWindowDelegate`: SwiftUI owns the Settings window's delegate and taking it
/// would break whatever it uses it for.
@MainActor
final class SettingsWindowTracker: ObservableObject {
    /// Holds the notification tokens so they are removed exactly once, when the
    /// tracker goes away.
    ///
    /// A separate, *non*-isolated class purely so its `deinit` can touch its own
    /// storage: a `@MainActor` type's `deinit` cannot read main-actor properties
    /// before Swift 6.1's isolated deinit, so tokens held directly here could
    /// never be removed. Same shape as `SplashWindow`'s observer handling.
    private final class ObserverBox: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
    private let observers = ObserverBox()

    private weak var window: NSWindow?
    private var saveGeneration = 0

    /// True while `restore` is still re-asserting the saved offset, so its own
    /// programmatic scrolls aren't recorded as the user's.
    ///
    /// Without this the feature walks itself back to the top: the early restore
    /// attempts clamp against a form that hasn't reached full height, each
    /// clamped position is recorded, and the shallower value is what next launch
    /// restores. `TableScrollStateSyncer` gates its recorder the same way, for
    /// the same reason.
    private var isRestoring = false

    /// Idempotent: `configureWindow` runs on every body evaluation, which for a
    /// pane whose stores publish per keystroke is every character typed.
    ///
    /// Note this does **not** record that Settings is open — that question is
    /// asked once at quit, in `SettingsWindowState.recordWhetherOpen`, because
    /// SwiftUI reuses this window and view across a close and reopen and there
    /// is no reliable "opened again" moment to hook.
    func attach(to w: NSWindow) {
        guard window !== w else { return }
        window = w
        attachScrollRecorder(in: w, attemptsLeft: 12)
    }

    /// Find the form's scroll view, restore the saved offset, and record further
    /// scrolling.
    ///
    /// Retried because the `NSScrollView` doesn't exist during the layout pass
    /// that first resolves the window, and its document height keeps growing for
    /// several turns afterwards as SwiftUI settles the form — the same lesson as
    /// `TableScrollStateSyncer.verifyPendingScroll`, learned there the hard way.
    private func attachScrollRecorder(in w: NSWindow, attemptsLeft: Int) {
        guard observers.tokens.isEmpty else { return }
        guard let scrollView = Self.tallestScrollView(in: w.contentView) else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak w] in
                    guard let self, let w else { return }
                    self.attachScrollRecorder(in: w, attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }
        if Self.diagnose {
            print("Settings scroll: found \(type(of: scrollView))"
                  + "  doc height \(scrollView.documentView?.frame.height ?? -1)"
                  + "  clip height \(scrollView.contentView.bounds.height)"
                  + "  saved \(String(describing: SettingsWindowState.scrollY))")
        }

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        observers.tokens.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] note in
            // Straight off the notification: the clip view that changed is the
            // one being asked about, and reading `self` synchronously here would
            // be touching main-actor state from a block that isn't isolated —
            // which `SplashWindow` and `TableScrollStateSyncer` both go out of
            // their way to avoid. It would also re-walk the whole view hierarchy
            // on every scroll tick.
            guard let clipView = note.object as? NSClipView else { return }
            let y = clipView.bounds.origin.y
            Task { @MainActor in self?.record(y) }
        })

        if let saved = SettingsWindowState.scrollY {
            isRestoring = true
            restore(saved, in: scrollView, attemptsLeft: 10, lastMaxY: -1)
        }
    }

    /// Printed once when the form's scroll view is located, or not at all if it
    /// never is. Off, intact, in the manner of the other diagnostics here.
    ///
    /// The question it answers: grouped `Form` is backed by a real `NSScrollView`
    /// on macOS 13–15, but SwiftUI's form rendering has changed since and this
    /// cannot be checked without running it. If the scroll position never comes
    /// back, turn this on — silence means the retry loop expired without finding
    /// anything, which is a different problem from finding it and mis-scrolling.
    ///
    /// Also covers the open/closed half: what `recordWhetherOpen` saw at quit,
    /// what `reopenIfItWasOpen` found at launch, which of the three opener
    /// routes worked, and a dump of the app menu. Switching this on is what
    /// found the macOS 26 behaviour recorded on `HiddenSettingsLink` — three
    /// builds' worth of guessing replaced by one run.
    static let diagnose = false

    /// Coalesced, because scrolling posts these continuously and each write is a
    /// UserDefaults hit. Same generation-token trick as `AppModel.rememberScroll`.
    private func record(_ y: CGFloat) {
        guard !isRestoring else { return }
        saveGeneration += 1
        let generation = saveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.saveGeneration == generation else { return }
            SettingsWindowState.scrollY = y
        }
    }

    /// Scroll to `y`, and keep re-asserting it while the form is still growing.
    ///
    /// A single scroll lands short: at the moment the scroll view first exists,
    /// its document is a fraction of its final height, so the offset clamps to
    /// whatever fits and the pane comes back near the top. Re-applying until the
    /// position sticks is what makes a deep section actually reappear.
    private func restore(_ y: CGFloat, in scrollView: NSScrollView,
                         attemptsLeft: Int, lastMaxY: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        let target = min(y, maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)

        // Stop when we've landed on `target` *and* the document has stopped
        // growing. Comparing against the raw `y` instead would never converge
        // whenever the saved offset is deeper than the form can now scroll — a
        // shorter window, or a collapsed section — and it would then re-assert
        // ten times over a second and a half, fighting the user if they scrolled
        // meanwhile.
        let landed = abs(clip.bounds.origin.y - target) <= 1
        let settled = abs(maxY - lastMaxY) <= 1
        guard attemptsLeft > 0, !(landed && settled) else {
            isRestoring = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.restore(y, in: scrollView, attemptsLeft: attemptsLeft - 1, lastMaxY: maxY)
        }
    }

    /// The scroll view with the tallest document, not merely the first found.
    ///
    /// Today the grouped `Form` is the only scrollable thing in this window, so
    /// either rule picks it. "Tallest" is chosen because it stays right if a
    /// section ever gains a nested `List` or `TextEditor` — where "first" would
    /// silently start scrolling the wrong thing, and the symptom would be the
    /// pane not restoring rather than anything that points at the cause.
    private static func tallestScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView {
                let h = s.documentView?.frame.height ?? 0
                if h > (best?.documentView?.frame.height ?? -1) { best = s }
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return best
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var accounts: AccountStore
    @EnvironmentObject var composeSettings: ComposeSettings
    /// The Settings window, so Save can close it. Captured by `WindowGrabber`.
    @State private var window: NSWindow?

    /// Remembers that this window was open, and where its form was scrolled to,
    /// so a quit-rebuild-run cycle puts you back where you were.
    @StateObject private var tracker = SettingsWindowTracker()

    /// The "me" set editor's in-progress new entry and last rescan result.
    @State private var newIdentity = ""
    @State private var rescanNote: String?

    /// The corrections list's in-progress new rule.
    @State private var newCorrectionTrigger = ""
    @State private var newCorrectionReplacement = ""

    /// Which app macOS opens `mailto:` links with, re-read whenever the pane
    /// appears and after the button is pressed.
    @State private var mailHandler = DefaultMailClient.Current(
        url: nil, isThisBuild: false, isAnotherEudora: false)
    @State private var mailHandlerNote: String?
    /// True while macOS's own confirmation is up, so the button can't stack
    /// alerts behind it.
    @State private var isSettingMailHandler = false

    /// Installed font families, resolved once for the composing-face picker.
    private static let families: [String] = NSFontManager.shared.availableFontFamilies

    /// The pane's fixed width. Only the height is the user's to choose; the
    /// fields, captions and the two-column rows are laid out for this number.
    private static let windowWidth: CGFloat = 480

    /// Where AppKit files the window's frame. Any string works as long as it
    /// stays stable — changing it silently forgets the remembered size.
    ///
    /// Shared with `SettingsWindowState`, which uses it at quit to pick this
    /// window out of `NSApp.windows`. One constant, so the two can't drift.
    private static let frameAutosaveName = SettingsWindowState.frameAutosaveName

    /// Make the Settings window vertically resizable, and have AppKit remember
    /// its frame across launches.
    ///
    /// Resizability is *not* set here — `.windowResizability(.contentSize)` on
    /// the scene does that, and it has to, because nothing done to the NSWindow
    /// survives SwiftUI's next layout pass. What this does is the part SwiftUI
    /// doesn't offer: remembering the frame across launches.
    ///
    /// **`.resizable` must be on before the restore.** `setFrameUsingName(_:)`
    /// is `setFrameUsingName(_:force:)` with `force: false`, and in that mode
    /// AppKit applies only the *origin* to a window that isn't resizable — the
    /// saved size is silently dropped. Hence the belt-and-braces insert below,
    /// ordered before the restore.
    private func configureWindow(_ w: NSWindow) {
        // Conditional: this runs on every body evaluation, which for a pane
        // whose stores publish per keystroke means every character typed.
        // `setStyleMask:` is not reliably a no-op on an equal value — it can
        // rebuild the title bar — so don't hand it one.
        //
        // Resizability itself comes from `.windowResizability(.contentSize)` on
        // the scene (see `EudoraApp`); SwiftUI sets this bit as a consequence.
        // It stays here because the frame restore below needs it: with
        // `force: false`, AppKit applies only the *origin* to a window that
        // isn't resizable, silently dropping the saved size.
        if !w.styleMask.contains(.resizable) { w.styleMask.insert(.resizable) }

        // Guarded because `updateNSView` can resolve the same window more than
        // once, and re-restoring would yank a window the user had just dragged
        // back to its saved frame.
        //
        // Restore *then* name: `setFrameUsingName` reads UserDefaults directly
        // and doesn't need the name to be set first, while naming first risks
        // AppKit writing the current frame out and clobbering the saved value
        // microseconds before it is read.
        if w.frameAutosaveName != Self.frameAutosaveName {
            w.setFrameUsingName(Self.frameAutosaveName)
            w.setFrameAutosaveName(Self.frameAutosaveName)
        }

        // Deliberately NOT setting contentMinSize/contentMaxSize. With
        // `.windowResizability(.contentSize)` SwiftUI derives both from the root
        // view's own minimum and maximum — which the `.frame` on the body
        // already states — and a second, hand-set copy of the same numbers is
        // one more thing to disagree with it. The earlier attempt set them and
        // they were simply overwritten.

        // After the frame work above, so the scroll restore measures a window
        // that is already its remembered size — restoring an offset against the
        // default height and then resizing would leave it pointing somewhere
        // else. `attach` is idempotent and returns immediately for a window it
        // has already seen.
        tracker.attach(to: w)

        Self.logSizing(w)
    }

    /// Why the Settings window will or won't resize, in one line.
    ///
    /// Off, but intact — the way this codebase keeps its diagnostics. It earned
    /// its keep immediately: two attempts at a resizable Settings pane failed
    /// before the cause was found, and both failures would have been one line of
    /// output each. What to read: `contentMin` and `contentMax` with *equal*
    /// heights mean something is pinning the window to its fitting size, which
    /// is what `.windowResizability(.contentSize)` on the scene exists to stop.
    /// Printed twice because the telling value isn't the one right after
    /// configuring, it's the one a layout pass later once SwiftUI has had its
    /// say.
    private static var logSizingEnabled = false

    /// Whether the deferred dump has been queued. `configureWindow` runs on
    /// every body evaluation — every keystroke — and without this the pane would
    /// queue one deferred print per character typed.
    private static var didLogSettled = false

    private static func logSizing(_ w: NSWindow) {
        guard logSizingEnabled else { return }
        // `n` guards every number: `contentMaxSize` defaults to CGFLOAT_MAX on
        // both axes, and `Int(CGFloat.greatestFiniteMagnitude)` is a trap — the
        // diagnostic would crash on exactly the reading it was turned on for.
        func n(_ v: CGFloat) -> String { v > 1e6 ? "∞" : String(Int(v)) }
        func describe(_ o: AnyObject?) -> String {
            o.map { String(describing: type(of: $0)) } ?? "nil"
        }
        func report(_ when: String) {
            // `type(of:)` on the Optional itself would print
            // `Optional<NSViewController>` — the static type, and useless. The
            // hosting class is the whole point, and for a SwiftUI scene it may
            // be the content *view* rather than a controller.
            print("""
                [Settings/\(when)] resizable=\(w.styleMask.contains(.resizable)) \
                frame=\(n(w.frame.width))×\(n(w.frame.height)) \
                contentMin=\(n(w.contentMinSize.width))×\(n(w.contentMinSize.height)) \
                contentMax=\(n(w.contentMaxSize.width))×\(n(w.contentMaxSize.height)) \
                controller=\(describe(w.contentViewController)) \
                view=\(describe(w.contentView))
                """)
        }
        report("configured")
        guard !didLogSettled else { return }
        didLogSettled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { report("settled") }
    }

    /// The auto-check interval field, clamped to at least 1 minute on entry so
    /// the number field can never hold a zero or negative interval.
    private var autoCheckMinutes: Binding<Int> {
        Binding(get: { accounts.autoCheckMinutes },
                set: { accounts.autoCheckMinutes = max(1, $0) })
    }

    var body: some View {
        // Form on top, Save fixed at the bottom. The button used to be the last
        // Section, which put it inside the form's scroll view — so on a short
        // window it scrolled away with everything else. A dialog's confirming
        // action shouldn't be something you have to go looking for.
        VStack(spacing: 0) {
            settingsForm
            Divider()
            footer
        }
        // Fixed width, free height. The width is a deliberate constant — the
        // fields and captions are laid out for it — while the height is
        // whatever the user drags it to, remembered between launches. The
        // grouped form scrolls when the window is shorter than its content, so
        // there is no height at which anything becomes unreachable.
        //
        // 880 was the old fixed height and is kept as the *ideal*, so a first
        // run with no remembered frame opens showing everything as it used to —
        // plus ~50pt, because the Save row now sits outside the form rather than
        // being the last thing in it.
        //
        // One call: `width:` and `minHeight:` are different overloads and cannot
        // be mixed, so the fixed width is expressed as min == ideal == max.
        .frame(minWidth: Self.windowWidth, idealWidth: Self.windowWidth,
               maxWidth: Self.windowWidth,
               minHeight: 360, idealHeight: 930, maxHeight: .infinity)
        // Return moves to the next field, the way Tab does.
        //
        // Attached to the container rather than to each field: SwiftUI
        // propagates a submit outward through the hierarchy, so one handler here
        // serves every text field in the form, including the ones inside the
        // per-account rows that don't exist until an account is added.
        //
        // The traversal is AppKit's own, so the order is exactly the order Tab
        // already follows and the two can't disagree. It wraps at the end,
        // again like Tab.
        .onSubmit(advanceFocus)
        // Not `!==`-guarded any more. `configureWindow` is idempotent, and the
        // window has to be re-asserted rather than configured once: SwiftUI
        // rewrites the window's content min/max size from the root view on its
        // own schedule, and a single early pass can be undone by a later one.
        // The `window` *assignment* is still guarded, because reassigning the
        // same value would invalidate the view and spin.
        .background(WindowGrabber { resolved in
            if window !== resolved { window = resolved }
            if let resolved { configureWindow(resolved) }
        })
        .navigationTitle("Settings")
    }

    /// Move focus one step along the key-view loop — Tab's own traversal.
    ///
    /// Neither half of this is incidental.
    ///
    /// **The starting view is captured now.** `selectNextKeyView(nil)` works
    /// from `window.firstResponder`, and during a Return that is the shared
    /// *field editor* — an `NSTextView` whose place in the loop is not the
    /// field's — or, for an instant, the window itself, in which case AppKit
    /// falls back to `initialFirstResponder` and focus would leap to the top of
    /// the form rather than to the next field. The editor's delegate is the
    /// control being edited, which is the view actually wanted.
    ///
    /// **The move is deferred a runloop turn.** AppKit isn't finished when the
    /// submit action runs: after it returns, the Return movement ends editing
    /// and then *re-establishes* it on the same field with its text selected.
    /// Moving focus from inside that would simply be undone — the symptom being
    /// a Return that appears to do nothing but highlight the text.
    private func advanceFocus() {
        guard let window else { return }
        let editor = window.firstResponder as? NSTextView
        let start = (editor?.isFieldEditor == true ? editor?.delegate as? NSView : nil)
            ?? window.firstResponder as? NSView
        DispatchQueue.main.async {
            if let start, start.window === window {
                window.selectKeyView(following: start)
            } else {
                window.selectNextKeyView(nil)
            }
        }
    }

    /// The Save row, outside the form's scroll view so it is always on screen.
    private var footer: some View {
        HStack(spacing: 12) {
            if accounts.account.security == .startTLS {
                Label("STARTTLS (587) isn't implemented yet — use SSL/TLS on 465 for now.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(red: 0.75, green: 0.05, blue: 0.05))
            }
            Spacer()
            // Save writes to the Keychain and closes the window — the close is
            // the confirmation, which is why there's no "Saved" checkmark.
            Button("Save") {
                // Commit whatever is mid-edit first. `TextField(value:format:)`
                // — the Port and interval fields — writes through only on Return
                // or on losing focus, and neither ⌘S nor a click on this button
                // moves the first responder. Without this, saving while the
                // caret sits in Port stores the *old* port.
                window?.makeFirstResponder(nil)
                accounts.save()
                window?.close()
            }
            .help("Save your settings (⌘S)")
            // Deliberately NOT `.keyboardShortcut(.defaultAction)`. That made
            // Save the window's default button, so Return anywhere in the pane
            // saved and closed it — in a form of forty-odd fields, where Return
            // is a natural thing to press after typing one. Return now advances
            // the focus instead (see `onSubmit` on the body). ⌘S still saves.
            //
            // Kept prominent so it still reads as the confirming action, even
            // though it is no longer the Return target.
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var settingsForm: some View {
        Form {
            Section("Identity") {
                TextField("Your name", text: $accounts.account.fromName)
                TextField("Email address", text: $accounts.account.fromAddress)
            }
            Section("Outgoing mail (SMTP)") {
                TextField("Server", text: $accounts.account.host)
                TextField("Port", value: $accounts.account.port, format: .number)
                Picker("Security", selection: $accounts.account.security) {
                    ForEach(SMTPAccount.Security.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                TextField("Username", text: $accounts.account.username)
                SecureField("Password", text: $accounts.password)
            }
            Section("Incoming mail (POP3)") {
                // Only when the stored list existed and wouldn't decode. A blank
                // pane after a real loss looks exactly like a blank pane on a
                // fresh install, and the difference matters: here there is
                // something to recover, and nothing has been overwritten yet.
                if accounts.incomingLoadFailed {
                    Text("Your saved incoming accounts couldn't be read and are "
                            + "shown blank. They haven't been overwritten — if you "
                            + "have a backup, restore it before saving.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // One block per server. Mail from all of them is delivered into
                // the single In box — there is no per-account mailbox, by
                // design (design-decisions.md §7).
                ForEach($accounts.incoming) { $entry in
                    IncomingAccountEditor(
                        entry: $entry,
                        canRemove: accounts.incoming.count > 1,
                        onRemove: { remove(entry) })
                }
                Button {
                    accounts.incoming.append(IncomingAccount())
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                Divider()
                // One interval for the app, not one per account: Check Mail
                // collects them all on each tick.
                HStack(spacing: 6) {
                    Toggle("", isOn: $accounts.autoCheckEnabled)
                        .labelsHidden()
                    Text("Automatically check for new mail every")
                    TextField("", value: autoCheckMinutes, format: .number)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .disabled(!accounts.autoCheckEnabled)
                    Text("minutes")
                }
            }
            Section("Default font") {
                Picker("Font", selection: $composeSettings.bodyFontName) {
                    // Keep the current face selectable even if it's not installed,
                    // so the picker never shows blank.
                    if !Self.families.contains(composeSettings.bodyFontName) {
                        Text(composeSettings.bodyFontName).tag(composeSettings.bodyFontName)
                    }
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                }
                Picker("Size", selection: $composeSettings.bodyFontSize) {
                    ForEach([8.0, 9, 10, 11, 12, 13, 14, 16, 18, 24], id: \.self) { size in
                        Text(size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size))
                            .tag(size)
                    }
                }
                Picker("Antialiasing", selection: $composeSettings.bodyAntialiasing) {
                    ForEach(BodyAntialiasing.allCases) { Text($0.label).tag($0) }
                }
                Text("Eudora-style applies when reading plain text. HTML mail is "
                        + "drawn by the system web view, which can't do the halo, "
                        + "so there it means ordinary smoothing — only None turns "
                        + "smoothing off there.")
                    .font(.caption).foregroundStyle(.secondary)
                if composeSettings.bodyAntialiasing == .eudora {
                    HStack {
                        Text("Halo lightness")
                        Slider(value: $composeSettings.eudoraHaloWhiteness, in: 0.4...0.95)
                    }
                    Text("Eudora-style keeps a crisp black core and adds a light gray "
                            + "edge, the way Eudora 7 did. Slide right for a lighter halo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Used to compose messages, to read plain text, and as the "
                        + "fallback for HTML mail — a sender's own font, size and "
                        + "colour override it, so their mail looks as they meant "
                        + "it to. On your screen only; sent mail carries no font "
                        + "unless you style it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Me — for the Who column") {
                // Every address (and whole-domain rule) that is you. The Who
                // column shows the *other* party and which way each message went,
                // so it needs to know which end is yours.
                ForEach(identityEntries, id: \.self) { entry in
                    HStack {
                        Text(entry)
                        Spacer()
                        Button {
                            model.removeMyIdentity(entry)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \u{201C}\(entry)\u{201D}")
                    }
                }
                HStack {
                    // Rounded-border, not the grouped Form's default borderless
                    // field — which was invisible until clicked.
                    TextField("Add address or *@domain", text: $newIdentity)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addIdentity)
                        // Stops the submit reaching the body's handler as well.
                        // Return here means "add this one", and the field clears
                        // ready for another — moving focus away too would be
                        // wrong, and adding several in a row is the normal way
                        // this field is used.
                        //
                        // Order matters and the failure is silent: the scope
                        // must be OUTSIDE the `onSubmit`, so the handler sits
                        // inside it. Reversed, `addIdentity` becomes an ancestor
                        // action relative to the trigger and Return does nothing
                        // at all — neither adds nor advances.
                        .submitScope()
                    Button("Add", action: addIdentity)
                        .disabled(newIdentity.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Scan Out mailbox for my addresses") {
                    let n = model.rescanOutForMyIdentity()
                    rescanNote = n == 0 ? "No new addresses found."
                                        : "Added \(n) address\(n == 1 ? "" : "es")."
                }
                if let rescanNote {
                    Text(rescanNote).font(.caption).foregroundStyle(.secondary)
                }
                Text("A domain rule like *@musanim.com counts every address at "
                        + "that domain as you. Changes take effect on the mailbox "
                        + "you're viewing right away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Search index") {
                Toggle("Rebuild overnight when the Mac is idle",
                       isOn: $model.autoRebuildIndex)
                Text("The index is a snapshot: mail that has arrived since it was "
                        + "built isn't found by Find, and a new correspondent gets no "
                        + "filing suggestions in Move To. Rebuilding takes minutes on a "
                        + "large folder, so this waits for 3 a.m. and for the Mac to "
                        + "have been untouched for an hour. Once a night, and never "
                        + "while you're using it — searching stays available "
                        + "throughout, because the new index is built alongside the "
                        + "old one and swapped in when it's finished.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Default email app") {
                HStack {
                    Text(mailHandler.isThisBuild
                         ? "This copy of Eudora opens mailto: links."
                         : "mailto: links open \(mailHandler.name).")
                    Spacer()
                    // A plain Button — note `SettingsButton` in this file is not
                    // a general-purpose button, it is the control that *opens*
                    // the Settings window.
                    //
                    // Only offered on macOS 14+, where there is an API for it.
                    // On 13 the caption below says where the setting lives
                    // instead: a button whose only possible outcome is "you
                    // can't do this here" is worse than no button.
                    //
                    // Gone entirely once Eudora *is* the default, rather than
                    // greyed out. A disabled "Make Eudora the default" implies
                    // an action that is currently blocked and might be unblocked
                    // — but there is nothing to unblock and nothing to want:
                    // undoing this means going to another mail app and making
                    // *it* the default. The sentence to the left already says
                    // the true thing, and the button had nothing to add.
                    if #available(macOS 14.0, *), !mailHandler.isThisBuild {
                        Button("Make Eudora the default") { makeEudoraDefault() }
                            .disabled(isSettingMailHandler)
                            .help("Ask macOS to send mailto: links to Eudora.")
                    }
                }
                // The path, not just the name — LaunchServices identifies an app
                // by where it is, so a build in DerivedData and a copy elsewhere
                // are two different apps to it despite sharing an identifier.
                // When a link doesn't reach the running Eudora, this line is
                // usually the reason, and it is otherwise invisible.
                if !mailHandler.path.isEmpty {
                    Text(mailHandler.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                }
                if let note = mailHandlerNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if #available(macOS 14.0, *) {
                    Text("Clicking an email address in a browser or another app "
                            + "opens a new message here. macOS may ask you to "
                            + "confirm the change.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("On this version of macOS the setting lives in "
                            + "Mail ▸ Settings ▸ General ▸ Default email reader.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Mailboxes") {
                Toggle("Show Junk mailbox", isOn: $model.showJunkMailbox)
                Text("Off hides the Junk mailbox from the sidebar and the move/search "
                        + "pickers. Nothing on disk changes — turning it back on just "
                        + "reveals it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Corrections — your auto-correct list") {
                // Your own set only; nothing from macOS's system dictionary or
                // text-replacement list. Same static-row + delete shape as "Me".
                ForEach(model.correctionRules) { rule in
                    HStack {
                        Text(rule.trigger)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(rule.replacement)
                        Spacer()
                        Button {
                            model.removeCorrection(trigger: rule.trigger)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \u{201C}\(rule.trigger)\u{201D}")
                    }
                }
                HStack {
                    // No `onSubmit` here on purpose: Return in "Word" should
                    // advance to "Replacement" (the body's handler does that),
                    // and only Return in "Replacement" adds the rule.
                    TextField("Word", text: $newCorrectionTrigger)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Replacement", text: $newCorrectionReplacement)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCorrection)
                        // As above: Return adds the rule and leaves both fields
                        // ready for the next one, rather than also advancing.
                        .submitScope()
                    Button("Add", action: addCorrection)
                        .disabled(newCorrectionTrigger.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newCorrectionReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Type the word on the left and it becomes the text on the right — "
                        + "case-sensitive. Adding a word that's already listed updates it. "
                        + "You can also right-click a word while writing a message to add it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Greedy, so the footer below is pinned to the bottom of the window
        // rather than floating under the last section on a tall window.
        .frame(maxHeight: .infinity)
        .onAppear { mailHandler = DefaultMailClient.current() }
        // `onAppear` alone is not enough, and the reason is documented at the
        // top of this file: the Settings scene keeps its window and hosting view
        // alive after a close, so the view never disappears and `onAppear` never
        // fires again. The handler can be changed from outside Eudora entirely —
        // Mail's own settings — and a stale line here would send you hunting for
        // a bug that isn't there. Re-reading on activation covers it.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            mailHandler = DefaultMailClient.current()
        }
    }

    /// Ask macOS to send `mailto:` links here.
    private func makeEudoraDefault() {
        mailHandlerNote = nil
        isSettingMailHandler = true
        DefaultMailClient.makeDefault { outcome in
            isSettingMailHandler = false
            mailHandler = DefaultMailClient.current()
            switch outcome {
            case .succeeded:
                // The registration is not reliably visible to this process the
                // instant the completion fires, so a successful change can read
                // back as "still Mail" — which looks exactly like failure. Look
                // again a moment later, and only then say something.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let now = DefaultMailClient.current()
                    mailHandler = now
                    mailHandlerNote = now.isThisBuild
                        ? nil
                        : "macOS accepted the change but still lists "
                          + "\(now.name). Reopen Settings to check."
                }
            case .failed(let message):
                mailHandlerNote = "macOS didn't make the change: \(message)"
            case .needsMailApp:
                mailHandlerNote = "This macOS version can only change it from "
                    + "Mail ▸ Settings ▸ General ▸ Default email reader."
            }
        }
    }

    /// The identity set as displayable rows: exact addresses, then domain rules
    /// shown in their `*@domain` form. Both sorted, so the list is stable.
    private var identityEntries: [String] {
        model.me.addresses.sorted()
            + model.me.domains.sorted().map { "*@\($0)" }
    }

    private func addIdentity() {
        let raw = newIdentity.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        model.addMyIdentity(raw)
        newIdentity = ""
        rescanNote = nil
    }

    private func addCorrection() {
        model.addCorrection(trigger: newCorrectionTrigger, replacement: newCorrectionReplacement)
        newCorrectionTrigger = ""
        newCorrectionReplacement = ""
    }

    /// Remove an incoming account, and forget its password.
    ///
    /// The row goes first, then `forgetPassword` — which checks that no
    /// remaining row still uses the same login before it touches the Keychain,
    /// so removing one of two rows pointing at the same server can't disarm the
    /// one being kept.
    ///
    /// The list never empties: the remove button is hidden at one row
    /// (`canRemove`), because a Settings pane with nothing to type into is a
    /// dead end. Clearing the last account is done by emptying its fields.
    private func remove(_ entry: IncomingAccount) {
        // Deferred to the next turn of the run loop. The button lives *inside*
        // the row being removed, and the row owns text fields that may still be
        // first responder — `TextField(value:format:)` for the port commits on
        // focus loss. Shrinking the array that `ForEach($accounts.incoming)`
        // indexes into, from within that row's own update pass, is the standard
        // way to get an index-out-of-range crash out of SwiftUI. Letting the
        // pass finish first costs nothing here.
        DispatchQueue.main.async {
            guard accounts.incoming.count > 1,
                  let i = accounts.incoming.firstIndex(where: { $0.id == entry.id })
            else { return }
            let removed = accounts.incoming[i].account
            accounts.incoming.remove(at: i)
            accounts.forgetPassword(for: removed)
            accounts.persistIncomingAccounts()
        }
    }
}

/// One incoming server's fields, extracted so the `ForEach` body is a single
/// row bound to a single element.
///
/// This is not a rendering optimisation and shouldn't be mistaken for one:
/// every keystroke writes through `$accounts.incoming`, which publishes, which
/// re-evaluates the whole of `SettingsView.body` — font pickers included. That
/// is the `AppModel`/store re-render caveat in CLAUDE.md, and it applies here.
/// Settings is a small, user-paced pane, so it doesn't matter; if it ever does,
/// the fix is to make this `Equatable` over plain values rather than to move
/// code around.
private struct IncomingAccountEditor: View {
    @Binding var entry: IncomingAccount
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // The server is the only thing that distinguishes one block from
                // the next at a glance, so it is the heading. Empty until it has
                // one, rather than showing a placeholder that looks like a value.
                Text(entry.account.host.isEmpty ? "New account" : entry.account.host)
                    .font(.headline)
                    .foregroundStyle(entry.account.host.isEmpty ? .secondary : .primary)
                Spacer()
                if canRemove {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this account")
                }
            }
            TextField("Server", text: $entry.account.host)
            TextField("Port", value: $entry.account.port, format: .number)
            TextField("Username", text: $entry.account.username)
            SecureField("Password", text: $entry.password)
            Toggle("Delete mail from server after downloading",
                   isOn: $entry.account.deleteAfterDownload)
            if entry.account.deleteAfterDownload {
                Text("Messages are deleted only after they're written to your local archive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Hands back the `NSWindow` hosting this view, once it exists — so Settings can
/// close itself on Save. `dismiss` isn't reliable for the Settings scene on
/// macOS 13, and `NSApp.keyWindow` can be the wrong window; the hosting view's
/// own `window` is unambiguous.
private struct WindowGrabber: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        // `window` is nil while the view is being made; read it next runloop turn.
        DispatchQueue.main.async { [weak v] in onResolve(v?.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in onResolve(nsView?.window) }
    }
}

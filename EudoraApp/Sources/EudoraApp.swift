import SwiftUI
import AppKit

@main
struct EudoraApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var accounts = AccountStore()
    @StateObject private var composeSettings = ComposeSettings()
    // The delegate exists for one thing: `applicationShouldTerminate`, so Quit
    // by *any* route (⌘Q, the Apple menu, the Dock, the main window's close
    // button) reviews unsaved compose windows first. See `AppDelegate`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    /// Arms the splash before SwiftUI builds its scenes, so the main window can
    /// be hidden the instant it's created rather than after it has been shown.
    /// This only registers an observer — see SplashWindow.arm, and note that
    /// creating a window here does *not* work.
    init() {
        SplashWindow.arm()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(accounts)
                .environmentObject(composeSettings)
                .frame(minWidth: 900, minHeight: 560)
                // A one-point, invisible `SettingsLink`, kept only so it can be
                // clicked programmatically when Settings has to be reopened.
                // It is the only opener that still works on macOS 26 — see
                // `HiddenSettingsLink`.
                .background(HiddenSettingsLink())
                // Bring Settings back if it was open at quit — the
                // adjust-a-setting, quit, rebuild, re-test loop. Hung off the
                // main window rather than `init` so the reopen happens after
                // there is a window for it to come up in front of. Does nothing
                // when Settings was closed. See `SettingsWindowState`.
                .onAppear { SettingsWindowState.reopenIfItWasOpen() }
                // NB: mailto: links are *not* handled with `.onOpenURL` here.
                // See `AppDelegate.application(_:open:)` — and note that
                // implementing that delegate method silently stops `.onOpenURL`
                // firing, so the two must never both be present.
        }
        .commands { eudoraCommands }

        // One window per message being composed, as Eudora had — several can be
        // open at once and each closes on its own.
        //
        // Keyed by draft id rather than presenting a draft value directly: the
        // draft itself lives in `AppModel.openDrafts`, because saving one draft
        // moves the records of the others in Out and they all have to be
        // corrected together. A window holding its own copy couldn't be told.
        //
        // `openWindow(id:value:)` reuses the window already showing a given
        // value rather than making a second one, which is exactly the behaviour
        // wanted when a draft is double-clicked while it's already open.
        WindowGroup(id: ComposeWindow.groupID, for: ComposeDraft.ID.self) { $draftID in
            ComposeWindow(draftID: draftID)
                .environmentObject(model)
                .environmentObject(accounts)
                .environmentObject(composeSettings)
        }
        // No `New Message` in the File menu for this group — the app's own
        // command creates the draft record first, and a window opened by
        // SwiftUI with no draft behind it would have nothing to edit.
        .commandsRemoved()

        // The Eudora "Find Messages" window (⌘F / Edit ▸ Find… / Tools ▸ Search…).
        // Shares the single AppModel so results open in the main window.
        Window("Find Messages", id: "find") {
            FindView()
                .environmentObject(model)
                .environmentObject(accounts)
                // The results pane now renders messages with `PreviewView`, the
                // same reader the main window uses, and that reads the body font
                // from here. Without it the window traps at launch on the
                // missing environment object.
                .environmentObject(composeSettings)
                .frame(minWidth: 720, minHeight: 620)
        }

        // The blacklist queue (Tools ▸ Blacklist…). A window rather than a
        // Settings pane: it is a working list that gets edited and emptied, not
        // a preference, and it needs to be open alongside a browser while its
        // contents are pasted into the ISP's form.
        Window("Blacklist", id: "blacklist") {
            BlacklistView()
                .environmentObject(model)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(accounts)
                .environmentObject(composeSettings)
        }
        // This is what makes the Settings window resizable, and it has to be
        // here on the *scene* — nothing done to the NSWindow survives.
        //
        // A scene's resizability defaults to `.automatic`, which for `Settings`
        // means "pin to the content's ideal size". SwiftUI re-asserts that on
        // its own schedule, so inserting `.resizable` into the window's style
        // mask and hand-setting its content min/max got overwritten a layout
        // pass later — the window claimed to be resizable and refused to drag.
        // `.contentSize` derives the window's limits from the root view's
        // *minimum and maximum* instead of its ideal, which is what lets
        // `SettingsView`'s `maxHeight: .infinity` mean anything.
        .windowResizability(.contentSize)
    }

    // MARK: - Menu-bar commands
    //
    /// The app's keyboard shortcuts, and the system menu bar they necessarily
    /// come with.
    ///
    /// **Why these aren't in `MenuBarView` with the menus they mirror.** They
    /// were, and none of them worked. A `.keyboardShortcut` on a Button inside an
    /// in-window `Menu` does not install a key equivalent — that content belongs
    /// to a popup button, not to the menu bar — so every shortcut in
    /// `MenuBarView` was decorative. The glyphs render in the menus, which is
    /// exactly why it looked wired up for so long. Only ⌘D in `ComposeView` ever
    /// worked, because that is a plain Button in the view hierarchy rather than
    /// `Menu` content, and those *do* register.
    ///
    /// So the real declarations live here, where macOS honours them. The cost is
    /// that the system menu bar is no longer minimal — it now mirrors the
    /// in-window menus — which was a deliberate trade, accepted knowingly.
    ///
    /// **The in-window `.keyboardShortcut` calls are kept for display.** They
    /// draw the ⌘ glyphs that make the in-window menus look like Eudora's, and
    /// they register nothing, so they don't collide with these. That is a
    /// standing bet on SwiftUI's current behaviour: if a future macOS *does*
    /// start honouring them, every shortcut here becomes a duplicate declaration
    /// and they will all stop firing at once. If that ever happens, this comment
    /// is the answer, and the fix is to strip the `.keyboardShortcut` calls from
    /// `MenuBarView`.
    /// Whether the message commands should be live.
    ///
    /// `openDrafts.isEmpty` is the load-bearing half. These shortcuts are global
    /// now, in a way the in-window menu's decorative ones never were, so ⌘⌫
    /// would reach Message ▸ Delete *while you are typing in a compose window*
    /// — where it otherwise means delete-to-start-of-line — and silently throw
    /// away whatever message is selected in the list behind it. A menu-bar key
    /// equivalent beats the field editor, so the only defence is not offering
    /// the command while a draft is open.
    ///
    /// Disabled while *any* draft is open, not just a frontmost one: a command
    /// menu has no notion of which window is key, and erring toward unavailable
    /// costs a menu click where erring the other way costs a message.
    private var messageCommandsEnabled: Bool {
        model.openDrafts.isEmpty && model.canActOnMessage
    }

    /// Reply, Reply to All and Forward — **not** gated on `openDrafts.isEmpty`.
    ///
    /// The paragraph above is about destructive commands and text-editing keys,
    /// and neither argument reaches these. ⌘R means nothing to a field editor, so
    /// there is no collision to avoid, and the worst a stray one can do is open a
    /// window. Stephen wants several replies open at once — the same message
    /// answered differently to different correspondents — and the model has always
    /// been built for it: `openDrafts` is keyed by draft id and
    /// `shiftDraftOffsets(after:by:except:)` exists precisely to keep other open
    /// drafts' offsets right. The old gate greyed ⌘R out while leaving the
    /// in-window menu's Reply live, so the two menus disagreed and the shortcut
    /// looked broken; this is what puts them back in step.
    ///
    /// Mark as Read/Unread stay on `messageCommandsEnabled`: ⌘U is a text-editing
    /// key, and a global one firing while you type in a composer is the very thing
    /// that guard is for.
    private var composeCommandsEnabled: Bool { model.canActOnMessage }

    /// Same draft-open guard, but for Delete, which acts on the whole
    /// multi-selection — `canActOnMessage` requires exactly one message and
    /// would grey Delete out the moment a second row was ⌘-clicked.
    private var deleteCommandEnabled: Bool {
        model.openDrafts.isEmpty && model.canActOnSelection
    }

    // `@MainActor` is not strictly required — the `@StateObject` properties
    // already infer it for the whole type under SE-0316 — but it is stated
    // rather than inferred, because everything in here calls into a
    // `@MainActor` model and inference is a thin thread to hang that on.
    @MainActor
    @CommandsBuilder
    private var eudoraCommands: some Commands {
        // File. Replacing `.newItem` also removes SwiftUI's automatic "New
        // Window", which would otherwise own ⌘N.
        CommandGroup(replacing: .newItem) {
            Button("New Message") { model.composeNew() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open Eudora Folder…") { pickFolder(model) }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            // ⌘M, plain, deliberately taking the key macOS gives Minimize.
            // Stephen minimises with the title-bar button and never the key, so
            // the shortcut is free to reuse — and Check Mail is the one command
            // worth a bare ⌘. It wins over Minimize because AppKit matches key
            // equivalents by walking the menu bar in order and File precedes
            // Window; see MinimizeKeyStripper, which removes the now-duplicate
            // ⌘M glyph the Window menu would otherwise still show.
            Button("Check Mail") { Task { await model.receiveMail(accounts: accounts) } }
                .keyboardShortcut("m", modifiers: .command)
        }

        // Edit. The standard `.pasteboard` and `.undoRedo` groups used to be
        // stripped, on the same mistaken belief that the in-window Edit menu's
        // shortcuts had taken over — so ⌘Z / ⌘X / ⌘C / ⌘V / ⌘A did nothing
        // anywhere in the app, including in the compose window's text fields.
        // Letting SwiftUI supply them restores all five, correctly routed
        // through the responder chain, for free.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { openWindow(id: "find") }
                .keyboardShortcut("f", modifiers: .command)
        }

        // Message. No standard placement exists for these, so this adds a menu.
        // Order and shortcuts mirror `MenuBarView.messageMenu`; the two are meant
        // to stay in step, and this is the one that actually functions.
        CommandMenu("Message") {
            // `.disabled` on a `Group` inside the menu, not on the `CommandMenu`
            // itself — `Commands` has no such modifier; these are Views. Three
            // gates, not one: Reply/Forward only need a message
            // (`composeCommandsEnabled`), Mark as Read/Unread additionally need no
            // draft open because ⌘U is a text-editing key
            // (`messageCommandsEnabled`), and the destructive commands act on the
            // whole selection (`deleteCommandEnabled`).
            //
            // This menu is at `ViewBuilder`'s ten-child limit. The divider before
            // Mark as Read lives *inside* its Group for that reason — a disabled
            // divider looks no different — so adding an item here means grouping
            // something, not appending.
            Group {
                Button("Reply") { model.reply(all: false) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Reply to All") { model.reply(all: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                // No shortcut. Eudora's ⌘L was unmemorable; Forward is reached
                // from this menu or the message's right-click menu.
                Button("Forward") { model.forward() }
            }
            .disabled(!composeCommandsEnabled)
            Group {
                Divider()
                Button("Mark as Read") { model.markSelected(read: true) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Mark as Unread") { model.markSelected(read: false) }
                    .keyboardShortcut("u", modifiers: .command)
            }
            .disabled(!messageCommandsEnabled)
            // Outside the Group because it acts on the whole selection, like
            // Delete — Reply and Forward above require exactly one message,
            // this one takes as many as are selected and attaches each.
            // No shortcut: a deliberate, occasional act (reporting messages),
            // not something to fire by reflex.
            Button("Forward as Attachment") { model.forwardAsAttachment() }
                .disabled(!deleteCommandEnabled)
            Divider()
            // Outside the Group deliberately: this is a view mode, not an action
            // on a message, so it stays usable with nothing selected — you turn
            // it on and then go looking. Named as Eudora named it, with the plain
            // description after it so the menu is still readable by someone who
            // never met Eudora 7. ⇧⌘B because ⌘B is bold in the composer and ⌘H
            // belongs to Hide.
            Toggle("Blah Blah Blah (All Headers)", isOn: $model.showAllHeaders)
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            // ⌘D, which is what Eudora used and what Stephen's hands expect.
            // ⌘⌫ still works — it is registered by a hidden button in the main
            // window (see `DeleteBackspaceShortcut`) rather than by a second menu
            // item, because two Delete entries advertising two keys reads as a
            // mistake, the same objection recorded against duplicating ⌘N.
            //
            // Being a menu shortcut, this is matched before any window's own key
            // equivalents — so it must stay `.disabled` whenever it shouldn't
            // act, or it silently eats ⌘D from every other window in the app.
            Button("Delete") { model.deleteSelected() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!deleteCommandEnabled)
            Divider()
            // No keyboard shortcut, deliberately. This destroys mail outright,
            // and the one thing it must never be is something the hand does on
            // the way to Delete. It also sits below a divider for the same
            // reason it sits below the gap in the right-click menu.
            Button {
                model.deletePermanentlySelected()
            } label: {
                // Concatenated `Text` rather than markdown in the title: this is
                // the one label whose emphasis has to be certain to render, and
                // `.bold()` on a `Text` run is, where a `LocalizedStringKey`'s
                // markdown depends on how the menu chooses to build its label.
                Text("Delete ") + Text("PERMANENTLY").bold() + Text("…")
            }
            .disabled(!deleteCommandEnabled)
        }
    }
}

/// The one reason this app has an application delegate: to review unsaved
/// compose windows before the app quits.
///
/// `applicationShouldTerminate` is the only hook that catches Quit by every
/// route — ⌘Q, the Apple and Dock menus, and (because the main window's close
/// button is wired to `NSApp.terminate`) the red button too. It defers the whole
/// decision to `onQuit`, a closure `ContentView` points at the model's review;
/// the closure is a plain (non-isolated) type on purpose, matching
/// `WindowCloseGuard.shouldClose` — it runs on the main thread, but
/// `applicationShouldTerminate` is a nonisolated requirement a `@MainActor`
/// method can't satisfy directly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the delegate exists, so `ContentView` — which has the model —
    /// can install the review closure.
    static weak var shared: AppDelegate?

    /// Whether Quit may proceed. Replaced by `ContentView.onAppear` with the
    /// model's review; until then, and if there's nothing to review, quitting is
    /// unobstructed.
    var onQuit: () -> NSApplication.TerminateReply = { .terminateNow }

    /// Where incoming `mailto:` URLs go once there is a model to take them.
    /// Installed by `ContentView.onAppear`, alongside `onQuit`.
    ///
    /// Setting it flushes whatever arrived first — see `openURLs`.
    var onOpenURLs: (([URL]) -> Void)? {
        didSet { flushOpenURLs() }
    }

    /// URLs delivered before `onOpenURLs` was installed.
    ///
    /// A `mailto:` clicked while Eudora is closed launches it *with* the URL,
    /// and that arrives during launch — before `ContentView` exists, let alone
    /// the mailbox tree. The delegate, by contrast, is constructed in
    /// `App.init` via `@NSApplicationDelegateAdaptor`, so it is guaranteed to be
    /// there first. That guarantee is the reason this is an AppKit delegate
    /// method rather than SwiftUI's `.onOpenURL`, whose replay of a launch URL
    /// depends on which view registers first.
    private var openURLs: [URL] = []

    /// Every URL macOS hands the app. Only `mailto:` is declared in Info.plist,
    /// so in practice that is all that arrives; the model checks the scheme
    /// again regardless.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let handler = onOpenURLs else {
            openURLs += urls
            return
        }
        handler(urls)
    }

    private func flushOpenURLs() {
        guard !openURLs.isEmpty, let handler = onOpenURLs else { return }
        let urls = openURLs
        openURLs = []
        handler(urls)
    }

    /// Set when this process is quitting because another Eudora already had the
    /// field. It exists to keep the loser quiet: `applicationWillTerminate`
    /// records whether Settings was open, and a duplicate instance — which has
    /// no windows at all — would record `false` over the surviving instance's
    /// state, so opening Settings and then accidentally launching a second copy
    /// would lose the setting.
    private var isDuplicateInstance = false

    /// Sent by a duplicate instance on its way out, asking the survivor to make
    /// itself visible. Scoped by the bundle id so it can't be confused with
    /// anything else on the machine.
    static let showYourselfNotification =
        Notification.Name("com.stephen.eudora.app.showYourself")

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only the survivor listens; a duplicate has already exited by here.
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showYourselfNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppDelegate.revealWindows() }
        }
    }

    /// Un-minimise and raise, for a user who tried to start a second copy.
    ///
    /// `deminiaturize` per window rather than `NSApp.unhide`: hidden and
    /// minimised are different states, and it was the minimised one that left
    /// the Dock icon highlighted with nothing on screen.
    @MainActor
    static func revealWindows() {
        for window in NSApp.windows where window.isMiniaturized {
            window.deminiaturize(nil)
        }
        // Deliberately no attempt to pick out "the main window" and order it
        // front. The obvious way is to match on the window title, which means
        // depending on `.navigationTitle("Eudora")` from a file that has no idea
        // this exists — and the failure would be silent, since a title that no
        // longer matches simply selects nothing. Deminiaturising every minimised
        // window and activating is enough: AppKit restores the window that was
        // key, which is the right one by construction.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Clicking the Dock icon with every window minimised.
    ///
    /// Same problem, arrived at by the ordinary route rather than by launching a
    /// second copy — and worth fixing here because it is the same one line. The
    /// system asks this before deciding what a reopen means; answering it by
    /// restoring the windows is what makes a Dock click behave the way every
    /// other Mac app does.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.revealWindows() }
        return true
    }

    /// One Eudora at a time: if another is already running, bring *it* forward
    /// and quit.
    ///
    /// Two copies were running on 2026aug02 — one launched by Xcode, one from
    /// the Dock — on different Spaces, with new mail arriving in the invisible
    /// one. That is more than confusing. `Outbox.append` reads the whole `.mbx`,
    /// appends, and atomically replaces it, so two processes appending
    /// concurrently is a lost update: both read 191 messages, both write 192,
    /// and the second write silently discards the first's. The same shape
    /// applies to `.toc` rewrites, `descmap.pce`, the downloaded-UID sets and
    /// the search index. The Message-ID guard catches some duplicate
    /// *deliveries*; nothing catches a lost *send*.
    ///
    /// Why macOS didn't prevent it by itself: Xcode launches the binary
    /// directly rather than through LaunchServices, so LaunchServices doesn't
    /// count that process as the running instance of the bundle and will happily
    /// start another from the Dock. The bundle identifier is stable across
    /// versions, so it is a sound key — two builds of different vintage still
    /// recognise each other.
    ///
    /// `willFinishLaunching`, the earliest hook there is: before any window,
    /// before the tree is opened, before a lock could be taken.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // An escape hatch, in the spirit of `EUDORA_ROOT`: two instances are
        // occasionally wanted deliberately (comparing builds, testing the tree
        // lock). Without it the only way to get a second copy is to edit this.
        guard ProcessInfo.processInfo.environment["EUDORA_ALLOW_SECOND_INSTANCE"] == nil,
              let mine = Bundle.main.bundleIdentifier else { return }

        let us = ProcessInfo.processInfo.processIdentifier
        let other = NSRunningApplication
            .runningApplications(withBundleIdentifier: mine)
            .first {
                // Compared by *pid*, not by object identity. `!=` on
                // NSRunningApplication is `isEqual:`, which does compare
                // processes — but these are freshly vended objects, and if that
                // ever failed to match, this app would find itself, activate
                // itself and quit, on every launch, by every route, with no way
                // in. The pid comparison cannot fail that way.
                $0.processIdentifier != us
                    && !$0.isTerminated
                    // LaunchServices drops a dead process from this list
                    // asynchronously, so an entry can outlive its process by a
                    // moment — exactly the moment an Xcode Run or a quick
                    // relaunch after ⌘Q lands in. Asking the kernel settles it;
                    // signal 0 tests for existence without delivering anything.
                    && kill($0.processIdentifier, 0) == 0
            }
        guard let other else { return }

        isDuplicateInstance = true
        // Says why, because otherwise an Xcode Run that instantly exits reads as
        // "the build did nothing". stdout survives the scheme's
        // OS_ACTIVITY_MODE=disable.
        print("Eudora: another instance (pid \(other.processIdentifier)) is already "
              + "running; bringing it forward and exiting. Set "
              + "EUDORA_ALLOW_SECOND_INSTANCE=1 to override.")

        // Ask the survivor to show itself, *then* activate it.
        //
        // Activation alone isn't enough when the survivor's window is
        // minimised: `NSRunningApplication.activate` makes an app frontmost, and
        // deliberately does not touch its windows — one app cannot deminiaturise
        // another's. So the survivor has to do it, and this is how it is told.
        // Without this the duplicate quits, the Dock icon highlights, and no
        // window appears — which from the user's side is indistinguishable from
        // the bug this whole guard exists to fix.
        //
        // `deliverImmediately: true` because this process is about to `exit(0)`.
        // A queued notification would be discarded with it.
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.showYourselfNotification,
            object: mine, userInfo: nil, deliverImmediately: true)

        // Bring the survivor forward rather than dying silently — the whole
        // failure mode was a window the user couldn't see, on another Space.
        //
        // **`activate(from:)` on macOS 14+ is the load-bearing part.** Activation
        // became cooperative in 14: an app can only raise another if it is
        // itself active, or by explicitly handing over its own activation. At
        // `willFinishLaunching` this process is not yet active, so a plain
        // `activate(options:)` is precisely the call the new model ignores — the
        // duplicate would quit and the survivor would stay invisible, which is
        // the original bug with extra steps.
        if #available(macOS 14.0, *) {
            other.activate(from: .current, options: [.activateAllWindows])
        } else {
            other.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }

        // `exit`, not `NSApp.terminate`. `terminate:` is documented as possibly
        // *returning* rather than terminating when the app hasn't finished
        // launching — in which case this duplicate would carry on, build a
        // window and open the tree. Nothing here needs the polite path:
        // `applicationShouldTerminate` is hard-wired to `.terminateNow` for a
        // duplicate and `applicationWillTerminate` is a deliberate no-op for it.
        exit(0)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The duplicate leaves at once: `onQuit` reviews unsaved drafts, and
        // this instance has none — it never got as far as a window.
        if isDuplicateInstance { return .terminateNow }
        return onQuit()
    }

    /// Note whether Settings was open, so the next launch can bring it back.
    ///
    /// Asked here rather than tracked as the window opens and closes: SwiftUI's
    /// `Settings` scene keeps its window alive across a close, so there is no
    /// dependable "opened again" moment to observe. See
    /// `SettingsWindowState.recordWhetherOpen`.
    ///
    /// `applicationWillTerminate` and not `applicationShouldTerminate`: the
    /// latter can be answered `.terminateCancel` by the unsaved-draft review, and
    /// recording there would file "quitting" state for a quit that didn't happen.
    func applicationWillTerminate(_ notification: Notification) {
        // Nothing from a duplicate instance: it has no windows, so it would
        // record "Settings was closed" over the surviving instance's state.
        guard !isDuplicateInstance else { return }
        SettingsWindowState.recordWhetherOpen()
        TreeLock.releaseIfHeld()
    }
}

/// Clears the ⌘M that macOS attaches to Window ▸ Minimize, now that File ▸ Check
/// Mail owns that key.
///
/// Only the *glyph* is at stake. Check Mail already wins the keystroke — AppKit
/// matches key equivalents by walking the menu bar in order, and File precedes
/// Window — but the Window menu would still print ⌘M beside Minimize, which by
/// this codebase's own standard "reads as a mistake". Minimize itself keeps
/// working, from the menu and the title-bar button; it only loses a shortcut
/// Stephen doesn't use.
///
/// A `.background` view rather than a launch hook, because the app has no
/// AppDelegate and this matches how `MainWindowAccessor` already reaches into
/// AppKit. `updateNSView` re-runs on SwiftUI updates, so if the Window menu is
/// ever rebuilt with the key restored, the next update strips it again; the
/// strip is idempotent, costing one menu walk.
struct MinimizeKeyStripper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The menu bar predates any view, but be defensive: on the very first
        // pass it is occasionally not installed yet, so retry a few times.
        DispatchQueue.main.async { Self.strip(attemptsLeft: 10) }
    }

    private static func strip(attemptsLeft: Int) {
        guard let item = minimizeItem() else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    strip(attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
    }

    /// The standard Minimize item, found by its *action* rather than its title,
    /// so a localised menu still matches. `performMiniaturize:` is the selector
    /// AppKit wires that item to.
    private static func minimizeItem() -> NSMenuItem? {
        let selector = #selector(NSWindow.performMiniaturize(_:))
        for top in NSApp.mainMenu?.items ?? [] {
            if let found = top.submenu?.items.first(where: { $0.action == selector }) {
                return found
            }
        }
        return nil
    }
}

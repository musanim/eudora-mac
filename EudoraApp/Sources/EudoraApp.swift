import SwiftUI
import AppKit

@main
struct EudoraApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var accounts = AccountStore()
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
                .frame(minWidth: 900, minHeight: 560)
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
                .frame(minWidth: 720, minHeight: 460)
        }

        Settings {
            SettingsView()
                .environmentObject(accounts)
        }
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
            Button("Check Mail") { Task { await model.receiveMail(accounts: accounts) } }
                .keyboardShortcut("m", modifiers: [.command, .shift])
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
            // itself — `Commands` has no such modifier; these are Views. One
            // guard for the lot, since every item acts on the selected message.
            // See `messageCommandsEnabled`.
            Group {
                Button("Reply") { model.reply(all: false) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Reply to All") { model.reply(all: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                // No shortcut. Eudora's ⌘L was unmemorable; Forward is reached
                // from this menu or the message's right-click menu.
                Button("Forward") { model.forward() }
                Divider()
                Button("Mark as Read") { model.markSelected(read: true) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Mark as Unread") { model.markSelected(read: false) }
                    .keyboardShortcut("u", modifiers: .command)
                Divider()
                Button("Delete") { model.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            .disabled(!messageCommandsEnabled)
        }
    }
}

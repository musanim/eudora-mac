import SwiftUI
import AppKit

/// A Windows-Eudora-style menu bar rendered *inside* the window, so the menus
/// are next to the content instead of at the top of a large display.
///
/// **Every `.keyboardShortcut` in this file is decorative.** A shortcut declared
/// on a Button inside an in-window `Menu` does not install a key equivalent —
/// that content belongs to a popup button, not to the menu bar — so these draw
/// the ⌘ glyphs and nothing more. They looked wired up for a long time precisely
/// because the glyphs render.
///
/// The declarations that actually work are in `EudoraApp.eudoraCommands`, and
/// the two are meant to stay in step: changing a shortcut here changes only its
/// label. Read the comment there before touching either.
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var accounts: AccountStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            fileMenu
            editMenu
            mailboxMenu
            messageMenu
            transferMenu
            specialMenu
            toolsMenu
            windowMenu
            helpMenu
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: menus

    private var fileMenu: some View {
        Menu("File") {
            Button("New Message") { model.composeNew() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open Eudora Folder…") { pickFolder(model) }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Check Mail") { Task { await model.receiveMail(accounts: accounts) } }
                .keyboardShortcut("m", modifiers: .command)
                .disabled(model.isChecking)
            Divider()
            Button("Save") {}.disabled(true)
            Button("Print…") {}.disabled(true)
        }.menuBarItem()
    }

    private var editMenu: some View {
        Menu("Edit") {
            Button("Undo") { responder("undo:") }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { responder("redo:") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Divider()
            Button("Cut") { responder("cut:") }
                .keyboardShortcut("x", modifiers: .command)
            Button("Copy") { responder("copy:") }
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste") { responder("paste:") }
                .keyboardShortcut("v", modifiers: .command)
            Button("Select All") { responder("selectAll:") }
                .keyboardShortcut("a", modifiers: .command)
            Divider()
            Button("Find…") { openWindow(id: "find") }
                .keyboardShortcut("f", modifiers: .command)
        }.menuBarItem()
    }

    private var mailboxMenu: some View {
        Menu("Mailbox") {
            Button("New…") {}.disabled(true)
            Button("New Folder…") {}.disabled(true)
            Divider()
            sortMenu
            Divider()
            Button("Rename…") {}.disabled(true)
            Button("Delete…") {}.disabled(true)
        }.menuBarItem()
    }

    /// The same sorts the column headers offer, plus the way back to mailbox
    /// order — which a header click can't give, since it only ever toggles
    /// between the two directions.
    ///
    /// Small enough not to care that SwiftUI builds nested menus eagerly: six
    /// items over no data, unlike the Transfer menu's 2,657 mailboxes.
    private var sortMenu: some View {
        Menu("Sort") {
            ForEach(MessageSortColumn.allCases, id: \.self) { column in
                Button(label(for: column)) { model.toggleSort(column) }
            }
            Divider()
            Button("Mailbox Order") { model.setSort(nil) }
                .disabled(model.sort == nil)
        }
        .disabled(model.selectedMailboxID == nil)
    }

    /// A tick and the direction on the active column, since a SwiftUI `Button` in
    /// a menu has no checked state to set.
    private func label(for column: MessageSortColumn) -> String {
        guard let sort = model.sort, sort.column == column else { return column.title }
        return "✓ \(column.title) \(sort.ascending ? "▲" : "▼")"
    }

    private var messageMenu: some View {
        Menu("Message") {
            // Deliberately unlabelled: File ▸ New Message shows the ⌘N hint, and
            // two items advertising the same key reads as a mistake.
            Button("New Message") { model.composeNew() }
            Button("Reply") { model.reply(all: false) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.canActOnMessage)
            Button("Reply to All") { model.reply(all: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canActOnMessage)
            // No ⌘L hint — the real command in `EudoraApp` has no shortcut.
            Button("Forward") { model.forward() }
                .disabled(!model.canActOnMessage)
            Divider()
            Button("Mark as Read") { model.markSelected(read: true) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!model.canActOnMessage)
            Button("Mark as Unread") { model.markSelected(read: false) }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(!model.canActOnMessage)
            Divider()
            Button("Delete") { model.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canActOnMessage)
        }.menuBarItem()
    }

    /// The one menu here that is *not* a SwiftUI `Menu`. It lists the whole
    /// mailbox tree, and SwiftUI would build all 2,657 items — every nested
    /// submenu included — every time this view's body ran, which is every time
    /// anything on `AppModel` publishes. `MoveToMenuButton` drops an `NSMenu`
    /// that fills one level at a time instead; see MoveToMenu.swift.
    ///
    /// `.plain` and `.menuBarItem()` are what make it sit level with the real
    /// menus either side of it: `menuBarItem`'s own `menuStyle`/`menuIndicator`
    /// do nothing to a Button, but its `fixedSize` and padding are the geometry.
    ///
    /// Deliberate change of behaviour: with nothing selected, or nowhere to move
    /// to, the *title* greys out. It used to open onto disabled items and a
    /// "No other mailboxes" placeholder. Greying it matches the toolbar's Move
    /// button, and there is nothing behind it worth opening to read.
    private var transferMenu: some View {
        MoveToMenuButton(tree: { model.tree },
                         onPick: { model.moveSelected(to: $0) }) {
            Text("Transfer")
        }
        .buttonStyle(.plain)
        .disabled(!model.canActOnMessage || !model.hasMoveTargets)
        .menuBarItem()
    }

    private var specialMenu: some View {
        Menu("Special") {
            Button("Empty Trash") {}.disabled(true)
            Divider()
            Button("Make Address Book Entry") {}.disabled(true)
            Button("Add as Recipient") {}.disabled(true)
        }.menuBarItem()
    }

    private var toolsMenu: some View {
        Menu("Tools") {
            // No ⌘, here — the Settings scene already registers it in the app
            // menu; duplicating the shortcut would conflict.
            SettingsButton { Text("Settings…") }
            Divider()
            Button("Address Book") {}.disabled(true)
            Button("Filters…") {}.disabled(true)
            Button("Search…") { openWindow(id: "find") }
            Button("Rebuild Search Index") { model.rebuildIndex() }
                .disabled(model.rootURL == nil)
        }.menuBarItem()
    }

    private var windowMenu: some View {
        Menu("Window") {
            Button("Minimize") { NSApp.keyWindow?.performMiniaturize(nil) }
            Button("Zoom") { NSApp.keyWindow?.performZoom(nil) }
            Divider()
            Button("Bring All to Front") { NSApp.arrangeInFront(nil) }
        }.menuBarItem()
    }

    private var helpMenu: some View {
        Menu("Help") {
            Button("Eudora Help") {}.disabled(true)
            Divider()
            Button("About Eudora") { NSApp.orderFrontStandardAboutPanel(nil) }
        }.menuBarItem()
    }

    // MARK: helpers

    /// Send a standard editing action to the first responder (the focused text
    /// field / editor), the way a real menu item would.
    private func responder(_ selector: String) {
        _ = NSApp.sendAction(Selector((selector)), to: nil, from: nil)
    }
}

private extension View {
    /// Common styling so each pull-down looks like a menu-bar title.
    func menuBarItem() -> some View {
        self.menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 2)
    }
}

import SwiftUI
import AppKit

/// A Windows-Eudora-style menu bar rendered *inside* the window, so the menus
/// are next to the content instead of at the top of a large display. The system
/// menu bar keeps only what macOS insists on (the app menu); everything else
/// lives here.
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
                .keyboardShortcut("m", modifiers: [.command, .shift])
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
            Button("Rename…") {}.disabled(true)
            Button("Delete…") {}.disabled(true)
        }.menuBarItem()
    }

    private var messageMenu: some View {
        Menu("Message") {
            Button("New Message") { model.composeNew() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Reply") { model.reply(all: false) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.canActOnMessage)
            Button("Reply to All") { model.reply(all: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canActOnMessage)
            Button("Forward") { model.forward() }
                .keyboardShortcut("l", modifiers: .command)
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

    private var transferMenu: some View {
        Menu("Transfer") {
            if model.moveTargets.isEmpty {
                Button("No other mailboxes") {}.disabled(true)
            } else {
                ForEach(model.moveTargets) { t in
                    Button(t.display) { model.moveSelected(to: t.id) }
                        .disabled(!model.canActOnMessage)
                }
            }
        }.menuBarItem()
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

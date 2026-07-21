import SwiftUI

/// The mailbox tree as menu items, for the three places that offer "move this
/// message somewhere": the toolbar Move button, the message-list context menu,
/// and Transfer in the menu bar.
///
/// Earlier this was a flat, alphabetically sorted list of every mailbox in the
/// tree, which in a real Eudora folder means hundreds of entries in one column
/// with the folder structure thrown away, so two mailboxes of the same name in
/// different folders were indistinguishable. Eudora 7's own Transfer menu is
/// hierarchical.
///
/// Two deliberate differences from the sidebar: a folder containing no mailboxes
/// is omitted (the sidebar shows it), and the current mailbox *is* listed.
/// Excluding it would make this menu depend on the selection, and rebuilding
/// 2,657 items on every click is what made switching mailboxes slow —
/// `moveSelected` ignores a move to where you already are.
///
/// Order is deliberately *not* re-sorted: it comes from `descmap.pce` by way of
/// `AppModel.tree`, which is the order Eudora itself shows, and the whole point
/// is that this menu and the sidebar agree.
/// The whole menu, wrapped so SwiftUI can skip rebuilding it.
///
/// **Why this wrapper exists.** These items live in the toolbar, and a `Menu`'s
/// content is built eagerly as part of its enclosing view — so all 2,657
/// mailboxes were being constructed during `NSToolbarItemViewer` layout. Sampling
/// the running app found 39% of wall time there, which is what made clicking a
/// mailbox feel slow: the click waited behind a toolbar re-layout.
///
/// It was rebuilt on every mailbox switch because the items used to depend on
/// the current selection (to exclude it). They no longer do — `moveSelected`
/// ignores a move to the mailbox you're already in — so the content depends only
/// on the tree, and a version lets SwiftUI skip it the rest of the time.
///
/// **Pass `AppModel.treeStructureVersion`, not `treeVersion`.** This menu draws
/// names and hierarchy and nothing else, but it was keyed on `treeVersion`,
/// which changes whenever a *count* does — so every delete rebuilt all 2,657
/// items inside `NSToolbarItemViewer` layout. Sampling caught 554 ms of it in a
/// single delete, on the main thread, in the window where the message list was
/// waiting to be redrawn.
struct MoveToMenuContent: View, Equatable {
    let tree: [MailboxItem]
    /// `AppModel.treeStructureVersion`. See the note above.
    let treeVersion: Int
    let action: (MailboxItem.ID) -> Void

    /// Deliberately ignores `action`: closures aren't comparable, and the ones
    /// passed here only ever call back into the model.
    static func == (a: MoveToMenuContent, b: MoveToMenuContent) -> Bool {
        a.treeVersion == b.treeVersion
    }

    var body: some View {
        MoveToMenuItems(items: tree, action: action)
    }
}

struct MoveToMenuItems: View {
    /// Usually `model.tree` — recursion passes a folder's children.
    let items: [MailboxItem]
    let action: (MailboxItem.ID) -> Void

    var body: some View {
        ForEach(items) { item in
            if item.isFolder {
                // Folders hold mailboxes, not messages, so a folder is only ever
                // a submenu — and only when something inside it can be picked.
                // Without that test, a tree full of empty folders (common: Eudora
                // leaves `.fol` directories behind) would fill the menu with
                // submenus that open onto nothing.
                if let kids = item.children, Self.containsDestination(kids) {
                    Menu(item.display) {
                        MoveToMenuItems(items: kids, action: action)
                    }
                }
            } else {
                Button(item.display) { action(item.id) }
            }
        }
    }

    /// Whether this subtree holds any mailbox at all — an empty folder is shown
    /// as a submenu opening onto nothing otherwise.
    static func containsDestination(_ items: [MailboxItem]) -> Bool {
        items.contains { $0.isFolder ? containsDestination($0.children ?? []) : true }
    }
}

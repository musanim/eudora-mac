import SwiftUI

/// The mailbox tree as menu items, for the three places that offer "move this
/// message somewhere": the toolbar Move button, the message-list context menu,
/// and Transfer in the menu bar.
///
/// Mirrors the sidebar's nesting and order, with one deliberate difference: a
/// folder containing nothing you could move to is omitted here, whereas the
/// sidebar shows it. Earlier this was a
/// flat, alphabetically sorted list of every mailbox in the tree, which in a real
/// Eudora folder means hundreds of entries in one column with the folder
/// structure thrown away, so two mailboxes of the same name in different folders
/// were indistinguishable. Eudora 7's own Transfer menu is hierarchical.
///
/// Order is deliberately *not* re-sorted: it comes from `descmap.pce` by way of
/// `AppModel.tree`, which is the order Eudora itself shows, and the whole point
/// is that this menu and the sidebar agree.
struct MoveToMenuItems: View {
    /// Usually `model.tree` — recursion passes a folder's children.
    let items: [MailboxItem]
    /// The mailbox the message is already in; never a destination.
    let excluding: MailboxItem.ID?
    let action: (MailboxItem.ID) -> Void

    var body: some View {
        ForEach(items) { item in
            if item.isFolder {
                // Folders hold mailboxes, not messages, so a folder is only ever
                // a submenu — and only when something inside it can be picked.
                // Without that test, a tree full of empty folders (common: Eudora
                // leaves `.fol` directories behind) would fill the menu with
                // submenus that open onto nothing.
                if let kids = item.children,
                   Self.containsDestination(kids, excluding: excluding) {
                    Menu(item.display) {
                        MoveToMenuItems(items: kids, excluding: excluding, action: action)
                    }
                }
            } else if item.id != excluding {
                Button(item.display) { action(item.id) }
            }
        }
    }

    /// Whether this subtree holds any mailbox that could be moved to.
    static func containsDestination(_ items: [MailboxItem],
                                    excluding: MailboxItem.ID?) -> Bool {
        items.contains { item in
            item.isFolder
                ? containsDestination(item.children ?? [], excluding: excluding)
                : item.id != excluding
        }
    }
}

import SwiftUI
import AppKit

/// The message list's right-click menu, built in AppKit rather than SwiftUI.
///
/// **Why not `.contextMenu`.** A context menu's content is constructed fresh on
/// every right-click, and SwiftUI builds nested menus *eagerly* — the whole tree,
/// to whatever depth, before anything appears. With a Move submenu covering
/// 2,657 mailboxes, sampling a single right-click found ~4 seconds, 79% of it
/// inside SwiftUI's menu machinery materialising a `PlatformItemList`. No amount
/// of `Equatable` wrapping helps, because there is no previous value to compare
/// a freshly built menu against.
///
/// `NSMenu` has the affordance SwiftUI lacks: a delegate is asked to fill a
/// submenu only when that submenu is about to open. So the top level costs 83
/// items (17 mailboxes + 66 folders) instead of 2,657, and a folder's contents
/// are built only if you actually go into it.
///
/// Assigning `NSTableView.menu` does *not* work here — SwiftUI's table subclass
/// owns the menu machinery for its own `.contextMenu` and never asks for it, so
/// the menu simply never appeared. The right-click is instead intercepted with a
/// local event monitor and the menu popped explicitly. The table itself is found
/// the same way the header art and scroll state are (`MessageTableFinder`).
struct MessageContextMenuInstaller: NSViewRepresentable {
    @ObservedObject var model: AppModel

    final class Coordinator {
        weak var table: NSTableView?
        var controller: MessageContextMenuController?
        var doubleClick: MessageDoubleClickController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        let model = self.model
        DispatchQueue.main.async {
            install(near: nsView, coordinator: coordinator, model: model, attemptsLeft: 20)
        }
    }

    /// `@MainActor` because it touches `MessageContextMenuController`, which is
    /// main-actor isolated — a plain method on a representable is *nonisolated*;
    /// only the protocol witnesses inherit it. The `DispatchQueue.main` closures
    /// that call this inherit isolation from their enclosing `@MainActor`
    /// context, so they remain legal call sites. Same shape as
    /// `TableScrollStateSyncer.attach`.
    @MainActor
    private func install(near view: NSView,
                         coordinator: Coordinator,
                         model: AppModel,
                         attemptsLeft: Int) {
        // Skip the view-tree walk when nothing can have changed: this runs on
        // every model update, and the walk isn't free. A rebuilt Table means a
        // *new* NSTableView, and the old one loses its window.
        if let known = coordinator.table, known.window != nil,
           let controller = coordinator.controller {
            controller.model = model
            coordinator.doubleClick?.model = model
            return
        }

        guard let table = MessageTableFinder.table(near: view) else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    install(near: view, coordinator: coordinator,
                            model: model, attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }

        // Rebuild the controller if the Table was torn down and remade, which
        // happens whenever a mailbox lists empty: the event monitor holds a weak
        // reference to the table, so a stale controller would stop responding.
        if coordinator.table !== table || coordinator.controller == nil {
            coordinator.table = table
            coordinator.controller = MessageContextMenuController(model: model, table: table)
            coordinator.doubleClick = MessageDoubleClickController(model: model, table: table)
        }
        coordinator.controller?.model = model
        coordinator.doubleClick?.model = model
    }
}

/// Double-clicking an unsent message reopens it in the editor.
///
/// AppKit again, and for a plainer reason than usual: SwiftUI's `Table` on
/// macOS 13 has no double-click action at all. `.onTapGesture(count: 2)` on a
/// cell fights the table's own selection handling and swallows the first click.
///
/// Deliberately a separate object from `MessageContextMenuController` even
/// though both watch the mouse over the same table: that one owns an `NSMenu`
/// and its lazy submenu builders, and folding an unrelated left-click handler
/// into it would tangle two lifetimes that have no reason to be shared.
///
/// Only unsent messages respond. A double-click anywhere else falls through
/// untouched, so the table keeps whatever default behaviour it has.
@MainActor
final class MessageDoubleClickController: NSObject {
    var model: AppModel
    private weak var table: NSTableView?
    private var monitor: Any?

    init(model: AppModel, table: NSTableView) {
        self.model = model
        self.table = table
        super.init()
        installEventMonitor()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func installEventMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard event.clickCount == 2,
                  let self, let table = self.table, let window = table.window,
                  event.window === window else { return event }

            // Row coordinates. A click on the column header converts to a
            // negative y and one in the empty strip right of the last column to
            // an x outside the table, so both fail this and pass through —
            // notably leaving the header-sort monitor's own handling alone.
            let point = table.convert(event.locationInWindow, from: nil)
            guard table.bounds.contains(point) else { return event }
            let row = table.row(at: point)
            guard row >= 0, row < self.model.rows.count else { return event }

            // `rows` is in display order, so the row number indexes it directly
            // — the same property the right-click menu relies on.
            // `isDraft`, not `isUnsent`: a message whose send failed is just as
            // editable, and is the one you are most likely to want to reopen.
            let message = self.model.rows[row]
            guard message.isDraft else { return event }

            self.model.reopenDraft(messageIndex: message.id)
            return nil          // consumed; the table must not also act on it
        }
    }
}

/// Owns the menu and performs its actions. Retained by the representable's
/// coordinator; the menu itself holds no strong reference back to the model.
@MainActor
final class MessageContextMenuController: NSObject, NSMenuDelegate {
    var model: AppModel
    private weak var table: NSTableView?
    let menu = NSMenu()

    /// The lazy builders for the Move submenu, kept alive here: `NSMenu.delegate`
    /// is a weak reference, so a builder that isn't retained would be gone by the
    /// time its submenu opened, and the submenu would come up empty.
    private var moveBuilders: [MailboxMenuBuilder] = []

    /// The row the right-click landed on, captured by the event monitor.
    ///
    /// Needed because we pop the menu ourselves: AppKit sets `clickedRow` inside
    /// its own `menu(for:)` handling, which never runs on this path.
    private var pendingRow: Int?

    /// Right-click interception. `NSTableView.menu` is ignored by the SwiftUI
    /// subclass backing `Table` — it overrides the menu machinery for its own
    /// `.contextMenu`, so assigning the property attaches a menu that is never
    /// asked for. Watching the event and popping the menu explicitly sidesteps
    /// that entirely.
    private var monitor: Any?

    init(model: AppModel, table: NSTableView) {
        self.model = model
        self.table = table
        super.init()
        menu.delegate = self
        installEventMonitor()
        // Enablement is stated here, not inferred. Automatic validation runs
        // *after* `menuNeedsUpdate`, so it would overwrite what we set on "Move
        // to"; and it decides an item carrying a submenu from that submenu's
        // contents — which, for a submenu deliberately left empty until it
        // opens, would grey out the one item this file exists for.
        menu.autoenablesItems = false
    }

    deinit {
        // Not `@MainActor`-isolated, and `removeMonitor` doesn't need to be.
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func installEventMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let table = self.table, let window = table.window,
                  event.window === window else { return event }

            // Only clicks inside the message list, and only on a real row —
            // anything else is passed through untouched.
            let point = table.convert(event.locationInWindow, from: nil)
            guard table.bounds.contains(point) else { return event }
            let row = table.row(at: point)
            guard row >= 0 else { return event }

            self.pendingRow = row
            NSMenu.popUpContextMenu(self.menu, with: event, for: table)
            return nil          // consumed; AppKit must not also handle it
        }
    }

    /// The message the click landed on, resolved once when the menu is built.
    ///
    /// Held rather than recomputed per action: `rows` can be replaced while the
    /// menu is open — the enrichment pass rewrites them, and a delete clears
    /// them — and the action must act on the message actually right-clicked, not
    /// on whatever has since moved into that position.
    private var clickedID: MessageRow.ID?

    /// `clickedRow` is a *position*, and `MessageRow.id` is a mailbox index —
    /// they differ whenever a mailbox has ghosts (deleted but not compacted), so
    /// this goes through `rows` rather than using the row number directly.
    private func resolveClickedID() -> MessageRow.ID? {
        guard let table else { return nil }
        // `pendingRow` first: we pop the menu ourselves from the event monitor,
        // so AppKit never sets `clickedRow` on this path. The others are
        // fallbacks in case the menu is ever reached the ordinary way.
        var row = pendingRow ?? table.clickedRow
        if row < 0, let event = NSApp.currentEvent {
            row = table.row(at: table.convert(event.locationInWindow, from: nil))
        }
        pendingRow = nil
        guard row >= 0, row < model.rows.count else { return nil }
        return model.rows[row].id
    }

    // MARK: building

    /// Rebuilt per right-click. Cheap: a handful of items, and the Move submenu
    /// is only a title until it is opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        moveBuilders.removeAll()

        clickedID = resolveClickedID()
        // An NSMenu with no items simply doesn't appear, which is
        // indistinguishable from never being asked — so never leave it empty.
        // If the click can't be tied to a row, fall back to whatever is
        // selected; the model's operations all work on the selection anyway.
        if clickedID == nil { clickedID = model.selectedMessageID }
        guard clickedID != nil else {
            let none = NSMenuItem(title: "No message selected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }

        // Move first: it's the reason this menu exists in AppKit at all, and the
        // one action used often enough to want under the pointer. Mark as
        // Read/Unread are deliberately absent — Stephen doesn't use them, and
        // they're still on the Message menu.
        //
        // The whole point: a title now, contents only if opened.
        let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Move to")
        submenu.autoenablesItems = false
        let builder = MailboxMenuBuilder(items: model.tree) { [weak self] destination in
            guard let self, let id = self.clickedID else { return }
            self.model.selectedMessageID = id
            self.model.moveSelected(to: destination)
        }
        submenu.delegate = builder
        moveBuilders.append(builder)
        move.submenu = submenu
        move.isEnabled = model.hasMoveTargets
        menu.addItem(move)

        menu.addItem(.separator())
        add("Reply", #selector(reply))
        add("Forward", #selector(forward))

        menu.addItem(.separator())
        add("Delete", #selector(deleteMessage))
    }

    private func add(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: actions

    /// Each action selects the clicked row first, matching what the SwiftUI menu
    /// did — the model's operations all work on the current selection.
    private func actOnClickedRow(_ body: () -> Void) {
        guard let id = clickedID else { return }
        model.selectedMessageID = id
        body()
    }

    @objc private func reply() { actOnClickedRow { model.reply(all: false) } }
    @objc private func forward() { actOnClickedRow { model.forward() } }
    @objc private func deleteMessage() { actOnClickedRow { model.deleteSelected() } }
}

/// Fills one level of the mailbox tree into a submenu, when that submenu opens.
///
/// One instance per level. Children are created only as their parent is opened,
/// so walking three folders deep builds three levels, not the whole tree.
@MainActor
final class MailboxMenuBuilder: NSObject, NSMenuDelegate {
    private let items: [MailboxItem]
    private let onPick: (MailboxItem.ID) -> Void

    /// Child builders, retained for the same reason `moveBuilders` is: menu
    /// delegates are weak.
    private var children: [MailboxMenuBuilder] = []

    init(items: [MailboxItem], onPick: @escaping (MailboxItem.ID) -> Void) {
        self.items = items
        self.onPick = onPick
        super.init()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Rebuilt each time it opens rather than cached: it is one level, the
        // tree can change under us (Rebuild, a new folder opened), and a stale
        // menu naming mailboxes that no longer exist would be worse than the
        // negligible cost of redoing it.
        menu.removeAllItems()
        children.removeAll()

        for item in items {
            if item.isFolder {
                guard let kids = item.children,
                      MoveToMenuItems.containsDestination(kids) else { continue }
                let submenu = NSMenu(title: item.display)
                submenu.autoenablesItems = false
                let child = MailboxMenuBuilder(items: kids, onPick: onPick)
                submenu.delegate = child
                children.append(child)

                let entry = NSMenuItem(title: item.display, action: nil, keyEquivalent: "")
                entry.submenu = submenu
                menu.addItem(entry)
            } else {
                let entry = NSMenuItem(title: item.display,
                                       action: #selector(pick(_:)),
                                       keyEquivalent: "")
                entry.target = self
                entry.representedObject = item.id
                menu.addItem(entry)
            }
        }
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? MailboxItem.ID else { return }
        onPick(id)
    }

    // The "does this folder hold anything?" test is `MoveToMenuItems
    // .containsDestination` — shared so the two Move menus can't drift. It is
    // recursive over the subtree, unlike the menu building itself, but it only
    // inspects `isFolder`/`children` and creates nothing.
}

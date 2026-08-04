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

            // While the removal veil is up the rows are a stale picture of a
            // mailbox that no longer exists — a double-click must not reopen
            // a draft by an index that now names a different message. The
            // SwiftUI overlay can't intercept for us: this monitor sees the
            // event before any view does.
            guard self.model.removalVeil == nil else { return event }

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

    /// Prints where the menu was asked to appear, for when it doesn't.
    ///
    /// Off, intact, in the manner of the other diagnostics here. It exists
    /// because two rounds of reasoning about flipped coordinates produced two
    /// identically-wrong answers, and the thing that would have settled it in
    /// one build was reading the numbers.
    static let diagnosePlacement = false

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

            // Stand down while the removal veil is up: the rows are a stale
            // picture, and a menu popped over them would act on indices that
            // now name different messages. (This monitor sees the event before
            // the SwiftUI overlay could block anything.)
            guard self.model.removalVeil == nil else { return event }

            // Only clicks inside the message list, and only on a real row —
            // anything else is passed through untouched.
            let point = table.convert(event.locationInWindow, from: nil)
            guard table.bounds.contains(point) else { return event }
            let row = table.row(at: point)
            guard row >= 0 else { return event }

            self.pendingRow = row
            // Below the row, not at the pointer.
            //
            // A context menu at the click point covers the message it is about —
            // and the one time that matters most is "Move to ▸ New…", where you
            // are naming a mailbox *after* the message you are looking at, and
            // the menu is sitting on top of it. Hanging the menu off the row's
            // bottom edge keeps the row visible whatever part of it was clicked.
            //
            // **In screen coordinates, deliberately.** Passing the row rect's
            // `maxY` in the table's own (flipped) space put the menu's top at
            // the row's *midpoint* — so the view-relative form does not mean
            // what it reads like here, and rather than nudge it by an
            // experimentally-derived half a row, this converts all the way out
            // to the screen, where there is only one convention and no flipping
            // to reason about.
            //
            // The chain: the row rect is in the table's flipped space, so its
            // visual bottom is `maxY` there; converting the *rect* to window
            // coordinates (unflipped, origin bottom-left) turns that edge into
            // the rect's `minY`; `convertPoint(toScreen:)` finishes the job.
            // `popUp(positioning:at:in:)` with a nil view takes screen
            // coordinates and places the menu's top-left at the point.
            //
            // `minX` rather than the click's x, so the menu lines up with the
            // row instead of wherever the pointer happened to be — otherwise it
            // still wanders horizontally, which is half the same complaint.
            //
            // Not `popUpContextMenu(_:with:for:)`, which positions from the
            // event and offers no say. AppKit may still slide the menu up when
            // it won't fit below — the same behaviour that had the Transfer menu
            // riding over the menu bar — but on a menu this short that needs a
            // row almost at the screen's edge.
            let rowInWindow = table.convert(table.rect(ofRow: row), to: nil)

            // **A measured correction, not a derived one.** `popUp` does not put
            // the menu's top-left at the point it is given: it sits the menu
            // somewhat higher, by an inset AppKit doesn't expose. Asking for the
            // row's bottom edge — first in the table's flipped space, then in
            // screen coordinates, which produced pixel-identical results and so
            // ruled out the coordinate maths — left the menu's top at the row's
            // *midpoint* both times.
            //
            // So the compensation is half a row, because that is what was
            // observed. It is expressed against `rowInWindow.height` rather than
            // as a number so it stays right if the row height changes, and the
            // row height here is pinned (see `TableScrollStateSyncer.pinRowHeight`),
            // so it is stable in practice.
            //
            // If this ever drifts, it is because AppKit's inset changed, and the
            // way to fix it is to measure again — not to reason about it. Set
            // `diagnosePlacement` and read the numbers.
            let correction = rowInWindow.height / 2
            let anchor = NSPoint(x: rowInWindow.minX, y: rowInWindow.minY - correction)
            if Self.diagnosePlacement {
                print("ctx menu diag: row \(row) rect(table) \(table.rect(ofRow: row))"
                      + "  rect(window) \(rowInWindow)  correction \(correction)"
                      + "  anchor(screen) \(window.convertPoint(toScreen: anchor))")
            }
            self.menu.popUp(positioning: nil,
                            at: window.convertPoint(toScreen: anchor),
                            in: nil)
            return nil          // consumed; AppKit must not also handle it
        }
    }

    /// The messages the menu acts on, resolved once when the menu is built.
    ///
    /// Held rather than recomputed per action: `rows` can be replaced while the
    /// menu is open — the enrichment pass rewrites them, and a delete clears
    /// them — and the action must act on the messages actually right-clicked,
    /// not on whatever has since moved into those positions.
    ///
    /// macOS convention decides the membership (see `menuNeedsUpdate`):
    /// right-clicking a row *inside* the current multi-selection targets the
    /// whole selection; right-clicking outside it targets just that row, and
    /// the action will re-select accordingly. `clickedPrimary` is the row under
    /// the pointer either way — it becomes the primary when the action installs
    /// the selection.
    private var clickedIDs: Set<MessageRow.ID> = []
    private var clickedPrimary: MessageRow.ID?

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

        if let clicked = resolveClickedID() {
            // Inside the current multi-selection → the menu acts on all of it;
            // outside (or a single selection elsewhere) → on the clicked row
            // alone, which the action will select first. The macOS convention.
            if model.selectedMessageIDs.count > 1, model.selectedMessageIDs.contains(clicked) {
                clickedIDs = model.selectedMessageIDs
            } else {
                clickedIDs = [clicked]
            }
            clickedPrimary = clicked
        } else {
            // An NSMenu with no items simply doesn't appear, which is
            // indistinguishable from never being asked — so never leave it
            // empty. If the click can't be tied to a row, fall back to whatever
            // is selected; the model's operations all work on the selection
            // anyway.
            clickedIDs = model.selectedMessageIDs
            clickedPrimary = model.primaryMessageID
        }
        guard !clickedIDs.isEmpty else {
            let none = NSMenuItem(title: "No message selected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }

        // Select the clicked rows now, up front, rather than when an item is
        // chosen. `actOnClickedRows` still does it on action — it has to, since
        // the menu can be dismissed and re-opened — but "Move to" needs the
        // selection *while it builds*, because its filing suggestions are
        // computed from it. Selecting on right-click is the platform
        // convention anyway.
        model.applyMessageSelection(clickedIDs, primary: clickedPrimary)

        // Move first: it's the reason this menu exists in AppKit at all, and the
        // one action used often enough to want under the pointer. Mark as
        // Read/Unread are deliberately absent — Stephen doesn't use them, and
        // they're still on the Message menu.
        //
        // The whole point: a title now, contents only if opened.
        let n = clickedIDs.count
        let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Move to")
        submenu.autoenablesItems = false
        let builder = MailboxMenuBuilder(
            items: model.visibleTree,
            onPick: { [weak self] destination in
                guard let self else { return }
                self.actOnClickedRows { self.model.moveSelected(to: destination) }
            },
            // Move to ▸ New…: create a mailbox at that level, then move the
            // clicked rows into it — one gesture, as in Eudora 7.
            onNew: { [weak self] parent in
                guard let self else { return }
                self.actOnClickedRows { self.model.createMailboxAndMoveSelection(under: parent) }
            },
            // A pure read. Suggestions come from the *selection*, and the
            // right-click has already made the clicked rows the selection — see
            // `menuNeedsUpdate`.
            //
            // It deliberately does not select here. An earlier version did,
            // because `actOnClickedRows` only selects when an item is chosen and
            // that is too late for a menu that must already show the right
            // suggestions. But selecting from inside `menuNeedsUpdate` meant
            // merely *hovering* "Move to" until its submenu opened and then
            // pressing Escape left the selection moved and the preview pane
            // loading a message nobody picked — and AppKit is free to call
            // `menuNeedsUpdate:` more than once, which a side-effecting closure
            // must not rely on.
            suggestions: { [weak self] in
                self?.model.filingSuggestions() ?? []
            })
        submenu.delegate = builder
        moveBuilders.append(builder)
        move.submenu = submenu
        move.isEnabled = model.hasMoveTargets
        menu.addItem(move)

        menu.addItem(.separator())
        // Reply and Forward only make sense on one message (the design
        // decision), so they grey out over a multi-selection rather than
        // silently acting on just one of it. `autoenablesItems` is false, so
        // what is set here is what shows.
        add("Reply", #selector(reply), enabled: n == 1)
        add("Forward", #selector(forward), enabled: n == 1)
        // Any number, unlike Reply and Forward above: each selected message
        // becomes its own attachment on one new mail.
        add(n == 1 ? "Forward as Attachment" : "Forward \(n) as Attachments",
            #selector(forwardAsAttachment), enabled: n >= 1)
        // "Send Again" only for a single, successfully-sent message: it opens a
        // fresh editable copy (see `AppModel.sendAgain`). Shown only when it
        // applies rather than greyed out, since it's meaningless on received or
        // draft mail.
        if n == 1, let id = clickedPrimary, model.isSentMessage(id) {
            add("Send Again", #selector(sendAgain))
        }

        menu.addItem(.separator())
        add("Delete", #selector(deleteMessage))

        // Blacklist a sender — a single *received* message (never one you sent,
        // which would blacklist yourself). Auto-sends and can't be undone, so the
        // action itself also gates hard behind a confirmation.
        //
        // Last, behind its own separator. It used to sit directly above Delete,
        // which put the menu's one irreversible, mail-sending action adjacent to
        // its most-used one. Isolating it costs nothing — the separator is the
        // whole safeguard at this level — and the confirmation still stands
        // behind it.
        //
        // The separators are added inside the `if`, so a menu without the item
        // doesn't end in stray dividers.
        //
        // The GAP is deliberate and is not a bug for a later reader to tidy away.
        // Stephen asked for real distance between the menu's most-used action and
        // its only irreversible one, so a slightly-off click lands on dead space
        // rather than on a thing that sends mail on his behalf. He also finds it
        // funny, which is a perfectly good second reason.
        //
        // **Consecutive separators do not work.** Three `.separator()` in a row
        // coalesce into a single line — tried 2026aug03, and the menu looked
        // exactly as it did before. AppKit needs something between them, so the
        // gap is separator / blank item / separator. The blank carries a space
        // rather than an empty string, which is what guarantees it a full-height
        // row, and it is disabled so it can't be "chosen".
        if n == 1, let id = clickedPrimary, !model.isSentMessage(id) {
            menu.addItem(.separator())
            let spacer = NSMenuItem(title: " ", action: nil, keyEquivalent: "")
            spacer.isEnabled = false
            menu.addItem(spacer)
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Add to BLACKLIST", action: #selector(blacklist),
                                  keyEquivalent: "")
            item.target = self
            // "BLACKLIST" in bold, the rest in the normal menu font. The plain
            // `title` stays set as the accessibility label.
            let menuFont = NSFont.menuFont(ofSize: 0)
            let bold = NSFontManager.shared.convert(menuFont, toHaveTrait: .boldFontMask)
            let title = NSMutableAttributedString(string: "Add to ", attributes: [.font: menuFont])
            title.append(NSAttributedString(string: "BLACKLIST", attributes: [.font: bold]))
            item.attributedTitle = title
            menu.addItem(item)
        }
    }

    private func add(_ title: String, _ action: Selector, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    // MARK: actions

    /// Each action installs the resolved target as the selection first,
    /// matching what the SwiftUI menu did — the model's operations all work on
    /// the current selection. For a right-click inside a multi-selection the
    /// set is that selection (a no-op install); for one outside it, this is
    /// what moves the selection to the clicked row.
    private func actOnClickedRows(_ body: () -> Void) {
        guard !clickedIDs.isEmpty else { return }
        model.applyMessageSelection(clickedIDs, primary: clickedPrimary)
        body()
    }

    @objc private func reply() { actOnClickedRows { model.reply(all: false) } }
    @objc private func forward() { actOnClickedRows { model.forward() } }
    @objc private func forwardAsAttachment() {
        actOnClickedRows { model.forwardAsAttachment() }
    }
    // Reads the clicked message by index and opens a copy; no need to move the
    // selection first, since it doesn't act on `selectedMessageID`.
    @objc private func sendAgain() {
        guard let id = clickedPrimary else { return }
        model.sendAgain(messageIndex: id)
    }
    @objc private func deleteMessage() { actOnClickedRows { model.deleteSelected() } }

    /// Blacklist the clicked message's sender, behind a deliberate confirmation.
    /// The dangerous button is *not* the default, so a stray Return cancels — the
    /// "in case I clicked by accident" guard.
    @objc private func blacklist() {
        actOnClickedRows {
            guard let address = model.selectedSenderAddress() else { NSSound.beep(); return }
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Add \(address) to your blacklist?"
            // The list has to match what actually happens — a confirmation that
            // under-reports its own consequences is worse than none. Hence the
            // last clause: blacklisting reuses the menu's own Delete, so in
            // Trash it removes rather than moves, and "delete" everywhere else
            // in this app means "to Trash".
            let fate = model.selectionIsInTrash
                ? "and delete the message permanently, since it is already in Trash."
                : "and move the message to Trash."
            alert.informativeText =
                "This can't be undone. It will reply to this message telling the sender "
                + "they've been blacklisted, add \(address) to ~/email_blacklist.txt, open that "
                + "file, " + fate
            let yes = alert.addButton(withTitle: "Yes, I'm totally sure")
            let cancel = alert.addButton(withTitle: "Cancel")
            yes.keyEquivalent = ""          // Return must not fire the destructive action
            cancel.keyEquivalent = "\r"     // Return / Esc both cancel
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            model.blacklistSelectedSender()
        }
    }
}

// `MailboxMenuBuilder`, which fills the Move submenu one level at a time, was
// written here and now lives in MoveToMenu.swift: the toolbar's Move button and
// the menu bar's Transfer menu use it too, so all three Move menus share one
// implementation and can't drift apart.

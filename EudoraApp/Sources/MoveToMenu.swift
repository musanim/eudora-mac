import SwiftUI
import AppKit

/// The mailbox tree as a menu, for the three places that offer "move this
/// message somewhere": the toolbar Move button, the message-list context menu,
/// and Transfer in the in-window menu bar.
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
///
/// # Why this is AppKit and not SwiftUI
///
/// It used to be a SwiftUI `Menu` over a recursive `ForEach`. **SwiftUI builds
/// menu content eagerly, and all the way down** — opening nothing at all still
/// constructed every one of the 2,657 mailboxes, every nested submenu included,
/// as part of the enclosing view's body.
///
/// Two rounds of mitigation got the cost down but never to zero. Wrapping the
/// content in an `Equatable` view keyed on `AppModel.treeStructureVersion` (a
/// counter that moves when the tree's *shape* changes, unlike `treeVersion`,
/// which also moves when a message count does) let SwiftUI skip re-running the
/// body most of the time. That was worth 554 ms on a delete. But `.equatable()`
/// only governs the body: when the *toolbar item* is invalidated, AppKit
/// rebuilds its platform item list from the retained content regardless, and
/// `.disabled(!hasSelection)` invalidates it on every selection change and every
/// delete. Sampling a delete still found 1,137 samples inside
/// `NSToolbarItemViewer` layout.
///
/// `NSMenu` has the affordance SwiftUI lacks: a delegate is asked to fill a menu
/// only when that menu is about to open. So the top level costs 83 items
/// (17 mailboxes + 66 folders) instead of 2,657, and a folder's contents are
/// built only if you actually go into it. The button still gets invalidated on
/// every selection change — that part is unavoidable, `disabled` depends on the
/// selection — but invalidating it now costs a `Label` and an empty anchor view.
///
/// This is the same fix, and the same `MailboxMenuBuilder`, that
/// `MessageContextMenu` already used for the right-click menu; a single
/// right-click there had sampled at ~4 seconds, 79% of it in SwiftUI's menu
/// machinery.

// MARK: - The lazy builder

/// Fills one level of the mailbox tree into a menu, when that menu opens.
///
/// One instance per level. Children are created only as their parent is opened,
/// so walking three folders deep builds three levels, not the whole tree.
///
/// Lives here rather than in `MessageContextMenu.swift`, where it was written,
/// because all three Move menus now share it.
@MainActor
final class MailboxMenuBuilder: NSObject, NSMenuDelegate {
    private let items: [MailboxItem]
    /// The folder whose contents this level shows, nil at the root — what
    /// "New…" at this level creates *inside*.
    private let folderID: MailboxItem.ID?
    private let onPick: (MailboxItem.ID) -> Void
    /// Eudora 7's "New…" at the top of every level. Nil means the item isn't
    /// offered (a caller that only moves, never creates).
    private let onNew: ((MailboxItem.ID?) -> Void)?

    /// Child builders, retained because `NSMenu.delegate` is a **weak**
    /// reference: a builder that nothing else held would be gone by the time its
    /// submenu opened, and the submenu would come up empty. Whoever owns the
    /// root menu has to retain the root builder for the same reason — see
    /// `MoveToMenuController.rootBuilder`.
    private var children: [MailboxMenuBuilder] = []

    init(items: [MailboxItem],
         folderID: MailboxItem.ID? = nil,
         onPick: @escaping (MailboxItem.ID) -> Void,
         onNew: ((MailboxItem.ID?) -> Void)? = nil) {
        self.items = items
        self.folderID = folderID
        self.onPick = onPick
        self.onNew = onNew
        super.init()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Rebuilt each time it opens rather than cached: it is one level, the
        // tree can change under us (Rebuild, a new folder opened), and a stale
        // menu naming mailboxes that no longer exist would be worse than the
        // negligible cost of redoing it.
        menu.removeAllItems()
        children.removeAll()

        // "New…" first, above a separator — where Eudora 7 put it, at every
        // level of the hierarchy.
        if onNew != nil {
            let entry = NSMenuItem(title: "New…", action: #selector(newHere), keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
            menu.addItem(.separator())
        }

        for item in items {
            if item.isFolder {
                // Folders hold mailboxes, not messages, so a folder is only ever
                // a submenu — and only when something inside it can be picked.
                // Without that test, a tree full of empty folders (common: Eudora
                // leaves `.fol` directories behind) would fill the menu with
                // submenus that open onto nothing.
                //
                // Unless the menu creates as well as moves: then an empty folder
                // opens onto its own "New…", which is exactly how something gets
                // *into* it for the first time.
                guard let kids = item.children,
                      onNew != nil || Self.containsDestination(kids) else { continue }
                let submenu = NSMenu(title: item.display)
                // Automatic validation runs *after* `menuNeedsUpdate`, so it
                // overwrites hand-set enablement; and it decides an item carrying
                // a submenu from that submenu's contents — which, for a submenu
                // deliberately left empty until it opens, greys out the very item
                // this file exists for.
                submenu.autoenablesItems = false
                let child = MailboxMenuBuilder(items: kids, folderID: item.id,
                                               onPick: onPick, onNew: onNew)
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

    @objc private func newHere() {
        onNew?(folderID)
    }

    /// Whether this subtree holds any mailbox at all — an empty folder would
    /// otherwise be shown as a submenu opening onto nothing.
    ///
    /// Recursive over the subtree, unlike the menu building itself, but it only
    /// inspects `isFolder`/`children` and creates nothing.
    static func containsDestination(_ items: [MailboxItem]) -> Bool {
        items.contains { $0.isFolder ? containsDestination($0.children ?? []) : true }
    }
}

// MARK: - A SwiftUI button that drops the menu

/// Owns the root menu and the root builder for one button.
///
/// An `ObservableObject` only so it can be a `@StateObject` and so survive the
/// button's body re-running; it never publishes anything, and nothing observes
/// it. That matters: a view that observed this would re-render on every model
/// change, which is the cost this whole file exists to remove.
@MainActor
final class MoveToMenuController: ObservableObject {
    private let menu = NSMenu()

    /// Retained because `NSMenu.delegate` is weak. Replaced on each pop rather
    /// than kept in step with the tree: the tree is read fresh at pop time, so a
    /// builder never outlives the menu it filled.
    private var rootBuilder: MailboxMenuBuilder?

    /// The view the menu hangs from, installed by `MenuAnchor` below. Weak: it
    /// belongs to the view hierarchy, and SwiftUI may replace it at will.
    weak var anchor: NSView?

    init() {
        // Same reasoning as the submenus, and doubly so for the root: every item
        // at the top level that is a folder carries a submenu left empty until
        // opened, so automatic validation would grey out every folder.
        menu.autoenablesItems = false
    }

    /// `tree` is passed in at the moment of the click, not held, so the menu can
    /// never show a tree older than the button press.
    func popUp(tree: [MailboxItem],
               onPick: @escaping (MailboxItem.ID) -> Void,
               onNew: ((MailboxItem.ID?) -> Void)? = nil) {
        let builder = MailboxMenuBuilder(items: tree, onPick: onPick, onNew: onNew)
        rootBuilder = builder
        menu.delegate = builder      // popUp asks the delegate to fill it

        // Captured before the hop: by the time the closure runs, the click that
        // opened the menu is no longer `NSApp.currentEvent`.
        let event = NSApp.currentEvent

        // Deferred rather than called straight through. `popUp` spins NSMenu's
        // own nested tracking loop, and running that inside a SwiftUI Button
        // action means running it inside SwiftUI's event dispatch: the button's
        // mouse-up doesn't complete until the menu closes (so it sits drawn in
        // its pressed state the whole time), and `onPick` would publish into a
        // view update that hadn't returned. `SettingsView.openSettingsWindow
        // Legacy` defers for the same reason, as does ContentView's selection
        // `.onChange`.
        //
        // The context menu gets away with popping synchronously because it does
        // it from an `NSEvent` monitor, outside SwiftUI altogether. That isn't
        // an argument that this path is safe.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let anchor = self.anchor, anchor.window != nil {
                // `MenuAnchorView` forces `isFlipped == false`, so (0, 0) is its
                // bottom-left corner, and a menu positioned there hangs below
                // the button the way a pull-down should. Don't remove that
                // override without revisiting this point: in a flipped view the
                // same coordinate is the *top* left and the menu would cover the
                // button. If the menu comes up over the button anyway, suspect
                // the anchor's *size* before this point — see `MenuAnchor`.
                self.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchor)
            } else if let event, let view = NSApp.keyWindow?.contentView {
                // The anchor is missing or offscreen — pop at the pointer rather
                // than not at all. Same call the context menu uses.
                NSMenu.popUpContextMenu(self.menu, with: event, for: view)
            }
        }
    }
}

// MARK: - The "New…" prompt

/// The name-and-kind dialog behind Move to ▸ New…, Eudora 7's main way of
/// creating mailboxes. Plain AppKit (`NSAlert.runModal`), which is fine here:
/// it runs from a menu action, after menu tracking has ended and outside any
/// SwiftUI update pass.
@MainActor
enum NewMailboxDialog {
    struct Response {
        let name: String
        let isFolder: Bool
    }

    /// Returns nil on Cancel. The name comes back untrimmed and unvalidated —
    /// `MailboxTreeMutator` owns the rules, and its errors carry the reason.
    static func run(locationDisplay: String) -> Response? {
        let alert = NSAlert()
        alert.messageText = "New Mailbox"
        alert.informativeText = "Create a mailbox in \u{201C}\(locationDisplay)\u{201D}:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 230, height: 24))
        field.placeholderString = "Mailbox name"
        let checkbox = NSButton(checkboxWithTitle: "Make it a folder",
                                target: nil, action: nil)
        checkbox.frame = NSRect(x: 0, y: 2, width: 230, height: 20)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 56))
        accessory.addSubview(field)
        accessory.addSubview(checkbox)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Response(name: field.stringValue, isFolder: checkbox.state == .on)
    }
}

/// An empty `NSView` that exists only to give the menu somewhere to hang from.
private final class MenuAnchorView: NSView {
    /// See the positioning note in `MoveToMenuController.popUp`.
    override var isFlipped: Bool { false }
}

/// Puts a `MenuAnchorView` behind the button's label and hands it to the
/// controller. Costs one empty view; nothing is drawn.
private struct MenuAnchor: NSViewRepresentable {
    let controller: MoveToMenuController

    // `makeNSView`/`updateNSView` are protocol witnesses, so they inherit
    // `NSViewRepresentable`'s main-actor isolation and may touch the
    // `@MainActor` controller. A plain method added here would *not* — see the
    // note on `MessageContextMenuInstaller.install`.
    func makeNSView(context: Context) -> NSView {
        let view = MenuAnchorView(frame: .zero)
        controller.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-assigned rather than assumed: SwiftUI can hand back a different
        // view than the one made, and the controller holds this weakly.
        controller.anchor = nsView
    }
}

/// A button whose menu is the mailbox tree, built lazily in AppKit.
///
/// The label is supplied by the caller because the two users want different
/// ones — a toolbar `Label` with an icon, and a bare `Text` matching the
/// in-window menu bar's titles — and because leaving it to the caller keeps the
/// button's own styling out of this file. Style and `.disabled` are applied at
/// the call site.
///
/// `tree` is a closure, not a value: it is called when the button is clicked, so
/// the menu is built from the tree as it is *then*, and the button doesn't have
/// to re-render to stay current.
struct MoveToMenuButton<Label: View>: View {
    let tree: () -> [MailboxItem]
    let onPick: (MailboxItem.ID) -> Void
    /// Optional "New…" handler, per level; nil leaves the item out.
    var onNew: ((MailboxItem.ID?) -> Void)? = nil
    @ViewBuilder let label: () -> Label

    @StateObject private var controller = MoveToMenuController()

    var body: some View {
        Button {
            controller.popUp(tree: tree(), onPick: onPick, onNew: onNew)
        } label: {
            label().background(
                // Made to fill deliberately. The menu is positioned from this
                // view's bottom-left, and a background that collapsed to zero
                // would be *centred* on the label — putting that corner in the
                // middle of the button and dropping the menu across it.
                MenuAnchor(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
    }
}

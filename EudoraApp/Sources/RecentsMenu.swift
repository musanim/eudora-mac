import SwiftUI
import AppKit

// The sidebar's Recents row and the menu it drops.
//
// Recents lists the mailboxes mail has been filed into lately — see
// `RecentMailboxes` for what goes on the list and how long it stays. Picking an
// entry opens that mailbox with its newest message selected
// (`AppModel.openRecent`).
//
// The menu is AppKit for the same reason `MoveToMenu`'s is: SwiftUI builds menu
// content eagerly, so a SwiftUI `Menu` over a list this long would be built on
// every sidebar render whether or not anyone opened it. This one is built in
// `menuNeedsUpdate`, at the moment it opens, from the model as it is then.

/// Fills the Recents menu when it opens.
///
/// Retained by the controller because `NSMenu.delegate` is weak.
@MainActor
final class RecentsMenuBuilder: NSObject, NSMenuDelegate {
    /// Read at open time, not held as a value: the list changes with every
    /// filing, and a menu showing yesterday's is worse than no menu.
    private let entries: () -> [(id: MailboxItem.ID, display: String)]
    private let onPick: (MailboxItem.ID) -> Void

    init(entries: @escaping () -> [(id: MailboxItem.ID, display: String)],
         onPick: @escaping (MailboxItem.ID) -> Void) {
        self.entries = entries
        self.onPick = onPick
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Rebuilt from empty, so this is idempotent — `MoveToMenu` relies on the
        // same property when it measures a menu's width before popping it.
        menu.removeAllItems()

        let list = entries()
        guard !list.isEmpty else {
            // A disabled item rather than an empty menu: an empty NSMenu opens as
            // a one-pixel sliver that reads as a glitch.
            let empty = NSMenuItem(title: "No recent mailboxes", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        // Bare display names, by Stephen's decision: two mailboxes anywhere in
        // the tree can share a name, but where that happens (two "MISC") the
        // pair are interchangeable to him and the folder path is only noise.
        for entry in list {
            let item = NSMenuItem(title: entry.display,
                                  action: #selector(pick(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            menu.addItem(item)
        }
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? MailboxItem.ID else { return }
        onPick(id)
    }
}

/// Owns the Recents menu and its builder.
///
/// An `ObservableObject` only so it can be a `@StateObject` and survive the
/// row's body re-running; it publishes nothing, and nothing observes it. Same
/// shape and same reasoning as `MoveToMenuController`.
@MainActor
final class RecentsMenuController: ObservableObject, MenuAnchoring {
    private let menu = NSMenu()
    private var builder: RecentsMenuBuilder?

    /// The row the menu hangs from, installed by `MenuAnchor`.
    weak var anchor: NSView?

    init() {
        // Without this, automatic validation runs after `menuNeedsUpdate` and
        // greys out every item — items whose action is on a plain NSObject
        // target fail the responder-chain check. `MoveToMenu` sets it for a
        // related reason (empty submenus) and the comment there is the fuller
        // account.
        menu.autoenablesItems = false
    }

    func popUp(entries: @escaping () -> [(id: MailboxItem.ID, display: String)],
               onPick: @escaping (MailboxItem.ID) -> Void) {
        let builder = RecentsMenuBuilder(entries: entries, onPick: onPick)
        self.builder = builder
        menu.delegate = builder

        // Captured before the hop below: by the time the closure runs, the click
        // that opened the menu is no longer `NSApp.currentEvent`.
        let event = NSApp.currentEvent

        // Deferred, not called straight through. `popUp` spins NSMenu's own
        // nested tracking loop, and doing that inside a SwiftUI Button action
        // runs it inside SwiftUI's event dispatch — the row would sit drawn in
        // its pressed state until the menu closed, and `onPick` would publish
        // into a view update that hadn't returned. The full account is in
        // `MoveToMenuController.popUp`.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let anchor = self.anchor, anchor.window != nil {
                // `MenuAnchorView.isFlipped` is false, so (0, 0) is its
                // bottom-left corner and the menu hangs below the row rather
                // than over it.
                self.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchor)
            } else if let event, let view = NSApp.keyWindow?.contentView {
                NSMenu.popUpContextMenu(self.menu, with: event, for: view)
            }
        }
    }
}

/// The Recents row in the sidebar, below the system mailboxes.
///
/// **It carries no `.tag`, and that is what keeps it out of the selection.**
/// Selectability in the sidebar `List` comes from the tag `MailboxTree.row(for:)`
/// attaches; an untagged row is inert, which is how the `Divider()` above it
/// already behaves. Clicking Recents therefore drops the menu and leaves the
/// sidebar selection — and the message list under it — exactly where they were.
///
/// Takes closures rather than the model so the sidebar doesn't gain a dependency
/// that re-renders it: `MailboxTree` is `Equatable` on three values, and the
/// recents list is not one of them (it doesn't need to be — the list is read
/// when the menu opens).
/// It also carries the two rules that make Recents a set of its own — drawn on
/// its own edges rather than as rows between the sets, so they cost no vertical
/// space. `SidebarSetRule` records why, and what to try if they come out short of
/// the window edges.
struct RecentsRow: View {
    let entries: () -> [(id: MailboxItem.ID, display: String)]
    let onPick: (MailboxItem.ID) -> Void
    /// Suppressed when there is nothing on that side to be parted from.
    var ruleAbove = true
    var ruleBelow = true

    @StateObject private var controller = RecentsMenuController()

    var body: some View {
        Button {
            controller.popUp(entries: entries, onPick: onPick)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .frame(width: 18)
                Text("Recents")
                    .font(EudoraFont.list)
                Spacer()
            }
            // Before `contentShape`, so the padded strip is clickable too rather
            // than being a dead band at the top and bottom of the row.
            .padding(.vertical, SidebarRowMetrics.recentsRowPadding)
            // Without this the button is only hittable on the glyph and the
            // word; the rest of the row would fall through to the List.
            .contentShape(Rectangle())
            .background(
                // Made to fill deliberately: the menu is positioned from this
                // view's bottom-left, and a background collapsed to zero would
                // be centred on the label, dropping the menu across the row.
                MenuAnchor(target: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
        .buttonStyle(.plain)
        // Offset outward, because a row edge is not the middle of the gap — see
        // `SidebarRowMetrics.setRuleOffset`. Overlays don't clip here (the
        // rules' horizontal overhang already proved that), so this moves the
        // line without moving anything else.
        .overlay(alignment: .top) {
            if ruleAbove {
                SidebarSetRule().offset(y: -SidebarRowMetrics.setRuleOffset)
            }
        }
        .overlay(alignment: .bottom) {
            if ruleBelow {
                SidebarSetRule().offset(y: SidebarRowMetrics.setRuleOffset)
            }
        }
        // The list's own hairlines would otherwise sit a point away from the
        // rules above and below, doubling each of them.
        .listRowSeparator(.hidden)
    }
}

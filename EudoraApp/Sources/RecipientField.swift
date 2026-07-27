import SwiftUI
import AppKit

/// A recipient field (To / Cc / Bcc) with recently-used auto-fill.
///
/// SwiftUI's `TextField` has no completion dropdown on macOS 13, so this is an
/// `NSTextField` bridged in. As you type the current comma-separated token, a
/// non-modal list of recently-used matches appears beneath the field. Arrow keys
/// move the highlight, Return accepts it, Esc dismisses, and — once you've
/// arrowed onto an entry — the Delete key forgets it. Everything else (typing,
/// commas, editing) behaves like an ordinary field.
///
/// The dropdown is a `.nonactivatingPanel` so the field keeps focus and typing
/// never stops; the key handling is done in the field editor's
/// `doCommandBySelector`, and the panel is driven programmatically.
///
/// It's generic over the composer's focus value so it can join the same
/// `@FocusState` the SwiftUI header fields use: SwiftUI's `.focused` doesn't
/// reliably move first responder into a bridged `NSView`, so the field watches
/// the binding and drives first responder itself (for Shift-Tab arriving via
/// `BackTabCatcher`) while writing focus back when editing begins (clicks and
/// AppKit's forward-Tab loop).
struct RecipientField<F: Hashable>: NSViewRepresentable {
    @Binding var text: String
    var focus: FocusState<F?>.Binding
    let id: F
    /// Matches for the token being typed, most-recently-used first.
    let completions: (String) -> [String]
    /// Forget a recipient (Delete in the dropdown).
    let remove: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focus: focus, id: id, completions: completions, remove: remove)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.stringValue = text
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.completions = completions
        context.coordinator.remove = remove
        context.coordinator.focus = focus
        context.coordinator.id = id
        // Adopt an external change (a seeded draft) without clobbering an edit.
        if field.stringValue != text { field.stringValue = text }
        // Shift-Tab (and the initial focus) arrive as a change to the binding;
        // move first responder to match. Deferred so we're not mutating the
        // responder chain mid-update. The begin-editing callback writes focus
        // back, so a value that already matches makes no change and can't loop.
        if focus.wrappedValue == id, field.window != nil, field.currentEditor() == nil {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak field, weak coordinator] in
                // Re-check intent: focus may have moved on (a click into another
                // field) between enqueue and now, and grabbing it back would yank
                // the user off wherever they actually are.
                guard let field, let coordinator,
                      coordinator.focus.wrappedValue == coordinator.id,
                      field.currentEditor() == nil
                else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.panel.hide()
    }

    // MARK: - coordinator

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        var focus: FocusState<F?>.Binding
        var id: F
        var completions: (String) -> [String]
        var remove: (String) -> Void
        weak var field: NSTextField?
        let panel = RecipientCompletionsPanel()

        /// True once the user has arrowed onto an entry — the gate for Delete
        /// forgetting it (so plain Backspace while typing still edits text).
        private var navigated = false

        init(text: Binding<String>,
             focus: FocusState<F?>.Binding,
             id: F,
             completions: @escaping (String) -> [String],
             remove: @escaping (String) -> Void) {
            self.text = text
            self.focus = focus
            self.id = id
            self.completions = completions
            self.remove = remove
            super.init()
            panel.onPick = { [weak self] entry in self?.accept(entry) }
        }

        // MARK: editing

        func controlTextDidBeginEditing(_ notification: Notification) {
            // Keep the shared @FocusState in step when focus arrives via a click
            // or AppKit's forward-Tab loop rather than through the binding.
            if focus.wrappedValue != id { focus.wrappedValue = id }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }
            text.wrappedValue = field.stringValue
            navigated = false            // typing = back to text mode
            refresh()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            panel.hide()
        }

        /// Recompute the current token and show/update/hide the dropdown.
        private func refresh() {
            guard let field, let editor = field.currentEditor() else { panel.hide(); return }
            let token = Self.currentToken(in: field.stringValue,
                                          caret: editor.selectedRange.location).text
            let matches = token.isEmpty ? [] : completions(token)
            if matches.isEmpty {
                panel.hide()
            } else {
                panel.show(items: matches, below: field, keepingSelection: navigated)
            }
        }

        // MARK: key commands

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                guard panel.isShowing else { return false }
                navigated = true
                panel.moveSelection(by: 1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard panel.isShowing else { return false }
                navigated = true
                panel.moveSelection(by: -1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                guard panel.isShowing, let entry = panel.selectedItem else { return false }
                accept(entry)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard panel.isShowing else { return false }
                panel.hide()
                return true
            case #selector(NSResponder.insertTab(_:)):
                panel.hide()             // let Tab move to the next field
                return false
            case #selector(NSResponder.deleteForward(_:)):
                // The forward-delete key (⌦). It doesn't collide with editing the
                // way Backspace does, so it forgets the highlighted entry whenever
                // the list is up — no need to arrow onto it first.
                guard panel.isShowing, let entry = panel.selectedItem else { return false }
                remove(entry)
                refresh()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                // Backspace too, but only once the user is navigating the list;
                // otherwise it edits the text as usual (fixing a typo).
                guard panel.isShowing, navigated, let entry = panel.selectedItem else { return false }
                remove(entry)
                refresh()
                return true
            default:
                // Anything else — notably a bare caret move (arrow left/right,
                // Home/End), which changes the token but fires no text-change
                // callback. Let it run, then recompute against the new caret and
                // drop out of list-navigation mode so Backspace edits text rather
                // than forgetting an entry.
                navigated = false
                DispatchQueue.main.async { [weak self] in self?.refresh() }
                return false
            }
        }

        // MARK: accept

        /// Replace the token being typed with the chosen recipient, add a
        /// separator, and dismiss the list.
        private func accept(_ entry: String) {
            guard let field, let editor = field.currentEditor() else { return }
            let caret = editor.selectedRange.location
            let token = Self.currentToken(in: field.stringValue, caret: caret)
            let replace = NSRange(location: token.start, length: caret - token.start)
            (editor as? NSTextView)?.insertText(entry, replacementRange: replace)
            text.wrappedValue = field.stringValue
            navigated = false
            panel.hide()
        }

        // MARK: token

        /// The token under the caret: the text from just after the last comma or
        /// semicolon (skipping the space after it) up to the caret, and where
        /// that replaceable token begins.
        static func currentToken(in string: String, caret: Int) -> (text: String, start: Int) {
            let ns = string as NSString
            let caret = max(0, min(caret, ns.length))
            let before = ns.substring(to: caret) as NSString
            let sep = before.rangeOfCharacter(from: CharacterSet(charactersIn: ",;"),
                                              options: .backwards)
            var start = sep.location == NSNotFound ? 0 : sep.location + sep.length
            while start < caret, ns.character(at: start) == 0x20 /* space */ { start += 1 }
            let token = ns.substring(with: NSRange(location: start, length: caret - start))
            return (token.trimmingCharacters(in: .whitespaces), start)
        }
    }
}

/// The non-modal list of completions shown under a recipient field.
final class RecipientCompletionsPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Called when a row is chosen (click or Return).
    var onPick: ((String) -> Void)?

    private let panel: NSPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var items: [String] = []

    /// Up to this many rows are shown before the list scrolls.
    private static let maxVisibleRows = 8
    private static let rowHeight: CGFloat = 20
    /// The scroll view's 1px border, top and bottom, kept clear of the rows.
    private static let verticalInset: CGFloat = 2

    var isShowing: Bool { panel.isVisible }

    var selectedItem: String? {
        let row = table.selectedRow
        return (row >= 0 && row < items.count) ? items[row] : nil
    }

    override init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        super.init()
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear

        table.headerView = nil
        table.backgroundColor = .clear
        // Plain style: the default `.automatic` resolves to an inset style that
        // pads each row, so a clip view sized to exactly one row clips it.
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: .init("recipient"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 5
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = scroll
    }

    /// Show (or update) the list beneath `field`. Keeps the current highlight
    /// when the user is navigating; otherwise highlights the first (best) match.
    func show(items: [String], below field: NSTextField, keepingSelection: Bool) {
        let priorSelection = keepingSelection ? selectedItem : nil
        self.items = items
        table.reloadData()

        let index = priorSelection.flatMap { items.firstIndex(of: $0) } ?? 0
        if !items.isEmpty {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }

        guard let window = field.window else { return }
        let rows = min(items.count, Self.maxVisibleRows)
        let height = CGFloat(rows) * Self.rowHeight + Self.verticalInset * 2
        let fieldInWindow = field.convert(field.bounds, to: nil)
        let fieldInScreen = window.convertToScreen(fieldInWindow)
        let frame = NSRect(x: fieldInScreen.minX,
                           y: fieldInScreen.minY - height - 1,
                           width: fieldInScreen.width,
                           height: height)
        panel.setFrame(frame, display: true)
        if !panel.isVisible { window.addChildWindow(panel, ordered: .above) }
    }

    func hide() {
        if panel.isVisible {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = table.selectedRow < 0 ? (delta > 0 ? -1 : items.count) : table.selectedRow
        let next = max(0, min(items.count - 1, current + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < items.count else { return }
        onPick?(items[row])
    }

    // MARK: table data

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
            ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = id
                f.lineBreakMode = .byTruncatingTail
                f.font = .systemFont(ofSize: NSFont.systemFontSize)
                return f
            }()
        cell.stringValue = items[row]
        return cell
    }
}

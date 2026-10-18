import SwiftUI
import AppKit
import EudoraStore

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
        let field = RecipientTextField()
        field.delegate = context.coordinator
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        // Wraps rather than scrolls sideways, so a long list is all visible —
        // and only between recipients; see `RecipientTextField`.
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.cell?.truncatesLastVisibleLine = false
        field.lineBreakMode = .byWordWrapping
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

    /// As tall as the wrapped recipients need at the offered width, and never
    /// shorter than one line. Nil for a size query with no usable width, which
    /// hands SwiftUI the field's intrinsic size: no preferred width, one-line
    /// height — so the field never asks for the width of its whole text.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField,
                      context: Context) -> CGSize? {
        guard let field = nsView as? RecipientTextField,
              let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: field.fittingHeight(forWidth: width))
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
            // The height may have changed with a new or removed line.
            field.invalidateIntrinsicContentSize()
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

// MARK: - wrapping between recipients

/// The `NSTextField` behind a recipient field: it wraps, but only at the start
/// of a recipient, so no address is ever split across lines.
///
/// Two drawing paths need steering, because a text field draws its text one way
/// at rest and another while being edited:
///
/// - **At rest** the cell draws with ordinary string drawing, which can only be
///   steered through its characters. `RecipientFieldCell.drawInterior` hands
///   that drawing `RecipientLineBreaks.displayString` instead — no-break spaces
///   inside each recipient — through a separate plain cell, so the field's real
///   value is never touched.
/// - **While editing** the text is in a field editor, a real `NSTextView`, whose
///   layout manager asks a delegate before breaking. The window's shared field
///   editor serves every field in the window, so steering it would steer the
///   Subject too; each recipient field supplies its own instead
///   (`RecipientFieldCell.fieldEditor(for:)`).
///
/// The storage lives here, on the view, rather than on the cell: `NSCell`
/// copies itself with a bitwise copy that doesn't retain Swift references, so a
/// cell that owned objects would be one copy away from a double release.
final class RecipientTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { RecipientFieldCell.self }
        set {}
    }

    private let breaker = RecipientLineBreaker()

    /// This field's own field editor. TextKit 1 explicitly, because the
    /// break-steering delegate is an `NSLayoutManager` one; a default
    /// `NSTextView()` is TextKit 2 on macOS 12 and later.
    lazy var recipientEditor: NSTextView = {
        let editor = NSTextView(usingTextLayoutManager: false)
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.layoutManager?.delegate = breaker
        return editor
    }()

    /// The plain cell the at-rest text is drawn and measured through.
    private let drawingCell = NSTextFieldCell(textCell: "")

    /// `drawingCell` set up to draw `text` exactly as this field's cell would —
    /// same bezel (which decides the text inset), font and colour — but with
    /// breaks only between recipients.
    func displayCell(showing text: String) -> NSTextFieldCell {
        let d = drawingCell
        if let cell = cell as? NSTextFieldCell {
            d.isBezeled = cell.isBezeled
            d.bezelStyle = cell.bezelStyle
            d.isBordered = cell.isBordered
            d.font = cell.font
            d.textColor = cell.textColor
            d.alignment = cell.alignment
            d.controlSize = cell.controlSize
            d.isEnabled = cell.isEnabled
        }
        d.wraps = true
        d.isScrollable = false
        d.truncatesLastVisibleLine = false
        d.lineBreakMode = .byWordWrapping
        d.stringValue = RecipientLineBreaks.displayString(text)
        return d
    }

    /// The height the wrapped text needs at `width`; one line at least.
    ///
    /// While editing, at the width the field already has, the answer comes from
    /// the field editor's own layout — the text the user is looking at — rather
    /// than from the at-rest drawing, so a line the editor wraps onto is never
    /// one the frame leaves out.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        if let editing = editorHeight(forWidth: width) {
            return max(Self.minimumHeight, ceil(editing))
        }
        let bounds = NSRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)
        let needed = displayCell(showing: stringValue).cellSize(forBounds: bounds).height
        return max(Self.minimumHeight, ceil(needed))
    }

    /// The field editor's laid-out height plus the bezel's vertical inset, or
    /// nil when not editing or when `width` isn't the current width (the
    /// editor is laid out for the frame it has, not the one being proposed).
    private func editorHeight(forWidth width: CGFloat) -> CGFloat? {
        guard let editor = currentEditor() as? NSTextView,
              abs(width - bounds.width) < 0.5,
              let layout = editor.layoutManager, let container = editor.textContainer,
              let cell
        else { return nil }
        layout.ensureLayout(for: container)
        let text = layout.usedRect(for: container).height + editor.textContainerInset.height * 2
        let inset = bounds.height - cell.titleRect(forBounds: bounds).height
        return text + max(0, inset)
    }

    /// The one-line height the field had when it was fixed.
    static let minimumHeight: CGFloat = 22

    /// No preferred width — the field takes what it is given — and the height
    /// that width needs. Without this a wrapping field reports its whole text's
    /// width as intrinsic, and would try to widen the window to fit it.
    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 0 ? bounds.width : 200
        return NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight(forWidth: width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

/// The cell for `RecipientTextField`. Deliberately holds no state of its own —
/// see the note on the field.
final class RecipientFieldCell: NSTextFieldCell {
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        (controlView as? RecipientTextField)?.recipientEditor
            ?? super.fieldEditor(for: controlView)
    }

    /// At rest, draw through the field's display cell. While editing the field
    /// editor shows the text, and the cell's own drawing is left to AppKit.
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let field = controlView as? RecipientTextField, field.currentEditor() == nil else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        field.displayCell(showing: stringValue).drawInterior(withFrame: cellFrame, in: controlView)
    }
}

/// The field editor's layout-manager delegate: a line may break only where a
/// recipient begins.
///
/// If one recipient is wider than the field, there is no allowed break inside
/// it and TextKit falls back to breaking it by character — the one case where
/// an address does get split, because the alternative is text running out of
/// the field.
final class RecipientLineBreaker: NSObject, NSLayoutManagerDelegate {
    /// The layout manager asks once per candidate break, so the starts are
    /// worked out once per change of text, not once per question.
    private var text = ""
    private var starts = Set<Int>()

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        let current = layoutManager.textStorage?.string ?? ""
        if current != text {
            text = current
            starts = RecipientLineBreaks.entryStarts(in: current)
        }
        return starts.contains(charIndex)
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

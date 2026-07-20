import SwiftUI
import AppKit

/// Click a column header to sort the message list; click it again to reverse.
///
/// **Why this is AppKit.** SwiftUI's `Table` makes headers clickable only when it
/// is given a `sortOrder` binding, and that binding requires the `value:` keypath
/// form of `TableColumn` — which this table deliberately doesn't use, because
/// each cell's content has to carry a hand-measured offset to land under its
/// header (see `MessageTableMetrics`). Even taking the binding, SwiftUI would
/// only *report* a desired order; the rows still have to be sorted by hand. So
/// the binding buys the click and nothing else, at the cost of reopening the
/// column-geometry work. Watching the mouse is cheaper and touches none of it.
///
/// The same shape as `MessageContextMenuInstaller`, for the same reason: a local
/// event monitor, because the `NSTableView` backing a SwiftUI `Table` belongs to
/// SwiftUI and can be neither subclassed nor given a delegate of ours.
///
/// This also owns the sort indicator, since it is the one place that knows both
/// the sort and the AppKit column it belongs to.
struct MessageHeaderSortInstaller: NSViewRepresentable {
    @ObservedObject var model: AppModel

    final class Coordinator {
        weak var table: NSTableView?
        var controller: MessageHeaderSortController?
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

    /// `@MainActor` for the same reason as `MessageContextMenuInstaller.install`:
    /// a plain method on a representable is nonisolated, and this touches a
    /// main-actor-isolated controller.
    @MainActor
    private func install(near view: NSView,
                         coordinator: Coordinator,
                         model: AppModel,
                         attemptsLeft: Int) {
        // Fast path when nothing structural can have changed. Unlike the context
        // menu's, this still re-applies the indicator every pass: `updateNSView`
        // runs on published changes, and the sort is one of them.
        if let known = coordinator.table, known.window != nil,
           let controller = coordinator.controller {
            controller.model = model
            reapplyIndicator(table: known, sort: model.sort)
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

        // A rebuilt `Table` is a new `NSTableView`, and the monitor holds the old
        // one weakly — so a stale controller would simply stop responding.
        if coordinator.table !== table || coordinator.controller == nil {
            coordinator.table = table
            coordinator.controller = MessageHeaderSortController(model: model, table: table)
        }
        coordinator.controller?.model = model
        reapplyIndicator(table: table, sort: model.sort)
    }

    /// Apply the indicator, retrying while the glyph column's header cell isn't
    /// there to take it.
    ///
    /// The retry is not belt-and-braces. `TableHeaderIconStyler` installs the
    /// `ImageHeaderCell` that carries the status/attachment triangle, and it does
    /// so on its *own* schedule — it waits for the art to load and for
    /// `table.bounds.width > 1`, retrying every 0.2 s for up to about four
    /// seconds after a `Table` is built. A `Table` is rebuilt on every mailbox
    /// switch (the list goes empty in between), so an indicator set before that
    /// cell exists lands on a plain `NSTableHeaderCell` and is simply lost. The
    /// budget here matches the styler's, for the obvious reason.
    ///
    /// Only the glyph column needs this; the other three take AppKit's own
    /// per-column indicator, which needs nothing installed first.
    ///
    /// `applyIndicator` is idempotent and compares against the live AppKit values
    /// before touching anything, so a retry that finds everything already right
    /// costs a few comparisons and never repaints.
    @MainActor
    private func reapplyIndicator(table: NSTableView, sort: MessageSort?, attemptsLeft: Int = 20) {
        guard !MessageHeaderSortController.applyIndicator(table: table, sort: sort),
              attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak table] in
            guard let table else { return }
            reapplyIndicator(table: table, sort: sort, attemptsLeft: attemptsLeft - 1)
        }
    }
}

/// Turns clicks on the message table's header into sorts, and paints the
/// indicator that says which column won.
@MainActor
final class MessageHeaderSortController: NSObject {
    var model: AppModel
    private weak var table: NSTableView?
    private var monitor: Any?

    /// Table column index → the thing it sorts by. Must match the `TableColumn`
    /// order in `MessageListView`, the same way `tableCell(column:)` does.
    ///
    /// Column 0 is nil because it is the shared glyph column and carries *two*
    /// sortable things; `sortColumn(at:x:header:)` splits it by x position.
    private static let columnSortKeys: [MessageSortColumn?] = [nil, .who, .date, .subject]

    init(model: AppModel, table: NSTableView) {
        self.model = model
        self.table = table
        super.init()
        installEventMonitor()
    }

    deinit {
        // Not main-actor isolated, and `removeMonitor` doesn't need to be.
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func installEventMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let table = self.table,
                  let header = table.headerView, let window = table.window,
                  event.window === window else { return event }

            // Only clicks on this table's own header, and only on a real column.
            // Everything else — rows, the sidebar, the preview — passes through.
            //
            // A hit test rather than a bounds check, matching the scroll monitor
            // in `TableScrollStateSyncer`: anything drawn in front of the header
            // keeps its own clicks.
            guard let hit = window.contentView?.hitTest(event.locationInWindow),
                  hit === header || hit.isDescendant(of: header) else { return event }
            let point = header.convert(event.locationInWindow, from: nil)
            let column = header.column(at: point)
            guard column >= 0 else { return event }

            guard let key = self.sortColumn(at: column, x: point.x, header: header) else {
                return event
            }
            // Only the first click of a multi-click acts. A double-click would
            // otherwise sort and immediately reverse, landing back where it
            // started — which reads as the header having stopped working. The
            // later clicks are still consumed, so AppKit doesn't get them either.
            guard event.clickCount == 1 else { return nil }
            self.model.toggleSort(key)
            // Consumed. AppKit's own header handling is column dragging and
            // resizing, both of which would fight the pinned widths that keep the
            // headers aligned with their content (see `MessageColumnWidths`).
            return nil
        }
    }

    /// What a click at `x` in `column` sorts by.
    ///
    /// The leading column holds the status and attachment icons side by side, as
    /// Eudora's two separate columns did, so which half was hit decides which of
    /// them is meant. The split is the status icon's own width — the same number
    /// the header art and the row glyphs are laid out from, so the boundary
    /// falls exactly where the icons visibly meet.
    private func sortColumn(at column: Int, x: CGFloat, header: NSTableHeaderView)
        -> MessageSortColumn? {
        guard column < Self.columnSortKeys.count else { return nil }
        if let key = Self.columnSortKeys[column] { return key }
        let rect = header.headerRect(ofColumn: column)
        return (x - rect.minX) < HeaderIcon.status.width ? .status : .attachment
    }

    // MARK: indicator

    /// Show which column is sorted, and which way.
    ///
    /// Idempotent and guarded on the live AppKit values, like
    /// `TableHeaderIconStyler.enforce` — it runs on every published change, and
    /// marking the header dirty unconditionally would repaint it constantly.
    ///
    /// - Returns: false only when there is a glyph-column indicator to show and
    ///   the `ImageHeaderCell` that would show it hasn't been installed yet, so
    ///   the caller knows to come back — see `reapplyIndicator`. True in every
    ///   other case, including "nothing to show", so the common path never sets a
    ///   retry chain running.
    @discardableResult
    static func applyIndicator(table: NSTableView, sort: MessageSort?) -> Bool {
        let ascending = sort?.ascending ?? true
        let art = indicatorArt(ascending: ascending)
        var changed = false
        var complete = true

        for (index, column) in table.tableColumns.enumerated() {
            // The glyph column draws its own indicator, under whichever of its
            // two icons is sorted — AppKit's is per column, and this column has
            // two sortable halves. See `ImageHeaderCell.drawSortIndicator`.
            if index == 0 {
                let icon: Int?
                switch sort?.column {
                case .status:     icon = 0
                case .attachment: icon = 1
                default:          icon = nil
                }
                guard let cell = column.headerCell as? ImageHeaderCell else {
                    // Only worth coming back for if there is something to draw.
                    // A cell that never becomes an `ImageHeaderCell` (a missing
                    // asset — see `TableHeaderIconStyler.apply`) would otherwise
                    // start a fresh four-second retry chain on every published
                    // change, forever, to set an indicator of nil.
                    if icon != nil { complete = false }
                    continue
                }
                if cell.sortedIcon != icon || cell.sortAscending != ascending {
                    cell.sortedIcon = icon
                    cell.sortAscending = ascending
                    changed = true
                }
                continue
            }

            let wanted = (columnSortKeys.indices.contains(index)
                          && columnSortKeys[index] == sort?.column) ? art : nil
            if table.indicatorImage(in: column) !== wanted {
                table.setIndicatorImage(wanted, in: column)
                changed = true
            }
        }

        // The highlight AppKit puts behind a sorted column's title. Left nil for
        // the glyph column: its header cell paints artwork edge to edge, and the
        // highlight under it reads as a rendering fault rather than as emphasis.
        let highlighted: NSTableColumn? = {
            guard let sort, let index = columnSortKeys.firstIndex(of: sort.column),
                  index < table.tableColumns.count else { return nil }
            return table.tableColumns[index]
        }()
        if table.highlightedTableColumn !== highlighted {
            table.highlightedTableColumn = highlighted
            changed = true
        }

        if changed { table.headerView?.needsDisplay = true }
        return complete
    }

    /// The little triangle, cached per direction.
    ///
    /// `NSAscendingSortIndicator` and `NSDescendingSortIndicator` are the names
    /// AppKit's own table headers use, but they are undocumented, and
    /// `NSImage(named:)` returning nil for them would leave every column with no
    /// indicator at all — silently, with nothing in the log. So there is a drawn
    /// fallback, the same shape `ImageHeaderCell` paints for the glyph column.
    ///
    /// Cached because `setIndicatorImage(_:in:)` is compared by identity in
    /// `applyIndicator`: a freshly built image every pass would never compare
    /// equal, and the header would be marked dirty on every published change.
    private static func indicatorArt(ascending: Bool) -> NSImage {
        if let cached = indicatorCache[ascending] { return cached }
        let system = NSImage(named: ascending ? "NSAscendingSortIndicator"
                                              : "NSDescendingSortIndicator")
        let image = system ?? drawnIndicator(ascending: ascending)
        indicatorCache[ascending] = image
        return image
    }

    private static var indicatorCache: [Bool: NSImage] = [:]

    private static func drawnIndicator(ascending: Bool) -> NSImage {
        let size = NSSize(width: 9, height: 9)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            let inset: CGFloat = 1.5
            let left = rect.minX + inset, right = rect.maxX - inset
            let low = rect.minY + inset, high = rect.maxY - inset
            if ascending {
                path.move(to: NSPoint(x: (left + right) / 2, y: high))
                path.line(to: NSPoint(x: right, y: low))
                path.line(to: NSPoint(x: left, y: low))
            } else {
                path.move(to: NSPoint(x: (left + right) / 2, y: low))
                path.line(to: NSPoint(x: right, y: high))
                path.line(to: NSPoint(x: left, y: high))
            }
            path.close()
            NSColor.secondaryLabelColor.setFill()
            path.fill()
            return true
        }
    }
}

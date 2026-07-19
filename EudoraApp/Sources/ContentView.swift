import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var accounts: AccountStore

    private var hasSelection: Bool { model.selectedMessageID != nil }

    var body: some View {
        VStack(spacing: 0) {
            MenuBarView()
            if model.isIndexing { IndexingBar() }
            splitView
        }
        // Tells SplashWindow which window is SwiftUI's, so it doesn't have to
        // guess from NSApp.windows (which raced with window placement).
        .background(MainWindowAccessor())
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 180)
        } detail: {
            // Classic Eudora: message list on top, preview below.
            VSplitView {
                MessageListView()
                    .frame(minWidth: 460, minHeight: 150)
                PreviewView()
                    .frame(minHeight: 140)
            }
        }
        .navigationTitle("Eudora")
        .navigationSubtitle(model.status)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.receiveMail(accounts: accounts) } } label: {
                    Label("Check Mail", systemImage: "arrow.down.circle")
                }.disabled(model.isChecking)
                Button { model.composeNew() } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                Button { model.reply(all: false) } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }.disabled(!hasSelection)
                Button { model.forward() } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                }.disabled(!hasSelection)

                Menu {
                    ForEach(model.moveTargets) { t in
                        Button(t.display) { model.moveSelected(to: t.id) }
                    }
                } label: {
                    Label("Move", systemImage: "tray.and.arrow.up")
                }.disabled(!hasSelection || model.moveTargets.isEmpty)

                Button { model.deleteSelected() } label: {
                    Label("Delete", systemImage: "trash")
                }.disabled(!hasSelection)
            }
        }
        // Deferred on purpose: openDefaultIfAvailable blocks the main thread for
        // several seconds on a large tree, and the splash (shown in
        // EudoraApp.init) has to be drawn before that starts, not after.
        //
        // 50 ms, not a plain async hop: onAppear runs inside AppKit's display
        // pass, and a main-queue block posted there is drained in the *same*
        // run-loop iteration — before CoreAnimation commits. That could block
        // the thread for seconds in the very iteration that would have put the
        // splash on screen. A short delay guarantees an idle pass first.
        .onAppear {
            // Splash first — the main window exists by now, so it can be
            // centered over it, and the run loop is running, so it paints.
            SplashWindow.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                model.openDefaultIfAvailable()
            }
        }
        // React to selection *after* the view-update pass, so the follow-on
        // @Published mutations don't fire during it.
        //
        // `.onChange` alone isn't enough: when the change originates in a
        // selection binding (clicking a mailbox in the sidebar List), SwiftUI
        // may run the handler inside the same update, and loadListing()'s
        // @Published writes then draw "Publishing changes from within view
        // updates is not allowed." Hopping to the next runloop turn puts those
        // writes safely outside the update. Ordering is unchanged — both still
        // run before any user interaction can follow.
        .onChange(of: model.selectedMailboxID) { _ in
            DispatchQueue.main.async { model.loadListing() }
        }
        .onChange(of: model.selectedMessageID) { _ in
            DispatchQueue.main.async { model.loadMessage() }
        }
        .sheet(item: $model.composing) { draft in
            ComposeView(seed: draft)
                .environmentObject(model)
                .environmentObject(accounts)
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                Text(banner)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.top, 10)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        model.banner = nil
                    }
            }
        }
    }
}

// MARK: - Sidebar: mailbox tree

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.tree.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No mailboxes")
                        .foregroundStyle(.secondary)
                    Button("Open Eudora Folder…") { pickFolder(model) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: model.mailboxSelection) {
                    OutlineGroup(model.tree, children: \.children) { item in
                        MailboxRow(item: item)
                            .tag(item.id)
                    }
                }
            }
        }
    }
}

struct MailboxRow: View {
    let item: MailboxItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.isFolder ? .secondary : .primary)
                .frame(width: 18)
            Text(item.display)
                .fontWeight(item.hasUnread ? .semibold : .regular)
            Spacer()
            if !item.isFolder && item.messageCount > 0 {
                Text("\(item.messageCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Message-list geometry

/// The one place the message table's horizontal geometry is decided.
///
/// Two layout systems share this table and neither knows about the other:
/// AppKit places the column *headers* from `NSTableView.intercellSpacing`, while
/// SwiftUI places the cell *content* on a grid of its own that assumes AppKit's
/// default 17 pt spacing whatever we set. Left alone, the columns sit 17 pt
/// apart with another ~8 pt of SwiftUI cell padding on top — a visible trench
/// between the status icons and "Who".
///
/// So the spacing is zeroed on the AppKit side and the SwiftUI content is drawn
/// back to where the headers now are: column *i*'s content is displaced by the
/// spacing it still thinks precedes it (17 × i) plus its own padding.
///
/// The displacement is an `.offset`, not `.padding`: padding would take the
/// space out of the cell's width and start truncating long subjects, whereas an
/// offset only moves the drawing.
///
/// **These values are measured, not chosen.** If a future macOS changes
/// SwiftUI's internal spacing, headers and content drift apart again, linearly
/// left to right — that symptom means `swiftUISpacing` is stale.
enum MessageTableMetrics {
    /// What we set AppKit's intercell spacing to. Zero butts the columns up.
    static let appKitSpacing: CGFloat = 0

    /// The spacing SwiftUI lays cell content out with regardless (macOS 13).
    static let swiftUISpacing: CGFloat = 17

    /// Extra inset carried by the leading glyph column only.
    ///
    /// Measured, and it applies to that column alone: with it added to the text
    /// columns as well they landed ~8 pt left of their headers, while the glyph
    /// column needs it to line up. The likely reason is that the glyph cell is an
    /// `HStack` of fixed-width frames while the text cells are bare `Text`, and
    /// SwiftUI treats the two differently.
    static let leadingGlyphInset: CGFloat = 8

    /// The text columns' headers sit this far right of where the spacing
    /// arithmetic alone puts their content — AppKit's own inset on a text header
    /// cell, which the icon column doesn't have because its header is drawn by
    /// `ImageHeaderCell` edge to edge. Measured.
    static let textHeaderInset: CGFloat = 2

    /// How far left column `index`'s content must be drawn to meet its header.
    static func contentOffset(column index: Int) -> CGFloat {
        let spacing = (swiftUISpacing - appKitSpacing) * CGFloat(index)
        if index == 0 { return -(spacing + leadingGlyphInset) }
        return -spacing + textHeaderInset
    }
}

extension View {
    /// Draws a table cell's content where its column header actually is.
    /// The column index must match the `TableColumn` order.
    func tableCell(column index: Int) -> some View {
        offset(x: MessageTableMetrics.contentOffset(column: index))
    }
}

// MARK: - Message-list column headers

/// A Eudora 7 column-header icon, taken from the original app's artwork and
/// shipped in `Assets.xcassets`.
///
/// Both icons live in a *single* table column, and that's deliberate.
///
/// As separate columns they were pushed apart by the table's 17 pt intercell
/// spacing, and that spacing can't be reduced: SwiftUI positions cell content on
/// a grid that assumes the default value, so changing it slides every header out
/// of line with its content, cumulatively, left to right. Drawing the icons out
/// into the gap doesn't work either — AppKit clips the header cell to its frame.
///
/// One column sidesteps all of it. There is no gap *within* a column, so the two
/// icons sit flush against each other in the header and the two glyphs line up
/// under them in each row. The column is exactly as wide as the two icons.
///
/// `TableHeaderIconStyler` still has to paint the header via AppKit: a SwiftUI
/// header is a `Text` and gets inset, and there's no API to stop that.
struct HeaderIcon {
    let assetName: String

    static let status = HeaderIcon(assetName: "ColumnStatus")
    static let attachment = HeaderIcon(assetName: "ColumnAttachment")

    /// The icons sharing the leading column, left to right.
    static let leadingColumns = [status, attachment]

    /// Combined width of that column: the icons laid side by side.
    static var leadingColumnWidth: CGFloat {
        leadingColumns.reduce(0) { $0 + $1.width }
    }

    /// Fallback width if the asset is missing (it shouldn't be).
    static let fallbackWidth: CGFloat = 22

    var nsImage: NSImage? { NSImage(named: assetName) }

    /// The icon's native width in points — the art is 1x, so this is its pixels.
    var width: CGFloat {
        guard let size = nsImage?.size, size.width > 0 else { return Self.fallbackWidth }
        return size.width
    }
}

/// An `NSTableHeaderCell` that draws an image across its entire frame: no inset,
/// no title, no separator. The Eudora art carries its own bezel, so the default
/// header chrome would only fight with it.
final class ImageHeaderCell: NSTableHeaderCell {
    /// Stretch the icon to fill the header, versus centering it at native size.
    /// The header row is usually a couple of points taller than the 22 px art.
    static let fillsHeader = false

    /// Held directly rather than in the inherited `NSCell.image`: AppKit ties
    /// that property to the cell *type*, and on a cell built with
    /// `initTextCell:` it can read back nil — which would silently draw nothing.
    private let icons: [NSImage]

    init(icons: [NSImage]) {
        self.icons = icons
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `NSCell`'s inherited copy is a shallow, non-retaining one, which would
    /// leave `icons` dangling. Copy explicitly instead.
    override func copy(with zone: NSZone? = nil) -> Any { ImageHeaderCell(icons: icons) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Lay the icons left to right at their native widths, so they touch.
        var x = cellFrame.minX
        for icon in icons {
            let target: NSRect
            if Self.fillsHeader {
                target = NSRect(x: x, y: cellFrame.minY,
                                width: icon.size.width, height: cellFrame.height)
            } else {
                target = NSRect(x: x, y: cellFrame.midY - icon.size.height / 2,
                                width: icon.size.width, height: icon.size.height)
            }
            // respectFlipped matters: NSTableHeaderView is flipped, and without
            // it the icons would draw upside down.
            icon.draw(in: target, from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            x += icon.size.width
        }
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        NSSize(width: icons.reduce(0) { $0 + $1.size.width },
               height: icons.map(\.size.height).max() ?? rect.height)
    }
}

/// Locates the `NSTableView` backing the message list, for the two places that
/// have to talk to AppKit directly (header icons, scroll position).
///
/// Care is needed because the mailbox sidebar is a table too. As of macOS 13 the
/// window contains:
///
///     SwiftUIOutlineTableView  columns=4  headerView=NSTableHeaderView
///     SwiftUIOutlineListView   columns=1  headerView=nil
///
/// The first is our `Table`, the second the sidebar `List`. Note that both are
/// `NSOutlineView` subclasses — an earlier version rejected outline views to
/// protect the sidebar and threw away the message table with it. So the
/// discriminator is the column count: the message table has four (glyphs, Who,
/// Date, Subject), the sidebar one. Climbing outward from the caller's own
/// backing view also biases toward the adjacent table.
enum MessageTableFinder {
    /// Minimum columns to be the message table rather than the sidebar.
    static let columnsAtLeast = 3

    static func table(near view: NSView) -> NSTableView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let found = search(in: current) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func search(in root: NSView) -> NSTableView? {
        if let table = root as? NSTableView, table.tableColumns.count >= columnsAtLeast {
            return table
        }
        for child in root.subviews {
            if let found = search(in: child) { return found }
        }
        return nil
    }
}

/// Installs `ImageHeaderCell` on the leading columns of the `Table` it is
/// attached to (as a `.background`).
///
/// This is deliberate SwiftUI-to-AppKit reach-through: from the backing view we
/// find the enclosing window's `NSTableView` and replace the header cells. It is
/// cosmetic and defensive throughout — if the hierarchy ever changes shape and
/// the table isn't found, the headers simply stay blank rather than breaking.
struct TableHeaderIconStyler: NSViewRepresentable {
    let icons: [HeaderIcon]

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The table doesn't exist yet during this pass of layout, so apply once
        // SwiftUI has committed the hierarchy — and retry a few times, since the
        // backing view can be in the tree before the Table's NSTableView is.
        DispatchQueue.main.async { apply(near: nsView, attemptsLeft: 5) }
    }

    private func apply(near view: NSView, attemptsLeft: Int) {
        let found = MessageTableFinder.table(near: view)
        if found == nil, attemptsLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                apply(near: view, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        guard let table = found else { return }

        // Close up the columns. AppKit lays the *headers* out from this property,
        // but SwiftUI positions cell content on its own grid that still assumes
        // the default spacing — so zeroing this alone slides every header 17 pt
        // per column left of its content. `MessageTableMetrics` cancels that on
        // the SwiftUI side; the two must be changed together.
        table.intercellSpacing = NSSize(width: MessageTableMetrics.appKitSpacing,
                                        height: table.intercellSpacing.height)
        let art = icons.compactMap(\.nsImage)
        guard !art.isEmpty, let column = table.tableColumns.first else { return }

        if !(column.headerCell is ImageHeaderCell) {
            column.headerCell = ImageHeaderCell(icons: art)
        }
        // Pin the width so AppKit can't resize the art away. This must agree with
        // the SwiftUI `.width(HeaderIcon.leadingColumnWidth)` on the same column —
        // both are the summed icon widths — or the two sides will overwrite each
        // other on every layout pass.
        let width = art.reduce(0) { $0 + $1.size.width }
        column.minWidth = width
        column.maxWidth = width
        column.width = width
        column.resizingMask = []
        table.headerView?.needsDisplay = true
    }
}

/// Keeps the message list's scroll position in sync with `AppModel`: records
/// where the user scrolled to, and restores it when a mailbox is listed.
///
/// AppKit again, for the same reason as the header icons — SwiftUI's `Table` on
/// macOS 13 offers no way to read or set a scroll offset. Working through the
/// enclosing `NSScrollView` also means the position is expressed as *the topmost
/// visible row*, which survives the window being resized; a raw pixel offset
/// wouldn't.
struct TableScrollStateSyncer: NSViewRepresentable {
    @ObservedObject var model: AppModel

    /// Scroll the message list one row per wheel notch, and reverse the
    /// direction relative to the system setting.
    enum Scrolling {
        /// Flip the direction the wheel moves the list. Set false to follow the
        /// system's scroll direction.
        ///
        /// In a flipped clip view AppKit's own handling is `origin.y -=
        /// scrollingDeltaY`, so reproducing the system direction means stepping
        /// the row index *down* by the delta; `inverted` steps it up instead.
        static let inverted = true

        /// Points of precise (trackpad) scrolling worth one row step. Anchoring
        /// to the row height keeps a swipe covering the distance it normally
        /// would, just snapped to rows.
        static func pointsPerRowStep(rowHeight: CGFloat) -> CGFloat { max(rowHeight, 1) }
    }

    /// `@unchecked Sendable` because the notification block below is `@Sendable`
    /// and captures this. Every access — from the block (delivered on `.main`),
    /// from `updateNSView`, from the `@MainActor` helpers — is on the main
    /// thread; the compiler just can't see that through `addObserver`'s queue
    /// argument. AppKit's own classes don't need this only because they're
    /// `@MainActor`, which would make the block's synchronous reads illegal here.
    final class Coordinator: @unchecked Sendable {
        weak var table: NSTableView?
        var observer: NSObjectProtocol?
        var scrollMonitor: Any?
        /// Leftover trackpad delta below one row's worth, carried to the next
        /// event so slow scrolling still advances instead of rounding to nothing
        /// each time. Reset when a gesture starts or reverses, so a leftover
        /// from one direction can't bias the next flick the other way.
        var scrollRemainder: CGFloat = 0
        /// Bumped per focus attempt, so overlapping attempts don't fight.
        var focusGeneration = 0
        /// True while we're programmatically scrolling, so the bounds
        /// notification that results isn't recorded as a user scroll.
        var isRestoring = false
        /// Bumped per restore attempt. `updateNSView` runs on *any* model
        /// change, so several restore chains can be in flight at once; only the
        /// newest may touch `isRestoring`, or an older one finishing would
        /// re-arm recording mid-restore.
        var restoreGeneration = 0

        deinit {
            if let observer = observer { NotificationCenter.default.removeObserver(observer) }
            if let scrollMonitor = scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            attach(near: nsView, coordinator: coordinator, attemptsLeft: 5)
            applyPendingScroll(coordinator: coordinator, attemptsLeft: 5)
            applyPendingFocus(coordinator: coordinator, attemptsLeft: 5)
        }
    }

    /// Starts listening for scrolls, once.
    ///
    /// `@MainActor` because it touches `model`, which is main-actor isolated —
    /// a plain method on a representable is *nonisolated*; only the protocol
    /// witnesses inherit isolation.
    @MainActor
    private func attach(near view: NSView, coordinator: Coordinator, attemptsLeft: Int) {
        guard coordinator.table == nil else { return }
        guard let table = MessageTableFinder.table(near: view),
              let clipView = table.enclosingScrollView?.contentView else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    attach(near: view, coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }

        coordinator.table = table
        clipView.postsBoundsChangedNotifications = true
        installScrollMonitor(coordinator: coordinator)

        // Everything captured here is weak or a reference type held elsewhere.
        // Capturing `coordinator` strongly would be a cycle — coordinator owns
        // the token, the token owns this block — and the observer would then
        // never be removed, so each teardown of the Table (which happens
        // whenever a mailbox lists empty) would leave a live observer behind and
        // register another.
        let model = self.model
        coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak table, weak coordinator] _ in
            guard let table, let coordinator, !coordinator.isRestoring else { return }
            let visible = table.rows(in: table.visibleRect)
            // rows(in:) reports {0, 0} — not NSNotFound — when nothing is
            // visible, which happens mid-reload. Recording that would overwrite
            // a good remembered position with 0.
            guard visible.length > 0, visible.location >= 0 else { return }
            let top = visible.location
            // AppModel is @MainActor and this closure is not, so hop rather than
            // assume isolation (MainActor.assumeIsolated is macOS 14+).
            Task { @MainActor in
                // A restore that hasn't been applied yet is still authoritative;
                // the snap-to-top that follows a reload must not clobber it.
                guard model.pendingScrollTopRow == nil else { return }
                model.rememberScroll(topRow: top)
            }
        }
    }

    /// Takes over the wheel for the message list: one row per notch, reversed.
    ///
    /// A local event monitor rather than an `NSScrollView` subclass, because the
    /// scroll view belongs to SwiftUI and can't be substituted. Anything that
    /// isn't a vertical scroll over this table is passed straight through.
    @MainActor
    private func installScrollMonitor(coordinator: Coordinator) {
        guard coordinator.scrollMonitor == nil else { return }
        coordinator.scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak coordinator] event in
            guard let coordinator,
                  let table = coordinator.table,
                  let scrollView = table.enclosingScrollView,
                  event.window === scrollView.window else { return event }

            // Only claim events actually over this list — hit-testing rather
            // than a bounds check, so an overlay or popover in front of the
            // table keeps its own scrolling, and the preview pane and sidebar
            // are unaffected.
            guard let hit = scrollView.window?.contentView?.hitTest(event.locationInWindow),
                  hit === scrollView || hit.isDescendant(of: scrollView) else { return event }

            // Horizontal scrolling isn't ours; let the table handle its columns.
            if event.scrollingDeltaY == 0 { return event }

            // Momentum ("glide" after the fingers lift) would send a long
            // uncontrolled run of row steps. Swallow it: this list steps in whole
            // rows under direct control only.
            guard event.momentumPhase == [] else { return nil }

            let steps: CGFloat
            if event.hasPreciseScrollingDeltas {
                let unit = Scrolling.pointsPerRowStep(rowHeight: table.rowHeight
                                                        + table.intercellSpacing.height)
                if event.phase.contains(.began)
                    || (coordinator.scrollRemainder < 0) != (event.scrollingDeltaY < 0) {
                    coordinator.scrollRemainder = 0
                }
                coordinator.scrollRemainder += event.scrollingDeltaY
                steps = (coordinator.scrollRemainder / unit).rounded(.towardZero)
                coordinator.scrollRemainder -= steps * unit
            } else {
                // A wheel notch reports a line count the driver has already
                // accelerated — 1 when turned slowly, 3+ when spun. Ignore the
                // magnitude: a notch is a row.
                steps = event.scrollingDeltaY > 0 ? 1 : -1
            }
            guard steps != 0 else { return nil }

            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return nil }

            let direction: CGFloat = Scrolling.inverted ? 1 : -1
            let targetRow = min(max(visible.location + Int(steps * direction), 0),
                                max(table.numberOfRows - 1, 0))

            let clipView = scrollView.contentView
            let document = scrollView.documentView ?? table
            let target = table.convert(table.rect(ofRow: targetRow), to: document)
            // NSClipView.scroll(to:) doesn't constrain, so stop where a normal
            // scroll view would: with the last row at the bottom, not the top.
            let maxY = max(0, document.frame.height - clipView.bounds.height)
            let y = min(max(0, target.minY - clipView.contentInsets.top), maxY)
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clipView)
            scrollView.flashScrollers()     // consuming the event skips this
            return nil                      // consumed
        }
    }

    /// Gives the message list keyboard focus after a restored selection, so the
    /// highlight is the active one and the arrow keys move from that row.
    @MainActor
    private func applyPendingFocus(coordinator: Coordinator, attemptsLeft: Int) {
        guard model.pendingListFocus else { return }
        coordinator.focusGeneration += 1
        let generation = coordinator.focusGeneration

        guard let table = coordinator.table, table.numberOfRows > 0,
              let window = table.window, window.makeFirstResponder(table) else {
            // Not ready: the window may not be key yet, or the rows may not
            // exist. makeFirstResponder can also simply refuse.
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard coordinator.focusGeneration == generation else { return }
                    applyPendingFocus(coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
                }
            } else {
                model.clearPendingListFocus()
            }
            return
        }

        // SwiftUI's own focus machinery can hand first responder back when it
        // rebuilds the Table, so confirm it stuck before giving up the flag.
        DispatchQueue.main.async {
            guard coordinator.focusGeneration == generation else { return }
            if window.firstResponder === table || attemptsLeft == 0 {
                model.clearPendingListFocus()
            } else {
                applyPendingFocus(coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    /// Scrolls to the remembered row, if the model is asking for one.
    @MainActor
    private func applyPendingScroll(coordinator: Coordinator, attemptsLeft: Int) {
        guard let row = model.pendingScrollTopRow else { return }
        guard let table = coordinator.table, table.numberOfRows > row,
              let scrollView = table.enclosingScrollView else {
            // Rows aren't realized yet — the listing has only just been published.
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    applyPendingScroll(coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
                }
            } else {
                model.clearPendingScroll()
            }
            return
        }

        coordinator.restoreGeneration += 1
        let generation = coordinator.restoreGeneration
        coordinator.isRestoring = true

        // Convert into the document view's space and allow for the clip view's
        // top inset, or the target row can end up hidden under the header.
        let clipView = scrollView.contentView
        let document = scrollView.documentView ?? table
        let target = table.convert(table.rect(ofRow: row), to: document)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x,
                                    y: target.minY - clipView.contentInsets.top))
        scrollView.reflectScrolledClipView(clipView)

        // Let the resulting bounds notification land before recording again.
        DispatchQueue.main.async {
            guard coordinator.restoreGeneration == generation else { return }
            coordinator.isRestoring = false
            model.clearPendingScroll()
            // Write the restored position straight back: recording was
            // suppressed throughout the restore, so without this the remembered
            // value would only ever be rewritten by a later user scroll.
            model.rememberScroll(topRow: row)
        }
    }
}

// MARK: - Middle: message list (Eudora column set)

struct MessageListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.mailboxSummary.isEmpty {
                HStack {
                    Text(model.mailboxSummary)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !model.listingSource.isEmpty {
                        Text(model.listingSource)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                Divider()
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        if model.selectedMailboxID == nil {
            placeholder("Select a mailbox")
        } else if model.rows.isEmpty {
            placeholder("No messages")
        } else {
            Table(model.rows, selection: model.messageSelection) {
                // One narrow glyph column on the left, Eudora-style: status and
                // attachment side by side, each sitting under its own icon in the
                // header. (Priority and color-label columns were dropped —
                // Stephen doesn't use either.) They share a column because
                // separate ones can't be butted together; see HeaderIcon.
                //
                // The header is blank here on purpose: TableHeaderIconStyler
                // paints Eudora 7's own icons via AppKit, the only way to get
                // them flush to the edges.
                // Each column's content is drawn back onto its header — see
                // MessageTableMetrics. The index passed to `tableCell` must match
                // this column's position.
                TableColumn("") { r in
                    HStack(spacing: 0) {
                        Text(r.statusGlyph)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(r.statusGlyph == "•" ? Color.accentColor : .primary)
                            .frame(width: HeaderIcon.status.width)
                        Group {
                            if r.hasAttachment {
                                Image(systemName: "paperclip")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: HeaderIcon.attachment.width)
                    }
                    .tableCell(column: 0)
                }.width(HeaderIcon.leadingColumnWidth)
                // Explicit content closures rather than the `value:` keypath
                // form, so the text can carry the offset. Nothing is lost: with
                // no sortOrder binding, `value:` only supplied the text.
                TableColumn("Who") { r in
                    Text(r.who).tableCell(column: 1)
                }
                TableColumn("Date") { r in
                    Text(r.date).tableCell(column: 2)
                }.width(min: 110, ideal: 132)
                TableColumn("Subject") { r in
                    Text(r.subject).tableCell(column: 3)
                }
            }
            .contextMenu(forSelectionType: MessageRow.ID.self) { ids in
                if let id = ids.first {
                    Button("Reply") { model.selectedMessageID = id; model.reply(all: false) }
                    Button("Forward") { model.selectedMessageID = id; model.forward() }
                    Divider()
                    Button("Mark as Read") { model.selectedMessageID = id; model.markSelected(read: true) }
                    Button("Mark as Unread") { model.selectedMessageID = id; model.markSelected(read: false) }
                    Menu("Move to") {
                        ForEach(model.moveTargets) { t in
                            Button(t.display) { model.selectedMessageID = id; model.moveSelected(to: t.id) }
                        }
                    }
                    Divider()
                    Button("Delete") { model.selectedMessageID = id; model.deleteSelected() }
                }
            }
            .background(TableHeaderIconStyler(icons: HeaderIcon.leadingColumns))
            .background(TableScrollStateSyncer(model: model))
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail: message preview

struct PreviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let p = model.preview {
            VStack(alignment: .leading, spacing: 0) {
                headers(p)
                Divider()
                if p.isHTML {
                    HTMLMailView(html: p.content, images: p.images) { url in
                        model.banner = "Link copied: \(url)"
                    }
                } else {
                    ScrollView {
                        Text(p.content.isEmpty ? "(no text body)" : p.content)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
        } else {
            Text("Select a message")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func headers(_ p: MessagePreview) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(p.subject.isEmpty ? "(no subject)" : p.subject)
                .font(.headline)
            headerLine("From", p.from)
            headerLine("To", p.to)
            headerLine("Date", p.date)
            if !p.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(p.attachments) { att in
                            AttachmentChip(attachment: att)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func headerLine(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                Text(value).textSelection(.enabled)
            }
            .font(.caption)
        }
    }
}

/// A single attachment, shown as a chip. The menu offers only Save As… (and
/// View for images) — never open-in-default-app, per the "dumb client" stance.
struct AttachmentChip: View {
    let attachment: MessageAttachment

    var body: some View {
        Menu {
            Button("Save As…") { AttachmentActions.saveAs(attachment) }
            if attachment.isImage {
                Button("View") { AttachmentActions.viewImage(attachment) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: attachment.isImage ? "photo" : "paperclip")
                    .foregroundStyle(.secondary)
                Text(attachment.filename).lineLimit(1)
                Text(attachment.sizeText).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Save this attachment" + (attachment.isImage ? " or view it" : ""))
    }
}

// MARK: - Indexing progress bar

/// A slim bar under the menu strip shown while the search index (re)builds in
/// the background. Determinate once the mailbox total is known.
struct IndexingBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption)
            if model.indexProgress.total > 0 {
                ProgressView(value: model.indexProgress.fraction)
                    .frame(width: 140)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var label: String {
        let p = model.indexProgress
        return p.total > 0 ? "Indexing… \(p.done) of \(p.total) mailboxes" : "Indexing…"
    }
}

// MARK: - Folder picker (shared)

@MainActor
func pickFolder(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose the Eudora data folder (the directory containing descmap.pce)."
    if panel.runModal() == .OK, let url = panel.url {
        model.open(url)
    }
}

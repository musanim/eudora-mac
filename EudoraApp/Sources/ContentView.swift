import SwiftUI
import AppKit
import EudoraStore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var accounts: AccountStore
    @Environment(\.openWindow) private var openWindow

    private var hasSelection: Bool { model.selectedMessageID != nil }

    /// Height of the preview pane, remembered across launches.
    ///
    /// `@AppStorage`, not `ViewState`. `ViewState` is deliberately per-Eudora-
    /// folder — it remembers selections and sort orders, which are properties of
    /// a particular tree — whereas where you like the divider is a property of
    /// the window and shouldn't change because a different folder was opened.
    ///
    /// The *preview* is the pane that's stored, so the message list absorbs a
    /// window resize and the reading pane stays the size you set it to. Every
    /// read of it is clamped by `PaneLayout` rather than trusted: a value
    /// written on a large display is nonsense on a small one, and the defaults
    /// database outlives any particular screen.
    @AppStorage("previewPaneHeight") private var storedPreviewHeight: Double =
        PaneLayout.defaultPreviewHeight

    /// The preview height when the current drag began; nil when not dragging.
    @State private var dragStartHeight: Double?

    /// The height being dragged to, before it is committed. Nil when not
    /// dragging, and the displayed height falls back to the stored one.
    @State private var liveHeight: Double?

    var body: some View {
        VStack(spacing: 0) {
            MenuBarView()
            if model.isIndexing { IndexingBar() }
            splitView
        }
        // Tells SplashWindow which window is SwiftUI's, so it doesn't have to
        // guess from NSApp.windows (which raced with window placement).
        .background(MainWindowAccessor())
        // Strips the now-duplicate ⌘M from Window ▸ Minimize; see the type.
        .background(MinimizeKeyStripper())
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 180)
        } detail: {
            // Classic Eudora: message list on top, preview below.
            //
            // Hand-built rather than a `VSplitView`. That gave a draggable region
            // barely wider than a hairline, and there is no way to widen it: the
            // AppKit answer is a delegate method, and SwiftUI's split view is
            // managed by an `NSSplitViewController`, which refuses to give up its
            // delegate (see PaneDivider). Owning the split outright also means
            // the position can be remembered, which VSplitView never offered.
            GeometryReader { geo in
                let previewHeight = PaneLayout.previewHeight(liveHeight ?? storedPreviewHeight,
                                                             total: geo.size.height)
                VStack(spacing: 0) {
                    MessageListView()
                        .frame(maxHeight: .infinity)
                    PaneDividerHandle { translation in
                        // A fresh gesture always reports zero first (the handle
                        // uses `minimumDistance: 0`). Clearing on that rather
                        // than trusting `onEnded` is what makes a *cancelled*
                        // drag harmless — SwiftUI doesn't promise to end a
                        // gesture the window resigned or another gesture won,
                        // and a stale base would teleport the divider on the
                        // next mouse-down.
                        if translation == 0 { dragStartHeight = nil }
                        // `translation` is measured from where the drag began,
                        // not since the last event, so the height it applies to
                        // must also be the one from where the drag began —
                        // otherwise each event compounds the last and the divider
                        // runs away from the pointer.
                        //
                        // The base is the *clamped* height, not the stored one.
                        // They differ whenever the window is shorter than it was
                        // when the value was written, and starting from the
                        // stored value then means the first part of the drag is
                        // spent re-clamping to the same number — the divider
                        // looks stuck until the pointer has covered the gap.
                        let base = dragStartHeight ?? Double(previewHeight)
                        if dragStartHeight == nil { dragStartHeight = base }
                        // Dragging down makes the preview *smaller*.
                        liveHeight = Double(
                            PaneLayout.previewHeight(base - Double(translation),
                                                     total: geo.size.height))
                    } onEnded: {
                        // Committed once, here, rather than on every frame:
                        // `@AppStorage` writes to UserDefaults, and a drag
                        // produces these at the refresh rate.
                        if let liveHeight { storedPreviewHeight = liveHeight }
                        liveHeight = nil
                        dragStartHeight = nil
                    }
                    PreviewView()
                        .frame(height: previewHeight)
                }
            }
            .frame(minWidth: 460, minHeight: PaneLayout.minimumTotal)
        }
        .navigationTitle("Eudora")
        .navigationSubtitle(model.status)
        .toolbar {
            // Centered between the window title and the action buttons — the
            // same spot Xcode puts its activity view. Spinner + "Checking mail"
            // during a fetch (⌘M / File ▸ Check Mail — there's no toolbar button
            // for it), then the outcome, which `showCheckMailNotice` retires
            // after a few seconds.
            ToolbarItem(placement: .principal) {
                if model.isChecking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking mail").foregroundStyle(.secondary)
                    }
                } else if let notice = model.checkMailNotice {
                    Text(notice).foregroundStyle(.secondary)
                }
            }
            ToolbarItemGroup {
                Button { model.composeNew() } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                // `SettingsButton` opens the Settings scene the version-correct
                // way (SettingsLink on 14+, the menu action on 13). The gear is
                // `assets/settings.png`, template-rendered so it tints like the SF
                // Symbol icons beside it; sized to sit with them rather than at
                // the artwork's own resolution.
                SettingsButton {
                    Image("settings")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                }
                .help("Settings")
                // Reply, Forward and Move-to are deliberately *not* here: each is
                // reachable from the Message/Transfer menus, the message-list
                // right-click, and (Reply) ⌘R, so a toolbar button for them is
                // redundant. `MoveToMenuButton` still exists — the Transfer menu
                // uses it — and `model.reply/forward/moveSelected` are still the
                // handlers those routes call.
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
            // Drafts are assembled from the account's From identity, and they
            // can be created from places that never see the AccountStore — the
            // message list's right-click Reply, for one. Handed over once here.
            model.accounts = accounts
            // Compose is a window per message now, not a sheet, and only a view
            // can reach `openWindow`. Handing the action over once means the
            // model can present a draft window even with no window on screen —
            // ⌘N used to write a record into Out and show nothing in that case.
            //
            // `openWindow(id:value:)` brings an existing window for the same
            // value forward rather than opening a second, which is what makes
            // double-clicking an already-open draft focus it.
            model.presentDraftWindow = { openWindow(id: ComposeWindow.groupID, value: $0) }
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
        .overlay(alignment: .top) {
            if let banner = model.banner {
                HStack(spacing: 8) {
                    if model.bannerIsError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(red: 0.75, green: 0.05, blue: 0.05))
                    }
                    Text(banner)
                        .copyable(banner)
                    if model.bannerIsError {
                        Button {
                            model.dismissBanner()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Dismiss")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.top, 10)
                // Successes time out; failures don't. A "Check mail failed: …"
                // that erases itself after two and a half seconds can't be read
                // to the end, let alone right-clicked and copied — and it's the
                // one message worth quoting verbatim, since it carries the
                // server's own code and wording.
                //
                // Keyed on `bannerGeneration`, not the text, so a second message
                // always restarts the timer rather than inheriting the first
                // one's — see the comment on that property.
                .task(id: model.bannerGeneration) {
                    guard !model.bannerIsError else { return }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    model.dismissBanner()
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
                MailboxTree(tree: model.tree,
                            treeVersion: model.treeVersion,
                            selected: model.selectedMailboxID,
                            selection: model.mailboxSelection)
                    .equatable()
            }
        }
    }
}

/// The mailbox tree, deliberately insulated from the rest of the model.
///
/// `SidebarView` observes `AppModel` through `@EnvironmentObject`, which means
/// *any* published change — a row arriving, a preview rendering, a banner
/// appearing — invalidates it and rebuilds this `OutlineGroup` over every
/// mailbox in the tree. On a real Eudora folder that is 2,723 nodes, and it was
/// costing ~0.7 s of main-thread render on **every** state change: the reason a
/// click took a perceptible moment to blank the message list even when both
/// mailboxes held a single message.
///
/// Taking the tree as plain values and declaring `Equatable` lets SwiftUI skip
/// the rebuild entirely unless something this view actually shows has changed.
/// Equality is on `treeVersion` rather than the tree itself: comparing 2,723
/// nested structs on every render would just move the cost around.
///
/// `selected` is compared even though the `List` reads selection through the
/// binding, because a *programmatic* selection change (restoring at launch,
/// opening a search hit) must still be able to move the highlight.
struct MailboxTree: View, Equatable {
    let tree: [MailboxItem]
    let treeVersion: Int
    let selected: MailboxItem.ID?
    let selection: Binding<MailboxItem.ID?>

    static func == (a: MailboxTree, b: MailboxTree) -> Bool {
        a.treeVersion == b.treeVersion && a.selected == b.selected
    }

    var body: some View {
        List(selection: selection) {
            OutlineGroup(tree, children: \.children) { item in
                MailboxRow(item: item)
                    .tag(item.id)
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
                .font(EudoraFont.list)
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
/// Two layout systems share this table: AppKit places the column *headers* from
/// `NSTableView.intercellSpacing`, and SwiftUI places the cell *content* on a
/// grid it derives from that same property. They agree — but only as long as
/// nobody changes the property behind SwiftUI's back.
///
/// **Why we no longer zero `intercellSpacing`.** An earlier version set it to 0
/// to butt the columns up, from an async callback because the `NSTableView`
/// doesn't exist during SwiftUI's layout pass. By then SwiftUI had already laid
/// out at the old spacing, so AppKit's headers collapsed and SwiftUI's content
/// did not, and per-column offsets of −17 × i were added to drag the content
/// back. That worked at launch and *only* at launch: the first window resize
/// made SwiftUI relayout, it re-read the now-zero spacing, its grid collapsed
/// onto AppKit's — and the offsets, no longer cancelling anything, threw every
/// column 17 × i too far left. Instrumentation caught it directly:
///
///     SwiftUI grid at launch    16   78  370  527   (read spacing 17)
///     SwiftUI grid after resize 16   61  336  476   (read spacing 0)
///     AppKit headers            10   61  336  476
///
/// No constant can be right in both states, so the spacing is now left alone.
/// Both sides stay on the 17 pt grid, and all that remains is a flat inset
/// SwiftUI adds inside each cell — 6 pt on the glyph column, 8 pt on the text
/// columns, the same at launch, after a resize, and at every window width.
///
/// The closed-up look is preserved through `MessageColumnWidths` instead: the
/// widths are chosen so the columns land where zeroing the spacing used to put
/// them. Those widths are a layout choice and safe to retune; the two insets
/// below are measured, and changing them means re-measuring.
///
/// The displacement is an `.offset`, not `.padding`: padding would take the
/// space out of the cell's width and start truncating long subjects, whereas an
/// offset only moves the drawing.
///
/// If headers and content ever drift apart again, note *which way*: a constant
/// error across all columns is one of the insets below, whereas an error growing
/// linearly left to right means something has started changing the intercell
/// spacing again, and the history above is the thing to re-read.
enum MessageTableMetrics {
    /// SwiftUI's inset inside the leading glyph cell. Measured.
    ///
    /// It differs from the text columns' because that cell is an `HStack` of
    /// fixed-width frames while the text cells are a bare `Text`, and SwiftUI
    /// treats the two differently.
    static let leadingGlyphInset: CGFloat = 6

    /// SwiftUI's inset inside a text cell. Measured.
    static let textCellInset: CGFloat = 8

    /// How far left column `index`'s content must be drawn to meet its header.
    static func contentOffset(column index: Int) -> CGFloat {
        index == 0 ? -leadingGlyphInset : -textCellInset
    }
}

/// The message list's column widths, as a single table both sides read from.
///
/// **Why these are fixed rather than flexible.** SwiftUI's `Table` and the
/// `NSTableView` backing it each negotiate flexible column widths *separately*,
/// and they do not arrive at the same answer: instrumentation showed AppKit's
/// columns 73 pt short of filling the table at launch but only 20 pt short after
/// a window resize, while SwiftUI's content grid filled the width throughout.
/// Headers are drawn from AppKit's widths and content from SwiftUI's, so the two
/// drifted apart by an amount that *changed when the window was resized* — the
/// symptom being one misalignment at launch and a different one afterwards.
///
/// No constant in `MessageTableMetrics` can fix that, because there is no single
/// error to cancel. Pinning the widths removes the negotiation instead: a column's
/// origin depends only on the widths *before* it, so with every column but the
/// last one fixed, both grids compute identical origins in every state. Only the
/// trailing column is left flexible, and nothing's origin depends on its width.
///
/// `TableHeaderIconStyler.enforce` pins the same numbers on the AppKit side. The
/// two must agree, or the sides will overwrite each other on every layout pass.
///
/// **Why these particular numbers.** With the 17 pt intercell spacing left in
/// place (see `MessageTableMetrics`), each column starts 17 pt further right than
/// it would have with the spacing zeroed. These widths give that back, so Date
/// and Subject land at 336 and 476 — exactly where the old zeroed-spacing layout
/// put them. Who alone starts ~11 pt further right, because the only way to
/// recover that last gap would be to shrink the glyph column below its 45 pt of
/// artwork. Retune freely: unlike the metrics, these are taste, not measurement.
enum MessageColumnWidths {
    static let who: CGFloat = 247
    static let date: CGFloat = 123

    /// Per column, in `TableColumn` order; `nil` means "let it flex".
    /// Only the trailing column may be `nil`.
    static var pinned: [CGFloat?] {
        [HeaderIcon.leadingColumnWidth, who, date, nil]
    }
}

extension View {
    /// Draws a table cell's content where its column header actually is.
    /// The column index must match the `TableColumn` order.
    func tableCell(column index: Int) -> some View {
        offset(x: MessageTableMetrics.contentOffset(column: index))
    }

    /// Makes text the user may need verbatim — error messages above all —
    /// selectable, right-click-copyable, and readable in full as a tooltip even
    /// when the layout truncates it.
    ///
    /// Errors from the network layer are exactly the strings worth quoting: an
    /// SMTP rejection carries the server's numeric code and its own explanation,
    /// and the difference between a 534 and a 535 is the difference between two
    /// completely different fixes. Text you can't copy is text that gets
    /// retyped, or paraphrased, or truncated with an ellipsis.
    ///
    /// `.textSelection` alone isn't enough: it requires selecting first, and
    /// these labels are often one truncated line in a crowded footer. The
    /// explicit Copy item takes the whole `text`, not the visible part of it.
    ///
    /// A `.contextMenu` is fine here despite the trouble SwiftUI menus caused
    /// over the mailbox tree (see `MessageContextMenu`): the problem there was
    /// SwiftUI eagerly building 2,657 nested items on every right-click. This is
    /// one button over no data.
    func copyable(_ text: String) -> some View {
        self
            .textSelection(.enabled)
            .help(text)
            .contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
    }
}

// MARK: - Message-list column headers

/// A Eudora 7 column-header icon, taken from the original app's artwork and
/// shipped in `Assets.xcassets`.
///
/// Both icons live in a *single* table column, and that's deliberate.
///
/// As separate columns they were pushed apart by the table's 17 pt intercell
/// spacing, and that spacing can't be reduced: SwiftUI derives its cell grid from
/// that property but only re-reads it on a relayout, so changing it slides every
/// header out of line with its content, cumulatively, left to right, until
/// something forces SwiftUI to catch up (see `MessageTableMetrics`). Drawing the
/// icons out into the gap doesn't work either — AppKit clips the header cell to
/// its frame.
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

/// Eudora 7's own row glyphs: the unread dot and the attachment mark that appear
/// in each message row, under the matching header icon.
///
/// Separate art from `HeaderIcon` — these are the smaller in-row marks (14 and 17
/// px) rather than the header's bezelled buttons (21 and 24 px) — but they sit in
/// the same two sub-columns, so each is centred in the *header* icon's width and
/// the two stay in register down the list.
///
/// Drawn `.resizable()` at its own native size with `.interpolation(.none)`: the
/// art is 1x pixel art, and nearest-neighbour keeps it crisp at 2x instead of
/// smoothing it into mush. The `.resizable()` is load-bearing — `.interpolation`
/// is silently ignored on a non-resizable `Image`, which is exactly the trap this
/// comment exists to stop someone falling into again.
/// The art in the catalog is *not* the art in `assets/`: the originals came with
/// an opaque near-white background, which showed as a white block on a selected
/// (blue) row. `assets/make-row-icons.py` regenerates the catalog copies with a
/// real alpha channel — rerun it if the source art is ever replaced.
enum RowIcon {
    static let unread = "RowUnread"
    static let attachment = "RowAttachment"
    /// A message composed but not sent — a draft in Out.
    static let unsent = "RowUnsent"
    /// A message whose send was attempted and failed.
    static let sendError = "RowSendError"

    /// Height of the glyph slot.
    ///
    /// Given explicitly so a row with no glyph is the same height as one with:
    /// the cell used to always hold a `Text` (status was `" "` for read mail) and
    /// so always had a line box, whereas an empty `Group` would collapse to zero
    /// and leave the table's row height resting on the text columns alone.
    static let height: CGFloat = 17

    /// A row glyph centred in its sub-column, or empty space of the same size.
    static func view(_ name: String, show: Bool, width: CGFloat) -> some View {
        let art = NSImage(named: name)?.size ?? CGSize(width: width, height: height)
        return Group {
            if show {
                Image(name)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: art.width, height: art.height)
            }
        }
        .frame(width: width, height: height)
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

    /// Which of the two icons the list is currently sorted by, and which way, or
    /// nil when the sort is on another column.
    ///
    /// AppKit's own `setIndicatorImage(_:in:)` can't help here: it draws one
    /// indicator per *column*, and these two sortable things share a column (see
    /// `HeaderIcon`). So the triangle is drawn here, under the icon it belongs to.
    var sortedIcon: Int?
    var sortAscending = true

    init(icons: [NSImage]) {
        self.icons = icons
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `NSCell`'s inherited copy is a shallow, non-retaining one, which would
    /// leave `icons` dangling. Copy explicitly instead.
    ///
    /// The sort state has to be carried across: AppKit draws through a copy on
    /// some paths, and a copy that lost it would drop the indicator at random.
    override func copy(with zone: NSZone? = nil) -> Any {
        let clone = ImageHeaderCell(icons: icons)
        clone.sortedIcon = sortedIcon
        clone.sortAscending = sortAscending
        return clone
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Lay the icons left to right at their native widths, so they touch.
        var x = cellFrame.minX
        for (index, icon) in icons.enumerated() {
            let slot = NSRect(x: x, y: cellFrame.minY,
                              width: icon.size.width, height: cellFrame.height)
            let target: NSRect
            if Self.fillsHeader {
                target = slot
            } else {
                target = NSRect(x: x, y: cellFrame.midY - icon.size.height / 2,
                                width: icon.size.width, height: icon.size.height)
            }
            // respectFlipped matters: NSTableHeaderView is flipped, and without
            // it the icons would draw upside down.
            icon.draw(in: target, from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            if index == sortedIcon { drawSortIndicator(in: slot) }
            x += icon.size.width
        }
    }

    /// A small triangle in the bottom-right of one icon's slot, standing in for
    /// the indicator AppKit would draw if these were separate columns.
    ///
    /// Drawn rather than stamped from `NSImage(named: "NSAscendingSortIndicator")`
    /// because the system art is sized for a text header and, laid over artwork
    /// only 21 px wide, covers the icon it is meant to annotate.
    private func drawSortIndicator(in slot: NSRect) {
        let size: CGFloat = 5
        let inset: CGFloat = 1.5
        let right = slot.maxX - inset
        let left = right - size
        // NSTableHeaderView is flipped, so minY is the *top* edge: "up" here
        // means toward minY.
        let bottom = slot.maxY - inset
        let top = bottom - size

        let path = NSBezierPath()
        if sortAscending {
            path.move(to: NSPoint(x: (left + right) / 2, y: top))
            path.line(to: NSPoint(x: right, y: bottom))
            path.line(to: NSPoint(x: left, y: bottom))
        } else {
            path.move(to: NSPoint(x: (left + right) / 2, y: bottom))
            path.line(to: NSPoint(x: right, y: top))
            path.line(to: NSPoint(x: left, y: top))
        }
        path.close()
        NSColor.secondaryLabelColor.setFill()
        path.fill()
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
    ///
    /// The table has four; three is deliberate slack, so that adding or removing
    /// a column doesn't silently stop the table being found — which would show up
    /// as blank headers and drifting columns rather than as an obvious failure.
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

/// Installs `ImageHeaderCell` on the leading column of the `Table` it is attached
/// to (as a `.background`), and pins the fixed column widths on the AppKit side
/// so they can't drift from the ones SwiftUI was given.
///
/// This is deliberate SwiftUI-to-AppKit reach-through: from the backing view we
/// find the enclosing window's `NSTableView` and replace the header cells. It is
/// cosmetic and defensive throughout — if the hierarchy ever changes shape and
/// the table isn't found, the headers simply stay blank rather than breaking.
struct TableHeaderIconStyler: NSViewRepresentable {
    let icons: [HeaderIcon]

    /// `@unchecked Sendable` for the same reason as `TableScrollStateSyncer`'s:
    /// the frame-change block below is `@Sendable` and captures this, but every
    /// access is on the main thread and the compiler can't see that through
    /// `addObserver`'s queue argument.
    final class Coordinator: @unchecked Sendable {
        weak var table: NSTableView?
        var observer: NSObjectProtocol?
        /// The resolved header art, kept so the frame-change block can re-assert
        /// the geometry without reaching back into the (non-`Sendable`) struct.
        var art: [NSImage] = []

        deinit {
            if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        // The table doesn't exist yet during this pass of layout, so apply once
        // SwiftUI has committed the hierarchy — and retry a few times, since the
        // backing view can be in the tree before the Table's NSTableView is.
        // The budget is generous because `openDefaultIfAvailable` blocks the main
        // thread for several seconds at launch, and the table isn't there until
        // it returns. The retries are chained rather than scheduled up front, so
        // 20 attempts is ~4 s of real waiting; it stops as soon as it succeeds,
        // so the ceiling only costs anything in the case where it was needed.
        DispatchQueue.main.async {
            apply(near: nsView, coordinator: coordinator, attemptsLeft: 20)
        }
    }

    // Deliberately not `@MainActor`: it is only ever called from `DispatchQueue
    // .main`, but annotating it makes those non-isolated closures illegal call
    // sites. Left nonisolated, as the rest of this file's AppKit reach-through is.
    private func apply(near view: NSView, coordinator: Coordinator, attemptsLeft: Int) {
        func retry() {
            guard attemptsLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                apply(near: view, coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
            }
        }

        guard let table = MessageTableFinder.table(near: view) else {
            retry()
            return
        }

        // A table that hasn't been sized yet would tile its flexible columns over
        // nothing, and the first window resize would then redistribute them
        // differently — which looks exactly like a stale metric but isn't. Wait
        // for a real width. (The splash hides the main window with `alphaValue`
        // rather than `orderOut`, so the window is on screen at full size the
        // whole time; a zero width here is SwiftUI not having sized the table
        // yet, not the splash.)
        guard table.bounds.width > 1 else {
            retry()
            return
        }

        // Before the art guard below, which returns for good if an asset is
        // missing. Dragging a column to a new position would break more than it
        // looks: cell content is offset onto its header by *index*
        // (`tableCell(column:)`) and the header-click sort maps index to sort key
        // the same way, so a reorder would leave both pointing at the wrong
        // column — and the pinned widths would then be applied to whatever column
        // had moved into each slot. Nothing here supports reordering, so it must
        // not survive a missing icon. `enforce` re-asserts it on every relayout,
        // since this path only runs when SwiftUI state changes. No `tile()`: the
        // flag is behavioural, not geometric.
        if table.allowsColumnReordering { table.allowsColumnReordering = false }

        // Note this bails out of the width pinning too, not just the art: a
        // missing asset means the headers can drift from the content on resize,
        // rather than merely leaving the header blank. Deliberate — and it
        // doesn't `retry()`, because an asset that failed to load won't appear on
        // a later attempt.
        let art = icons.compactMap(\.nsImage)
        guard !art.isEmpty else { return }

        let previousTable = coordinator.table
        coordinator.table = table
        coordinator.art = art
        Self.enforce(table: table, art: art)
        // The listing takes 6-7 s to build behind the splash, so a dump taken now
        // would measure an empty table; this one lands after the rows exist.
        // Costs nothing when `diagnoseGeometry` is off.
        if Self.diagnoseGeometry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                Self.dump(table: table, stage: "launch + 10s, rows loaded")
            }
        }

        // Re-assert on every relayout, not just on `updateNSView`, which runs only
        // when SwiftUI *state* changes — and resizing the window changes no state.
        // Without this, anything AppKit resets during a relayout (notably the
        // pinned column widths) would stay reset until the next model change.
        //
        // `enforce` is idempotent and only tiles when it actually changed
        // something, so the `tile()` it does can't feed itself a second frame
        // change.
        //
        // A rebuilt Table means a *new* NSTableView, and an observer registered
        // against the old one never fires again — which would look exactly like
        // this bug returning, but only after switching mailboxes. So re-register
        // on a swap rather than returning early on a token pointed at nothing.
        if previousTable !== table, let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
            coordinator.observer = nil
        }
        guard coordinator.observer == nil else { return }

        // The enclosing scroll view rather than the table itself: its frame
        // changes on every window or split resize just the same, but `tile()`
        // cannot change it, so this hook can't feed itself the way observing the
        // table's own frame can. The flag is additive — several observers may
        // want it, so it is only ever turned on, never off in teardown.
        let source: NSView = table.enclosingScrollView ?? table
        source.postsFrameChangedNotifications = true
        // Captures the coordinator weakly: it owns the token and the token owns
        // this block, so a strong capture would be a cycle and the observer would
        // outlive every teardown of the Table (which happens whenever a mailbox
        // lists empty), accumulating one per rebuild.
        coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: source,
            queue: .main
        ) { [weak coordinator] _ in
            guard let coordinator = coordinator, let table = coordinator.table else { return }
            Self.dump(table: table, stage: "frame change")
            Self.enforce(table: table, art: coordinator.art)
            // Again on the next runloop turn, in case SwiftUI resets the column
            // widths *after* this notification within the same layout pass — we
            // can't order ourselves against its internal relayout. `enforce`
            // no-ops when nothing has drifted, so the second pass is almost free.
            DispatchQueue.main.async {
                guard let table = coordinator.table else { return }
                Self.enforce(table: table, art: coordinator.art)
                Self.dump(table: table, stage: "after resize, settled")
            }
        }
    }

    /// Instrumentation for the header/content alignment work. Flip
    /// `diagnoseGeometry` to true to re-enable it.
    ///
    /// Kept rather than deleted because the alignment has now needed measuring
    /// twice, and pixel-measuring a screenshot cannot distinguish "AppKit moved
    /// the header" from "SwiftUI moved the content" — which was exactly the
    /// distinction that finally identified the bug. The `drew` lines are the
    /// valuable part: they report where SwiftUI actually placed each cell, which
    /// no AppKit query will tell you.
    ///
    /// The number that matters is **header − cell** on each column: that is the
    /// gap `MessageTableMetrics` is trying to cancel. If it is identical at launch
    /// and after a resize, the remaining error is a constant to be dialled out. If
    /// it differs, something is still moving and no constant can fix both states.
    static let diagnoseGeometry = false

    private static func dump(table: NSTableView, stage: String) {
        guard diagnoseGeometry else { return }
        func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }

        var lines = ["[geometry] \(stage)",
                     "  table.bounds.width \(f(table.bounds.width))"
                        + "  intercellSpacing \(f(table.intercellSpacing.width))"
                        + "  scale \(f(table.window?.backingScaleFactor ?? 0))"]
        for index in table.tableColumns.indices {
            let cell = table.rect(ofColumn: index)
            let header = table.headerView?.headerRect(ofColumn: index) ?? .zero
            let title = table.tableColumns[index].title
            lines.append("  col \(index) \(title.isEmpty ? "(icons)" : title)"
                            + "  width \(f(table.tableColumns[index].width))"
                            + "  cell.x \(f(cell.minX))"
                            + "  header.x \(f(header.minX))"
                            + "  header-cell \(f(header.minX - cell.minX))"
                            + "  swiftUIOffset \(f(MessageTableMetrics.contentOffset(column: index)))")
        }
        // Where SwiftUI actually *drew* the first row's content, as opposed to
        // where AppKit's column rects say it should be. This is the measurement
        // the AppKit numbers above cannot give: `Table` positions its cell views
        // on its own grid, so a drift between the two shows up here and nowhere
        // else. Compare `drew.x` against the matching `cell.x` — the difference,
        // minus that column's `swiftUIOffset`, is the raw error to cancel.
        // Walk the table's own view tree rather than asking for row 0 via
        // `rowView(atRow:makeIfNecessary:)`: that returned nil every time, so
        // SwiftUI's outline view either reports no rows or doesn't vend them
        // through that API. The real views are in the hierarchy regardless.
        lines.append("  numberOfRows \(table.numberOfRows)"
                        + "  subviews \(table.subviews.count)")
        // No filtering by position: the table is flipped *and* scrolled, so the
        // visible rows are nowhere near y = 0. AppKit recycles row views, so the
        // whole tree is only a few dozen nodes and can just be dumped.
        var emitted = 0
        func walk(_ view: NSView, depth: Int) {
            for sub in view.subviews where sub.frame.width > 1 && sub.frame.height > 1 {
                guard emitted < 60 else { return }
                emitted += 1
                let box = sub.convert(sub.bounds, to: table)
                lines.append("  drew"
                                + String(repeating: ">", count: depth)
                                + " \(type(of: sub))"
                                + "  x \(f(box.minX))  w \(f(box.width))"
                                + "  y \(f(box.minY))")
                if depth < 4 { walk(sub, depth: depth + 1) }
            }
        }
        walk(table, depth: 0)
        if emitted == 0 { lines.append("  (no subviews with a drawable size)") }

        print(lines.joined(separator: "\n"))
    }

    /// Pins the fixed column widths on the AppKit side, and puts the art in the
    /// leading header.
    ///
    /// The widths must match the ones SwiftUI was given in `MessageColumnWidths`
    /// exactly. Headers are drawn from AppKit's widths and content from SwiftUI's,
    /// so any disagreement shows up as misalignment that changes with the window
    /// width. Note this does *not* touch `intercellSpacing` — see
    /// `MessageTableMetrics` for why that would reintroduce the original bug.
    ///
    /// Every write is guarded on the *live AppKit value* rather than a stored
    /// "already applied" flag, which is what makes this safe to call from a frame
    /// -change notification: it is a no-op unless something has actually drifted,
    /// so it neither thrashes layout nor retriggers its own notification. Reading
    /// the table itself also means a rebuilt `Table`, or anything that resets
    /// these behind our back, is picked up rather than latched off forever.
    private static func enforce(table: NSTableView, art: [NSImage]) {
        // AppKit rounds and clamps these, so exact equality can read "changed"
        // forever — which would tile on every notification, post another frame
        // change, and loop at low grade for as long as the app is open. Half a
        // point is far below anything visible.
        func differs(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > 0.5 }

        // `intercellSpacing` is deliberately NOT touched here — see
        // MessageTableMetrics. Writing it from this async callback is what caused
        // the launch-vs-resize misalignment, because SwiftUI has already laid out
        // by the time this runs and only re-reads the property on its next
        // relayout. Leave it alone and both sides stay on the same grid.
        var geometryChanged = false

        // An `if`, not a `guard ... else { return }`: returning here would skip
        // the tile below.
        if let column = table.tableColumns.first, !(column.headerCell is ImageHeaderCell) {
            column.headerCell = ImageHeaderCell(icons: art)
            geometryChanged = true
        }

        // Headers are `NSTableHeaderCell`s drawn by AppKit, not SwiftUI text, so
        // they don't inherit the font set on the cells and have to be told.
        // Guarded like everything else here: this runs on every relayout.
        for column in table.tableColumns.dropFirst()
        where column.headerCell.font != EudoraFont.listNSFont {
            column.headerCell.font = EudoraFont.listNSFont
            geometryChanged = true
        }

        // Pin every fixed column to the same width SwiftUI was given, so the two
        // grids can't negotiate different answers and drift apart. Each column's
        // origin depends only on the widths before it, so pinning all but the
        // trailing one is enough to fix every origin. A `nil` entry is a column
        // deliberately left flexible; extra columns beyond the table are ignored,
        // so the two can be edited independently without crashing.
        for (index, target) in MessageColumnWidths.pinned.enumerated() {
            guard let target = target, index < table.tableColumns.count else { continue }
            let column = table.tableColumns[index]
            if differs(column.minWidth, target) || differs(column.maxWidth, target)
                || differs(column.width, target) {
                // Raise the ceiling before the floor, so `minWidth` never briefly
                // exceeds `maxWidth`.
                column.maxWidth = .greatestFiniteMagnitude
                column.minWidth = target
                column.maxWidth = target
                column.width = target
                geometryChanged = true
            }
            if !column.resizingMask.isEmpty {
                column.resizingMask = []
                geometryChanged = true
            }
        }

        // Re-asserted here as well as in `apply`, because this is the path the
        // frame-change observer takes: a relayout that re-enabled column dragging
        // would otherwise leave it enabled until the next model change. Outside
        // `geometryChanged` deliberately — it moves nothing, so it must not cause
        // a `tile()`.
        if table.allowsColumnReordering { table.allowsColumnReordering = false }

        // One re-tile, after every input is final, or none at all. `tile()`
        // recomputes the column origins *and* the header view's frame and marks
        // both for display, so no separate header invalidation is needed.
        if geometryChanged {
            table.tile()
            table.headerView?.needsDisplay = true
        }
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

    /// Scroll the message list one row per wheel notch, in the system's own
    /// direction.
    enum Scrolling {
        /// Flip the direction the wheel moves the list. False follows the
        /// system's scroll direction, which is what Stephen wants; set true to
        /// reverse it.
        ///
        /// In a flipped clip view AppKit's own handling is `origin.y -=
        /// scrollingDeltaY`, so reproducing the system direction means stepping
        /// the row index *down* by the delta; `inverted` steps it up instead.
        static let inverted = false

        /// Points of precise (trackpad) scrolling worth one row step. Anchoring
        /// to the row height keeps a swipe covering the distance it normally
        /// would, just snapped to rows.
        static func pointsPerRowStep(rowHeight: CGFloat) -> CGFloat { max(rowHeight, 1) }

        /// The row at the top of the visible *content* area.
        ///
        /// Deliberately not `table.rows(in: table.visibleRect).location`, which
        /// is what this used to be and what broke the wheel.
        ///
        /// The clip view carries a 28 pt top content inset — the band the column
        /// header sits over. That band is part of the clip view's bounds, so it
        /// is part of `visibleRect` too, and the row hidden underneath the header
        /// still counts as visible. Reading the top row that way while *writing*
        /// the new position with the inset subtracted (see `originY`) meant the
        /// two disagreed by 28 pt — a little over one row — so every notch
        /// computed a target at or behind where the list already was:
        ///
        ///     In (134 rows)     rows 0 and 1 map to origins −23 and 2, and the
        ///                       old `max(0, …)` clamp turned −23 into 0. Two
        ///                       reachable positions two pixels apart, with
        ///                       `rows(in:)` reporting row 0 at both — so the
        ///                       list jittered and never moved.
        ///     CUSTOMERS (3155)  at origin 5288 the header covered row 218 while
        ///                       `rows(in:)` still called it the top row, so a
        ///                       step "down" to 219 resolved to origin 5265 —
        ///                       above where the list already was. Both
        ///                       directions scrolled toward the top.
        ///
        /// **Do not reach for `row(at:)` here.** It is the obvious API for "which
        /// row is at this point" and it does not work in this table: the clip
        /// view is wider than the table (1439 vs 1127 pt), so
        /// `clipView.bounds.minX` is −312 and any probe point built from it is
        /// outside the table horizontally. `row(at:)` rejects that and returns −1
        /// for *every* row, whatever the y, which sends the caller to its
        /// fallback on every call and pins the list to a single row. That was a
        /// real bug here, not a hypothetical — it is what the second attempt at
        /// this did.
        ///
        /// So the range comes from `rows(in:)` instead, over a rect built from
        /// the clip origin with the header band taken off the top.
        ///
        /// Two deliberate details in that rect, both removing a dependency this
        /// would otherwise rest on:
        ///
        /// - The y comes from `clipView.bounds`, not from `table.visibleRect`.
        ///   `visibleRect` is intersected with the table's own bounds, so at the
        ///   legal top origin (−28 … −23) it reports `minY` 0 and the probe lands
        ///   28 pt down — inside row 0 *only* because row 0 happens to run to
        ///   y=30. Two points of margin is not something to rely on; if SwiftUI
        ///   ever drops the 5 pt leading pad, that spelling would report row 1
        ///   while row 0 was plainly on screen.
        /// - The half-point offset puts the probe inside the row rather than on
        ///   its edge. `rows(in:)` excludes a zero-area intersection at the max
        ///   edge, so an exactly-aligned origin already resolves to the row below
        ///   — but if it didn't, `topVisibleRow` and `originY` would stop being
        ///   inverses and a down-notch would compute the position it is already
        ///   at. That is the classic stick, and half a point rules it out for
        ///   free.
        ///
        /// - Returns: -1 when there is no top row to report — the table has no
        ///   rows yet, or the clip is still parked where a previous, longer
        ///   mailbox left it and the rect intersects nothing. Callers must treat
        ///   that as "don't touch anything"; recording it would overwrite a good
        ///   remembered position.
        static func topVisibleRow(table: NSTableView, clipView: NSClipView) -> Int {
            let hidden = clipView.contentInsets.top
            let top = table.convert(NSPoint(x: 0, y: clipView.bounds.minY + hidden),
                                    from: clipView).y
            let height = clipView.bounds.height - hidden - clipView.contentInsets.bottom
            // The table's own x, so this doesn't lean on `rows(in:)` tolerating
            // the clip's negative one (it does, but there's no reason to depend
            // on it).
            let content = NSRect(x: table.bounds.minX, y: top + 0.5,
                                 width: max(table.bounds.width, 1),
                                 height: max(height, 1))
            let visible = table.rows(in: content)
            guard visible.length > 0, visible.location >= 0 else { return -1 }
            return visible.location
        }

        /// The clip origin that puts `row` flush at the top of the visible
        /// content area, clamped where a normal scroll view would stop.
        ///
        /// The floor is `-contentInsets.top`, **not** zero. The inset band is
        /// inside the clip view's bounds, so an origin of 0 already has the first
        /// row tucked up under the header; clamping there made the true top
        /// unreachable, which is half of the `In` symptom above.
        ///
        /// The one place this geometry is expressed. The wheel and the
        /// remembered-position restore both come through here, so they cannot
        /// drift apart the way the read and the write just did.
        static func originY(forTopRow row: Int, table: NSTableView,
                            clipView: NSClipView, document: NSView) -> CGFloat {
            // Into the clip view's own bounds space rather than assuming the
            // document sits at its origin. `topVisibleRow` converts clip → table
            // directly, so without this the two would be exact inverses only
            // while `document.frame.origin` happens to be zero — which is true
            // today and is precisely the kind of assumption this pair must not
            // rest on, given they exist because a read and a write drifted apart.
            let target = table.convert(table.rect(ofRow: row), to: document)
            let wanted = clipView.convert(target.origin, from: document).y
            let minY = -clipView.contentInsets.top
            let maxY = max(minY, document.frame.maxY + clipView.contentInsets.bottom
                                    - clipView.bounds.height)
            return min(max(minY, wanted - clipView.contentInsets.top), maxY)
        }

        /// One console block per wheel event, reporting every number the monitor
        /// computes and where the list actually ended up. Off; flip to true.
        ///
        /// Kept because it earned its place. The wheel misbehaved *differently
        /// per mailbox* — a two-pixel jitter in a 134-row one, always-toward-the-
        /// top in a 3,155-row one — while the scrollbar and arrow keys were both
        /// fine. Nothing about that can be read off the screen: it looks the same
        /// whether `rows(in:)` reports the wrong row, `rect(ofRow:)` returns a
        /// degenerate rect, or the scroll is applied and then reverted.
        ///
        /// One run settled it, and not in favour of the obvious suspect.
        /// `rect(ofRow:)` was perfectly healthy (row 0 at y=5, row 1 at 30, row
        /// 133 at 3215) — the guess had been that SwiftUI's table subclass didn't
        /// implement it, since it already doesn't implement
        /// `rowView(atRow:makeIfNecessary:)`. The culprit was the line nobody was
        /// looking at, `clip.insets.top 28.0`: see `topVisibleRow`.
        ///
        /// Two things to note if this is ever turned on again. `rowHeight`
        /// reports 24 while the rects are 25 tall, so row offsets must come from
        /// `rect(ofRow:)` and never from arithmetic on `rowHeight`. And
        /// `document.frame.height` grows by a few points between consecutive
        /// events on a long list (76208 → 76228 → 76247…) as SwiftUI refines its
        /// row estimates — so treat any single height reading as approximate.
        static let diagnose = false
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
        /// The same, for reveal-after-sort attempts: `updateNSView` runs on any
        /// published change, so several chains can be in flight, and a stale one
        /// exhausting its attempts would clear a newer reveal.
        var revealGeneration = 0
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
            applyPendingReveal(coordinator: coordinator, attemptsLeft: 5)
            applyPendingFocus(coordinator: coordinator, attemptsLeft: 5)
        }
    }

    /// Scrolls just far enough to show a row, if the model is asking for one.
    ///
    /// Distinct from `applyPendingScroll` in both effect and bookkeeping: that
    /// one restores a remembered *top* row and suppresses the scroll recorder
    /// while it does, so the restore can't overwrite what it is restoring. This
    /// one is a reveal after a re-sort — it moves the list the way the user would
    /// have, so the resulting position is left to be recorded normally.
    @MainActor
    private func applyPendingReveal(coordinator: Coordinator, attemptsLeft: Int) {
        guard let row = model.pendingRevealRow else { return }
        // Never during a restore. `applyPendingScroll` runs first in this same
        // turn and only clears `isRestoring` a turn later, so scrolling now would
        // both override the restore and have its own bounds notification
        // swallowed by the recorder — leaving the remembered position describing
        // somewhere the list isn't. Waiting costs nothing: clearing the pending
        // scroll republishes, which brings us straight back here.
        guard model.pendingScrollTopRow == nil, !coordinator.isRestoring else { return }

        coordinator.revealGeneration += 1
        let generation = coordinator.revealGeneration

        guard let table = coordinator.table, table.numberOfRows > row else {
            // The reorder has been published but the table hasn't caught up.
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard coordinator.revealGeneration == generation else { return }
                    applyPendingReveal(coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
                }
            } else {
                model.clearPendingReveal()
            }
            return
        }

        // One turn later, not now: the row *count* doesn't change across a
        // re-sort, so the readiness check above passes even when SwiftUI hasn't
        // committed the reordered rows yet, and scrolling here would reveal the
        // row that used to be at this position.
        DispatchQueue.main.async {
            guard coordinator.revealGeneration == generation,
                  let table = coordinator.table, table.numberOfRows > row else { return }
            table.scrollRowToVisible(row)
            model.clearPendingReveal()
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
        ) { [weak table, weak clipView, weak coordinator] _ in
            guard let table, let clipView, let coordinator,
                  !coordinator.isRestoring else { return }
            // The same inset-aware reading the wheel uses, so the position that
            // gets remembered is the one the user sees at the top rather than
            // the row hidden under the header — otherwise every restore came
            // back a row higher than where they left off.
            let top = Scrolling.topVisibleRow(table: table, clipView: clipView)
            // -1 covers the mid-reload case as well as an empty table: the clip
            // can still be parked at an origin inherited from the mailbox being
            // left — a deep position in a 3,155-row mailbox landing on a 134-row
            // one — and `topVisibleRow` reports the intersection is empty rather
            // than guessing. Recording a guess would persist a wrong position
            // for the mailbox just opened.
            guard top >= 0 else { return }
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
                  event.window === scrollView.window else {
                Self.diagnoseBail("no live table / wrong window",
                                  table: coordinator?.table)
                return event
            }

            // Only claim events actually over this list — hit-testing rather
            // than a bounds check, so an overlay or popover in front of the
            // table keeps its own scrolling, and the preview pane and sidebar
            // are unaffected.
            guard let hit = scrollView.window?.contentView?.hitTest(event.locationInWindow),
                  hit === scrollView || hit.isDescendant(of: scrollView) else {
                Self.diagnoseBail("hit test missed the scroll view", table: table)
                return event
            }

            // Horizontal scrolling isn't ours; let the table handle its columns.
            if event.scrollingDeltaY == 0 {
                Self.diagnoseBail("deltaY == 0", table: table)
                return event
            }

            // Momentum ("glide" after the fingers lift) would send a long
            // uncontrolled run of row steps. Swallow it: this list steps in whole
            // rows under direct control only.
            guard event.momentumPhase == [] else {
                Self.diagnoseBail("momentum phase", table: table)
                return nil
            }

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
            guard steps != 0 else {
                Self.diagnoseBail("steps rounded to 0", table: table)
                return nil
            }

            let clipView = scrollView.contentView
            let document = scrollView.documentView ?? table

            // The row you can actually see, not the one under the header — see
            // `Scrolling.topVisibleRow`, which is where this went wrong.
            let currentTop = Scrolling.topVisibleRow(table: table, clipView: clipView)
            guard currentTop >= 0 else {
                Self.diagnoseBail("no rows", table: table)
                return nil
            }

            let direction: CGFloat = Scrolling.inverted ? 1 : -1
            let targetRow = min(max(currentTop + Int(steps * direction), 0),
                                max(table.numberOfRows - 1, 0))

            // Already showing that row. Consume the notch and do nothing, rather
            // than re-deriving the origin: at the very top the clip can sit a few
            // points above row 0's own origin (−28 vs −23), and recomputing would
            // nudge the list *down* by that difference — an up-notch visibly
            // moving the wrong way. Also spares a pointless scroller flash at
            // both ends of the list.
            guard targetRow != currentTop else { return nil }

            // NSClipView.scroll(to:) doesn't constrain, so `originY` stops where
            // a normal scroll view would: the first row clear of the header at
            // one end, the last row at the bottom at the other.
            let y = Scrolling.originY(forTopRow: targetRow, table: table,
                                      clipView: clipView, document: document)
            let before = clipView.bounds.origin.y
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clipView)
            scrollView.flashScrollers()     // consuming the event skips this
            Self.diagnoseScroll(event: event, table: table,
                                clipView: clipView, document: document,
                                steps: steps, currentTop: currentTop,
                                targetRow: targetRow, y: y, before: before)
            return nil                      // consumed
        }
    }

    // MARK: wheel diagnostics

    private static func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
    private static func f(_ r: NSRect) -> String {
        "(\(f(r.minX)),\(f(r.minY)) \(f(r.width))×\(f(r.height)))"
    }

    /// Why a wheel event was passed through or swallowed without scrolling.
    private static func diagnoseBail(_ reason: String, table: NSTableView?) {
        guard Scrolling.diagnose else { return }
        print("[wheel] BAIL: \(reason)  rows \(table?.numberOfRows ?? -1)")
    }

    /// Everything the monitor computed, and where the list actually ended up.
    ///
    /// Read it in this order:
    ///
    /// 1. **`currentTop` across consecutive notches.** It should move by exactly
    ///    one per notch and in the direction of `steps`. If it stands still, or
    ///    moves the wrong way, the reading of the current position is wrong —
    ///    which is what it was, and `topVisibleRow` records why.
    /// 2. **`rect(ofRow:)`** — the four sample rows should step by one row height
    ///    each. If they are identical or zero-height, AppKit's row geometry isn't
    ///    working on SwiftUI's table subclass and every notch computes the same
    ///    `y`. (Checked: it is fine. Don't spend a second round here.)
    /// 3. **`wanted y` vs `after` vs `settled`** — if `y` is right but `after` or
    ///    `settled` differ, the scroll is being applied and then reverted by
    ///    something else and this monitor's arithmetic is innocent.
    private static func diagnoseScroll(event: NSEvent, table: NSTableView,
                                       clipView: NSClipView,
                                       document: NSView, steps: CGFloat,
                                       currentTop: Int, targetRow: Int,
                                       y: CGFloat, before: CGFloat) {
        guard Scrolling.diagnose else { return }
        let last = max(table.numberOfRows - 1, 0)
        // Type pinned: a six-element literal of concatenated interpolations is
        // exactly the shape that trips "unable to type-check in reasonable time".
        let lines: [String] = [
            "[wheel] deltaY \(f(event.scrollingDeltaY))"
                + "  precise \(event.hasPreciseScrollingDeltas)"
                + "  steps \(f(steps))"
                + "  inverted \(Scrolling.inverted)",
            "  rows \(table.numberOfRows)"
                + "  rowHeight \(f(table.rowHeight))"
                + "  spacing.h \(f(table.intercellSpacing.height))",
            "  visibleRect \(f(table.visibleRect))"
                + "  currentTop \(currentTop)"
                + "  -> targetRow \(targetRow)",
            "  rect(ofRow:) 0 \(f(table.rect(ofRow: 0)))"
                + "  1 \(f(table.rect(ofRow: min(1, last))))"
                + "  target \(f(table.rect(ofRow: targetRow)))"
                + "  last[\(last)] \(f(table.rect(ofRow: last)))",
            "  documentView \(document === table ? "IS the table" : String(describing: type(of: document)))"
                + "  document.frame \(f(document.frame))"
                + "  clip.bounds \(f(clipView.bounds))"
                + "  clip.insets.top \(f(clipView.contentInsets.top))",
            "  wanted y \(f(y))"
                + "  before \(f(before))  after \(f(clipView.bounds.origin.y))",
        ]
        print(lines.joined(separator: "\n"))
        // One turn later: if something else reverts the scroll, this is where it
        // shows up — `after` above would be right and this one wrong.
        DispatchQueue.main.async { [weak clipView, weak table] in
            guard let clipView, let table else { return }
            print("  [wheel] settled clip.origin.y \(f(clipView.bounds.origin.y))"
                    + "  topVisibleRow \(Scrolling.topVisibleRow(table: table, clipView: clipView))")
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

        // Through `Scrolling.originY`, the one place that knows how a row index
        // becomes a clip origin — so a restore lands exactly where the wheel
        // would have put it, and neither can be fixed without the other.
        let clipView = scrollView.contentView
        let document = scrollView.documentView ?? table
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x,
                                    y: Scrolling.originY(forTopRow: row, table: table,
                                                         clipView: clipView,
                                                         document: document)))
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
                    // The rows are usable while this runs — Who, Date and the
                    // attachment mark are still settling — so this is a quiet
                    // note rather than a blocking indicator. It also explains
                    // why those columns change under you a few seconds in.
                    if model.isEnriching {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text("reading messages…")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
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
        } else if model.isListing && model.rows.isEmpty {
            // Before this, a mailbox mid-listing was indistinguishable from an
            // empty one — it said "No messages" for however long the read took,
            // which on Trash is several seconds of the app confidently
            // asserting something false.
            busy("Listing messages…")
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
                        // Eudora 7's own row art, each centred under its header
                        // icon. Unread gets the dot; the other states Eudora
                        // tracks — replied, forwarded, redirected, queued, sent —
                        // keep their letter, because there is only art for the
                        // unread case and dropping the letters would lose real
                        // information from the list.
                        Group {
                            // Draft states before unread: neither is ever
                            // unread, but testing them first keeps the
                            // precedence explicit rather than incidental. All
                            // three are Eudora's own art; the states that only
                            // have a letter fall through.
                            if r.isSendError {
                                RowIcon.view(RowIcon.sendError,
                                             show: true,
                                             width: HeaderIcon.status.width)
                            } else if r.isUnsent {
                                RowIcon.view(RowIcon.unsent,
                                             show: true,
                                             width: HeaderIcon.status.width)
                            } else if r.isUnread {
                                RowIcon.view(RowIcon.unread,
                                             show: true,
                                             width: HeaderIcon.status.width)
                            } else if !r.statusGlyph.trimmingCharacters(in: .whitespaces).isEmpty {
                                Text(r.statusGlyph)
                                    .font(EudoraFont.list)
                                    .frame(width: HeaderIcon.status.width,
                                           height: RowIcon.height)
                            } else {
                                Color.clear
                                    .frame(width: HeaderIcon.status.width,
                                           height: RowIcon.height)
                            }
                        }
                        RowIcon.view(RowIcon.attachment,
                                     show: r.hasAttachment,
                                     width: HeaderIcon.attachment.width)
                    }
                    .tableCell(column: 0)
                }.width(HeaderIcon.leadingColumnWidth)
                // Explicit content closures rather than the `value:` keypath
                // form, so the text can carry the offset. Nothing is lost:
                // sorting is done on `model.rows` and the header clicks come from
                // `MessageHeaderSortInstaller`, so this table still has no
                // `sortOrder` binding and `value:` would supply only the text.
                // Fixed widths, not flexible: see MessageColumnWidths for why.
                // Subject alone is left to flex, and nothing's origin depends on
                // its width because it is last.
                TableColumn("Who") { r in
                    Text(r.who).font(EudoraFont.list).tableCell(column: 1)
                }.width(MessageColumnWidths.who)
                TableColumn("Date") { r in
                    Text(r.date).font(EudoraFont.list).tableCell(column: 2)
                }.width(MessageColumnWidths.date)
                TableColumn("Subject") { r in
                    Text(r.subject).font(EudoraFont.list).tableCell(column: 3)
                }
            }
            // The right-click menu is AppKit, not `.contextMenu` — see
            // MessageContextMenuInstaller. SwiftUI builds nested menus eagerly,
            // which made every right-click construct all 2,657 mailboxes.
            .background(MessageContextMenuInstaller(model: model))
            .background(MessageHeaderSortInstaller(model: model))
            .background(TableHeaderIconStyler(icons: HeaderIcon.leadingColumns))
            .background(TableScrollStateSyncer(model: model))
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A placeholder that says work is happening, rather than one that states a
    /// fact which isn't true yet.
    private func busy(_ text: String) -> some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail: message preview

/// The rule marking the split between the message list and the message view.
///
/// Drawn by `PaneDividerHandle`, which also carries the drag.
///
/// **Historical note, so nobody re-treads it.** This used to be a cosmetic
/// overlay on top of a `VSplitView`, whose own divider stayed a hairline and was
/// fiddly to grab. The obvious AppKit repair is
/// `splitView(_:additionalEffectiveRectOfDividerAt:)`, which adds to both the
/// drag region and the cursor region — but it is a *delegate* method, and
/// SwiftUI's `VSplitView` is managed by an `NSSplitViewController`, which throws
/// the moment you assign to its split view's delegate: *"A SplitView managed by
/// a SplitViewController cannot have its delegate modified."* The slot is not
/// available, interposed or otherwise. Hence the hand-built split.
///
/// All values here are taste, not measurement. Retune freely.
/// The drawn rule and the draggable strip are the same thing: the whole
/// thickness takes the drag, so what you can see is exactly what you can grab.
///
/// It was briefly a 5 pt rule inside an 11 pt invisible grab band, which worked
/// but meant the target didn't match the target you could see, and the surplus
/// showed as a strip of bare window background above the preview.
enum PaneDivider {
    /// 9 rather than the 5 this was for a long time — two points more above and
    /// below, which is the difference between fiddly and easy to hit.
    static let thickness: CGFloat = 9

    /// `.primary` rather than `.separatorColor` — the system separator is
    /// deliberately faint, which is the thing being corrected here. Going
    /// through the semantic colour keeps it legible in both appearances instead
    /// of being a dark grey that disappears in dark mode.
    static let color = Color.primary.opacity(0.35)
}

/// Where the divider is allowed to be.
///
/// Every read of the stored height goes through `previewHeight`, so a stored
/// value can never put either pane below its minimum however it was arrived at
/// — dragged on a taller window, restored from an older build, or hand-edited in
/// the defaults database.
enum PaneLayout {
    /// Enough to see a useful number of rows.
    static let listMinimum: CGFloat = 150
    /// Enough for the header block and a line or two of body.
    static let previewMinimum: CGFloat = 140
    static let defaultPreviewHeight: Double = 300

    /// The smallest the detail area may be, which becomes the window's own
    /// minimum. `VSplitView` used to impose this implicitly, from the two panes'
    /// `minHeight`s; stating it keeps the window from being resized into the
    /// degenerate case below.
    static var minimumTotal: CGFloat { listMinimum + previewMinimum + PaneDivider.thickness }

    /// The preview's height, clamped to what `total` can actually accommodate.
    static func previewHeight(_ stored: Double, total: CGFloat) -> CGFloat {
        let available = max(0, total - PaneDivider.thickness)
        let mostThePreviewMayTake = available - listMinimum
        // `>=`, not `>`: at exactly `minimumTotal` the two minimums fit precisely,
        // and `>` would send the one window height this layout is designed
        // around down the degenerate path below — giving the list 145 pt when
        // its stated minimum is 150.
        guard mostThePreviewMayTake >= previewMinimum else {
            // Not enough room for both minimums — the window is smaller than the
            // layout supports, which `minimumTotal` should prevent but a display
            // change or a restored frame can still produce. Halve it rather than
            // let either pane go negative, which lays out as a hard crash in
            // some SwiftUI versions and as nothing at all in others.
            return available / 2
        }
        return min(max(CGFloat(stored), previewMinimum), mostThePreviewMayTake)
    }
}

/// The divider: draws the rule, takes the drag, and shows the resize cursor.
struct PaneDividerHandle: View {
    /// Distance dragged since the gesture began, positive downward.
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    /// Whether *we* put a cursor on the stack. See the hover handler.
    @State private var pushedCursor = false

    var body: some View {
        Rectangle()
            .fill(PaneDivider.color)
            .frame(height: PaneDivider.thickness)
            .contentShape(Rectangle())
            // Push/pop rather than `set()`: `set` is undone by the next view that
            // has an opinion, which over a scrolling list is immediately.
            //
            // The flag is what keeps the pair balanced. `onHover(true)` can arrive
            // without a matching `false` — the window hidden with ⌘H, a menu opening
            // over the pointer, the app deactivating — and the two leaks are not
            // symmetric: a spare `pop` is documented as a no-op, but a spare `push`
            // means someone else's cursor gets popped later.
            .onHover { inside in
                if inside, !pushedCursor {
                    NSCursor.resizeUpDown.push()
                    pushedCursor = true
                } else if !inside, pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
            // `minimumDistance: 0` so the drag starts on mouse-down rather than
            // after a few points of slop, which on a divider reads as stickiness.
            //
            // **`coordinateSpace: .global` is load-bearing — do not drop it.**
            // `DragGesture` defaults to `.local`, meaning local to this view, and
            // this view is the thing being dragged. Every frame the divider moves,
            // its local origin moves with it, so the same pointer position reports a
            // different translation, which moves the divider again. It is a feedback
            // loop, and it looks like the divider fighting the mouse: frantic
            // jittering that never settles under the cursor. A space that doesn't
            // move with the handle breaks the loop.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { onChanged($0.translation.height) }
                    .onEnded { _ in onEnded() }
            )
    }
}

struct PreviewView: View {
    @EnvironmentObject var model: AppModel

    /// Wrapped in a `GeometryReader` so the pane's height is decided by the
    /// split view and the user, never by the message being shown.
    ///
    /// `VSplitView` sizes its panes from their content's minimum height, and
    /// this pane's minimum used to change with every selection: the detached
    /// attachment bar is `fixedSize`d and so demands up to 120 pt on a message
    /// that has attachments and nothing on one that doesn't, and the header block
    /// grows and shrinks with the To line, the attachment chips and a subject
    /// long enough to wrap. Switching messages therefore moved the divider —
    /// which looks like the app resizing the pane behind your back, because it is.
    ///
    /// A `GeometryReader` has no intrinsic size of its own: it reports no
    /// minimum, takes whatever height it is offered, and hands it down. That
    /// leaves exactly one thing deciding this pane's size — the explicit
    /// `.frame(height:)` it is given in `splitView`, which is `PaneLayout`'s
    /// clamp of wherever the user last dragged the divider. The content is then
    /// pinned to that height rather than asking for one, and clipped, since a
    /// very short pane can't fit a tall header block.
    ///
    /// (The `GeometryReader` was originally here to defend against `VSplitView`
    /// sizing panes from their content's minimum, which made the divider jump
    /// whenever a selection changed the header block's height. The split is
    /// hand-built now and no longer asks, but the reasoning still holds: this
    /// pane must take the height it is given and not ask for one.)
    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.width, height: geo.size.height,
                       alignment: .topLeading)
                .clipped()
                // The rule that used to be overlaid here is now drawn by
                // `PaneDividerHandle`, which sits above this pane in the stack
                // and carries the drag as well as the line.
        }
    }

    @ViewBuilder private var content: some View {
        if let p = model.preview {
            VStack(alignment: .leading, spacing: 0) {
                headers(p)
                Divider()
                if p.isHTML {
                    HTMLMailView(html: p.content, images: p.images) { url in
                        model.showBanner("Link copied: \(url)")
                    }
                } else {
                    ScrollView {
                        // An attachment-only message genuinely has no text, so
                        // say that rather than implying something failed.
                        Text(p.content.isEmpty
                             ? (p.detached.isEmpty ? "(no text body)"
                                                   : "(no message text — attachment only)")
                             : p.content)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                // After the body, where Eudora put them — but *pinned* below it
                // rather than inline, and outside the web view. Native views keep
                // them out of reach of the message's own CSS, which could restyle
                // or hide them inside the WKWebView's document; pinning means a
                // long message doesn't bury the attachment list off-screen. The
                // height cap is what stops a message with many attachments from
                // squeezing the body to nothing.
                if !p.detached.isEmpty {
                    Divider()
                    ScrollView {
                        DetachedAttachmentBar(items: p.detached)
                    }
                    .frame(maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if model.isLoadingPreview {
            // `loadMessage` clears `preview` and then reads and renders off the
            // main actor, which on a large mailbox is a noticeable wait. Without
            // this the pane sat on "Select a message" throughout — telling the
            // user to do the thing they had just done.
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Opening message…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// The attachments Eudora detached to disk, listed after the body the way
/// Eudora 7 listed them: a file icon and the filename.
///
/// Unlike `AttachmentChip` these have no bytes in the message — the file is out
/// in the Attachments folder — so the actions differ: **Reveal in Finder** and
/// **Save a Copy**, plus **View** for images through the existing native viewer.
/// Never open-in-default-app, per the "dumb client" stance (design-decisions §3):
/// handing a `.doc` to Word is exactly the message-triggered behaviour that stance
/// exists to prevent, and it would be no less dangerous for the file having been
/// unpacked to disk by Eudora years ago.
///
/// A file Eudora recorded but that isn't on disk is still listed, greyed and
/// unclickable, with the recorded Windows path as its tooltip — that path is the
/// only remaining clue to where it went, and silently dropping the row would
/// misrepresent the message as having had no attachment.
struct DetachedAttachmentBar: View {
    let items: [LocatedAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Keyed by position, not by value: a forwarded message can record the
            // same file twice, and identical values would collide as IDs.
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if item.isFound {
                    Menu {
                        Button("Reveal in Finder") { DetachedAttachmentActions.reveal(item) }
                        Button("Save a Copy…") { DetachedAttachmentActions.saveCopy(item) }
                        if DetachedAttachmentActions.isImage(item) {
                            Button("View") { DetachedAttachmentActions.viewImage(item) }
                        }
                    } label: {
                        row(item, enabled: true)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(item.url?.path ?? item.filename)
                } else {
                    row(item, enabled: false)
                        .help("Not found in the Attachments folder. Eudora recorded it as: "
                                + item.recordedPath)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ item: LocatedAttachment, enabled: Bool) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: icon(for: item))
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .opacity(enabled ? 1 : 0.4)
            // `.underline` before `.lineLimit`, so this uses `Text`'s own
            // underline rather than the `View` one that needs macOS 13.
            Text(item.filename)
                .underline(enabled)
                .lineLimit(1)
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
        }
        .font(.callout)
    }

    /// The system's icon for the file, so a .doc looks like a Word document and
    /// a .pdf like a PDF — as Eudora's own list did. Looked up from the *path*
    /// for files that exist, and from the extension otherwise, so a missing file
    /// still gets a plausible icon rather than a blank.
    private func icon(for item: LocatedAttachment) -> NSImage {
        if let url = item.url {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let ext = (item.filename as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
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

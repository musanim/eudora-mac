import Foundation
import SwiftUI
import AppKit
import EudoraStore
import EudoraSearch
import EudoraNet

// MARK: - UI-facing value types
//
// These wrap the format-agnostic types EudoraStore already vends (MailboxNode,
// ListingRow, MIMEPart) in Identifiable/Hashable shells that SwiftUI's List,
// OutlineGroup and Table require. Nothing here touches Eudora's on-disk format —
// that all stays behind MailStore.

/// One node in the sidebar mailbox tree. `children == nil` marks a leaf mailbox
/// (no disclosure triangle); a folder always has a `children` array (possibly
/// empty).
struct MailboxItem: Identifiable, Hashable {
    let id: String          // path-style key, e.g. "In" or "Projects/Music"
    let display: String     // friendly name from descmap.pce
    let type: MailboxType
    let base: URL           // mailbox base URL (…/In), passed straight to MailStore
    let isFolder: Bool
    let messageCount: Int
    let hasUnread: Bool
    let children: [MailboxItem]?

    /// SF Symbol for the row icon, chosen by Eudora mailbox role.
    var systemImage: String {
        switch type {
        case .inbox:   return "tray.and.arrow.down"
        case .outbox:  return "tray.and.arrow.up"
        case .trash:   return "trash"
        case .junk:    return "xmark.bin"
        case .folder:  return "folder"
        case .mailbox: return "tray"
        }
    }
}

/// One row in the message-list table. Combines the TOC-cache columns from
/// `ListingRow` (status, priority, date, subject, size) with two things only a
/// parse can give us on this fixture: the real correspondent (the TOC "to"
/// field caches the recipient for every incoming message) and whether the
/// message carries an attachment.
struct MessageRow: Identifiable, Hashable, Sendable {
    let id: Int             // 1-based message index within the mailbox
    let statusGlyph: String
    /// Raw Eudora status byte, -1 when unknown. See `isUnsent`.
    let status: Int
    let priority: Int       // Eudora: 1=highest … 4=normal … 7=lowest; 0=unknown
    let label: String       // color-label placeholder (not parsed yet)
    let size: Int
    let subject: String

    // Filled in by the background pass — see `RowEnrichment`. The rows appear
    // immediately from the TOC, which knows all of these approximately, and they
    // settle to the message's own values as the parse catches up.
    var who: String         // From for incoming, To for outgoing (display name)
    var date: String        // Eudora-style short date/time
    var hasAttachment: Bool

    /// `date` as an instant, for the Date column's sort. Nil when neither the
    /// TOC's cached string nor the message's own header could be parsed.
    ///
    /// Carried rather than derived on demand because sorting 22,515 rows would
    /// otherwise re-parse each string ~15 times over, and because the displayed
    /// string changes format when enrichment lands (see `EudoraDateFormat`) —
    /// a comparator working from the text would silently change its mind.
    var sortDate: Date?

    /// Size in K, rounded up, minimum 1K — as Eudora showed it.
    var sizeK: String { "\(max(1, (size + 1023) / 1024))K" }

    /// Never read — Eudora's TOC status 0 (MS_UNREAD). Every other status
    /// ("R", "F", "→", "Q", "S", " ") means the message has been opened at
    /// least once. Named so the list doesn't have to know the glyph.
    var isUnread: Bool { statusGlyph == MailStore.unreadGlyph }

    /// A message composed but never sent — a draft sitting in Out.
    ///
    /// From the raw status byte, not the glyph: read, unsendable, sendable and
    /// unsent all render blank, so the glyph can't tell a draft from ordinary
    /// mail. False on the scan fallback, where there's no `.toc` and therefore
    /// no status at all — a mailbox with no index simply can't show drafts as
    /// drafts.
    var isUnsent: Bool { status == MailboxMutator.statusUnsent }

    /// Sending was attempted and failed. Stays this way until the message is
    /// edited and saved again, which puts it back to unsent.
    var isSendError: Bool { status == MailboxMutator.statusSendError }

    /// Anything still editable in the composer — an unsent draft or one whose
    /// send failed. The distinction matters for the icon and nowhere else, so
    /// every behaviour (reopen on double-click, refusing to mark read) keys off
    /// this rather than testing the two states separately and forgetting one.
    var isDraft: Bool { isUnsent || isSendError }
}

/// The rendered preview of a single message.
///
/// `Sendable` because rendering happens off the main actor now — a message is
/// parsed and rendered on a background task, and only this finished value
/// crosses back. The `MIMEPart` never does: it's a class, and it stays inside
/// the task that made it.
struct MessagePreview: Sendable {
    let subject: String
    let from: String
    let to: String
    let date: String
    let isHTML: Bool
    let content: String          // HTML string when isHTML, else plain text
    let images: [String: EmbeddedImage]  // eudora-image:<id> -> bytes (HTML only)
    let attachments: [MessageAttachment]
    /// Attachments Eudora detached to disk. Shown after the body, as Eudora did,
    /// rather than as header chips — their bytes aren't in the message.
    let detached: [LocatedAttachment]
    let indexSourceNote: String  // shown subtly so we can see toc vs scan
}

/// One attached file whose bytes are present in the message. Carried so the
/// preview can offer **Save As…** (and, for images, View) — never auto-opened,
/// per the "dumb client" stance (design-decisions §3).
struct MessageAttachment: Identifiable, Hashable, Sendable {
    let id: String            // stable within one rendered message, e.g. "eu-att-1"
    let filename: String      // sanitized display / save name
    let mimeType: String
    let data: Data

    var fileExtension: String { (filename as NSString).pathExtension.lowercased() }

    /// Extensions the native image viewer can display. One list, shared with
    /// `DetachedAttachmentActions` — two copies would drift.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff",
        "webp", "heic", "heif", "ico",
    ]

    /// Whether this attachment can open in the existing native image viewer.
    var isImage: Bool {
        if mimeType.lowercased().hasPrefix("image/") { return true }
        return Self.imageExtensions.contains(fileExtension)
    }

    /// Human-readable size for the chip.
    var sizeText: String {
        let b = data.count
        if b < 1024 { return "\(b) B" }
        let kb = Double(b) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

/// An editable outgoing message, and the record in Out that backs it. Address
/// fields are free text (comma/semicolon separated) as the user types them.
///
/// A draft is not just UI state: as in Eudora 7, the message exists in the Out
/// mailbox as **unsent** from the moment it is opened, before a word is typed.
/// That is what makes a half-written message survive a quit, and what lets Out
/// show what you are working on.
struct ComposeDraft: Identifiable {
    let id = UUID()
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    var body: String = ""
    var inReplyTo: String? = nil
    var references: [String] = []

    /// Byte offset of this draft's record in Out.
    ///
    /// An offset rather than an index, for the reason `ViewState` gives about
    /// the remembered selection: an index is a position and shifts as soon as
    /// anything earlier is removed, and a draft can stay open for a long time.
    /// The offset survives `MailboxMutator.replace` of *this* record, which is
    /// the common case — only resizing an earlier record moves it.
    ///
    /// Nil only if the record couldn't be written (no Out mailbox, a lock). The
    /// window still opens in that case; Save and Send fall back to appending.
    var outOffset: Int? = nil

    /// This draft's `Message-ID`, fixed for its whole life and written into
    /// every version of the record.
    ///
    /// The offset alone can't be trusted as identity. Removing an earlier
    /// message shifts everything after it left, and if the removed record
    /// happened to be exactly as long as this one, the stale offset lands on a
    /// *different* real message — which `replace` would then overwrite and
    /// `discard` would delete, silently. So the offset is the fast path and this
    /// is the proof: resolve by offset, then confirm the record really is this
    /// message before touching it.
    var messageID: String = ""

    /// Why the record couldn't be written on open, if it couldn't.
    ///
    /// Carried on the draft rather than shown as a banner: the compose window
    /// goes up immediately on top, so a banner would be covered before it was
    /// read. `ComposeView` surfaces it in its own error line instead.
    var openError: String? = nil

    /// True once the user's content has actually been written.
    ///
    /// Distinguishes "unsaved changes" from "never saved at all", which is what
    /// Don't Save has to decide between: with nothing ever saved, the record in
    /// Out is the empty shell created on open and discarding means removing it;
    /// once there is a saved version, discarding means reverting to it.
    var hasBeenSaved = false
}

/// What parsing a message adds to the row the TOC already gave us.
///
/// The TOC caches status, date, subject and size, so a listing can be shown from
/// it alone. It does *not* record who the message is actually from (its "to"
/// field caches the recipient even for incoming mail) and knows nothing about
/// attachments, so those two need the message itself.
struct RowEnrichment: Sendable {
    let index: Int          // 1-based, matches MessageRow.id
    let who: String
    let date: Date?         // nil when the Date header is missing or unparseable
    let hasAttachment: Bool
}

/// A finished render, ready to hand back to the main actor.
struct RenderedMessage: Sendable {
    let preview: MessagePreview
    let offset: Int         // byte offset, for remembering the selection
}

/// A listing built off the main actor, before enrichment.
struct BuiltListing: Sendable {
    let rows: [MessageRow]
    let source: String
    let summary: String
}

/// How many messages one enrichment batch covers.
///
/// Each batch costs one full SwiftUI `Table` diff, and Trash has 22,515 rows, so
/// this trades granularity against render cost: 2,000 gives ~11 visible steps
/// there instead of ~113 re-renders. Small mailboxes finish in a single batch.
///
/// Top-level rather than a static on `AppModel`, because that class is
/// `@MainActor` and its static stored properties are isolated with it — which
/// the background parse could not then read.
let enrichBatchSize = 2_000

/// How long a selection must hold still before anything is read from disk —
/// used by both the mailbox listing and the message preview. Long enough to skip
/// everything an arrow-key repeat passes over, short enough to feel immediate
/// when you stop.
let selectionSettleDelay: UInt64 = 150_000_000  // 150 ms

/// Timestamped marks for performance work. Off by default.
///
/// Kept rather than deleted: this is how the mailbox-switch latency was chased,
/// and parts 2 and 3 of the performance work will want it again. Set `enabled`
/// to true to use it.
///
/// Lines are buffered and printed three seconds after the last mark, never
/// inline. `print()` to Xcode's console goes through LLDB's stdout pipe, which
/// is slow enough to distort the very timings being measured — logging must not
/// sit inside the measurement.
///
/// **A caution learned the hard way.** In-app instrumentation kept reporting
/// "main thread idle, nothing happening" while the app was plainly stalling: a
/// `CFRunLoopObserver` at order 0 fires *before* CoreAnimation's commit (order
/// 2000000), which is where AppKit and SwiftUI actually lay out and draw, so it
/// measured every turn as ~0 ms. `sample $(pgrep -x Eudora) 10 -file out.txt`
/// found the real cause — a toolbar menu building 2,657 items — in one shot.
/// Reach for the OS sampler before writing more counters.
enum PerfLog {
    static var enabled = false

    private static let start = DispatchTime.now()
    private static var last: UInt64 = DispatchTime.now().uptimeNanoseconds
    private static var buffer: [String] = []
    private static var flushTimer: Timer?

    static func mark(_ label: String) {
        guard enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let sinceLast = Double(now &- last) / 1_000_000
        let sinceStart = Double(now &- start.uptimeNanoseconds) / 1_000_000
        last = now
        buffer.append(String(format: "[perf] %8.1f ms  (+%7.1f)  %@",
                             sinceStart, sinceLast, label))
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            for line in buffer { print(line) }
            buffer.removeAll()
        }
    }
}

/// Progress of a background index build, in mailboxes.
struct IndexProgress: Equatable {
    var done: Int
    var total: Int
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

// MARK: - App model

@MainActor
final class AppModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var tree: [MailboxItem] = []

    /// Bumped whenever `tree` is replaced. The sidebar compares this instead of
    /// the tree itself — see `MailboxTree` — because a structural comparison of
    /// 2,723 nested items on every render would cost as much as it saves.
    @Published private(set) var treeVersion = 0

    /// Bumped only when the tree's *shape* changes — a mailbox added, removed or
    /// renamed. Message counts and unread flags don't touch it.
    ///
    /// **Currently unread by anything.** It existed for the Move menus, which
    /// show names and hierarchy and nothing else but were keyed on
    /// `treeVersion`, so every delete — which changes two counts and no
    /// structure — rebuilt all 2,657 items eagerly inside `NSToolbarItemViewer`
    /// layout. Sampling caught 554 ms of that in one delete, on the main thread,
    /// in the exact window where the message list was waiting to be redrawn.
    ///
    /// Those menus are now AppKit and lazy (see MoveToMenu.swift), so they hold
    /// no items to invalidate and don't need the distinction. Kept because it is
    /// cheap and any future view that draws the tree's shape will want it; drop
    /// it, with `treeShape` and `shapeSignature`, if none appears.
    @Published private(set) var treeStructureVersion = 0

    /// Hash of the last published shape, to tell the two apart.
    private var treeShape = 0
    @Published var status: String = "No Eudora folder open."

    // Selected mailbox (sidebar) and message (table), by their ids. Reactions
    // are driven from the view via `.onChange` (see ContentView) rather than
    // `didSet`, so the follow-on @Published mutations happen *after* SwiftUI's
    // view-update pass — not during it (which SwiftUI warns about).
    @Published var selectedMailboxID: MailboxItem.ID?

    /// The selected messages. Usually one; ⌘-click and ⇧-click grow it.
    @Published var selectedMessageIDs: Set<MessageRow.ID> = []

    /// The **primary** selected message — the last row the user actually
    /// clicked, as against the rest of a multi-selection. This is the one the
    /// preview would show if only one were selected, the one whose position
    /// `keepSelectionVisible` protects, and the one that persists across
    /// relaunch. Maintained by `applyMessageSelection`; always a member of
    /// `selectedMessageIDs`, or nil when that is empty.
    @Published private(set) var primaryMessageID: MessageRow.ID?

    /// The single selected message, or nil when none — **or several** — are
    /// selected. The accessor for every operation that only makes sense on one
    /// message (preview, reply, forward, mark read): with a multi-selection
    /// those don't apply, per the design decision, and this returning nil is
    /// what disables them.
    var selectedMessageID: MessageRow.ID? {
        selectedMessageIDs.count == 1 ? selectedMessageIDs.first : nil
    }

    // Bind List/Table selection through these, never to `$selectedMailboxID`
    // directly. A selection binding is written *during* SwiftUI's update pass —
    // both when the user clicks and when a control reconciles its selection
    // against changed contents — and writing an @Published there produces
    // "Publishing changes from within view updates is not allowed."
    // Deferring the write by one runloop turn moves it safely outside.
    var mailboxSelection: Binding<MailboxItem.ID?> {
        Binding(get: { [weak self] in self?.selectedMailboxID },
                set: { [weak self] new in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        PerfLog.mark("sidebar selection -> \(new ?? "nil")")
                        // Blank here rather than waiting for `loadListing`, which
                        // is two runloop hops away (this one, then `onChange`'s).
                        // More importantly this stops the enrichment *now*: each
                        // of its batches re-diffs the whole table on the main
                        // actor, and a click arriving mid-batch waits behind it.
                        // Only for a real switch. The List also writes nil
                        // through this binding while reconciling against a
                        // freshly replaced tree (see `rememberSelection`), and
                        // treating that as a switch would blank the list and
                        // cancel live work for no reason.
                        if let new, new != self.selectedMailboxID { self.beginMailboxSwitch() }
                        self.selectedMailboxID = new
                    }
                })
    }

    /// Abandon the outgoing mailbox's work and clear what's on screen, so the
    /// switch reads as instant even though the new listing is seconds away.
    private func beginMailboxSwitch() {
        cancelBackgroundWork()
        // Drop the outgoing mailbox's sort with its rows. `rebuildRows` will
        // adopt the incoming one's before the listing lands; clearing here keeps
        // "rows are ordered by `sort`" true in the gap between, rather than only
        // by the accident of the rows being empty.
        sort = nil
        setRows([])
        preview = nil
        mailboxSummary = ""
        listingSource = ""
        PerfLog.mark("cleared for switch")
    }

    var messageSelection: Binding<Set<MessageRow.ID>> {
        Binding(get: { [weak self] in self?.selectedMessageIDs ?? [] },
                set: { [weak self] new in
                    DispatchQueue.main.async { self?.applyMessageSelection(new) }
                })
    }

    /// Install a new selection set and keep `primaryMessageID` truthful.
    ///
    /// The Table's `Set` binding reports only the new membership — not which
    /// row was clicked — so the primary is inferred from the difference:
    /// exactly one row appearing is a click (plain or ⌘), and that row is the
    /// new primary. A ⇧-click extends the range by several rows at once and
    /// keeps its anchor, so an unchanged primary that is still selected stays.
    /// A primary that *left* the selection (⌘-click deselected it) falls back
    /// to an arbitrary member: which one is primary then matters less than
    /// there being one at all.
    ///
    /// Every programmatic selection change goes through here too, so the
    /// invariant — primary is a member, or nil — has one owner. A caller that
    /// *knows* which row was clicked (the AppKit context menu does; the Table
    /// binding doesn't) passes it as `primary` and overrides the inference.
    func applyMessageSelection(_ new: Set<MessageRow.ID>,
                               primary preferred: MessageRow.ID? = nil) {
        // While the removal veil is up the rows are a stale picture, so a
        // non-empty selection arriving through the Table binding (arrow keys —
        // the veil's overlay already swallows clicks) would select by an index
        // that names a different message after the re-list. Ignore it; clears
        // still pass, and the binding's `get` keeps the Table showing none.
        if removalVeil != nil, !new.isEmpty { return }
        if new != selectedMessageIDs {
            let added = new.subtracting(selectedMessageIDs)
            selectedMessageIDs = new
            if new.isEmpty {
                primaryMessageID = nil
            } else if let p = preferred, new.contains(p) {
                primaryMessageID = p
            } else if added.count == 1 {
                primaryMessageID = added.first
            } else if let p = primaryMessageID, new.contains(p) {
                // ⇧-click range extension: the anchor stays primary.
            } else {
                primaryMessageID = new.first
            }
        } else if let p = preferred, new.contains(p), p != primaryMessageID {
            // Same membership, different pointer — a right-click inside the
            // selection moves the primary without moving the selection.
            primaryMessageID = p
        }
    }

    /// Select exactly one message (the programmatic equivalent of a click).
    private func selectMessage(_ id: MessageRow.ID?) {
        if let id {
            applyMessageSelection([id])
        } else {
            applyMessageSelection([])
        }
    }

    /// The message list, **in display order** — `rows[n]` is the nth row on
    /// screen, sorted or not.
    ///
    /// That is load-bearing. The `Table` has no `sortOrder` binding (SwiftUI's
    /// would only report a desired order back to us anyway, not reorder
    /// anything), so everything that maps a table row number to a message — the
    /// right-click menu's `resolveClickedID`, the remembered scroll position —
    /// indexes straight into this array. Sorting the array itself is what keeps
    /// those correct for free; presenting a different order in the view while
    /// leaving this one alone is what would break them.
    @Published var rows: [MessageRow] = []

    /// How `rows` is ordered, or nil for mailbox order. Per mailbox, and
    /// remembered across launches (see `ViewState.sortByMailbox`).
    @Published private(set) var sort: MessageSort?

    @Published var listingSource: String = ""
    @Published var mailboxSummary: String = ""
    @Published var preview: MessagePreview?

    /// True while the mailbox's rows are being built (reading and scanning the
    /// .mbx, which is O(file)).
    @Published private(set) var isListing = false
    /// True while the background parse is still filling in Who, Date and the
    /// attachment glyph. The rows are usable throughout.
    @Published private(set) var isEnriching = false
    /// True between selecting a message and its preview being ready.
    @Published private(set) var isLoadingPreview = false

    // In-flight background work, cancelled whenever it is superseded. Selection
    // must stay instant no matter how slow the mailbox is, so nothing that
    // touches the disk runs on the main actor any more.
    private var listingTask: Task<Void, Never>?
    private var enrichTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    /// Bumped per listing. Late work checks it before touching anything, which is
    /// sturdier than comparing `selectedMailboxID` — the sidebar's deferred
    /// binding writes nil through that transiently while reconciling.
    private var listingGeneration = 0

    /// Message index → position in `rows`, maintained by `setRows`.
    private var rowPositionByID: [Int: Int] = [:]

    /// Every message currently open for editing, keyed by draft id.
    ///
    /// The model owns these, not the windows, and that is the whole point.
    /// Several drafts can be open at once, they all live in the same Out
    /// mailbox, and saving one *moves the others*: `replace` shifts every record
    /// after the one it rewrote. A window holding its own offset in `@State`
    /// would go stale the moment you saved an earlier draft, and its next save
    /// would append a duplicate rather than update. Keeping them here means
    /// `shiftDraftOffsets` can fix all of them at once.
    @Published private(set) var openDrafts: [ComposeDraft.ID: ComposeDraft] = [:]

    /// Opens (or brings forward) the window for a draft.
    ///
    /// `openWindow` is an `@Environment` action, so only a view can reach it —
    /// the model can't open its own windows. `ContentView` hands the action over
    /// once at launch, and the captured `OpenWindowAction` keeps working
    /// afterwards, including when no window is on screen.
    ///
    /// This replaced a published queue that `ContentView` drained. The queue had
    /// a hole: with the main window closed nothing was draining it, so ⌘N wrote
    /// an empty record into Out and no window ever appeared — a silent orphan
    /// every time.
    var presentDraftWindow: ((ComposeDraft.ID) -> Void)?

    /// The mail account, for assembling a draft's From line.
    ///
    /// Held rather than passed in because drafts are now created from places
    /// that have no access to it — `MessageContextMenuController` holds only the
    /// model, and Reply and Forward are reachable from there. Set once by
    /// `ContentView.onAppear`; nil only in the moment before that, when a draft
    /// simply gets an empty From.
    weak var accounts: AccountStore?
    /// Banner text (e.g. "Message sent", or why Check Mail failed).
    ///
    /// Write through `showBanner`/`showError`/`dismissBanner` rather than
    /// assigning, so `bannerIsError` can't be left describing the previous one.
    @Published private(set) var banner: String?

    /// True when `banner` is reporting a failure.
    ///
    /// Errors don't time out — see the overlay in `ContentView`. A failure you
    /// can't finish reading, let alone right-click and copy, before it erases
    /// itself may as well not have been shown, and these are the messages most
    /// worth quoting verbatim: "Check mail failed: …" carries the server's own
    /// numeric code and explanation.
    @Published private(set) var bannerIsError = false

    /// Bumped per banner, and used as the dismissal timer's identity.
    ///
    /// Keying that timer on the banner *text* would be almost right: a second
    /// message restarts it, and one that goes away and comes back rebuilds the
    /// view anyway. But an error replaced by a success carrying the same string
    /// would change only `bannerIsError`, leaving the timer torn down and the
    /// success sitting there forever. A counter has no such case to reason about.
    @Published private(set) var bannerGeneration = 0

    /// Something worked. Says so briefly, then gets out of the way.
    func showBanner(_ text: String) {
        banner = text
        bannerIsError = false
        bannerGeneration &+= 1
    }

    /// Something failed. Stays up until dismissed.
    func showError(_ text: String) {
        banner = text
        bannerIsError = true
        bannerGeneration &+= 1
    }

    func dismissBanner() {
        banner = nil
        bannerIsError = false
    }

    /// True while a Check Mail fetch is in flight. Drives the spinner phase of
    /// the toolbar indicator.
    @Published var isChecking = false

    /// The Check Mail indicator's completion line — "No new mail", "Received 3
    /// messages", "Check mail failed". Set when a fetch finishes and cleared a
    /// few seconds later, so the toolbar shows the outcome and then gets out of
    /// the way. `isChecking` is the phase before this.
    @Published private(set) var checkMailNotice: String?
    private var checkMailNoticeGeneration = 0

    /// Show a Check Mail outcome, then retire it after a beat. Generation-keyed
    /// like `rememberScroll`'s coalescer: a later notice cancels an earlier
    /// one's timer, and the `asyncAfter` closure inherits this method's main
    /// actor so it may touch the published state.
    private func showCheckMailNotice(_ text: String) {
        checkMailNotice = text
        checkMailNoticeGeneration &+= 1
        let generation = checkMailNoticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.checkMailNoticeGeneration == generation else { return }
            self.checkMailNotice = nil
        }
    }

    // MARK: search (Find window)
    /// Hits from the last Find run, newest first.
    @Published var searchResults: [SearchHit] = []
    /// Status line for the Find window ("Indexed N messages.", "12 results.", …).
    @Published var searchStatus: String = ""
    /// True while the search index is (re)building in the background.
    @Published var isIndexing = false
    /// Indexing progress, in mailboxes.
    @Published var indexProgress = IndexProgress(done: 0, total: 0)

    private var store: MailStore?
    private var itemsByID: [MailboxItem.ID: MailboxItem] = [:]

    /// The full-text index for the open tree (nil until a tree is opened/built).
    private var searchIndex: SearchIndex?
    /// Bumped on each (re)index; a background build applies its result only if it
    /// still matches — so a superseded build (e.g. a different tree opened
    /// meanwhile) is discarded.
    private var indexGeneration = 0
    /// Index-file path of the build currently in flight, to avoid launching a
    /// second concurrent build against the *same* file.
    private var indexingPath: String?
    /// When opening a search hit into a not-yet-loaded mailbox, the message to
    /// select once that mailbox's listing has been rebuilt (see loadListing()).
    private var pendingMessageID: MessageRow.ID?

    /// Remembered selection for the open tree (see ViewState.swift). Held in
    /// memory and written on every selection change.
    private var viewState = ViewState()

    /// The mailbox `rows` currently reflects, so a repeat load can be skipped.
    private var listedMailboxID: MailboxItem.ID?

    /// Coalescing token for scroll-position writes (see rememberScroll).
    private var scrollSaveGeneration = 0

    /// True between `open()` returning and the restored mailbox being listed —
    /// the window stays hidden behind the splash for that gap.
    private var splashHeldForRestore = false

    // MARK: opening a tree

    /// UserDefaults key holding the last-opened Eudora folder path. The app is
    /// non-sandboxed, so a plain path round-trips fine (no security-scoped
    /// bookmark needed).
    private static let lastFolderKey = "EudoraRootPath"

    /// Restore on launch: $EUDORA_ROOT wins (handy for the fixture), otherwise
    /// the last folder opened, if it still exists. Else wait for File ▸ Open.
    func openDefaultIfAvailable() {
        // Every exit from here ends the launch wait, including the early return
        // when a tree is already open (onAppear can fire more than once) —
        // unless a restore is going to finish the job (see restoreSelection).
        defer { hideSplashUnlessRestoring() }
        guard rootURL == nil else { return }
        if let env = ProcessInfo.processInfo.environment["EUDORA_ROOT"] {
            open(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
            return
        }
        if let saved = UserDefaults.standard.string(forKey: Self.lastFolderKey) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: saved, isDirectory: &isDir), isDir.boolValue {
                open(URL(fileURLWithPath: saved))
            }
        }
    }

    func open(_ url: URL) {
        // Whatever happens below — success, empty tree, unreadable folder — the
        // splash comes down when this returns, unless a restored selection is
        // still to be listed, in which case restoreSelection takes it down.
        splashHeldForRestore = false
        defer { hideSplashUnlessRestoring() }
        UserDefaults.standard.set(url.path, forKey: Self.lastFolderKey)

        // In/Out/Junk/Trash are load-bearing — receiving needs In, sending
        // needs Out, delete needs Trash — so any that are missing are created
        // before the tree is read, and a genuinely fresh directory becomes a
        // minimal Eudora tree (its first descmap.pce plus the four boxes). On
        // a complete tree this is a pure read and touches nothing. Failure is
        // non-fatal: a read-only archive still opens for browsing, and the
        // operations that need a missing box complain when actually used.
        do {
            let created = try MailboxTreeMutator.ensureSystemMailboxes(root: url)
            if !created.isEmpty {
                showBanner("Created \(created.joined(separator: ", ")).")
            }
        } catch {
            showError("Couldn't create the standard mailboxes: \(error.localizedDescription)")
        }

        let s = MailStore(root: url)
        store = s
        rootURL = url
        let nodes = s.tree()
        tree = Self.buildItems(nodes, prefix: "")
        treeVersion &+= 1
        itemsByID = [:]
        indexItems(tree)
        // Abandon anything still running against the *previous* tree. Without
        // this, a listing already in flight resumes, finds its generation still
        // current, and installs the old tree's rows into the new one — then runs
        // its completion, which persists the wrong selection and takes the splash
        // down over a message list that belongs to a folder we just closed.
        cancelBackgroundWork()
        // Also abandon any tree walk still running against the *previous*
        // store. `cancelBackgroundWork` deliberately doesn't do this — it is
        // called on every sidebar click too, and dropping count refreshes there
        // would leave the unread badges stale.
        treeReloadGeneration &+= 1

        selectedMailboxID = nil
        selectMessage(nil)
        listedMailboxID = nil
        // Before `setRows`, so the (empty) rows aren't run through a sort
        // belonging to a mailbox in the tree being closed.
        sort = nil
        setRows([])
        preview = nil
        status = tree.isEmpty
            ? "No descmap.pce found at \(url.lastPathComponent)."
            : "\(url.lastPathComponent) — \(itemsByID.values.filter { !$0.isFolder }.count) mailboxes."

        // Reuse a completed index for this tree if one exists (instant), else
        // build it off the main thread with progress.
        searchResults = []
        if tree.isEmpty {
            indexGeneration += 1        // cancel any in-flight build's result
            searchIndex = nil
            searchStatus = ""
            isIndexing = false
        } else {
            openOrBuildIndex(for: url)
        }

        restoreSelection(forRoot: url.path)
    }

    // MARK: remembered selection

    /// Puts the sidebar and message selection back where the user left them for
    /// this tree. Both are validated against what's on disk *now* — a mailbox may
    /// be gone, and the remembered message may have been deleted — so a stale
    /// blob degrades to "no selection" rather than to a wrong selection.
    private func restoreSelection(forRoot root: String) {
        viewState = ViewStateStore.load(forRoot: root)
        guard let saved = viewState.selectedMailbox,
              let item = itemsByID[saved], !item.isFolder else { return }

        let savedOffset = viewState.selectedMessageOffsetByMailbox[saved]
        // `pendingListFocus` is set once the rows exist, not here: the focus
        // helper retries for about a second and then gives up, and the listing
        // can now take longer than that to arrive.
        selectedMailboxID = saved
        // Keep the splash up past the end of open(): the listing is built on the
        // next runloop turn, and revealing the window before then shows an empty
        // message list for the mailbox that's supposedly selected.
        splashHeldForRestore = true

        // Drive the reload explicitly rather than relying on
        // `.onChange(of: selectedMailboxID)`. open() has just set the selection
        // to nil and back, both before SwiftUI observed either value, so if the
        // newly-opened tree's remembered mailbox has the same id as the one
        // already showing (say "In" in both trees), onChange sees no change and
        // never fires — leaving an empty list under a selected mailbox and a
        // pendingMessageID that leaks into whatever the user clicks next.
        // Resolving the remembered byte offset to today's index means reading and
        // scanning the whole .mbx — the very thing this change moved off the main
        // thread, and at launch it lands on whichever mailbox was last open. Do
        // it in the background, then list. nil means that message is gone.
        let base = item.base
        let mailStore = store
        Task { [weak self] in
            let resolved: Int? = await Task.detached(priority: .userInitiated) {
                savedOffset.flatMap { mailStore?.indexOfRecord(at: base, offset: $0) }
            }.value
            guard let self else { return }
            self.pendingMessageID = resolved
            self.loadListing()
        }

        // The splash comes down when the rows land (from `loadListing`'s
        // completion), not a runloop turn later: the listing is no longer built
        // synchronously, so revealing on a fixed delay would show exactly the
        // empty message list this is here to hide. The timeout is the backstop —
        // a mailbox that fails to list must not strand the splash on screen
        // forever, which would look like a hang with no window at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.splashHeldForRestore else { return }
            self.splashHeldForRestore = false
            SplashWindow.hide()
        }
    }

    /// Takes the splash down unless a restore is still finishing.
    private func hideSplashUnlessRestoring() {
        guard !splashHeldForRestore else { return }
        SplashWindow.hide()
    }

    /// Set when a listing loads with a remembered scroll position; the message
    /// table's AppKit bridge applies it and then clears it. Published so the
    /// bridge's `updateNSView` is invoked.
    @Published var pendingScrollTopRow: Int?

    /// Records the message list's scroll position for the current mailbox.
    ///
    /// Scrolling fires continuously, so the write to UserDefaults is coalesced —
    /// the in-memory state updates immediately, the save lands once the scroll
    /// has been still for a moment.
    func rememberScroll(topRow: Int) {
        guard let mailbox = selectedMailboxID, topRow >= 0 else { return }
        guard viewState.scrollTopRowByMailbox[mailbox] != topRow else { return }
        viewState.scrollTopRowByMailbox[mailbox] = topRow

        // Coalesce with a generation token rather than a DispatchWorkItem: a
        // work item's block is escaping and doesn't inherit this method's main
        // actor isolation, so it couldn't touch `viewState` at all. A closure
        // passed to asyncAfter from a @MainActor method does inherit it.
        scrollSaveGeneration += 1
        let generation = scrollSaveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.scrollSaveGeneration == generation,
                  let root = self.rootURL?.path else { return }
            ViewStateStore.save(self.viewState, forRoot: root)
        }
    }

    /// Called by the bridge once the scroll position has been applied.
    func clearPendingScroll() {
        // Only a restore that was actually pending may take the veil down —
        // a straggler from before the veil went up (a launch restore's
        // one-turn-deferred clear, say) finds `pendingScrollTopRow` already
        // nil, because `afterRemoval` nils it when raising the veil, and must
        // not un-hide the very swap the veil exists to cover.
        let hadPending = pendingScrollTopRow != nil
        pendingScrollTopRow = nil
        if hadPending { dropRemovalVeil(showNotice: true) }
    }

    /// Non-nil from a delete/move until the re-listed rows are back *and*
    /// their restored scroll position has been applied. While set, the
    /// message list keeps showing the pre-removal list as a picture —
    /// washed halfway to white, this text over them, all interaction blocked —
    /// instead of the old blank → wrong offset → jump sequence. The value is
    /// the label ("Deleting…" / "Moving…"). See `afterRemoval`.
    @Published private(set) var removalVeil: String? {
        didSet {
            // The frozen picture lives exactly as long as the veil.
            if removalVeil == nil, removalVeilImage != nil { removalVeilImage = nil }
        }
    }
    private var removalVeilGeneration = 0

    /// The pre-removal list, photographed. Shown *opaque* under the veil's
    /// wash, so nothing the live table does while re-listing — the row diff,
    /// the scroll restore, SwiftUI's own geometry settling — can show through.
    /// A translucent wash over the live table was tried first, and every one
    /// of those movements read as a jerk through it. Nil (capture failed, or
    /// the bridge isn't attached) falls back to washing the live table.
    @Published private(set) var removalVeilImage: NSImage?

    /// The completion message ("Moved to Trash." and friends), shown in the
    /// exact spot the veil's label occupied, the moment the veil lifts —
    /// never alongside it, and never in the window banner, so the one capsule
    /// reads Deleting… → Moved to Trash. with no second location to track.
    /// Retires itself after a couple of seconds.
    @Published private(set) var removalNotice: String?
    private var pendingRemovalNotice: String?
    private var removalNoticeGeneration = 0

    /// The veil's one exit. Publishes the held completion notice into the
    /// label's spot (unless the veil is being superseded — a mailbox switch
    /// doesn't earn a notice about a list no longer showing) and stands the
    /// backstop timer down.
    private func dropRemovalVeil(showNotice: Bool) {
        guard removalVeil != nil else { return }
        removalVeil = nil                 // didSet drops the frozen picture
        removalVeilGeneration += 1        // disarm the backstop
        if showNotice, let notice = pendingRemovalNotice {
            removalNotice = notice
            removalNoticeGeneration += 1
            let generation = removalNoticeGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.removalNoticeGeneration == generation,
                      self.removalNotice != nil else { return }
                self.removalNotice = nil
            }
        }
        pendingRemovalNotice = nil
    }

    /// Installed by the message table's AppKit bridge (`TableScrollStateSyncer.
    /// attach`): photographs the list's scroll view exactly as it looks now.
    /// A closure because the model decides *when* to photograph
    /// (`afterRemoval`, before anything visual changes) while only the bridge
    /// holds the NSViews. Weakly captured on the bridge side, so a torn-down
    /// table returns nil rather than a stale view's pixels.
    var captureListSnapshot: (() -> NSImage?)?

    /// A row to bring into view, scrolling the least amount that does it — as
    /// opposed to `pendingScrollTopRow`, which puts a row *at the top*. Set after
    /// a re-sort so the selection doesn't vanish; cleared by the bridge.
    ///
    /// Unlike a restore, this is not suppressed from the scroll recorder: it
    /// moves the list the way the user would have, so the position it lands on is
    /// worth remembering.
    @Published var pendingRevealRow: Int?

    /// Called by the bridge once the row has been revealed.
    func clearPendingReveal() { pendingRevealRow = nil }

    /// Set when a restored selection should also take keyboard focus, so the
    /// highlight is the active (not washed-out) one and the arrow keys move from
    /// the restored row. Only set on restore — focusing the list on every
    /// mailbox click would steal the arrow keys from the sidebar.
    @Published var pendingListFocus = false

    /// Called by the bridge once focus has been given to the message list.
    func clearPendingListFocus() { pendingListFocus = false }

    /// Records the current selection. Called once a selection has actually taken
    /// effect, never while one is mid-flight.
    ///
    /// - Parameter messageOffset: the selected message's byte offset in the
    ///   .mbx, from the caller that just read the record.
    private func rememberSelection(messageOffset: Int? = nil) {
        // A nil mailbox is never persisted: the sidebar List writes nil through
        // its (deferred) selection binding while reconciling against a freshly
        // replaced tree, which would otherwise land after restoreSelection and
        // erase what was just restored.
        guard let root = rootURL?.path, let mailbox = selectedMailboxID else { return }
        viewState.selectedMailbox = mailbox
        if let offset = messageOffset {
            viewState.selectedMessageOffsetByMailbox[mailbox] = offset
        }
        ViewStateStore.save(viewState, forRoot: root)
    }

    /// The first mailbox of a given type, from the tree already in memory.
    ///
    /// **Never call `MailStore.mailboxBase(ofType:)` from here.** It looks like
    /// an accessor and is a full filesystem walk: `flatten(tree())` rebuilds
    /// every node from disk — 84 `descmap.pce` reads and a
    /// `FileManager.attributesOfItem` per mailbox, 6,699 of them on Stephen's
    /// archive. `outboxBase()` is the same function.
    ///
    /// That was being paid twice for every ⌘N (once to find Out, once for the
    /// `reloadTree` afterwards), twice per draft save, and twice per delete —
    /// on the main thread, which is why opening a compose window and deleting a
    /// message both took a surprisingly long time despite touching a mailbox
    /// with one message in it.
    ///
    /// Depth-first pre-order, matching what `flatten` returned, so "first of
    /// this type" still means the same mailbox.
    func base(ofType type: MailboxType) -> URL? {
        func find(_ items: [MailboxItem]) -> MailboxItem? {
            for item in items {
                if !item.isFolder, item.type == type { return item }
                if let kids = item.children, let hit = find(kids) { return hit }
            }
            return nil
        }
        return find(tree)?.base
    }

    /// Where sent and unsent mail lives, from the in-memory tree.
    var outboxBase: URL? { base(ofType: .outbox) }

    /// A hash of everything the Move menus draw: ids, labels, folder-ness and
    /// nesting. Deliberately excludes `messageCount` and `hasUnread`, which are
    /// the only things our own mutations change.
    private static func shapeSignature(_ items: [MailboxItem]) -> Int {
        var hasher = Hasher()
        func walk(_ items: [MailboxItem]) {
            for item in items {
                hasher.combine(item.id)
                hasher.combine(item.display)
                hasher.combine(item.isFolder)
                if let kids = item.children { walk(kids) }
            }
        }
        walk(items)
        return hasher.finalize()
    }

    private func indexItems(_ items: [MailboxItem]) {
        for i in items {
            itemsByID[i.id] = i
            if let c = i.children { indexItems(c) }
        }
    }

    private static func buildItems(_ nodes: [MailboxNode], prefix: String) -> [MailboxItem] {
        nodes.map { n in
            let path = prefix.isEmpty ? n.entry.filename : prefix + "/" + n.entry.filename
            let kids = n.isFolder ? buildItems(n.children, prefix: path) : nil
            return MailboxItem(id: path,
                               display: n.entry.display,
                               type: n.entry.type,
                               base: n.base,
                               isFolder: n.isFolder,
                               messageCount: n.messageCount,
                               hasUnread: n.entry.hasUnread,
                               children: kids)
        }
    }

    // MARK: listing a mailbox

    /// Full (re)load of the selected mailbox — clears the message selection,
    /// unless a hit is being opened (pendingMessageID), in which case that
    /// message is selected once the rows exist.
    /// - Parameter force: rebuild even if this mailbox is already listed. Used by
    ///   the in-place refreshes (mail sent, mail received); the default path is
    ///   idempotent so the explicit restore call and a subsequent `onChange` for
    ///   the same mailbox don't load twice — the second pass would find
    ///   `pendingMessageID` already consumed and clear the restored selection.
    func loadListing(force: Bool = false) {
        guard force || listedMailboxID != selectedMailboxID || pendingMessageID != nil else {
            return
        }
        PerfLog.mark("loadListing begins")
        // A fresh listing supersedes any removal still veiled: the veil's own
        // completion was cancelled with the old mailbox's listing task, so
        // left up it would sit over the *next* mailbox, dead to clicks, until
        // the backstop timer. No notice — it would describe a list that is no
        // longer showing — and any notice already up comes down for the same
        // reason.
        dropRemovalVeil(showNotice: false)
        if removalNotice != nil { removalNotice = nil }
        listedMailboxID = selectedMailboxID
        preview = nil
        previewTask?.cancel()
        isLoadingPreview = false

        let pending = pendingMessageID
        pendingMessageID = nil
        selectMessage(nil)
        // Clear immediately: the old mailbox's rows must not linger under the
        // new mailbox's name while the listing is built.
        setRows([])

        // Everything that depends on the rows now has to wait for them — the
        // listing is built off the main actor and lands later.
        rebuildRows { [weak self] in
            guard let self else { return }
            if let pending {
                // The index may no longer exist — a restored selection can
                // outlive the messages it pointed at (deleted, or a mailbox that
                // shrank).
                if self.rows.contains(where: { $0.id == pending }) {
                    self.selectMessage(pending)
                    // Ask for keyboard focus now the rows are real. Asking in
                    // restoreSelection would start the retry clock before the
                    // listing existed, and it expires after about a second.
                    self.pendingListFocus = true
                    // Render directly: onChange(selectedMessageIDs) won't fire
                    // if `pending` equals the previously selected index (e.g.
                    // row 2 → row 2 in another mailbox), which would leave the
                    // preview blank.
                    self.loadMessage()
                } else {
                    self.selectMessage(nil)
                }
            }
            self.rememberSelection()

            // Hand the remembered scroll position to the AppKit bridge, clamped
            // to what this mailbox now holds.
            if let mailbox = self.selectedMailboxID,
               let top = self.viewState.scrollTopRowByMailbox[mailbox], !self.rows.isEmpty {
                self.pendingScrollTopRow = min(top, self.rows.count - 1)
            } else {
                self.pendingScrollTopRow = nil
            }

            // Rows are on screen; it is safe to uncover the window.
            if self.splashHeldForRestore {
                self.splashHeldForRestore = false
                SplashWindow.hide()
            }
        }
    }

    /// Rebuild the row list for the current mailbox WITHOUT clearing the message
    /// selection (used after an in-place change like mark-as-read).
    ///
    /// Two phases, because the mailbox has to appear before it can be complete.
    /// The TOC alone gives status, date, subject and size, so the list is built
    /// and shown from that; the correspondent and the attachment glyph need the
    /// messages themselves, and arrive afterwards (see `startEnrichment`).
    ///
    /// Both phases run off the main actor. Reading and record-scanning a mailbox
    /// is O(file), and Trash here is 613 MB — this used to block the main thread
    /// for seconds, *and* parse all 22,515 messages before drawing a single row.
    /// - Parameter carryingEnrichment: enrichment already in hand for rows that
    ///   survive a removal, keyed by their NEW 1-based index. The fresh listing
    ///   is TOC-only — recipient cached as Who, the TOC's own date format — and
    ///   without this the surviving rows visibly regressed to those values the
    ///   moment the removal veil lifted, then "settled" back as the background
    ///   parse re-derived what the old rows already knew (and reshuffled the
    ///   sort with them). Carried values are exactly what the parse will
    ///   produce, so enrichment lands as a visual no-op on these rows.
    private func rebuildRows(carryingEnrichment carryOver: [Int: MessageRow]? = nil,
                             completion: (() -> Void)? = nil) {
        listingTask?.cancel()
        enrichTask?.cancel()

        guard let store,
              let id = selectedMailboxID,
              let item = itemsByID[id], !item.isFolder else {
            // No mailbox, so no sort: leaving the last one set would put a stale
            // indicator on the header and apply that order to whatever is listed
            // next before its own remembered sort could be adopted.
            sort = nil
            setRows([])
            listingSource = ""
            mailboxSummary = ""
            isListing = false
            isEnriching = false
            completion?()
            return
        }

        let base = item.base
        let display = item.display
        let outgoing = (item.type == .outbox)
        // This mailbox's remembered sort, adopted *before* the listing lands so
        // `setRows` orders it on arrival rather than reordering it a frame later.
        // Assigned directly rather than through `setSort`, which would try to
        // re-sort rows belonging to the mailbox being left and write the value
        // straight back to where it came from.
        //
        // PRECONDITION: `rows` is either empty or already belongs to `id`. Every
        // caller satisfies that today — `loadListing` clears the rows first,
        // `markSelected`'s fallback re-lists the mailbox it is already showing,
        // and `afterRemoval` deliberately leaves the *same mailbox's* stale rows
        // up under the removal veil (they were built for `id`, in `id`'s own
        // sort). A new caller that left another mailbox's rows in place would
        // leave them in one order with `sort` claiming another, and
        // `rowPositionByID` would still be right, so nothing would look wrong
        // until a click landed on the wrong message. Clear the rows, or follow
        // this with `setRows(rows)`.
        sort = viewState.sortByMailbox[id]
        isListing = true

        listingGeneration &+= 1
        let generation = listingGeneration

        listingTask = Task { [weak self] in
            // Settle first, for the same reason the preview does — and here it
            // matters more. Arrowing down the sidebar fires one of these per
            // keypress, each a detached read of a whole .mbx that cannot be
            // interrupted once it has begun. Without this, holding a key would
            // stack up overlapping 613 MB reads.
            try? await Task.sleep(nanoseconds: selectionSettleDelay)
            guard !Task.isCancelled else { return }
            PerfLog.mark("settled, starting read of \(display)")

            let built = await Task.detached(priority: .userInitiated) { () -> BuiltListing? in
                AppModel.buildListing(store: store, base: base, display: display)
            }.value
            PerfLog.mark("read+scan done: \(built?.rows.count ?? 0) rows")

            guard !Task.isCancelled, let self, self.listingGeneration == generation else { return }
            var newRows = built?.rows ?? []
            if let carryOver {
                newRows = newRows.map { r in
                    guard let old = carryOver[r.id] else { return r }
                    var carried = r        // status/subject/size stay the TOC's
                    carried.who = old.who
                    carried.date = old.date
                    carried.hasAttachment = old.hasAttachment
                    carried.sortDate = old.sortDate
                    return carried
                }
            }
            self.setRows(newRows)
            PerfLog.mark("rows published")
            self.listingSource = built?.source ?? ""
            self.mailboxSummary = built?.summary ?? ""
            self.isListing = false
            self.isEnriching = false
            completion?()
            if built != nil {
                self.startEnrichment(store: store, base: base,
                                     outgoing: outgoing, generation: generation)
            }
        }
    }

    /// Stop every background task and invalidate anything still in flight, so a
    /// late result can't install itself. Bumping the generation is what makes the
    /// already-suspended tasks stand down when they resume.
    private func cancelBackgroundWork() {
        listingTask?.cancel();  listingTask = nil
        enrichTask?.cancel();   enrichTask = nil
        previewTask?.cancel();  previewTask = nil
        listingGeneration &+= 1
        isListing = false
        isEnriching = false
        isLoadingPreview = false
    }

    /// Replace the rows and the id→position index together, so the two can never
    /// disagree. Enrichment looks rows up by message index, which is not the same
    /// as their position (a compacted mailbox has gaps), and rebuilding that map
    /// per batch was 113 × 22,515 dictionary inserts on the main actor.
    ///
    /// The current sort is applied here, so there is exactly one place rows can
    /// enter the model and exactly one place they can be ordered — a caller that
    /// forgot to sort would leave `rowPositionByID` describing an order the table
    /// isn't in, which is the bug class this method exists to prevent.
    private func setRows(_ new: [MessageRow]) {
        let ordered = MessageSort.apply(sort, to: new)
        rows = ordered
        rowPositionByID.removeAll(keepingCapacity: true)
        rowPositionByID.reserveCapacity(ordered.count)
        for (pos, row) in ordered.enumerated() { rowPositionByID[row.id] = pos }
    }

    // MARK: sorting

    /// Sort by a column, reversing if it is already the sorted one — the whole
    /// behaviour of a header click.
    func toggleSort(_ column: MessageSortColumn) {
        if sort?.column == column {
            setSort(MessageSort(column: column, ascending: !(sort?.ascending ?? true)))
        } else {
            // A new column starts ascending, except Date, which starts newest
            // first: that is the order anyone clicking a date column is asking
            // for, and it's what Eudora's own descending-by-default date sort did.
            setSort(MessageSort(column: column, ascending: column != .date))
        }
    }

    /// Set the sort (or nil for mailbox order), reorder what's on screen, and
    /// remember it for this mailbox.
    func setSort(_ new: MessageSort?) {
        guard sort != new else { return }
        sort = new
        // Re-run the rows through `setRows`, which is where ordering happens.
        // Sorting an already-sorted array is not a problem: `MessageSort.apply`
        // computes the order from the rows' own fields, never from their current
        // positions, so it is idempotent and reversal is exact rather than
        // cumulative.
        setRows(rows)
        keepSelectionVisible()

        guard let mailbox = selectedMailboxID else { return }
        // Assigning nil removes the key, which is what `sortByMailbox` wants for
        // "mailbox order" — see ViewState.
        viewState.sortByMailbox[mailbox] = new
        if let root = rootURL?.path { ViewStateStore.save(viewState, forRoot: root) }
    }

    /// After a reorder, bring the selected message back into view.
    ///
    /// Reordering leaves the table's scroll offset alone, so the selected row can
    /// end up thousands of rows away with nothing on screen having visibly moved
    /// — the list would just look like it had lost the selection.
    ///
    /// `pendingRevealRow`, not `pendingScrollTopRow`: the latter means "make this
    /// the topmost row", which would yank the list even when the selection was
    /// already comfortably on screen, and would then write that row back as the
    /// mailbox's remembered scroll position. Revealing scrolls the minimum
    /// distance and does nothing at all when the row is already visible.
    private func keepSelectionVisible() {
        guard let id = primaryMessageID, let pos = rowPositionByID[id] else { return }
        pendingRevealRow = pos
    }

    /// The TOC-only listing. Pure, and runs off the main actor.
    nonisolated private static func buildListing(store: MailStore,
                                                 base: URL,
                                                 display: String) -> BuiltListing? {
        guard let listing = store.list(at: base, name: display) else { return nil }
        var unread = 0
        let rows = listing.rows.map { r -> MessageRow in
            if r.statusGlyph == MailStore.unreadGlyph { unread += 1 }
            return MessageRow(id: r.index,
                              statusGlyph: r.statusGlyph,
                              status: r.status,
                              priority: Int(r.priority) ?? 0,
                              label: "",
                              size: r.size,
                              subject: r.subject,
                              // The TOC's own values, until the parse lands.
                              // `who` is right for outgoing mail and often wrong
                              // for incoming (the TOC caches the recipient
                              // either way) — but it is what Eudora itself shows
                              // from that cache, and far better than a blank
                              // column while the parse catches up.
                              who: r.who,
                              date: r.date,
                              hasAttachment: false,
                              // The TOC's cached string, read as an instant so
                              // the Date column can sort before the parse lands.
                              sortDate: EudoraDateFormat.tocDate(r.date))
        }
        let sizeK = max(1, (rows.reduce(0) { $0 + $1.size } + 1023) / 1024)
        return BuiltListing(rows: rows,
                            source: listing.source.rawValue,
                            summary: "\(rows.count) messages"
                                + (unread > 0 ? ", \(unread) unread" : "")
                                + " · \(sizeK)K")
    }

    /// Parse the mailbox in the background and fill in Who and the attachment
    /// glyph, applying results in batches so the list settles progressively
    /// rather than in one jump at the end.
    private func startEnrichment(store: MailStore, base: URL,
                                 outgoing: Bool, generation: Int) {
        isEnriching = true

        enrichTask = Task { [weak self] in
            // Unbounded on purpose: a buffering policy would silently *drop*
            // batches, and a dropped batch means rows left un-enriched with
            // nothing to notice it. The buffer is bounded by the mailbox anyway.
            let stream = AsyncStream<[RowEnrichment]> { continuation in
                let work = Task.detached(priority: .utility) {
                    var batch: [RowEnrichment] = []
                    store.forEachMessage(at: base, isCancelled: { Task.isCancelled }) { index, _, part in
                        if Task.isCancelled { return false }
                        // Argument order follows RowEnrichment's declaration.
                        batch.append(RowEnrichment(
                            index: index,
                            who: AppModel.correspondent(part, outgoing: outgoing),
                            date: EudoraDateFormat.parse(part.header("Date")),
                            // Both forms count: mail Eudora processed has no MIME
                            // attachment left (it detached the bytes to disk and
                            // wrote an "Attachment Converted:" line into the
                            // body), while mail it never touched, and everything
                            // outgoing, still carries real MIME parts.
                            hasAttachment: part.walk().contains(where: { $0.isAttachment })
                                || DetachedAttachment.isPresent(in: part)))
                        if batch.count >= enrichBatchSize {
                            continuation.yield(batch)
                            batch = []
                        }
                        return true
                    }
                    if !batch.isEmpty { continuation.yield(batch) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in work.cancel() }
            }

            for await batch in stream {
                guard !Task.isCancelled, let self,
                      self.listingGeneration == generation else { return }
                self.applyEnrichment(batch)
            }
            guard let self, self.listingGeneration == generation else { return }
            self.isEnriching = false
            // Who, Date and the attachment glyph were provisional until now: the
            // TOC caches the *recipient* as "who" even for incoming mail, and its
            // date can differ from the message's own. A sort on one of those was
            // therefore ordering the wrong values, so redo it once — once, at the
            // end, rather than per batch, which would shuffle the list under the
            // pointer every 2,000 messages and cost a full table diff each time.
            if self.sort?.column.dependsOnEnrichment == true {
                self.setRows(self.rows)
                self.keepSelectionVisible()
            }
        }
    }

    /// Recompute the "N messages, M unread · sizeK" line from the rows in hand.
    /// Cheap, and avoids a re-list just because one status changed.
    private func refreshMailboxSummary() {
        let unread = rows.reduce(0) { $0 + ($1.isUnread ? 1 : 0) }
        let sizeK = max(1, (rows.reduce(0) { $0 + $1.size } + 1023) / 1024)
        mailboxSummary = "\(rows.count) messages"
            + (unread > 0 ? ", \(unread) unread" : "")
            + " · \(sizeK)K"
    }

    private func applyEnrichment(_ batch: [RowEnrichment]) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
            PerfLog.mark(String(format: "enrich batch of %d applied in %.1f ms",
                                batch.count, ms))
        }
        for e in batch {
            guard let pos = rowPositionByID[e.index], pos < rows.count else { continue }
            var row = rows[pos]
            row.who = e.who
            row.hasAttachment = e.hasAttachment
            // An unparseable Date header leaves the TOC's value in place — both
            // the displayed string and the sort key — which is what the
            // synchronous version did too.
            if let date = e.date {
                row.date = EudoraDateFormat.display(date)
                row.sortDate = date
            }
            // One write, not three: each mutation through `rows[pos].x` publishes
            // separately, and there are tens of thousands of rows.
            rows[pos] = row
        }
    }

    // MARK: display helpers

    /// From (incoming) or To (outgoing), reduced to a display name.
    nonisolated static func correspondent(_ part: MIMEPart, outgoing: Bool) -> String {
        let primary = outgoing ? "To" : "From"
        let fallback = outgoing ? "From" : "To"
        let raw = HeaderDecoder.decode(part.header(primary) ?? part.header(fallback) ?? "")
        return displayName(raw)
    }

    /// "Steve Dorner <d@x>" → "Steve Dorner"; "a@b (Name)" → "Name"; else the
    /// address. Strips surrounding quotes.
    nonisolated static func displayName(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let lt = s.firstIndex(of: "<") {
            let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !name.isEmpty { return name }
            if let gt = s.firstIndex(of: ">"), s.index(after: lt) < gt {
                return String(s[s.index(after: lt)..<gt])
            }
        }
        if let op = s.firstIndex(of: "("), let cp = s.firstIndex(of: ")"), op < cp {
            let name = s[s.index(after: op)..<cp].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return s
    }

    // The date formatters live in `EudoraDateFormat`, outside this class:
    // `AppModel` is `@MainActor`, so a static stored property here would be
    // main-actor isolated and unreachable from the background parsing that now
    // builds the message list.

    /// Parse an RFC-822 Date header and render it Eudora-style ("12/17/02 9:04 AM").
    nonisolated static func eudoraDate(_ header: String?) -> String? {
        EudoraDateFormat.eudoraDate(header)
    }

    // MARK: rendering one message

    /// Render the selected message, off the main actor.
    ///
    /// Selection itself is instant — it's an `Int` — and this is what used to
    /// make it feel otherwise: reading and record-scanning the whole .mbx, then
    /// parsing and rendering, all on the main thread, per arrow-key press.
    ///
    /// Two behaviours matter for the feel of it. The preview is cleared at once,
    /// so the pane never shows the *previous* message's text while the next one
    /// loads. And the work waits out `selectionSettleDelay` first, so holding an arrow key
    /// down doesn't queue a render for every message passed through — only the
    /// one landed on is ever read from disk.
    func loadMessage() {
        PerfLog.mark("loadMessage begins")
        previewTask?.cancel()

        guard let store,
              let mid = selectedMailboxID,
              let item = itemsByID[mid], !item.isFolder,
              let index = selectedMessageID else {
            preview = nil
            isLoadingPreview = false
            return
        }

        preview = nil
        isLoadingPreview = true

        let base = item.base
        let root = store.root
        let note = listingSource

        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: selectionSettleDelay)
            guard !Task.isCancelled else { return }

            let rendered = await Task.detached(priority: .userInitiated) { () -> RenderedMessage? in
                guard let msg = store.message(at: base, index: index) else { return nil }
                return RenderedMessage(
                    preview: AppModel.render(msg.part,
                                             sourceNote: note,
                                             locator: AttachmentLocator(mailRoot: root)),
                    offset: msg.record.offset)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.preview = rendered?.preview
            self.isLoadingPreview = false
            if let offset = rendered?.offset { self.rememberSelection(messageOffset: offset) }
        }
    }


    /// Choose the best displayable body (prefer text/html, else text/plain),
    /// decode it tolerantly, and collect attachment filenames.
    nonisolated static func render(_ part: MIMEPart,
                       sourceNote: String,
                       locator: AttachmentLocator? = nil) -> MessagePreview {
        let subject = HeaderDecoder.decode(part.header("Subject") ?? "")
        let from = HeaderDecoder.decode(part.header("From") ?? "")
        let to = HeaderDecoder.decode(part.header("To") ?? "")
        let date = part.header("Date") ?? ""

        var htmlPart: MIMEPart?
        var textPart: MIMEPart?
        var attachments: [MessageAttachment] = []
        var attCounter = 0

        for p in part.walk() {
            if p.isMultipart { continue }
            if p.isAttachment {
                attCounter += 1
                attachments.append(attachment(from: p, index: attCounter))
                continue
            }
            if p.mainType == "text" {
                if p.subType == "html" {
                    if htmlPart == nil { htmlPart = p }
                } else if textPart == nil {
                    textPart = p
                }
            }
        }

        // Eudora's detached attachments: recorded in the body, bytes on disk.
        let detached = locator?.locateAll(in: part) ?? []

        if let h = htmlPart {
            let dec = CharsetDecoder.smartDecode(h.decodedPayload(), declared: h.charset)
            // Turn every <img> into a safe box and collect the embedded-image
            // bytes the view resolves on an `eudora-image:` click (no network).
            let rendered = BodyRenderer.rewrite(html: dec.text, in: part)
            return MessagePreview(subject: subject, from: from, to: to, date: date,
                                  isHTML: true, content: rendered.html,
                                  images: rendered.images,
                                  attachments: attachments, detached: detached,
                                  indexSourceNote: sourceNote)
        }
        let text = textPart.map {
            CharsetDecoder.smartDecode($0.decodedPayload(), declared: $0.charset).text
        } ?? ""
        return MessagePreview(subject: subject, from: from, to: to, date: date,
                              isHTML: false, content: text,
                              images: [:],
                              attachments: attachments, detached: detached,
                              indexSourceNote: sourceNote)
    }

    /// Build an attachment descriptor (with decoded bytes) from a MIME part.
    nonisolated static func attachment(from part: MIMEPart, index: Int) -> MessageAttachment {
        let name = sanitizedFilename(part.filename) ?? "attachment-\(index)"
        return MessageAttachment(id: "eu-att-\(index)",
                                 filename: name,
                                 mimeType: part.contentType,
                                 data: part.decodedPayload())
    }

    /// Decode (RFC 2047) then strip path separators and control characters from
    /// the attacker-controlled MIME filename, for a safe Save-panel default.
    nonisolated static func sanitizedFilename(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let decoded = HeaderDecoder.decode(raw)
        let cleaned = decoded.map { ch -> Character in
            if ch == "/" || ch == "\\" || ch == ":" { return "_" }
            if let s = ch.unicodeScalars.first, s.value < 0x20 { return "_" }
            return ch
        }
        let name = String(cleaned).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: compose / reply / forward

    func composeNew() {
        beginCompose(ComposeDraft())
    }

    /// The single funnel every new message goes through — new, reply, forward.
    ///
    /// Writes the message into Out as unsent *before* showing it, so it exists
    /// in the mailbox from the moment it opens, as Eudora 7 did. The record is
    /// an empty shell at this point; Save and Send rewrite it in place.
    ///
    /// A failure here is reported but doesn't block composing: being unable to
    /// pre-save is a much smaller problem than refusing to let the user write a
    /// message, and Save and Send both cope with `outOffset == nil` by
    /// appending instead.
    private func beginCompose(_ draft: ComposeDraft) {
        var draft = draft
        // Fixed now and never regenerated — this is the draft's identity for the
        // rest of its life. `OutgoingMessage.generatedMessageID` builds one from
        // the From domain, so it needs the account, but falls back sensibly.
        draft.messageID = OutgoingMessage(
            fromName: "", fromAddress: accounts?.account.fromAddress ?? "",
            to: [], subject: "", body: "").generatedMessageID()
        do {
            draft.outOffset = try appendDraftRecord(draft)
        } catch {
            draft.openError = "Couldn't put this message in Out: "
                + describe(error)
                + " It can still be written and sent; it just isn't saved yet."
        }
        openDrafts[draft.id] = draft
        presentDraftWindow?(draft.id)
    }

    /// A compose window has closed. The record in Out stays; only the editing
    /// session ends.
    func closeDraft(_ id: ComposeDraft.ID) {
        openDrafts.removeValue(forKey: id)
    }

    /// Fold a window's edits back into the model's copy.
    func updateDraft(_ draft: ComposeDraft) {
        guard openDrafts[draft.id] != nil else { return }
        openDrafts[draft.id] = draft
    }

    /// Move every *other* open draft's offset to follow a write to Out.
    ///
    /// A replacement that changes length shifts every record after it, and a
    /// removal shifts everything after the hole. Drafts sitting after the
    /// changed record must be told, or their offsets silently start naming the
    /// wrong bytes — and `locateDraft`'s Message-ID check would then reject
    /// them, so every subsequent save would append a copy instead of updating.
    ///
    /// Strictly greater than: a record at exactly `offset` is the one that
    /// changed, and `replace` leaves its own offset alone.
    private func shiftDraftOffsets(after offset: Int, by delta: Int, except id: ComposeDraft.ID?) {
        guard delta != 0 else { return }
        for key in openDrafts.keys where key != id {
            guard var draft = openDrafts[key],
                  let existing = draft.outOffset, existing > offset else { continue }
            draft.outOffset = existing + delta
            openDrafts[key] = draft
        }
    }

    /// A readable message for a store error. `MutateError` and `WriteError`
    /// aren't `LocalizedError`, so `localizedDescription` alone yields
    /// "The operation couldn't be completed. (… error 0.)" — which is exactly
    /// what the user gets on the most likely failure, a tree with no Out.
    func describe(_ error: Error) -> String {
        switch error {
        case MailboxMutator.MutateError.notFound:
            return "this Eudora folder has no Out mailbox."
        case MailboxMutator.MutateError.outOfRange:
            return "the message is no longer where it was in Out."
        case Outbox.WriteError.locked:
            return "the mailbox is locked (a .lck file is next to it)."
        case let MailboxMutator.MutateError.ioError(m), let Outbox.WriteError.ioError(m):
            return m
        default:
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Append a draft to Out as unsent, returning the record's byte offset.
    private func appendDraftRecord(_ draft: ComposeDraft) throws -> Int {
        guard let outbox = outboxBase else {
            throw MailboxMutator.MutateError.notFound
        }
        let result = try Outbox.append(messageData: draftBytes(draft),
                                       to: outbox,
                                       status: MailboxMutator.statusUnsent,
                                       who: draft.to,
                                       subject: draft.subject)
        refreshOutIfShowing()
        return result.messageOffset
    }

    /// A draft's RFC-822 bytes, assembled the same way a sent message is.
    ///
    /// Every version carries the draft's own `Message-ID`, fixed at
    /// `beginCompose` — that is what lets `locateDraft` prove a record really is
    /// this message before overwriting it, which the byte offset alone cannot.
    ///
    /// The From identity comes from the account when there is one. A draft
    /// written before Settings has been filled in simply has an empty From,
    /// which is what an unconfigured Eudora showed too.
    private func draftBytes(_ draft: ComposeDraft) -> Data {
        let message = OutgoingMessage(
            fromName: accounts?.account.fromName ?? "",
            fromAddress: accounts?.account.fromAddress ?? "",
            to: splitAddresses(draft.to),
            cc: splitAddresses(draft.cc),
            bcc: splitAddresses(draft.bcc),
            subject: draft.subject,
            body: draft.body,
            inReplyTo: draft.inReplyTo,
            references: draft.references)
        // The draft's own ID, every time — that's what makes the record
        // identifiable across saves. See `ComposeDraft.messageID`.
        //
        // Empty maps to nil, not to an empty header: `rfc822` writes whatever
        // non-nil value it is handed, and a literal `Message-ID: ` would parse
        // back as "" and defeat the identity check for good.
        return message.rfc822(messageID: draft.messageID.isEmpty ? nil
                                                                 : draft.messageID).data
    }

    /// Where this draft's record is right now, or nil if it can't be trusted.
    ///
    /// Offset first because it's cheap, then a `Message-ID` check because the
    /// offset can be stale *and still resolve* — remove an earlier record of the
    /// same length as this one and the offset lands squarely on the next
    /// message. Without the second test, saving a draft after deleting from Out
    /// could overwrite unrelated mail. Returning nil is safe: callers append
    /// instead, which at worst duplicates rather than destroys.
    private func locateDraft(_ draft: ComposeDraft, in outbox: URL) -> Int? {
        // Fails *closed*: a draft with no ID can't be proven to be any record,
        // and appending a duplicate is a far smaller harm than overwriting
        // someone's mail. Nothing today can reach this — every draft gets an ID
        // in `beginCompose` — but the default is `""`, so a future one built
        // another way would otherwise silently get the unchecked behaviour this
        // method exists to prevent.
        guard let store, !draft.messageID.isEmpty else { return nil }

        if let offset = draft.outOffset,
           let index = store.indexOfRecord(at: outbox, offset: offset),
           MailboxMutator.messageID(base: outbox, index: index) == draft.messageID {
            return index
        }
        return findDraft(draft, in: outbox)
    }

    /// Find a draft's record by Message-ID when its offset has gone stale.
    ///
    /// Offsets go stale for reasons the draft's window never hears about:
    /// deleting or moving a message in Out from the main window shifts
    /// everything after it, and unlike a save from another compose window that
    /// path has no idea any drafts exist. Without this, the next save from the
    /// affected window appends a duplicate and orphans the original — which is
    /// the failure this whole design is trying to avoid, arriving by a different
    /// door.
    ///
    /// A linear scan, which is only defensible because it runs on a save that
    /// has already failed its cheap lookup, and because Out is small. Never let
    /// this become the primary path.
    private func findDraft(_ draft: ComposeDraft, in outbox: URL) -> Int? {
        guard let store, let listing = store.list(at: outbox) else { return nil }
        for row in listing.rows
        where MailboxMutator.messageID(base: outbox, index: row.index) == draft.messageID {
            return row.index
        }
        return nil
    }

    /// Re-list Out if it's the mailbox on screen, so a draft appearing,
    /// changing or going away is visible immediately.
    private func refreshOutIfShowing() {
        reloadTree()
        if let id = selectedMailboxID, itemsByID[id]?.type == .outbox {
            loadListing(force: true)
        }
    }

    /// Write the draft's current content into its record in Out, still unsent.
    ///
    /// - Returns: the draft with `outOffset` and `hasBeenSaved` brought up to
    ///   date, for the caller to hold on to.
    @discardableResult
    func saveDraft(_ draft: ComposeDraft) throws -> ComposeDraft {
        var draft = draft
        // Always unsent, never send-error. This is what puts a failed message
        // back to a plain draft once it has been edited: the send-error mark is
        // a statement about the last *attempt*, and editing invalidates it.
        draft.outOffset = try writeDraft(draft, status: MailboxMutator.statusUnsent)
        draft.hasBeenSaved = true
        updateDraft(draft)
        return draft
    }

    /// Record that this message could not be sent.
    ///
    /// Writes the current content as well as the status, so the attempt isn't
    /// lost along with the delivery — and so closing the window straight after a
    /// failure has nothing left to prompt about, which is what lets a
    /// send-error message simply be closed with its mark intact.
    @discardableResult
    func markSendFailed(_ draft: ComposeDraft) throws -> ComposeDraft {
        var draft = draft
        draft.outOffset = try writeDraft(draft, status: MailboxMutator.statusSendError)
        draft.hasBeenSaved = true
        updateDraft(draft)
        return draft
    }

    /// Record a draft that has just been delivered: same record, sent bytes,
    /// status 8.
    ///
    /// Replaces rather than appends. `recordSent` used to append, which was
    /// right when a draft had no record of its own — now it would leave the
    /// unsent original sitting in Out beside its own sent copy.
    func recordSent(_ draft: ComposeDraft, raw: Data, who: String, subject: String) throws {
        guard let outbox = outboxBase else { return }
        if let index = locateDraft(draft, in: outbox) {
            let result = try MailboxMutator.replace(base: outbox, index: index,
                                                    messageData: raw,
                                                    status: MailboxMutator.statusSent,
                                                    who: who, subject: subject)
            shiftDraftOffsets(after: result.offset, by: result.delta, except: draft.id)
        } else {
            // No record to update — the pre-save failed, or something outside
            // the app removed it. Appending is the honest fallback: better a
            // sent message recorded in the wrong position than one delivered
            // and never recorded at all.
            _ = try Outbox.append(messageData: raw, to: outbox,
                                  status: MailboxMutator.statusSent,
                                  who: who, subject: subject)
        }
        refreshOutIfShowing()
    }

    /// Throw away a draft's record. Used by Don't Save on a message that was
    /// never saved, where the record holds only the empty shell from opening.
    func discardDraft(_ draft: ComposeDraft) {
        guard let outbox = outboxBase,
              let index = locateDraft(draft, in: outbox) else { return }
        do {
            let (record, entry) = try MailboxMutator.remove(base: outbox, index: index)
            // Removing leaves a hole, so everything after it slides left by the
            // record's length. Same bookkeeping as a replace, opposite sign.
            //
            // `entry.offset`, not the draft's: the located record may not be
            // where the draft thought it was.
            shiftDraftOffsets(after: entry.offset, by: -record.count, except: draft.id)
            refreshOutIfShowing()
        } catch {
            showError("Couldn't remove the abandoned message from Out: " + describe(error))
        }
    }

    /// The one place a draft's bytes reach the mailbox, so the resolve-offset →
    /// replace → fall-back-to-append sequence exists once.
    private func writeDraft(_ draft: ComposeDraft, status: Int) throws -> Int {
        guard let outbox = outboxBase else {
            throw MailboxMutator.MutateError.notFound
        }
        let data = draftBytes(draft)
        defer { refreshOutIfShowing() }

        if let index = locateDraft(draft, in: outbox) {
            let result = try MailboxMutator.replace(base: outbox, index: index,
                                                    messageData: data, status: status,
                                                    who: draft.to, subject: draft.subject)
            // Everything after this record just moved. Tell the other open
            // drafts before returning, or the next save from one of those
            // windows writes to the wrong place.
            shiftDraftOffsets(after: result.offset, by: result.delta, except: draft.id)
            // `result.offset`, not the draft's own: `locateDraft` may have
            // recovered from a stale offset by finding the record's Message-ID
            // elsewhere, in which case the value we came in with is wrong and
            // returning it would leave the draft stale for good.
            return result.offset
        }
        // Appending only grows the file at the end, so no existing offset moves.
        return try Outbox.append(messageData: data, to: outbox, status: status,
                                 who: draft.to, subject: draft.subject).messageOffset
    }

    /// Reopen an unsent message in Out for further editing.
    ///
    /// Unlike `beginCompose`, this must *not* write a new record — the message
    /// already has one, and that is precisely what it is being reattached to. It
    /// takes over the existing record's offset and Message-ID, and comes back
    /// already saved, so closing without edits asks nothing and discards nothing.
    ///
    /// **Bcc is lost.** `OutgoingMessage.rfc822` deliberately omits Bcc from the
    /// headers, as it must — so once a draft has been written to Out there is
    /// nowhere for those addresses to have survived. Reopening therefore silently
    /// drops them. Keeping them would mean storing them outside the message, and
    /// a blind-copy list sitting in a side file is a worse idea than losing it.
    func reopenDraft(messageIndex: Int) {
        // Only from Out. `isUnsent` is a status test, not a location one, and a
        // status-9 record can sit in any mailbox — dragged out of Out, or left
        // by real Eudora. Every write path here targets the Out mailbox, so
        // reopening one from elsewhere would save a *copy* into Out and leave
        // the original behind, quietly forking the message.
        //
        guard let store,
              let mid = selectedMailboxID, let item = itemsByID[mid],
              !item.isFolder, item.type == .outbox,
              let msg = store.message(at: item.base, index: messageIndex) else { return }
        let part = msg.part

        // Already open? Bring that window forward instead of starting a second
        // editing session on the same record — two windows saving over each
        // other would be a fine way to lose half a message. Matched on the
        // record's offset, which is what identifies a draft in Out.
        if let open = openDrafts.values.first(where: { $0.outOffset == msg.record.offset }) {
            presentDraftWindow?(open.id)
            return
        }

        var draft = ComposeDraft(
            to: HeaderDecoder.decode(part.header("To") ?? ""),
            cc: HeaderDecoder.decode(part.header("Cc") ?? ""),
            subject: HeaderDecoder.decode(part.header("Subject") ?? ""),
            body: Self.plainText(of: part),
            inReplyTo: part.header("In-Reply-To")?.trimmingCharacters(in: .whitespaces),
            references: (part.header("References") ?? "")
                .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init))
        draft.outOffset = msg.record.offset
        draft.hasBeenSaved = true

        let existingID = part.header("Message-ID")?.trimmingCharacters(in: .whitespaces) ?? ""
        if existingID.isEmpty {
            // Real Eudora stamps Message-ID at *send* time, so a draft it wrote
            // has none — and this app's identity check needs one. Without it
            // `locateDraft` fails closed, every save appends another copy, and
            // the count grows without bound.
            //
            // So mint one and stamp it on the record now, while `messageIndex`
            // is known good because we have just read it. `replace` leaves this
            // record's own offset alone, so `outOffset` stays valid.
            draft.messageID = OutgoingMessage(
                fromName: "", fromAddress: accounts?.account.fromAddress ?? "",
                to: [], subject: "", body: "").generatedMessageID()
            do {
                let result = try MailboxMutator.replace(base: item.base, index: messageIndex,
                                                        messageData: draftBytes(draft),
                                                        status: MailboxMutator.statusUnsent,
                                                        who: draft.to, subject: draft.subject)
                // Stamping the ID rewrites the record and almost certainly
                // changes its length, so this moves everything after it just as
                // a save would. `except: nil` — this draft isn't in `openDrafts`
                // yet, and its own offset doesn't move anyway.
                shiftDraftOffsets(after: result.offset, by: result.delta, except: nil)
                refreshOutIfShowing()
            } catch {
                // The stamp didn't land, so saving can't prove this record is
                // the draft and will append instead of replacing. Say so rather
                // than letting copies pile up unexplained.
                draft.openError = "This message couldn't be tagged for editing ("
                    + describe(error)
                    + ") Saving will add a copy to Out rather than update it."
            }
        } else {
            draft.messageID = existingID
        }
        openDrafts[draft.id] = draft
        presentDraftWindow?(draft.id)
    }

    /// Build a reply (or reply-all) from the selected message.
    func reply(all: Bool) {
        guard let part = selectedPart() else { return }
        let origFrom = part.header("From") ?? ""
        let origTo = part.header("To") ?? ""
        let origCc = part.header("Cc") ?? ""
        let subject = HeaderDecoder.decode(part.header("Subject") ?? "")
        let msgID = part.header("Message-ID")?.trimmingCharacters(in: .whitespaces)

        var refs = (part.header("References") ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if let m = msgID { refs.append(m) }

        var cc: [String] = []
        if all { cc = (splitAddresses(origTo) + splitAddresses(origCc)) }

        beginCompose(ComposeDraft(
            to: origFrom,
            cc: cc.joined(separator: ", "),
            subject: subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)",
            body: quotedReply(part, from: origFrom),
            inReplyTo: msgID,
            references: refs))
    }

    /// Build a forward from the selected message.
    func forward() {
        guard let part = selectedPart() else { return }
        let subject = HeaderDecoder.decode(part.header("Subject") ?? "")
        let intro = """


        ---------- Forwarded message ----------
        From: \(part.header("From") ?? "")
        Date: \(part.header("Date") ?? "")
        Subject: \(subject)
        To: \(part.header("To") ?? "")

        """
        beginCompose(ComposeDraft(
            subject: subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)",
            body: intro + Self.plainText(of: part)))
    }

    private func selectedPart() -> MIMEPart? {
        guard let store,
              let mid = selectedMailboxID,
              let item = itemsByID[mid], !item.isFolder,
              let idx = selectedMessageID,
              let msg = store.message(at: item.base, index: idx) else { return nil }
        return msg.part
    }

    /// Best-effort plain text of a message for quoting (prefers text/plain,
    /// falls back to tag-stripped HTML).
    static func plainText(of part: MIMEPart) -> String {
        var html: String?
        for p in part.walk() where !p.isMultipart && !p.isAttachment && p.mainType == "text" {
            let text = CharsetDecoder.smartDecode(p.decodedPayload(), declared: p.charset).text
            if p.subType == "html" { if html == nil { html = text } }
            else { return text }
        }
        guard let h = html else { return "" }
        var out = ""; var inTag = false
        for ch in h {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; out.append(" "); continue }
            if !inTag { out.append(ch) }
        }
        return out
    }

    private func quotedReply(_ part: MIMEPart, from: String) -> String {
        let quoted = Self.plainText(of: part)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        let who = HeaderDecoder.decode(from)
        return "\n\nOn \(part.header("Date") ?? "a previous date"), \(who) wrote:\n\(quoted)\n"
    }

    /// Split a header address list on commas/semicolons into trimmed entries.
    func splitAddresses(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: write-back after a successful send

    /// Bumped per tree rebuild, so a slow one can't install itself over a newer
    /// — or over a different tree entirely, which is why `open` bumps it too.
    private var treeReloadGeneration = 0

    /// One walk at a time, with at most one more queued behind it.
    ///
    /// Every save, delete and mark-as-read asks for a refresh, so deleting ten
    /// messages quickly would otherwise start ten independent walks of 6,699
    /// mailboxes. The generation guard makes the *result* right, but the work
    /// still runs — each one holding a cooperative-pool thread blocked in
    /// `getattrlist`, and the pool is only core-count sized, so a burst can
    /// starve the listing and enrichment tasks of threads for seconds. That is
    /// the same shape as the stacked-overlapping-reads bug this project has hit
    /// before.
    ///
    /// Collapsing them loses nothing: a walk sees whatever is on disk when it
    /// runs, so one at the end reports everything the skipped ones would have.
    private var treeReloadInFlight = false
    private var treeReloadRequested = false

    /// Refresh the sidebar's mailbox counts, off the main thread.
    ///
    /// **Why this can't be synchronous.** Building the tree stats every mailbox
    /// to read its `.toc` size, and Stephen's archive has 6,699 of them. Sampling
    /// a single ⌘N measured 434 ms on the main thread, 339 of it here, almost
    /// all in `getattrlist` — one syscall per mailbox. That is a kernel cost, so
    /// it doesn't go away in a release build, and it was being paid after every
    /// new message, every draft save, every delete and every mark-as-read.
    ///
    /// Nothing needs the result synchronously. Under the message mutations —
    /// counts and unread flags — `itemsByID`, `base(ofType:)` and the listing
    /// all stay valid while this is in flight, and the sidebar's numbers settle
    /// a moment later. `deleteMailbox` *does* change the structure now: for the
    /// moment this walk takes, the deleted mailbox is still clickable in the
    /// sidebar, which degrades to an empty listing — `deleteMailbox` tears down
    /// its own selection first, and `shapeSignature` bumps
    /// `treeStructureVersion` when the walk lands, so the Move menus rebuild.
    /// The one capability given up is noticing a mailbox made in the Finder
    /// while the app is running, which needs a File ▸ Open rather than arriving
    /// on the next mutation.
    private func reloadTree() {
        guard store != nil else { return }
        guard !treeReloadInFlight else {
            treeReloadRequested = true
            return
        }
        startTreeReload()
    }

    private func startTreeReload() {
        guard let store else { return }
        treeReloadInFlight = true
        treeReloadRequested = false
        treeReloadGeneration &+= 1
        let generation = treeReloadGeneration
        PerfLog.mark("tree walk queued")
        Task { [weak self] in
            let nodes = await Task.detached(priority: .userInitiated) {
                store.tree()
            }.value
            PerfLog.mark("tree walk done: \(nodes.count) roots")
            guard let self else { return }
            self.treeReloadInFlight = false
            // A different tree may have been opened while this walked. Installing
            // it would put the old folder's mailboxes in the sidebar — the same
            // failure `cancelBackgroundWork` guards against for listings.
            guard self.treeReloadGeneration == generation else { return }
            let items = Self.buildItems(nodes, prefix: "")
            let shape = Self.shapeSignature(items)
            self.tree = items
            self.treeVersion &+= 1
            // Only when the shape actually moved. Hashing 6,699 ids costs
            // microseconds; rebuilding the Move menus costs half a second.
            if shape != self.treeShape {
                self.treeShape = shape
                self.treeStructureVersion &+= 1
            }
            self.itemsByID = [:]
            self.indexItems(self.tree)
            PerfLog.mark("tree published (treeVersion \(self.treeVersion))")
            if self.treeReloadRequested { self.startTreeReload() }
        }
    }

    // MARK: message management (delete / move / mark read)

    /// The currently selected (mailbox item, message index) — **only when
    /// exactly one message is selected**. `selectedMessageID` is nil for a
    /// multi-selection, so this is the gate for the single-message operations:
    /// reply, forward, mark read. Delete and move take `currentSelectionSet`.
    private func currentSelection() -> (item: MailboxItem, index: Int)? {
        guard let id = selectedMailboxID, let item = itemsByID[id], !item.isFolder,
              let idx = selectedMessageID else { return nil }
        return (item, idx)
    }

    /// The selected (mailbox item, message indices) for any non-empty
    /// selection — what delete and move act on.
    private func currentSelectionSet() -> (item: MailboxItem, indices: [Int])? {
        guard let id = selectedMailboxID, let item = itemsByID[id], !item.isFolder,
              !selectedMessageIDs.isEmpty else { return nil }
        return (item, Array(selectedMessageIDs))
    }

    /// Whether anywhere exists to move a message to.
    ///
    /// Only the yes/no is needed — the menus themselves walk `tree` so they can
    /// mirror the sidebar's hierarchy (see `MailboxMenuBuilder`). This used to build
    /// and alphabetically sort every mailbox in the tree just to ask whether the
    /// result was empty, which on a real folder is 2,657 items re-sorted every
    /// time a toolbar button re-evaluated `disabled`.
    var hasMoveTargets: Bool {
        let current = selectedMailboxID
        return itemsByID.values.contains { !$0.isFolder && $0.id != current }
    }

    /// Exactly one message selected — enables the single-message commands
    /// (Reply, Forward, Mark as Read/Unread).
    var canActOnMessage: Bool { currentSelection() != nil }

    /// At least one message selected — enables Delete and Transfer, which act
    /// on the whole selection.
    var canActOnSelection: Bool { currentSelectionSet() != nil }

    func markSelected(read: Bool) {
        guard let sel = currentSelection() else { return }
        // Never on a draft. Status is a single byte, so writing read/unread over
        // an unsent message doesn't annotate it — it *replaces* the unsent
        // state. `isUnsent` would go false, the row would stop being a draft,
        // and double-click would never reopen it again. One keystroke, silently
        // unrecoverable.
        if let pos = rowPositionByID[sel.index], pos < rows.count, rows[pos].isDraft {
            showBanner("That message hasn't been sent yet — it has no read state.")
            return
        }
        do {
            try MailboxMutator.setStatus(base: sel.item.base, index: sel.index,
                                         status: read ? MailboxMutator.statusRead
                                                      : MailboxMutator.statusUnread)
            // Patch the one row rather than re-listing. A rebuild would discard
            // every enriched Who and attachment glyph and restart the whole
            // background parse — on Trash, minutes of re-work to change one
            // character.
            //
            // Written in place, so the row keeps its position even when the list
            // is sorted by status. Deliberate: a message jumping away from under
            // the pointer the instant it is marked read would be worse than a
            // list momentarily one row out of order, and the order is restored
            // the next time the mailbox is listed.
            if let pos = rowPositionByID[sel.index], pos < rows.count {
                let r = rows[pos]
                rows[pos] = MessageRow(id: r.id,
                                       statusGlyph: read ? " " : MailStore.unreadGlyph,
                                       status: read ? MailboxMutator.statusRead
                                                    : MailboxMutator.statusUnread,
                                       priority: r.priority,
                                       label: r.label,
                                       size: r.size,
                                       subject: r.subject,
                                       who: r.who,
                                       date: r.date,
                                       hasAttachment: r.hasAttachment,
                                       sortDate: r.sortDate)
                refreshMailboxSummary()
            } else {
                // Rows aren't in hand yet (the listing is still running), so
                // there is nothing to patch — fall back to a re-list, or the
                // change would be on disk but invisible.
                rebuildRows()
            }
            reloadTree()                  // unread badge may change
        } catch {
            showError("Couldn't update status: \(error.localizedDescription)")
        }
    }

    /// Delete = move to Trash; if already in Trash, remove permanently.
    /// Acts on the whole selection: the batch goes to `MailboxMutator` as one
    /// set of indices against one snapshot of the mailbox — never a loop over
    /// single removes, which would corrupt the not-yet-processed indices as
    /// each removal shifted the ones after it.
    func deleteSelected() {
        guard let sel = currentSelectionSet() else { return }
        let n = sel.indices.count
        do {
            // Success text goes through the veil's notice — the same capsule
            // that says "Deleting…", updated when the veil lifts — never the
            // window banner, so the eye tracks one spot. Failures still use
            // the banner: they're actionable and shouldn't auto-retire.
            if sel.item.type == .trash {
                try MailboxMutator.removeMany(base: sel.item.base, indices: sel.indices)
                afterRemoval(veil: "Deleting…",
                             notice: n == 1 ? "Message deleted." : "\(n) messages deleted.")
            } else if let trash = base(ofType: .trash) {
                try MailboxMutator.moveMany(from: sel.item.base, indices: sel.indices, to: trash)
                afterRemoval(veil: "Deleting…",
                             notice: n == 1 ? "Moved to Trash." : "\(n) messages moved to Trash.")
            } else {
                try MailboxMutator.removeMany(base: sel.item.base, indices: sel.indices)
                afterRemoval(veil: "Deleting…",
                             notice: n == 1 ? "Message deleted (no Trash mailbox)."
                                            : "\(n) messages deleted (no Trash mailbox).")
            }
        } catch {
            showError("Delete failed: \(error.localizedDescription)")
        }
    }

    func moveSelected(to destID: MailboxItem.ID) {
        guard let sel = currentSelectionSet(), let dest = itemsByID[destID] else { return }
        // The menu lists every mailbox, including this one — see MoveToMenu.swift
        // for why it can't depend on the selection. Moving a message to where it
        // already is should do nothing rather than rewrite two mailboxes.
        guard destID != selectedMailboxID else { return }
        let n = sel.indices.count
        do {
            try MailboxMutator.moveMany(from: sel.item.base, indices: sel.indices, to: dest.base)
            afterRemoval(veil: "Moving…",
                         notice: n == 1 ? "Moved to \(dest.display)."
                                        : "\(n) messages moved to \(dest.display).")
        } catch {
            showError("Move failed: \(error.localizedDescription)")
        }
    }

    /// The selected message(s) left the current mailbox: clear the selection
    /// and refresh, behind the veil. `notice` is what the veil's label spot
    /// says once the veil lifts ("Moved to Trash." and friends) — held here,
    /// not shown, until then.
    private func afterRemoval(veil: String, notice: String) {
        PerfLog.mark("afterRemoval begins")
        pendingRemovalNotice = notice
        if removalNotice != nil { removalNotice = nil }   // a new veil replaces any old notice

        // Where the list is looking, and where in it the departing messages sat —
        // both captured now, so the viewport can be put back after the rebuild.
        // Without this the list was left wherever the rebuild happened to park
        // it, a position unrelated to the messages just removed. `rows` here is
        // still the pre-removal list, so these are display positions in it.
        let priorTop = selectedMailboxID.flatMap { viewState.scrollTopRowByMailbox[$0] }
        let removedPositions = selectedMessageIDs.compactMap { id in
            rowPositionByID[id]
        }

        // The survivors' enrichment, re-keyed to the indices they are about
        // to have. A removal shifts every later record's index down by the
        // number of removed records before it — the same arithmetic
        // `MailboxMutator` just performed on disk — so the old rows' parsed
        // Who/Date/attachment/sort-date can be handed to the fresh listing
        // instead of being re-derived while the user watches. Binary search
        // over the sorted removed indices: a select-all delete in a large
        // mailbox makes the quadratic version real money.
        let removedSorted = selectedMessageIDs.sorted()
        var carryOver: [Int: MessageRow] = [:]
        carryOver.reserveCapacity(max(0, rows.count - removedSorted.count))
        for old in rows where !selectedMessageIDs.contains(old.id) {
            var lo = 0, hi = removedSorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if removedSorted[mid] < old.id { lo = mid + 1 } else { hi = mid }
            }
            carryOver[old.id - lo] = old
        }

        // Photograph the list FIRST, while it still shows the pre-removal
        // world — selection highlight included; that's the picture the user
        // was just looking at. Everything after this line changes what's on
        // screen.
        removalVeilImage = captureListSnapshot?()

        selectMessage(nil)
        preview = nil
        // The rows are deliberately NOT cleared. They used to be — removing a
        // message shifts every later index, so the rows on screen no longer
        // describe the mailbox, and a stale list that takes clicks is a lie.
        // But blanking produced a worse experience: blank, rows back at the
        // wrong offset, then the jump to the restored one. So the stale rows
        // stay up as a *picture*, washed halfway to white under `removalVeil`
        // with a label over them, and everything that could act on them is
        // blocked while the veil is up — the overlay swallows clicks, and the
        // right-click and double-click monitors stand down (see
        // MessageListView and MessageContextMenu). The veil comes down when
        // the re-listed rows AND their restored scroll position are in
        // (`clearPendingScroll`), so neither the blank nor the jump is ever
        // seen.
        // Any restore still pending belongs to a load from *before* the
        // removal; letting it apply against the stale picture — and worse,
        // letting its `clearPendingScroll` take the veil down — would un-hide
        // exactly the artifact the veil covers. The completion below sets the
        // real one.
        pendingScrollTopRow = nil
        removalVeil = veil
        removalVeilGeneration += 1
        let generation = removalVeilGeneration
        // Backstop only: if the scroll bridge never applies (a mailbox that
        // fails to re-list, a torn-down table), the veil must not sit on a
        // stale picture forever. Generous on purpose — re-listing a large
        // mailbox after a Trash delete is a whole-file read that can take
        // several honest seconds, and the veil expiring *mid-listing* would
        // uncover the stale rows, re-arm the click paths over them, and then
        // show the very swap-and-jump it exists to hide. Every normal removal
        // ends via `clearPendingScroll` long before this fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.removalVeilGeneration == generation else { return }
            self.dropRemovalVeil(showNotice: true)
        }
        // The tree refresh runs *after* the rows are back, not alongside them.
        //
        // Publishing a new tree re-renders the sidebar over 6,699 nodes, and
        // that lands on the main actor — where the listing's continuation is
        // also queued. Started together, the render wins and the finished
        // listing waits behind it: measured at 4,017 ms between the read
        // completing and the rows appearing, for a mailbox holding one 350-byte
        // message. Sequencing them puts the list back immediately and lets the
        // sidebar's counts settle a moment later, which is the order that
        // matters to someone watching.
        rebuildRows(carryingEnrichment: carryOver) { [weak self] in
            guard let self else { return }
            // Put the viewport back where it was. The top moves only by the
            // number of removed rows that sat *above* it (everything below them
            // shifted up); rows removed at or below the top leave the rows
            // above it — and the top — untouched. In the common case where you
            // delete the rows you were looking at, that keeps the row just
            // after them sitting where the first deleted one was. Clamped to
            // what the mailbox now holds. Handed to the same AppKit bridge, and
            // via the same `pendingScrollTopRow`, that `loadListing` restores
            // through.
            if let top = priorTop, !self.rows.isEmpty {
                let shifted = top - removedPositions.filter { $0 < top }.count
                self.pendingScrollTopRow = max(0, min(shifted, self.rows.count - 1))
                // The veil stays up: the rows are in but sitting at the wrong
                // offset until the bridge applies this. `clearPendingScroll`
                // takes it down.
            } else {
                self.pendingScrollTopRow = nil
                // Nothing to restore (empty list, or no remembered top), so
                // the rows as published are the final picture.
                self.dropRemovalVeil(showNotice: true)
            }
            self.reloadTree()
        }
        PerfLog.mark("afterRemoval returned")
    }

    // MARK: mailbox management (delete)

    /// Live emptiness check for the sidebar's right-click menu — a stat, not a
    /// read (`messageCount` prefers the .toc's size). The row's own count badge
    /// comes from the same source, so the menu and the badge agree. The
    /// primitive is more permissive (it trusts the .mbx, not the .toc), so a
    /// stale .toc can grey the menu out for a genuinely empty mailbox — a safe
    /// failure, resolved by the next re-list rewriting the .toc.
    ///
    /// Only a regular, non-folder mailbox is ever "deletable-empty": system
    /// mailboxes and folders return false so the menu offers nothing for them.
    func mailboxIsDeletablyEmpty(_ id: MailboxItem.ID) -> Bool {
        guard let store, let item = itemsByID[id],
              !item.isFolder, item.type == .mailbox else { return false }
        return store.messageCount(base: item.base) == 0
    }

    /// Sidebar right-click ▸ Delete. The heavy lifting — descmap.pce edit,
    /// file removal, and the *authoritative* emptiness check against the .mbx —
    /// is `MailboxTreeMutator.deleteEmptyMailbox`; the menu's grey-out is only
    /// a courtesy, so a stale count here degrades to an error banner, never to
    /// a deleted message.
    func deleteMailbox(_ id: MailboxItem.ID) {
        guard let item = itemsByID[id], !item.isFolder, item.type == .mailbox else { return }
        // The descmap filename is the id's last path component — buildItems
        // constructs ids by joining exactly those (`item.base` has the
        // extension stripped and can't be used for the match).
        let filename = id.split(separator: "/").last.map(String.init) ?? id
        do {
            try MailboxTreeMutator.deleteEmptyMailbox(
                directory: item.base.deletingLastPathComponent(),
                filename: filename)
        } catch {
            showError("Couldn't delete \(item.display): \(error.localizedDescription)")
            return
        }

        // If the deleted mailbox was on screen, clear everything that points
        // at it — same teardown a mailbox switch does, then no mailbox at all.
        if selectedMailboxID == id {
            beginMailboxSwitch()
            selectedMailboxID = nil
            listedMailboxID = nil
            selectMessage(nil)
        }

        // Its remembered view state would otherwise linger forever keyed on an
        // id nothing can select again.
        viewState.sortByMailbox[id] = nil
        viewState.scrollTopRowByMailbox[id] = nil
        viewState.selectedMessageOffsetByMailbox[id] = nil
        if viewState.selectedMailbox == id { viewState.selectedMailbox = nil }
        if let root = rootURL?.path { ViewStateStore.save(viewState, forRoot: root) }

        showBanner("Deleted mailbox \u{201C}\(item.display)\u{201D}.")
        reloadTree()
    }

    // MARK: mailbox management (create)

    /// Move to ▸ New… — Eudora 7's main way of creating mailboxes: prompt for
    /// a name at the level the menu was opened on, create, and move the
    /// current selection into the new mailbox, all one gesture. "Make it a
    /// folder" creates the folder and re-prompts *inside* it, Eudora-style,
    /// until a mailbox exists to receive the move (or Cancel — folders already
    /// created stay, which is also what Eudora did).
    func createMailboxAndMoveSelection(under parentID: MailboxItem.ID?) {
        guard let rootURL else { return }

        // The parent is resolved through `itemsByID` exactly once, *before*
        // the first dialog, and carried through the loop as a directory URL
        // from then on. The modal alert pumps the main runloop, so an
        // in-flight tree walk can land mid-dialog and rebuild `itemsByID`
        // from a snapshot older than a folder created two prompts ago —
        // re-resolving each turn would find nothing and silently stop.
        var directory: URL
        var location: String
        var idPrefix: MailboxItem.ID?
        if let parentID {
            guard let parent = itemsByID[parentID], parent.isFolder else {
                showError("Couldn't find that folder any more — the mailbox list just changed. Try again.")
                return
            }
            directory = parent.base
            location = parent.display
            idPrefix = parentID
        } else {
            directory = rootURL
            location = rootURL.lastPathComponent
            idPrefix = nil
        }

        while true {
            guard let response = NewMailboxDialog.run(locationDisplay: location) else { return }
            guard let created = createMailbox(named: response.name,
                                              inDirectory: directory,
                                              idPrefix: idPrefix,
                                              asFolder: response.isFolder) else { return }
            if response.isFolder {
                directory = created.base
                location = created.display
                idPrefix = created.id
                continue
            }
            // The selection can have emptied while the dialog was up — a mail
            // check landing in the viewed mailbox re-lists it and clears the
            // selection. Say so rather than silently creating-without-moving.
            if selectedMessageIDs.isEmpty {
                showBanner("Created \u{201C}\(created.display)\u{201D} — the selection changed, so nothing was moved.")
            } else {
                moveSelected(to: created.id)
            }
            return
        }
    }

    /// Create a mailbox or folder in `directory` and return the synthesized
    /// item — or nil, with the error already on a banner. `idPrefix` is the
    /// parent's id (nil at the top level), so the new item's id is exactly
    /// what `buildItems` will derive when the tree walk catches up.
    ///
    /// The new item goes into `itemsByID` *synchronously*: the caller's next
    /// step is usually `moveSelected(to:)`, which resolves the destination
    /// there, and the tree walk that would add it is async. The published
    /// `tree` catches up when `reloadTree` lands (its shape changes, so
    /// `treeStructureVersion` bumps and the sidebar and menus rebuild).
    func createMailbox(named name: String,
                       inDirectory directory: URL,
                       idPrefix: MailboxItem.ID?,
                       asFolder: Bool) -> MailboxItem? {
        let filename: String
        do {
            filename = asFolder
                ? try MailboxTreeMutator.createFolder(directory: directory, name: name)
                : try MailboxTreeMutator.createMailbox(directory: directory, name: name)
        } catch {
            showError("Couldn't create \u{201C}\(name)\u{201D}: \(error.localizedDescription)")
            return nil
        }

        // The same id and base derivations `buildItems` uses, so the async
        // tree walk resolves to an identical item and nothing jumps.
        let id = idPrefix.map { "\($0)/\(filename)" } ?? filename
        let base = asFolder
            ? directory.appendingPathComponent(filename)
            : directory.appendingPathComponent(filename).deletingPathExtension()
        let item = MailboxItem(id: id,
                               display: name.trimmingCharacters(in: .whitespaces),
                               type: asFolder ? .folder : .mailbox,
                               base: base,
                               isFolder: asFolder,
                               messageCount: 0,
                               hasUnread: false,
                               children: asFolder ? [] : nil)
        itemsByID[id] = item
        reloadTree()
        return item
    }

    // MARK: receiving (POP3)

    /// Check mail: fetch new messages into the In box, then — only if the user
    /// opted in — delete them from the server in a second pass, after they're
    /// safely written locally.
    func receiveMail(accounts: AccountStore) async {
        guard let inbox = base(ofType: .inbox) else {
            showError("No In mailbox in this tree.")
            return
        }
        guard accounts.pop.isConfigured else {
            showError("Incoming mail not set up: server=\"\(accounts.pop.host)\", "
                + "user=\"\(accounts.pop.username)\", port=\(accounts.pop.port). "
                + "Fill these in Settings ▸ Incoming mail (POP3), then Save.")
            return
        }
        guard !accounts.incomingPassword.isEmpty else {
            showError("Incoming password is empty — enter it in Settings ▸ Incoming mail (POP3), then Save.")
            return
        }
        guard !isChecking else { return }
        isChecking = true
        checkMailNotice = nil        // spinner only, until this fetch resolves
        defer { isChecking = false }

        do {
            let known = accounts.knownUIDs()
            let fetched = try await POP3Client.fetchNew(account: accounts.pop,
                                                        password: accounts.incomingPassword,
                                                        knownUIDs: known)
            var newKnown = known
            var delivered: [String] = []
            for msg in fetched {
                try Delivery.deliverIncoming(messageData: msg.raw, to: inbox)
                newKnown.insert(msg.uid)
                delivered.append(msg.uid)
                // Persist after each delivery so a mid-batch failure can't cause
                // the already-stored messages to be re-downloaded as duplicates.
                accounts.setKnownUIDs(newKnown)
            }

            // Delete pass — only after every message is stored locally.
            if accounts.pop.deleteAfterDownload, !delivered.isEmpty {
                try await POP3Client.delete(account: accounts.pop,
                                            password: accounts.incomingPassword,
                                            uids: Set(delivered))
            }

            reloadTree()
            if let id = selectedMailboxID, itemsByID[id]?.type == .inbox { loadListing(force: true) }
            showCheckMailNotice(fetched.isEmpty
                        ? "No new mail"
                        : "Received \(fetched.count) message\(fetched.count == 1 ? "" : "s")")
        } catch {
            // Short line in the toolbar indicator; the full reason stays up in
            // the banner until dismissed, since it's usually actionable.
            showCheckMailNotice("Check mail failed")
            showError("Check mail failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    // MARK: search (Find window)

    /// Display name for a mailbox path-id (as carried on a `SearchHit`).
    func mailboxDisplay(_ id: MailboxItem.ID) -> String { itemsByID[id]?.display ?? id }

    /// Every non-folder mailbox's path-id — the default (all-selected) search scope.
    var allLeafMailboxIDs: Set<MailboxItem.ID> {
        Set(itemsByID.values.filter { !$0.isFolder }.map { $0.id })
    }

    /// Application Support/Eudora/Indexes/<key>.sqlite for a given tree. The key
    /// is a stable hash of the root path, so each tree gets its own sidecar and
    /// the index never lands inside the Eudora folder.
    private func indexURL(for root: URL) -> URL? {
        guard let appSup = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask).first else { return nil }
        let dir = appSup.appendingPathComponent("Eudora/Indexes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(Self.stableKey(root.path)).sqlite")
    }

    /// Deterministic FNV-1a hash → hex. (Swift's Hasher is per-run randomised, so
    /// it can't key a file that must be found again next launch.)
    private static func stableKey(_ s: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for b in s.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        return String(hash, radix: 16)
    }

    /// On open: reuse a previously completed index for this tree if one is on
    /// disk (instant), otherwise build it. A finished build is all-or-nothing (a
    /// single transaction), so a non-empty index with the current schema is a
    /// complete one. Tools ▸ Rebuild Search Index refreshes after new mail.
    private func openOrBuildIndex(for root: URL) {
        if let path = indexURL(for: root)?.path, let reuse = reusableIndex(at: path) {
            indexGeneration += 1        // supersede any in-flight build's result
            searchIndex = reuse.index
            isIndexing = false
            indexingPath = nil
            searchStatus = "Search index ready — \(reuse.count) messages (Rebuild to refresh)."
            return
        }
        startIndexing(for: root)
    }

    /// A ready-to-use existing index at `path`, or nil if none is present, it's
    /// empty, or it was written by an older schema (→ rebuild).
    private func reusableIndex(at path: String) -> (index: SearchIndex, count: Int)? {
        guard FileManager.default.fileExists(atPath: path),
              let idx = try? SearchIndex(path: path),
              idx.hasCurrentSchema(),
              let n = try? idx.count(), n > 0 else { return nil }
        return (idx, n)
    }

    /// Build (wipe + rebuild) the index for the given tree on a background task,
    /// publishing progress. All @Published mutations happen on the main actor
    /// *after* the current view-update pass (via the enclosing `Task { @MainActor }`
    /// and the awaited hop back), so this never mutates state mid-render.
    private func startIndexing(for root: URL) {
        guard let store else { return }
        let path = indexURL(for: root)?.path ?? ":memory:"
        // Already building this same index file? Let it finish — don't open a
        // second writer to the same path.
        if isIndexing, indexingPath == path { return }
        indexGeneration += 1
        let gen = indexGeneration
        indexingPath = path

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isIndexing = true
            self.indexProgress = IndexProgress(done: 0, total: 0)
            self.searchStatus = "Indexing…"
            self.searchIndex = nil

            // Heavy work off the main thread; awaiting keeps the UI responsive.
            let outcome = await Task.detached(priority: .userInitiated) { () -> (SearchIndex?, String) in
                do {
                    let idx = try SearchIndex(path: path)
                    try idx.rebuild(from: store) { done, total in
                        Task { @MainActor [weak self] in
                            guard let self, self.indexGeneration == gen else { return }
                            self.indexProgress = IndexProgress(done: done, total: total)
                        }
                    }
                    return (idx, "Indexed \(try idx.count()) messages.")
                } catch {
                    return (nil, "Index error: \(error)")
                }
            }.value

            // Apply only if this build wasn't superseded by a newer one.
            guard self.indexGeneration == gen else { return }
            self.searchIndex = outcome.0
            self.searchStatus = outcome.1
            self.isIndexing = false
            self.indexingPath = nil
        }
    }

    /// Menu/command "Rebuild Search Index".
    func rebuildIndex() {
        guard let rootURL else { showError("Open a Eudora folder first."); return }
        guard !isIndexing else { showBanner("Already indexing…"); return }
        showBanner("Rebuilding search index…")
        startIndexing(for: rootURL)
    }

    /// Run a Find query and publish the hits.
    func runSearch(_ query: SearchQuery) {
        guard let searchIndex else {
            searchResults = []
            searchStatus = "No index — open a Eudora folder, or Rebuild Index."
            return
        }
        do {
            searchResults = try searchIndex.search(query)
            let n = searchResults.count
            searchStatus = n == 0 ? "No results." : "\(n) result\(n == 1 ? "" : "s")."
        } catch {
            searchResults = []
            searchStatus = "Search error: \(error)"
        }
    }

    /// Open a search hit in the main window: select its mailbox, map the hit's
    /// byte offset to a 1-based index, and select that message.
    func openHit(_ hit: SearchHit) {
        guard let store, let item = itemsByID[hit.mailbox],
              let index = store.indexOfRecord(at: item.base, offset: hit.offset) else {
            showError("Couldn't locate that message (index may be stale — try Rebuild Index).")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if selectedMailboxID == hit.mailbox {
            // Mailbox already listed; just move the selection (onChange renders it).
            selectMessage(index)
        } else {
            pendingMessageID = index
            selectedMailboxID = hit.mailbox   // onChange → loadListing() applies pending
        }
    }
}

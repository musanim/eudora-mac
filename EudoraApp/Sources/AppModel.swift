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

/// An editable outgoing-message seed handed to the compose sheet. Address
/// fields are free text (comma/semicolon separated) as the user types them.
struct ComposeDraft: Identifiable {
    let id = UUID()
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    var body: String = ""
    var inReplyTo: String? = nil
    var references: [String] = []
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
    @Published var status: String = "No Eudora folder open."

    // Selected mailbox (sidebar) and message (table), by their ids. Reactions
    // are driven from the view via `.onChange` (see ContentView) rather than
    // `didSet`, so the follow-on @Published mutations happen *after* SwiftUI's
    // view-update pass — not during it (which SwiftUI warns about).
    @Published var selectedMailboxID: MailboxItem.ID?
    @Published var selectedMessageID: MessageRow.ID?

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

    var messageSelection: Binding<MessageRow.ID?> {
        Binding(get: { [weak self] in self?.selectedMessageID },
                set: { [weak self] new in
                    DispatchQueue.main.async { self?.selectedMessageID = new }
                })
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

    /// Non-nil while a compose sheet is open.
    @Published var composing: ComposeDraft?
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

    /// True while a Check Mail fetch is in flight.
    @Published var isChecking = false

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

        selectedMailboxID = nil
        selectedMessageID = nil
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
    func clearPendingScroll() { pendingScrollTopRow = nil }

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
        listedMailboxID = selectedMailboxID
        preview = nil
        previewTask?.cancel()
        isLoadingPreview = false

        let pending = pendingMessageID
        pendingMessageID = nil
        selectedMessageID = nil
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
                    self.selectedMessageID = pending
                    // Ask for keyboard focus now the rows are real. Asking in
                    // restoreSelection would start the retry clock before the
                    // listing existed, and it expires after about a second.
                    self.pendingListFocus = true
                    // Render directly: onChange(selectedMessageID) won't fire if
                    // `pending` equals the previously selected index (e.g. row 2
                    // → row 2 in another mailbox), which would leave the preview
                    // blank.
                    self.loadMessage()
                } else {
                    self.selectedMessageID = nil
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
    private func rebuildRows(completion: (() -> Void)? = nil) {
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
        // caller satisfies that today — `loadListing` and `afterRemoval` clear
        // the rows first, and `markSelected`'s fallback re-lists the mailbox it
        // is already showing. A new caller that left another mailbox's rows in
        // place would leave them in one order with `sort` claiming another, and
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
            self.setRows(built?.rows ?? [])
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
        guard let id = selectedMessageID, let pos = rowPositionByID[id] else { return }
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
        composing = ComposeDraft()
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

        composing = ComposeDraft(
            to: origFrom,
            cc: cc.joined(separator: ", "),
            subject: subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)",
            body: quotedReply(part, from: origFrom),
            inReplyTo: msgID,
            references: refs)
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
        composing = ComposeDraft(
            subject: subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)",
            body: intro + Self.plainText(of: part))
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

    /// Append a just-sent message to the Out mailbox and refresh the UI.
    func recordSent(raw: Data, who: String, subject: String) throws {
        guard let store, let outbox = store.outboxBase() else { return }
        _ = try Outbox.append(messageData: raw, to: outbox, who: who, subject: subject)
        reloadTree()
        if let id = selectedMailboxID, itemsByID[id]?.type == .outbox { loadListing(force: true) }
    }

    /// Rebuild the sidebar tree (e.g. after message counts change) without
    /// disturbing the current selection.
    private func reloadTree() {
        guard let store else { return }
        tree = Self.buildItems(store.tree(), prefix: "")
        treeVersion &+= 1
        itemsByID = [:]
        indexItems(tree)
    }

    // MARK: message management (delete / move / mark read)

    /// The currently selected (mailbox item, message index), if any.
    private func currentSelection() -> (item: MailboxItem, index: Int)? {
        guard let id = selectedMailboxID, let item = itemsByID[id], !item.isFolder,
              let idx = selectedMessageID else { return nil }
        return (item, idx)
    }

    /// Whether anywhere exists to move a message to.
    ///
    /// Only the yes/no is needed — the menus themselves walk `tree` so they can
    /// mirror the sidebar's hierarchy (see `MoveToMenuItems`). This used to build
    /// and alphabetically sort every mailbox in the tree just to ask whether the
    /// result was empty, which on a real folder is 2,657 items re-sorted every
    /// time a toolbar button re-evaluated `disabled`.
    var hasMoveTargets: Bool {
        let current = selectedMailboxID
        return itemsByID.values.contains { !$0.isFolder && $0.id != current }
    }

    var canActOnMessage: Bool { currentSelection() != nil }

    func markSelected(read: Bool) {
        guard let sel = currentSelection() else { return }
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
    func deleteSelected() {
        guard let store, let sel = currentSelection() else { return }
        do {
            if sel.item.type == .trash {
                try MailboxMutator.remove(base: sel.item.base, index: sel.index)
                showBanner("Message deleted.")
            } else if let trash = store.mailboxBase(ofType: .trash) {
                try MailboxMutator.move(from: sel.item.base, index: sel.index, to: trash)
                showBanner("Moved to Trash.")
            } else {
                try MailboxMutator.remove(base: sel.item.base, index: sel.index)
                showBanner("Message deleted (no Trash mailbox).")
            }
            afterRemoval()
        } catch {
            showError("Delete failed: \(error.localizedDescription)")
        }
    }

    func moveSelected(to destID: MailboxItem.ID) {
        guard let sel = currentSelection(), let dest = itemsByID[destID] else { return }
        // The menu lists every mailbox, including this one — see MoveToMenuItems
        // for why it can't depend on the selection. Moving a message to where it
        // already is should do nothing rather than rewrite two mailboxes.
        guard destID != selectedMailboxID else { return }
        do {
            try MailboxMutator.move(from: sel.item.base, index: sel.index, to: dest.base)
            showBanner("Moved to \(dest.display).")
            afterRemoval()
        } catch {
            showError("Move failed: \(error.localizedDescription)")
        }
    }

    /// The selected message left the current mailbox: clear it and refresh.
    private func afterRemoval() {
        selectedMessageID = nil
        preview = nil
        // Clear the rows rather than leaving them up during the re-list.
        // Removing a message shifts every later index, so the rows on screen no
        // longer describe the mailbox: clicking one would select a different
        // message than the one shown. A blank list for the duration is honest;
        // a stale one is not.
        setRows([])
        rebuildRows()
        reloadTree()
    }

    // MARK: receiving (POP3)

    /// Check mail: fetch new messages into the In box, then — only if the user
    /// opted in — delete them from the server in a second pass, after they're
    /// safely written locally.
    func receiveMail(accounts: AccountStore) async {
        guard let store, let inbox = store.mailboxBase(ofType: .inbox) else {
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
            showBanner(fetched.isEmpty
                        ? "No new mail."
                        : "Received \(fetched.count) message\(fetched.count == 1 ? "" : "s").")
        } catch {
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
            selectedMessageID = index
        } else {
            pendingMessageID = index
            selectedMailboxID = hit.mailbox   // onChange → loadListing() applies pending
        }
    }
}

import Foundation
import SwiftUI
import AppKit
// For `CGEventSource.secondsSinceLastEventType` — how the overnight rebuild
// asks whether anyone is at the Mac.
import CoreGraphics
import EudoraStore
import EudoraSearch
import EudoraNet

/// Runs an `NSAlert` centred on the pointer instead of in the middle of the
/// screen.
///
/// **Setting the frame before running does nothing** — measured 2026aug05, first
/// attempt: `alert.layout()`, `setFrameOrigin`, then run. The alert appeared
/// dead centre exactly as before. `NSAlert` positions its own panel when the
/// panel is *shown*, which is after any frame we set, so the assignment is
/// simply overwritten. That also retired the first version's use of
/// `NSApp.runModal(for:)`, which had been there only to bypass a centring it
/// turned out not to bypass; this is back to the documented `alert.runModal()`,
/// which also closes the panel for us.
///
/// **A queued main-queue block wasn't enough either** — measured, second attempt.
/// The panel still landed in AppKit's default spot: horizontally centred on the
/// display, about 30% down. The block does run during the modal session, but
/// evidently before the panel is displayed, so `NSAlert`'s own positioning still
/// came last. What worked was repositioning on `didBecomeKeyNotification`, which
/// fires after the panel is on screen and therefore after that.
///
/// The pointer is sampled **now**, before the loop, not inside the block: by the
/// time the block runs the hand may have moved, and the whole point is where the
/// hand was when it chose the menu item.
///
/// Anchored by its **lower-right corner** at the pointer, so the panel opens up
/// and to the left and its buttons — which AppKit puts at the bottom right — land
/// where the hand already is. Stephen's call, and the right one for a dialog
/// reached from a right-click: nothing else in the panel needs to be near the
/// pointer, and the buttons are the only thing you came here to click.
///
/// It does mean the *destructive* button sits nearest, since the first button
/// added is the rightmost. An earlier version centred on the pointer to keep some
/// distance from it for exactly that reason. What makes the trade sound is that
/// the danger is handled where it should be rather than by geometry: the delete
/// button is deliberately not the default, and Return cancels (see
/// `deletePermanentlySelected`). A mis-aimed click is a miss, not a deletion.
///
/// Not hidden and un-hidden around the move, which would avoid any flash of the
/// centred position. That was considered and rejected as the wrong risk to take
/// first: if the queued block ever failed to run, an `alphaValue` of 0 would
/// leave an invisible modal dialog and a hung-looking app, where the worst this
/// version can do is show the alert somewhere unhelpful. If a flash turns out to
/// be visible, the fix is that trick, and by then the block will be known to run.
///
/// Lives here rather than in its own file only to keep `xcodegen generate` out of
/// the loop for a small helper. If a second caller appears — the blacklist
/// confirmation and the two New Mailbox/Folder prompts are the candidates — it
/// should move.
enum PointerAlert {
    /// Off, and intact. It is what would say **which of the two hooks below
    /// actually does the work** — that was never captured, because the build that
    /// added the trace also fixed the behaviour and the question stopped being
    /// urgent. So both hooks are kept deliberately rather than out of neglect:
    /// they are idempotent, one of them is very likely redundant, and one run with
    /// this on would settle which to delete.
    static let traceEnabled = false

    static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let pointer = NSEvent.mouseLocation
        let window = alert.window

        // Hook 1: the main queue, as before. Kept because if this is what runs
        // too early, that is worth seeing rather than assuming.
        DispatchQueue.main.async {
            place(window, near: pointer, via: "queued")
        }

        // Hook 2: after the panel is key, which is after it has been displayed and
        // therefore after `NSAlert` has positioned it. This is the one expected to
        // stick.
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in
            place(window, near: pointer, via: "didBecomeKey")
        }
        defer { NotificationCenter.default.removeObserver(token) }

        return alert.runModal()
    }

    private static func place(_ window: NSWindow, near pointer: NSPoint, via: String) {
        let was = window.frame.origin
        let target = origin(for: window.frame.size, near: pointer)
        window.setFrameOrigin(target)
        guard traceEnabled else { return }
        // `isVisible` is the discriminator: a hook that fires before the panel is
        // on screen is one whose frame `NSAlert` is about to overwrite.
        print("[alertpos] \(via)  visible \(window.isVisible)"
              + "  was \(was)  asked \(target)  now \(window.frame.origin)")
    }

    /// Origin that puts a panel's **lower-right corner** at `pointer`, clamped to
    /// the screen the pointer is on so a right-click near an edge — or on a second
    /// display — can't put a button where it cannot be clicked. `visibleFrame`
    /// rather than `frame`: it excludes the menu bar and the Dock.
    ///
    /// An `NSWindow`'s origin is its **bottom-left** and screen y grows upward, so
    /// the right edge at `pointer.x` means `x - width`, and the bottom edge at
    /// `pointer.y` means `y` unchanged. Neither is a half-size offset any more; if
    /// this ever looks centred again, that is the line that regressed.
    private static func origin(for size: NSSize, near pointer: NSPoint) -> NSPoint {
        var origin = NSPoint(x: pointer.x - size.width, y: pointer.y)
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        }
        return origin
    }
}

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
    /// Whether this mailbox holds at least one unsent (status-9) message. Only
    /// ever true for Out — it's the flag behind the green Unsent badge on the Out
    /// row in the sidebar. Computed off-main during the tree build, so it rides
    /// the same `treeVersion` bump that re-renders the (Equatable) mailbox tree.
    let hasUnsent: Bool
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
    /// Byte offset of this message's record in the `.mbx`.
    ///
    /// Carried so a status write can address the message directly. Going by
    /// index instead costs a full read and separator scan of the mailbox to
    /// translate one number — 612 MB on Trash — which is fine for a menu
    /// command and not fine on the click path.
    let offset: Int
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
    var who: String         // the other party's display name (may carry " +N")
    /// The Who value for *sorting* — the correspondent name without the "+N"
    /// overflow suffix, so "Bob" and "Bob +2" cluster together and a person's
    /// sent and received mail sort as one. Equals `who` until enrichment lands.
    var whoSort: String
    /// Which way this message went relative to me, for the direction glyph.
    /// `.neither` until the parse settles it — no glyph while provisional.
    var direction: WhoDirection
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

    /// A message that was successfully sent — the gate for "Send Again" in the
    /// message context menu. Needs the `.toc` status byte, so it's false on the
    /// scan fallback (no index, no status).
    var isSent: Bool { status == MailboxMutator.statusSent }

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
    /// The message's own `Date:`, or the listing's cached date when it has none.
    /// See `supplyDateIfMissing`.
    var date: String
    /// The header block as it sits on disk, for "Blah Blah Blah". A `var` with a
    /// default because it can't be filled in by `render`, which is handed a
    /// parsed `MIMEPart` and never sees the bytes — `loadMessage` re-reads it by
    /// offset and assigns it afterwards. Empty when that read failed, which the
    /// view treats as "nothing to show" rather than an error.
    var rawHeaders: String = ""

    let isHTML: Bool
    let content: String          // HTML string when isHTML, else plain text
    let images: [String: EmbeddedImage]  // eudora-image:<id> -> bytes (HTML only)
    /// Links whose visible text names a different destination from their href,
    /// as URL -> claimed host. Noted at render time because that is the only
    /// point where both are visible — see `RenderedBody.misleadingLinks`.
    var misleadingLinks: [String: String] = [:]
    let attachments: [MessageAttachment]
    /// Attachments Eudora detached to disk. Shown after the body, as Eudora did,
    /// rather than as header chips — their bytes aren't in the message.
    let detached: [LocatedAttachment]
    let indexSourceNote: String  // shown subtly so we can see toc vs scan

    /// Supply the listing's cached date when the message itself carries none.
    ///
    /// **Eudora 7 never wrote `Date:` into its stored copy** — only into what
    /// went over the wire. Measured against the real tree: of 694 messages
    /// Eudora 7 composed in `MISCINQ.mbx`, not one has the header, and that is
    /// every message it ever sent or drafted, across the whole archive. The
    /// `.toc` holds the date, which is why the Date *column* was populated all
    /// along and only the reader looked blank.
    ///
    /// **The three-line summary only.** The raw header block is deliberately
    /// left alone: "Blah Blah Blah" promises the bytes as they sit on disk, and
    /// a date that is not among them must not appear there. The summary is
    /// derived by definition, so filling a gap in it from the index is honest;
    /// doing the same to the raw block would be a small forgery.
    mutating func supplyDateIfMissing(_ cached: String) {
        if date.trimmingCharacters(in: .whitespaces).isEmpty { date = cached }
    }
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
    /// The From line the message is sent under, editable in the composer. Empty
    /// on a freshly built draft; `beginCompose` fills it with the account's own
    /// identity, and a reopened or resent message carries the stored `From:` in.
    var from: String = ""
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    var body: String = ""

    /// The styled body, set only when the user actually formatted something.
    ///
    /// **Nil is the plain-text guarantee, carried up from `OutgoingMessage`.**
    /// When nil the message assembles exactly as it did before rich text
    /// existed — a single `text/plain` entity — and `body` is the whole of it.
    /// When set, its `plainText` *is* `body` (the editor keeps them in step), so
    /// `body` stays the authoritative plain-text alternative and the source for
    /// the `who`/subject TOC fields; the styling is the extra.
    var styledBody: RichText? = nil

    /// The body as a single value, whichever way it is held. The editor binds to
    /// this; the plain and styled fields are derived from it on save.
    var content: RichText { styledBody ?? RichText(plain: body) }

    /// Files attached to this message. Their bytes travel with the draft (read
    /// when dropped in), so they survive a save/close/reopen and can't go missing
    /// between attaching and sending. Assembled into multipart/mixed on send.
    var attachments: [OutgoingMessage.Attachment] = []

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
    let whoSort: String
    let direction: WhoDirection
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
    /// Each live message's `(row id, byte offset, length)` in the `.mbx`, so
    /// enrichment can read messages directly instead of re-scanning the file.
    let records: [MessageLocation]
}

/// Where one message lives in the `.mbx`, for the per-message enrichment read.
struct MessageLocation: Sendable {
    let index: Int
    let offset: Int
    let length: Int
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

    /// Whether the Junk mailbox is shown. Off by default — Stephen doesn't use
    /// junk filtering — but restorable in Settings for a future user who wants it.
    /// Display-only: `tree` stays complete (Junk is still on disk, still indexed,
    /// still resolved by `item(ofType:)`); this only hides it from the sidebar and
    /// the mailbox pickers, via `visibleTree`.
    @Published var showJunkMailbox: Bool = UserDefaults.standard.bool(forKey: AppModel.showJunkKey) {
        didSet {
            guard showJunkMailbox != oldValue else { return }
            UserDefaults.standard.set(showJunkMailbox, forKey: Self.showJunkKey)
            // The tree itself didn't change, but what's *visible* did — nudge the
            // version the sidebar and menus diff on so they re-read `visibleTree`.
            treeVersion &+= 1
        }
    }
    private static let showJunkKey = "showJunkMailbox"

    /// Eudora 7's "Blah Blah Blah": show the message's headers as they arrived.
    ///
    /// A mode rather than a per-message state, which is what 7 did and what the
    /// use for it wants — you turn it on because you are looking into something,
    /// and you want it to stay on across the several messages you compare. It
    /// costs nothing to leave on: the block is read with the message either way.
    @Published var showAllHeaders: Bool = UserDefaults.standard.bool(forKey: AppModel.allHeadersKey) {
        didSet {
            guard showAllHeaders != oldValue else { return }
            UserDefaults.standard.set(showAllHeaders, forKey: Self.allHeadersKey)
        }
    }
    private static let allHeadersKey = "showAllHeaders"

    /// The tree as shown to the user: the full `tree`, minus the Junk mailbox when
    /// it's hidden. The one source every mailbox picker should draw from.
    var visibleTree: [MailboxItem] {
        showJunkMailbox ? tree : tree.filter { $0.type != .junk }
    }

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
    /// cheap and any future view that draws the tree's shape will want it.
    @Published private(set) var treeStructureVersion = 0

    /// Hash of the last published shape, to tell the two apart.
    private var treeShape = 0

    /// Bumped when the tree's *parentage graph* changes — an item added,
    /// removed, or moved to a different parent. Narrower than
    /// `treeStructureVersion`, which also moves on a rename, and narrower again
    /// than the obvious reading: a **reorder among siblings does not bump it**.
    ///
    /// **Do not remove this, and do not widen it.** It is the sidebar `List`'s
    /// `.id()` (see `MailboxTree`), and it is what stops SwiftUI diffing a
    /// restructured outline — a diff that crashed the app outright on
    /// 2026jul30 when expanded groups were moved into a new one. Every bump
    /// discards and rebuilds the sidebar, collapsing it, so anything added to
    /// the signature is paid for by the user on every occurrence of it.
    ///
    /// A rename is deliberately *excluded*: it rewrites only the descmap
    /// display field, every row keeps its identity, nothing reparents, and
    /// SwiftUI's diff handles it safely. Renaming is a normal action, not a
    /// restructuring one, and it shouldn't collapse 6,699 rows.
    @Published private(set) var treeIdentityVersion = 0

    /// Hash of the last published identity graph.
    private var treeIdentity = 0
    @Published var status: String = "No Eudora folder open."

    // Selected mailbox (sidebar) and message (table), by their ids. Reactions
    // are driven from the view via `.onChange` (see ContentView) rather than
    // `didSet`, so the follow-on @Published mutations happen *after* SwiftUI's
    // view-update pass — not during it (which SwiftUI warns about).
    @Published var selectedMailboxID: MailboxItem.ID?

    /// Addresses waiting to be pasted into the ISP's blocklist, edited in
    /// Tools ▸ Blacklist….
    ///
    /// Saved on every change, including every keystroke while the window is
    /// open. That is a few hundred bytes into `UserDefaults` and not worth
    /// debouncing — where losing the list to a crash mid-edit would be, since the
    /// window is the only copy until it is drained.
    @Published var blacklistQueue = BlacklistStore.load() {
        didSet { BlacklistStore.save(blacklistQueue) }
    }

    /// The selected messages. Usually one; ⌘-click and ⇧-click grow it.
    /// `private(set)` so "one owner" is a compile error to violate rather than a
    /// convention. `applyMessageSelection` is the only writer, and the getter of
    /// `messageSelection` now stands in for this while a write is deferred — a
    /// direct assignment from anywhere else would leave that stand-in reporting
    /// a set that no longer matches, which is worse than the bug it fixed.
    @Published private(set) var selectedMessageIDs: Set<MessageRow.ID> = []

    /// The **primary** selected message — the moving end of the selection, as
    /// against the rest of it. For a single selection that is simply the row; for
    /// a range it is the end furthest from `selectionAnchorID`, which is the row
    /// a ⇧-click just landed on or the row ⇧-arrow has reached.
    ///
    /// This is the one the preview shows — including for a multi-selection, which
    /// is the point of it moving — the one whose position `keepSelectionVisible`
    /// protects, and the one that persists across relaunch. Maintained by
    /// `applyMessageSelection`; always a member of `selectedMessageIDs`, or nil
    /// when that is empty.
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
                        if let new, new != self.selectedMailboxID {
                            self.beginMailboxSwitch()
                        }
                        // Refuse a nil the List writes because the selected row
                        // isn't among the ones it has realized.
                        //
                        // It already did this transiently while reconciling
                        // against a replaced tree, and it was harmless because
                        // the right value was written back in the same drain.
                        // Since the sidebar rebuilds outright on a structural
                        // change (`MailboxTree`'s `.id()`), the new outline
                        // starts *collapsed* — so a mailbox nested in a group is
                        // genuinely not a realized row, nothing writes back, and
                        // the nil sticks: `onChange` fires, `loadListing` runs,
                        // and a rename of some unrelated folder silently drops
                        // the user out of the mailbox they were reading.
                        //
                        // Safe to refuse because every deliberate clear —
                        // `deleteMailbox`, `moveIntoGroup`, `open` — assigns
                        // `selectedMailboxID` directly rather than through this
                        // binding. `itemsByID` is rebuilt in the same block as
                        // `tree`, so it always describes what the List is
                        // reconciling against.
                        if new == nil, let current = self.selectedMailboxID,
                           self.itemsByID[current] != nil { return }
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

    /// What the Table has been *told* is selected, before the deferred write to
    /// `selectedMessageIDs` has landed.
    ///
    /// **This exists because holding ⇧ and auto-repeating ↓ skipped rows.**
    ///
    /// The setter below must defer its work by a runloop turn (see the note on
    /// `mailboxSelection` — writing an `@Published` during SwiftUI's update pass
    /// is what produces "Publishing changes from within view updates is not
    /// allowed"). That leaves the getter a turn behind, and the getter is not
    /// merely an answer: SwiftUI *pushes* it back into the table whenever the
    /// table reconciles.
    ///
    /// Note what does **not** happen, because it is the tempting explanation and
    /// it is wrong. The ⇧-extension is AppKit's, computed inside `NSTableView`
    /// from its own `selectedRowIndexes` and its own anchor; nothing here is
    /// consulted to work out which row comes next. The damage is done on the way
    /// back:
    ///
    /// 1. ⇧↓ extends AppKit's selection to {5, 6} and the setter fires; the
    ///    published write is deferred.
    /// 2. An enrichment batch republishes `rows`, so `ContentView` re-renders and
    ///    SwiftUI reads this binding — which still says {5} — and *resets* the
    ///    table's selection to {5}, taking the anchor back with it.
    /// 3. The next auto-repeat extends from {5} again. The rows in between were
    ///    never selected.
    ///
    /// So the skip needs an intervening re-render, which is why it is
    /// intermittent and worse in big mailboxes: enrichment re-diffs the whole
    /// table on the main actor, far slower than the key-repeat interval, and it
    /// is exactly the condition documented on the `changed` check below.
    ///
    /// The getter therefore answers from here the moment a set arrives, so a
    /// reconciliation mid-repeat pushes back what the table already believes
    /// rather than a stale set. The async block still owns the published write.
    /// Cleared by `applyMessageSelection`, which every path — deferred or
    /// programmatic — goes through, so this cannot outlive the truth it stands
    /// in for.
    private var pendingMessageSelection: Set<MessageRow.ID>?

    /// Trace every selection change and every preview load: the incoming set,
    /// the anchor, the primary, and whether the render landed.
    ///
    /// Off, and kept. It was switched on because ⇧↓ moved the preview once and
    /// then stopped, and it settled the question in a single run by printing
    /// `new [13, 19] … primary 13` followed by `new [13, 15, 19] … primary 13`.
    /// Two selections apart on screen, the same primary — which said plainly
    /// that "furthest from the anchor" was being computed in the wrong space.
    /// The rows are sorted by date, so ⇧↓ from ID 19 selects 13, then 15, then
    /// 14; `abs(id - anchor)` crowned 13 on the first press and nothing could
    /// unseat it. No amount of staring at the code would have shown that,
    /// because the code looked right — it was the assumption underneath it that
    /// was wrong.
    static let diagnoseSelection = false

    /// The row a ⇧-extension measures from — the one that stays put while the
    /// other end moves.
    ///
    /// Its own stored fact rather than something inferred from
    /// `primaryMessageID`, because the primary is now the *moving* end (see
    /// `applyMessageSelection`) and the two are the opposite ends of the same
    /// range. Set whenever the selection collapses to a single row, or when a
    /// caller names the clicked row.
    private var selectionAnchorID: MessageRow.ID?

    /// Guards against a superseded keystroke's deferred block applying after a
    /// newer one. Each `set` bumps this and its block refuses unless it is still
    /// the newest, so an auto-repeat burst applies once, with the final set,
    /// instead of once per keystroke.
    ///
    /// Without it the unconditional clear in `applyMessageSelection` could wipe a
    /// stand-in that a *newer* setter had already written, regressing the getter
    /// to an older set — the very thing this pair exists to prevent. Today the
    /// main queue drains the whole burst in one pass so nothing could read
    /// between them, but that is an implementation detail to depend on rather
    /// than a guarantee, and this file is full of things that spin the runloop.
    ///
    /// It also removes the intermediate published writes, each of which
    /// re-rendered everything observing `AppModel` and kicked off a preview load
    /// — main-actor congestion of the same kind that made the bug visible.
    private var messageSelectionEpoch = 0

    var messageSelection: Binding<Set<MessageRow.ID>> {
        Binding(get: { [weak self] in
                    guard let self else { return [] }
                    return self.pendingMessageSelection ?? self.selectedMessageIDs
                },
                set: { [weak self] new in
                    guard let self else { return }
                    self.pendingMessageSelection = new
                    self.messageSelectionEpoch &+= 1
                    let epoch = self.messageSelectionEpoch
                    DispatchQueue.main.async { [weak self] in
                        // A user selection in In counts as engaging with it, so it
                        // dismisses the new-mail badge. Programmatic selection goes
                        // through `applyMessageSelection` directly, not this
                        // binding, so a delivery re-list can't trip this.
                        //
                        // Superseded keystrokes drop out here — see
                        // `messageSelectionEpoch`.
                        guard let self, self.messageSelectionEpoch == epoch else { return }
                        // Whether this is a real change, decided *before*
                        // applying it. SwiftUI writes a selection binding back
                        // when a control reconciles against changed contents —
                        // every enrichment batch, every delivery refresh, even
                        // the mark-read below — and an echo of the same set must
                        // not restart the clock, or a message could be marked
                        // read purely because rows were republished under it.
                        let changed = new != self.selectedMessageIDs
                        self.applyMessageSelection(new)
                        // Clicking a message is what clears its unread flag.
                        //
                        // Eudora 7 could equate unread with never-opened,
                        // because reading a message meant opening it. Eudora 8
                        // shows the message in the preview without opening
                        // anything, so that equation no longer holds and the
                        // click — which you make anyway, to act on a message —
                        // is what stands in for it.
                        //
                        // Hooked to this binding rather than to `loadMessage`
                        // deliberately: only *user* selection comes through
                        // here. Restoring the last selection at launch and
                        // opening a search hit both go through
                        // `applyMessageSelection` directly, so neither silently
                        // marks a message you had left unread. The `changed`
                        // filter above makes that structurally true rather than
                        // merely true in practice: an echo is by definition
                        // equal, so it can never get this far.
                        //
                        // `removalVeil` too: `applyMessageSelection` refuses a
                        // non-empty selection while the veil is up, so `changed`
                        // can be true with nothing applied, and mark-read would
                        // run against the *previous* selection. Unreachable
                        // today only because `afterRemoval` happens to clear the
                        // selection before raising the veil — an ordering, not a
                        // guarantee.
                        if changed, self.removalVeil == nil {
                            self.scheduleMarkSelectedRead()
                        }
                    }
                })
    }

    /// Where a message sits in the list *as displayed*.
    ///
    /// The selection's two ends are decided by this, never by comparing IDs. An
    /// ID is a position in the mailbox file; the list is sorted by date, who or
    /// subject, so consecutive rows on screen are not consecutive IDs and are
    /// not even monotonic in ID. Falls back to the ID only when the row isn't in
    /// the current listing, where any answer is a guess and a stable one beats a
    /// crash.
    private func position(of id: MessageRow.ID) -> Int {
        rowPositionByID[id] ?? id
    }

    /// How far apart two messages are on screen, in rows.
    private func selectionDistance(_ id: MessageRow.ID, from anchor: MessageRow.ID) -> Int {
        abs(position(of: id) - position(of: anchor))
    }

    /// Install a new selection set and keep `primaryMessageID` truthful.
    ///
    /// The Table's `Set` binding reports only the new membership — not which row
    /// was clicked, nor which way a range grew — so both ends are derived from
    /// the set itself. `selectionAnchorID` is the fixed end, reset whenever the
    /// selection collapses to one row; `primaryMessageID` is the moving end, the
    /// member furthest from it.
    ///
    /// Expressed as a property of the resulting set rather than a case analysis
    /// over what changed, because the case analysis is where the bugs live: an
    /// earlier version handled growth and let every other gesture fall through to
    /// an arbitrary `Set.first`, which was invisible only for as long as a
    /// multi-selection previewed nothing.
    ///
    /// Every programmatic selection change goes through here too, so the
    /// invariant — primary is a member, or nil — has one owner. A caller that
    /// *knows* which row was clicked (the AppKit context menu does; the Table
    /// binding doesn't) passes it as `primary` and overrides the inference.
    func applyMessageSelection(_ new: Set<MessageRow.ID>,
                               primary preferred: MessageRow.ID? = nil) {
        // The stand-in the binding's getter reads has now been overtaken —
        // either by this call applying it, or by a programmatic selection that
        // supersedes it. Cleared before the veil guard below, deliberately: if
        // that guard refuses the selection, the stand-in must not be left
        // reporting a set that was never applied.
        pendingMessageSelection = nil

        // While the removal veil is up the rows are a stale picture, so a
        // non-empty selection arriving through the Table binding (arrow keys —
        // the veil's overlay already swallows clicks) would select by an index
        // that names a different message after the re-list. Ignore it; clears
        // still pass, and the binding's `get` keeps the Table showing none —
        // from the next turn on, now that the getter answers from the stand-in
        // first.
        if removalVeil != nil, !new.isEmpty { return }
        if new != selectedMessageIDs {
            selectedMessageIDs = new
            if new.isEmpty {
                primaryMessageID = nil
                selectionAnchorID = nil
            } else if let p = preferred, new.contains(p) {
                // A caller that knows which row was clicked. It becomes both the
                // primary and the anchor a later ⇧-extension will measure from.
                primaryMessageID = p
                selectionAnchorID = p
            } else if new.count == 1 {
                // The selection collapsed to one row — a plain click, a plain
                // arrow, a programmatic select. That row is where any subsequent
                // ⇧-extension starts, so it is the new anchor.
                primaryMessageID = new.first
                selectionAnchorID = new.first
            } else {
                // A multi-selection. The primary is the member FURTHEST FROM THE
                // ANCHOR — the moving end — because that is the row the user's
                // attention is on and, now that a multi-selection previews the
                // primary, the message they expect to be looking at.
                //
                // One rule covers every gesture, which is why it is expressed as
                // a property of the resulting set rather than as a case analysis
                // over what changed:
                //   ⇧↓ growing away from the anchor   → the newest row
                //   ⇧↑ shrinking back toward it       → the new far end
                //   ⇧-click across the anchor         → the row clicked
                //   ⌘-click adding a distant row      → that row
                //   ⌘-click removing the primary      → the far end of what's left
                //
                // An earlier version keyed on "rows were added" and kept the
                // anchor primary otherwise. It got growth right and everything
                // else arbitrary: shrinking fell through to `Set.first`, which is
                // hash-ordered, so ⇧↓ ⇧↓ ⇧↑ previewed a random member of the
                // selection. That was invisible while a multi-selection previewed
                // nothing, and is not any more.
                //
                // The anchor has to be its own stored fact. It used to be implied
                // by the primary, and once the primary moves to the far end that
                // implication is gone.
                //
                // **Distance is measured in VISUAL ROW POSITION, not in ID.** An
                // ID is a 1-based index into the mailbox file; the list is sorted
                // by date (or who, or subject), so the two orders are unrelated.
                // Measured, after a first attempt that did the arithmetic on IDs:
                // ⇧↓ from row-ID 19 selected 13, then 15, then 14 — so `abs(id -
                // anchor)` crowned 13 on the first press and never unseated it,
                // and the preview moved once and then stopped.
                if selectionAnchorID == nil || !new.contains(selectionAnchorID!) {
                    // The anchor left the selection (⌘-click, or a re-list that
                    // dropped it). Topmost survivor, by position: deterministic,
                    // and it doesn't pretend to guess an intent that is gone.
                    selectionAnchorID = new.min(by: { position(of: $0) < position(of: $1) })
                }
                if let anchor = selectionAnchorID {
                    primaryMessageID = new.max(by: {
                        selectionDistance($0, from: anchor) < selectionDistance($1, from: anchor)
                    })
                }
            }
            if Self.diagnoseSelection {
                print("sel: new \(new.sorted()) preferred \(preferred as Any)"
                      + "  anchor \(selectionAnchorID as Any)"
                      + "  primary \(primaryMessageID as Any)")
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

    /// Whether In's **newest** message is unread — the green badge next to "In",
    /// the counterpart of the unsent glyph next to Out.
    ///
    /// **Derived, and assigned in exactly two places**: the initial open and
    /// `startTreeReload`, each in the same synchronous block as the `tree` it was
    /// computed from. See `inboxNewestIsUnread` for the rule and for the two bugs
    /// that produced it. Nothing else may set this — if the badge is ever wrong,
    /// the question is which tree walk was missing, not which clear misfired.
    ///
    /// Not the same signal as the bold row name, which is `MailboxItem.hasUnread`
    /// and means "In holds unread mail anywhere". This one narrows that to the most
    /// recent arrival, so working back through a backlog turns the badge off as
    /// soon as the newest is read, while leaving the bold name alone.
    @Published private(set) var inboxHasNewMail = false

    /// The message list's Who and Date column widths, adjustable by dragging the
    /// header dividers (see `MessageColumnResizeController`) and remembered
    /// globally across launches. The Table reads these for its columns' `ideal`
    /// width.
    ///
    /// **Deliberately not `@Published`.** The drag updates these every frame, and
    /// on a huge mailbox re-rendering the whole message list per frame beachballs.
    /// The drag's live feedback comes from setting the `NSTableColumn` width
    /// directly; these just need to hold the value the Table will read at its next
    /// natural re-render, so a re-render mid-enrichment re-applies the current
    /// width rather than the launch one. No observer needs to fire when they
    /// change.
    private(set) var whoColumnWidth: CGFloat =
        MessageColumnWidths.loaded(key: MessageColumnWidths.whoWidthKey,
                                   default: MessageColumnWidths.whoDefault,
                                   min: MessageColumnWidths.whoMin)
    private(set) var dateColumnWidth: CGFloat =
        MessageColumnWidths.loaded(key: MessageColumnWidths.dateWidthKey,
                                   default: MessageColumnWidths.dateDefault,
                                   min: MessageColumnWidths.dateMin)

    /// Set the Who column width (live, during a drag), clamped to its minimum and
    /// remembered. A no-op when unchanged. Does not trigger a re-render — see the
    /// note on `whoColumnWidth`.
    func setWhoColumnWidth(_ width: CGFloat) {
        let clamped = max(MessageColumnWidths.whoMin, width)
        guard abs(clamped - whoColumnWidth) > 0.5 else { return }
        whoColumnWidth = clamped
        UserDefaults.standard.set(Double(clamped), forKey: MessageColumnWidths.whoWidthKey)
    }

    /// Set the Date column width. See `setWhoColumnWidth`.
    func setDateColumnWidth(_ width: CGFloat) {
        let clamped = max(MessageColumnWidths.dateMin, width)
        guard abs(clamped - dateColumnWidth) > 0.5 else { return }
        dateColumnWidth = clamped
        UserDefaults.standard.set(Double(clamped), forKey: MessageColumnWidths.dateWidthKey)
    }

    @Published var listingSource: String = ""
    @Published var mailboxSummary: String = ""

    /// The selected mailbox as a readable path — "GOVERNMENT ▸ USPTO".
    ///
    /// Computed here rather than folded into `mailboxSummary` because that
    /// string is built by `buildListing`, which runs *off* the main actor and
    /// has no access to the tree. This needs `itemsByID`, which is main-actor
    /// state, so it belongs on this side.
    ///
    /// **Display names, not the id.** A `MailboxItem.ID` is already a path, but
    /// of *filenames* — the GOVERNMENT group's is `GOVERNMENT.fol`, and the
    /// PROJECTS one is `______PROJECTS.fol` — so showing the id would put
    /// Eudora's on-disk spelling in front of the user. The id's components are
    /// walked instead, and each successive prefix is resolved back through
    /// `itemsByID` to the name descmap gives it.
    ///
    /// Cheap enough to be a computed property: a split and a handful of
    /// dictionary lookups, on a path that is two or three deep.
    var selectedMailboxPath: String {
        guard let id = selectedMailboxID,
              let item = itemsByID[id], !item.isFolder else { return "" }
        return readablePath(of: id)
    }
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

    /// Whether `pendingMessageID` is an explicit jump — "View in Mailbox" from a
    /// search result — as opposed to the launch-time restore of the message that
    /// was selected last time.
    ///
    /// The distinction decides what happens to the scroll position, and getting
    /// it wrong is not a cosmetic matter. A restore must honour the mailbox's
    /// remembered position, including its at-the-bottom flag; a centred reveal
    /// instead would scroll somewhere else *and* be recorded, so a mailbox left
    /// parked at its end would quietly lose that state at the next launch. See
    /// the reasoning in `loadListing` and `rememberScroll`.
    private var pendingMessageIsExplicitJump = false

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

        // Claim the tree before touching it. Two Eudoras writing one tree is a
        // lost-update hazard, not a cosmetic one — `Outbox.append` reads the
        // whole `.mbx`, appends and replaces it — and the app-level
        // single-instance guard doesn't cover a second copy pointed at the same
        // folder from elsewhere. Declining is a hard stop: the folder is not
        // opened and nothing is written.
        var staleNote: String?
        switch TreeLock.take(root: url) {
        case .took:
            break
        case .tookStale(let previous):
            // Reported, not asked. The previous holder is provably gone; the
            // reason to mention it at all is that the run ended without
            // releasing the lock, so it may have died mid-write.
            //
            // Not in DEBUG, though. Xcode's Stop sends SIGKILL, so
            // `applicationWillTerminate` never runs and *every* debug launch
            // would find a stale lock and say so. A warning that fires forty
            // times a week is a warning nobody reads by Thursday — and in that
            // case it is evidence of nothing at all.
            #if !DEBUG
            let when = previous.started == .distantPast
                ? nil
                : DateFormatter.localizedString(from: previous.started,
                                                dateStyle: .short, timeStyle: .short)
            staleNote = "Recovered a lock left by an earlier run"
                + (when.map { " (started \($0))" } ?? "")
                + " — it ended without closing properly."
            #else
            _ = previous
            #endif
        case .declined:
            showError("Didn't open \(url.lastPathComponent) — another program has it locked.")
            return
        }
        UserDefaults.standard.set(url.path, forKey: Self.lastFolderKey)
        // `!bannerIsError` because this defer runs *after* the whole function
        // body: without the check, a real failure below — "Couldn't create the
        // standard mailboxes" — would be overwritten by this note, and
        // `showBanner` clears the error styling, so a sticky error would become
        // a self-dismissing aside and the failure would vanish.
        defer { if let staleNote, !bannerIsError { showBanner(staleNote) } }

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
        // Scanned inline here — this is the initial open, so the badge is right
        // from the first paint (a launch with unsent mail already shows it), and
        // Out is always small enough that the extra TOC read costs nothing.
        tree = Self.buildItems(nodes, prefix: "",
                               outboxUnsent: Self.outboxHasUnsent(in: nodes, store: s))
        // Same reasoning for In's new-mail badge, and cheaper still — one
        // 218-byte record rather than a listing. This is what makes the badge
        // correct on a cold launch, which is where it was previously always wrong:
        // the flag it replaced started every process as false.
        inboxHasNewMail = Self.inboxNewestIsUnread(in: nodes, store: s)
        treeVersion &+= 1
        // Seeded in the same turn as the tree itself, for both halves of the
        // invariant `startTreeReload` keeps.
        //
        // Without the bump, opening a different Eudora folder replaces every
        // item under an *unchanged* sidebar `.id()`, so SwiftUI diffs one
        // folder's outline against another's — the most extreme restructure
        // there is, and the exact crash path `treeIdentityVersion` exists to
        // close. Without seeding the two signatures, they stay 0 while the real
        // tree is on screen, and the first reload for any reason — a delivery,
        // a mark-as-read — reads as a structural change and collapses the
        // sidebar for a message count.
        treeShape = Self.shapeSignature(tree)
        treeIdentity = Self.identitySignature(tree)
        treeStructureVersion &+= 1
        treeIdentityVersion &+= 1
        itemsByID = [:]
        indexItems(tree)
        // Per tree, not per launch: the watch needs a root to rebuild, and
        // opening a different folder should watch that one.
        startOvernightRebuildWatch()
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

        // There is now somewhere to save a draft. If a mailto: link has been
        // waiting — because Eudora was launched by one with no remembered
        // folder, and the folder has just been chosen by hand — this is what
        // stops it being stranded. Does nothing in every other case.
        drainPendingMailtos()
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

    /// Whether the current mailbox's list was last left scrolled to its end.
    ///
    /// The remembered fact, not a live measurement — only the AppKit bridge can
    /// see where the list actually is. Used where bottom-ness has to be decided
    /// without the geometry to hand: the delivery refresh, and the restore
    /// write-back when the table has gone away.
    var selectedMailboxWasAtBottom: Bool {
        selectedMailboxID.map { viewState.atBottomByMailbox[$0] == true } ?? false
    }

    /// Records the message list's scroll position for the current mailbox.
    ///
    /// Scrolling fires continuously, so the write to UserDefaults is coalesced —
    /// the in-memory state updates immediately, the save lands once the scroll
    /// has been still for a moment.
    ///
    /// - Parameter atBottom: whether the list is scrolled to its end. Stored
    ///   separately from `topRow` because a row index can't express it: "top row
    ///   412" is the end only until the row count changes, and delivery changes
    ///   it. See `ViewState.atBottomByMailbox`.
    func rememberScroll(topRow: Int, atBottom: Bool) {
        // `listedMailboxID` as well as `selectedMailboxID`: the sidebar writes
        // the selection a turn before `loadListing` clears the rows, and in that
        // window the table still shows the *previous* mailbox at the previous
        // position. A bounds change landing there would file that reading under
        // the newly-selected mailbox's key — harmless-ish for a top row, which
        // the `-1` guard mostly catches once the rows clear, but bottom-ness is
        // a sticky flag and would be inherited outright.
        guard let mailbox = selectedMailboxID, listedMailboxID == mailbox,
              topRow >= 0 else { return }
        let wasAtBottom = viewState.atBottomByMailbox[mailbox] == true
        // Both compared before returning early: the top row can be unchanged
        // while bottom-ness flips — a window resized taller brings the last row
        // into view without moving the clip origin at all.
        guard viewState.scrollTopRowByMailbox[mailbox] != topRow
                || wasAtBottom != atBottom else { return }
        viewState.scrollTopRowByMailbox[mailbox] = topRow
        // Removed rather than stored false, so the blob doesn't accumulate an
        // entry for every mailbox ever scrolled.
        if atBottom {
            viewState.atBottomByMailbox[mailbox] = true
        } else {
            viewState.atBottomByMailbox.removeValue(forKey: mailbox)
        }

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

    /// Whether that reveal should *centre* the row rather than scroll the least
    /// amount that shows it.
    ///
    /// Minimal is right when the list is already where the user put it and the
    /// selection merely needs to stay in sight — after a re-sort, say. Centring
    /// is right when arriving from somewhere else, which is the Find window's
    /// "View in Mailbox": the reason for going there is to see what came before
    /// and after, and a row scrolled to the very bottom edge shows the before and
    /// none of the after.
    ///
    /// A companion flag rather than a value on `pendingRevealRow` so the existing
    /// call sites keep working unchanged; both are cleared together.
    @Published var pendingRevealCentered = false

    /// Called by the bridge once the row has been revealed.
    func clearPendingReveal() {
        pendingRevealRow = nil
        pendingRevealCentered = false
    }

    /// Bring a row into view with the least scrolling that does it.
    ///
    /// Every plain reveal goes through here rather than assigning
    /// `pendingRevealRow` directly, so the centred flag cannot be left standing
    /// from an earlier request — the bridge retries a reveal for up to three
    /// seconds, which is ample time for a re-sort to re-target the row under a
    /// flag that no longer describes what was asked for.
    func reveal(row: Int) {
        pendingRevealCentered = false
        pendingRevealRow = row
    }

    /// Bring a row into view, centred. Used when a message is reached from
    /// outside the list.
    ///
    /// The flag is set before the row, and cleared after it, so whichever the
    /// bridge notices first it never sees a row with a stale companion value.
    func revealCentered(row: Int) {
        pendingRevealCentered = true
        pendingRevealRow = row
    }

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

    // MARK: - Sidebar expansion

    /// Which sidebar folders were open when this Eudora folder was last used.
    ///
    /// Deliberately **not** `@Published`, and read rather than observed. The
    /// sidebar owns the live value for as long as it is on screen (see
    /// `MailboxTree`); publishing from here would invalidate every view
    /// observing this model on each click of a disclosure triangle, which is the
    /// cost `MailboxTree.==` exists to avoid.
    var savedSidebarExpansion: Set<String> { viewState.sidebarExpansion.expandedIDs }

    /// Record the sidebar's expansion, pruned to folders that still exist.
    ///
    /// Pruning here rather than at each delete, rename and move site: all three
    /// either retire a path-derived id or change it, so one intersection applied
    /// on save covers all three without four call sites having to remember. The
    /// non-empty guard is load-bearing — `retain` with nothing present empties
    /// the set (there is a test named for it), and a save that landed while the
    /// tree was between reloads would otherwise forget every open folder.
    func recordSidebarExpansion(_ ids: Set<String>) {
        var next = SidebarExpansion(expandedIDs: ids)
        if !tree.isEmpty { next.retain(idsIn: Self.folderIDs(in: tree)) }
        guard next != viewState.sidebarExpansion else { return }
        viewState.sidebarExpansion = next
        if let root = rootURL?.path { ViewStateStore.save(viewState, forRoot: root) }
    }

    /// Every folder id in the tree. Folders are exactly the items with non-nil
    /// `children` (a mailbox gets nil, an empty folder gets `[]` — see the tree
    /// build), and only a folder can be expanded.
    private static func folderIDs(in items: [MailboxItem]) -> Set<String> {
        var ids: Set<String> = []
        func walk(_ items: [MailboxItem]) {
            for item in items {
                guard let children = item.children else { continue }
                ids.insert(item.id)
                walk(children)
            }
        }
        walk(items)
        return ids
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
    func base(ofType type: MailboxType) -> URL? { item(ofType: type)?.base }

    /// The first mailbox of a role in the tree, or nil — the item itself, when
    /// the caller needs more than its `base` (e.g. its `id` to key view state).
    /// Depth-first pre-order, like `base(ofType:)`.
    func item(ofType type: MailboxType) -> MailboxItem? {
        func find(_ items: [MailboxItem]) -> MailboxItem? {
            for item in items {
                if !item.isFolder, item.type == type { return item }
                if let kids = item.children, let hit = find(kids) { return hit }
            }
            return nil
        }
        return find(tree)
    }

    /// The In box's tree id, or nil when the tree has none. Cheap enough to walk
    /// on demand at the (user-paced) points that need it.
    var inboxID: MailboxItem.ID? { item(ofType: .inbox)?.id }

    /// Where sent and unsent mail lives, from the in-memory tree.
    var outboxBase: URL? { base(ofType: .outbox) }

    /// A hash of everything the Move menus draw: ids, labels, folder-ness and
    /// nesting. Deliberately excludes `messageCount` and `hasUnread`, which are
    /// the only things our own mutations change.
    /// A hash of the tree's *parentage* graph: which items exist, what kind they
    /// are, and what each one's parent is. Keys the sidebar's `.id()`.
    ///
    /// Three things are deliberately excluded, each for its own reason:
    ///
    /// - **Display names**, because a rename leaves every row identity intact
    ///   (see `treeIdentityVersion`).
    /// - **Message counts and unread flags**, because mail arriving must not
    ///   rebuild the sidebar.
    /// - **Sibling order** — which is why the per-item hashes are XOR-ed rather
    ///   than fed to a `Hasher` in sequence. `Hasher` is order-sensitive, so
    ///   walking the tree in order made a Move Up/Down bump the version and
    ///   collapse the whole sidebar; reordering a mailbox inside a group is
    ///   *the* most common structural edit, and collapsing on every one of them
    ///   made the feature unusable.
    ///
    /// That last exclusion is safe for a specific, checked reason rather than
    /// optimism: `MailboxTreeMutator.moveEntry` exchanges two lines within one
    /// `descmap.pce` and touches no other file, so a reorder **cannot** change
    /// any item's parent — whichever two lines it picks. What
    /// crashed SwiftUI's outline diff was reparenting an *expanded subtree* —
    /// deleting it from one parent and inserting it under another inside one
    /// animated batch. A permutation of the same ids under the same parent is
    /// the ordinary case that diff exists to handle.
    ///
    /// XOR is sound here because ids are unique, so no two per-item hashes can
    /// cancel each other out.
    private static func identitySignature(_ items: [MailboxItem]) -> Int {
        var combined = 0
        func walk(_ items: [MailboxItem], parent: String) {
            for item in items {
                var hasher = Hasher()
                hasher.combine(parent)
                hasher.combine(item.id)
                hasher.combine(item.isFolder)
                combined ^= hasher.finalize()
                if let kids = item.children { walk(kids, parent: item.id) }
            }
        }
        walk(items, parent: "")
        return combined
    }

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

    private static func buildItems(_ nodes: [MailboxNode], prefix: String,
                                   outboxUnsent: Bool) -> [MailboxItem] {
        nodes.map { n in
            let path = prefix.isEmpty ? n.entry.filename : prefix + "/" + n.entry.filename
            let kids = n.isFolder ? buildItems(n.children, prefix: path,
                                               outboxUnsent: outboxUnsent) : nil
            return MailboxItem(id: path,
                               display: n.entry.display,
                               type: n.entry.type,
                               base: n.base,
                               isFolder: n.isFolder,
                               messageCount: n.messageCount,
                               hasUnread: n.entry.hasUnread,
                               hasUnsent: n.entry.type == .outbox && outboxUnsent,
                               children: kids)
        }
    }

    /// The Out mailbox in a freshly-walked tree, if there is one.
    nonisolated private static func firstOutbox(in nodes: [MailboxNode]) -> MailboxNode? {
        for n in nodes {
            if n.entry.type == .outbox { return n }
            if let found = firstOutbox(in: n.children) { return found }
        }
        return nil
    }

    /// Whether Out holds at least one unsent (status-9) message. Read from the
    /// TOC via the ordinary listing — Out is small, and this runs off the main
    /// thread as part of the tree walk. A send-error message (status 10) does not
    /// count: the badge is specifically the *unsent* one.
    nonisolated private static func outboxHasUnsent(in nodes: [MailboxNode],
                                                    store: MailStore) -> Bool {
        guard let outbox = firstOutbox(in: nodes),
              let listing = store.list(at: outbox.base) else { return false }
        return listing.rows.contains { $0.status == MailboxMutator.statusUnsent }
    }

    /// The In mailbox in a freshly-walked tree, if there is one. The counterpart
    /// of `firstOutbox`, and separate from `item(ofType:)` for the same reason
    /// that one is: this runs against the walk's own nodes, before `tree` exists.
    nonisolated private static func firstInbox(in nodes: [MailboxNode]) -> MailboxNode? {
        for n in nodes {
            if n.entry.type == .inbox { return n }
            if let found = firstInbox(in: n.children) { return found }
        }
        return nil
    }

    /// Whether In's newest message is still unread — the sidebar's green badge.
    ///
    /// **Derived, not remembered, and that is the point.** The badge used to be a
    /// published flag set on delivery and cleared by whichever user action was
    /// judged to count as "engaging with In", which took two bugs to expose as the
    /// wrong shape: a delivery re-list echoed the selection binding and put it out
    /// with nobody touching anything, and it didn't survive a quit at all because
    /// nothing persisted it. Persisting it would have been a third patch on the
    /// same mistake.
    ///
    /// The rule it replaces all that with is Stephen's, and it needs no state:
    /// *if the most recent message in In is unread, the pass through In is
    /// unfinished.* That is a fact about the mail on disk, so it can simply be
    /// recomputed — here, on every tree walk, which already happens at launch, on
    /// delivery, and at the end of `markSelected` ("unread badge may change").
    /// Reading the newest message therefore puts the badge out by itself, and
    /// reading an older one leaves it lit, which is the intended reading of
    /// "perusal still incomplete".
    ///
    /// Costs one 218-byte read — see `MailStore.newestStatus`.
    nonisolated private static func inboxNewestIsUnread(in nodes: [MailboxNode],
                                                       store: MailStore) -> Bool {
        guard let inbox = firstInbox(in: nodes) else { return false }
        return store.newestIsUnread(base: inbox.base)
    }

    // MARK: listing a mailbox

    /// Full (re)load of the selected mailbox — clears the message selection,
    /// unless a hit is being opened (pendingMessageID), in which case that
    /// message is selected once the rows exist.
    /// - Parameter force: rebuild even if this mailbox is already listed. Used by
    ///   the in-place refreshes (mail sent, and the mailbox mutations); the
    ///   received path no longer comes through here — see
    ///   `refreshInPlaceAfterDelivery`. The default path is
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
        let pendingIsJump = pendingMessageIsExplicitJump
        pendingMessageID = nil
        pendingMessageIsExplicitJump = false
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
            //
            // Bottom-ness first, and it wins: it is the more specific fact. A
            // mailbox left at the end has a remembered top row too, but that
            // number describes the end only for the row count it was recorded
            // at — which is precisely what delivery changes while the mailbox is
            // away. Honouring the index instead would put a list that was at the
            // bottom back into the middle, one screenful short of the new mail,
            // which is the symptom this whole change exists to remove.
            //
            // A *reveal* of the last row rather than a top-row pin, because
            // pinning the last row to the top is not what "at the bottom" looks
            // like: `originY` clamps it to the maximum legal origin, so it
            // happens to land correctly today, but only as a side effect of the
            // clamp. `pendingRevealRow` says what is meant.
            // An explicit jump beats the remembered position, and has to be
            // checked first. Opening a search hit in a mailbox that was left at
            // the bottom — or anywhere else — used to select the message and then
            // immediately scroll somewhere else, so "View in Mailbox" landed on
            // a mailbox whose selected row was off screen. The remembered
            // position describes where the user last was; it is not what they
            // just asked for.
            //
            // `pendingIsJump` is what keeps this off the launch path, which sets
            // `pendingMessageID` too and must still restore the remembered
            // position rather than centre on it.
            if pendingIsJump, let pending, let pos = self.rowPositionByID[pending] {
                self.pendingScrollTopRow = nil
                self.revealCentered(row: pos)
            } else if let mailbox = self.selectedMailboxID, !self.rows.isEmpty,
               self.viewState.atBottomByMailbox[mailbox] == true {
                self.pendingScrollTopRow = nil
                self.reveal(row: self.rows.count - 1)
            } else if let mailbox = self.selectedMailboxID,
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

    /// Fold newly delivered mail into the In box *while the user is looking at
    /// it*: no blank, no jump, and the messages already on screen stay under the
    /// same pixels.
    ///
    /// `loadListing(force:)` is deliberately not reused. It clears the rows first
    /// — "the old mailbox's rows must not linger under the new mailbox's name" —
    /// which is right when switching mailboxes and wrong when refreshing the one
    /// already shown. That clear is the blank; the two-phase TOC-then-enrichment
    /// rebuild behind it is the draw-down-the-list and the reshuffle that
    /// followed.
    ///
    /// Here the current rows stay up, accurate but one delivery out of date,
    /// while the fresh listing is built underneath them. Each hands its parsed
    /// Who/date/attachment values to its replacement, so the arriving messages
    /// are the only rows with anything to settle. Same trick as `afterRemoval`,
    /// minus the veil: nothing on screen is a lie in the meantime, so there is
    /// nothing to cover.
    private func refreshInPlaceAfterDelivery() {
        // The message at the top of the viewport, remembered by id rather than
        // by position. Delivery appends, but where the new rows *land* depends
        // on the sort — newest-first puts them above everything and pushes the
        // list down — so a position restored numerically would show different
        // messages than it did a moment earlier. Restoring by id puts the same
        // message back under the same pixel, which is what "the scrolling
        // position shouldn't change" has to mean for it to look like nothing
        // happened.
        //
        // `pendingScrollTopRow` first: a restore in flight is the position the
        // list is *going* to be at, and it reaches `scrollTopRowByMailbox` only
        // once the AppKit bridge has applied and confirmed it (retries at 0.2s,
        // a 0.15s verification). A second delivery inside that window would
        // otherwise read the previous top — an index into the *old* rows — and
        // anchor to the wrong message.
        //
        // Falling back to 0 rather than to "no anchor" keeps the two cases from
        // behaving oppositely: a list sitting at the top with nothing recorded
        // used to leave the offset alone (new mail appearing above the
        // viewport), while the same list with a recorded 0 anchored (new mail
        // pushed out of sight). Same screen, opposite results, decided by
        // whether a scroll had ever been recorded. Now both anchor.
        let top = pendingScrollTopRow
            ?? selectedMailboxID.flatMap { viewState.scrollTopRowByMailbox[$0] }
            ?? 0
        let anchorID: Int? = rows.indices.contains(top) ? rows[top].id : nil

        // …unless the list was sitting at the end, in which case the end is the
        // anchor. Holding the *top* row still is what "nothing moved" means for
        // a list positioned in the middle; for one deliberately parked at the
        // bottom it means the opposite, because the new mail lands below the
        // viewport and holding the top row is precisely what keeps it out of
        // sight. Two readings of "don't move", and which one is right is
        // decided by where the user left the list.
        //
        // No test of the sort here. Under a descending sort new rows land above
        // everything, so a list parked at the end is still parked at the same
        // message and the reveal is a no-op; the top-row anchor case is
        // unaffected. And a list short enough to fit the pane is never recorded
        // as "at the end" at all — see `Scrolling.lastRowVisible`, where that
        // exclusion is load-bearing rather than tidiness. So the rule states
        // itself: if the end was in view, keep the end in view.
        //
        // Which does mean "the bottom" is whatever sorts last, not necessarily
        // the newest. Under a Who sort, mail from Zoe follows and mail from
        // Alice doesn't. That is the honest consequence of not testing the sort,
        // and it is still what the user asked for by parking at the end.
        let wasAtBottom = selectedMailboxWasAtBottom

        // Every listed row's enrichment, keyed by the index it will still have.
        // Delivery appends to the .mbx and the .toc, so nothing already listed
        // is renumbered — unlike a removal, which is why `afterRemoval` has to
        // shift its keys and this does not. The arriving messages are absent
        // from the map and are therefore exactly the rows enrichment fills in.
        var carryOver: [Int: MessageRow] = [:]
        carryOver.reserveCapacity(rows.count)
        for row in rows { carryOver[row.id] = row }

        // The mailbox this refresh belongs to, so a scroll offset computed for
        // In can't be applied to something else. `beginMailboxSwitch` cancels
        // the listing and bumps the generation on a normal sidebar switch, so
        // the completion would already stand down — but `openHit` assigns
        // `selectedMailboxID` directly and its cancelling `loadListing` only
        // arrives a runloop hop later, leaving a gap.
        //
        // Note this guards the *offset* only. `rebuildRows` publishes its rows
        // before calling here, so a read landing in that gap still installs In's
        // rows over the newly selected mailbox — a pre-existing hazard of that
        // path, not one this refresh introduces, and self-correcting once the
        // cancelling `loadListing` arrives.
        let mailbox = selectedMailboxID

        rebuildRows(carryingEnrichment: carryOver) { [weak self] in
            guard let self else { return }
            if self.selectedMailboxID == mailbox {
                // This runs in the same main-actor turn as the `setRows` inside
                // `rebuildRows`, so the new rows and their corrected offset reach
                // the table together — the uncorrected position is never drawn.
                if wasAtBottom, !self.rows.isEmpty {
                    self.pendingScrollTopRow = nil
                    self.reveal(row: self.rows.count - 1)
                    // Re-asserted now rather than waiting for the reveal's bounds
                    // change to be observed and recorded. A second delivery
                    // arriving inside that window would otherwise read a flag
                    // that hasn't caught up and fall back to anchoring the top
                    // row — dropping out of follow-the-bottom precisely when
                    // mail is arriving fast enough to matter. Same reasoning as
                    // `pendingScrollTopRow` taking precedence above.
                    //
                    // In memory only; no save is scheduled. This is a re-assert
                    // of a value the user's own scrolling put on disk, not a new
                    // fact, and the reveal's own bounds change routes through
                    // `rememberScroll` a beat later and coalesces a save then.
                    if let mailbox { self.viewState.atBottomByMailbox[mailbox] = true }
                } else if let anchorID, let pos = self.rowPositionByID[anchorID], !self.rows.isEmpty {
                    self.pendingScrollTopRow = min(pos, self.rows.count - 1)
                } else {
                    // No usable anchor: In was empty before this delivery, or
                    // the remembered top is past the end, or the anchored
                    // message is gone. Leave the offset alone rather than
                    // invent one.
                    self.pendingScrollTopRow = nil
                }
            }
            // Outside the mailbox guard above: mail arrived, so In's unread
            // state has to reach the sidebar whatever is on screen now.
            //
            // After the rows, not alongside them. Publishing a new tree
            // re-renders the sidebar on the main actor, and a listing finishing
            // alongside it queues behind that render — measured at 4,017 ms in
            // the removal path, which is why `afterRemoval` sequences it the
            // same way.
            //
            // KNOWN GAP: `rebuildRows` returns without calling its completion if
            // its listing task is cancelled (a sidebar switch during the settle
            // delay), so a delivery in that window never reaches this line and
            // In's bold-unread name stays stale until the next tree reload. The
            // new-mail glyph is set unconditionally in `receiveMail`, so the
            // arrival is still announced.
            self.reloadTree()
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
        // The identity set decides direction per message now — the old
        // per-mailbox "outgoing = it's the Out mailbox" flag is gone (it showed
        // my own name in every mixed archive folder). Captured by value here so
        // the detached enrichment reads a stable snapshot.
        let me = self.me
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
                    carried.whoSort = old.whoSort
                    carried.direction = old.direction
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
            if let built {
                self.startEnrichment(store: store, base: base, records: built.records,
                                     me: me, generation: generation)
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
        // A pending mark-read belongs to the mailbox being left. Its own
        // re-check would refuse to fire anyway, but leaving a task running
        // against a torn-down listing is the pattern this method exists to
        // prevent.
        markReadTask?.cancel(); markReadTask = nil
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

    /// The whole behaviour of a header click: walk the clicked column through
    /// NotSorted → Forward → Reverse → Forward → …
    ///
    /// A column that isn't the sorted one starts ascending (Forward) — including
    /// Date, which no longer has a descending-by-default exception, so every
    /// column behaves the same way. Clicking the already-sorted column flips its
    /// direction. It never cycles back to NotSorted; Mailbox ▸ Sort ▸ Mailbox
    /// Order is the way there. Because `sort` names a single column, sorting one
    /// column leaves every other NotSorted by construction.
    func toggleSort(_ column: MessageSortColumn) {
        if sort?.column == column {
            setSort(MessageSort(column: column, ascending: !(sort?.ascending ?? true)))
        } else {
            setSort(MessageSort(column: column, ascending: true))
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
        reveal(row: pos)
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
                              offset: r.offset,
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
                              // Sort on the same TOC name until the parse lands;
                              // no direction is known yet, so no glyph shows.
                              whoSort: r.who,
                              direction: .neither,
                              // Formatted from the TOC's cached date so the
                              // column shows YYYYmmmDD immediately, in the same
                              // shape the parse will confirm — not the raw TOC
                              // string flipping format when enrichment lands.
                              date: EudoraDateFormat.displayCached(r.date),
                              hasAttachment: false,
                              // The TOC's cached string, read as an instant so
                              // the Date column can sort before the parse lands.
                              sortDate: EudoraDateFormat.tocDate(r.date))
        }
        let sizeK = max(1, (rows.reduce(0) { $0 + $1.size } + 1023) / 1024)
        let records = listing.rows.map {
            MessageLocation(index: $0.index, offset: $0.offset, length: $0.size)
        }
        return BuiltListing(rows: rows,
                            source: listing.source.rawValue,
                            summary: "\(rows.count) messages"
                                + (unread > 0 ? ", \(unread) unread" : "")
                                + " · \(sizeK)K",
                            records: records)
    }

    /// Parse the mailbox in the background and fill in Who and the attachment
    /// glyph, applying results in batches so the list settles progressively
    /// rather than in one jump at the end.
    private func startEnrichment(store: MailStore, base: URL, records: [MessageLocation],
                                 me: MeIdentity, generation: Int) {
        isEnriching = true

        // The listing already located every message; hand the offsets to the
        // reader as a plain tuple array so it can seek to each without a second
        // scan of the file. Built here, off the detached task, so `MessageLocation`
        // stays an app type.
        let locations = records.map { (index: $0.index, offset: $0.offset, length: $0.length) }

        enrichTask = Task { [weak self] in
            // Unbounded on purpose: a buffering policy would silently *drop*
            // batches, and a dropped batch means rows left un-enriched with
            // nothing to notice it. The buffer is bounded by the mailbox anyway.
            let stream = AsyncStream<[RowEnrichment]> { continuation in
                let work = Task.detached(priority: .utility) {
                    var batch: [RowEnrichment] = []
                    // The digest read, not a full parse: Who and Date are single
                    // headers and the attachment flag is settled from the top
                    // headers for all but genuine multipart mail. And it reads
                    // each message directly by offset (the memory-mapped file),
                    // cancellable between messages — so switching away from a big
                    // mailbox abandons this at once instead of finishing a
                    // whole-file read. See `MessageDigest` / `forEachMessageDigest`.
                    store.forEachMessageDigest(at: base, records: locations,
                                               isCancelled: { Task.isCancelled }) { index, digest in
                        if Task.isCancelled { return false }
                        // The other party and which way the message went, from
                        // the identity set — one rule for every mailbox. See
                        // CorrespondentResolver.
                        let resolved = CorrespondentResolver.resolve(
                            from: digest.from, to: digest.to,
                            cc: digest.cc, bcc: digest.bcc, me: me)
                        batch.append(RowEnrichment(
                            index: index,
                            who: resolved.name,
                            whoSort: resolved.sortKey,
                            direction: resolved.direction,
                            date: EudoraDateFormat.parse(digest.date),
                            hasAttachment: digest.hasAttachment))
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
                let before = self.rows.map(\.id)
                self.setRows(self.rows)
                // Only chase the selection when the re-sort actually moved
                // something. The reveal exists so a selected row displaced by
                // the new order is still findable; if the order is unchanged
                // there is nothing to find, and scrolling to the selection is an
                // unasked-for jump.
                //
                // Conditional because of `refreshInPlaceAfterDelivery`, which
                // rebuilds while *keeping* the selection and the scroll
                // position. Unconditional, this fired seconds after every
                // delivery — once In's enrichment finished — and scrolled the
                // list back to the selected message, undoing the anchored
                // position the refresh had just restored.
                //
                // Costs two id arrays on a mailbox that may hold 22,515 rows;
                // negligible beside the sort and the 22,515 dictionary inserts
                // `setRows` does on the line above.
                //
                // And when the list was parked at its end, the end wins over the
                // selection. Both want `pendingRevealRow`, which holds one row,
                // and whichever is written last takes it — today that is the
                // selection, silently, by arriving second. Stated deliberately
                // instead: a displaced selection is still findable and still
                // selected, whereas losing the end of the list is the whole
                // symptom this exists to remove. Without this, opening a
                // date-sorted mailbox parked at its end scrolls back to the
                // selection a second or two later, and the bounds observer then
                // records that mid-list position — so one visit silently costs
                // the mailbox its bottom-ness.
                if self.rows.map(\.id) != before {
                    if self.selectedMailboxWasAtBottom, !self.rows.isEmpty {
                        self.reveal(row: self.rows.count - 1)
                    } else {
                        self.keepSelectionVisible()
                    }
                }
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
            row.whoSort = e.whoSort
            row.direction = e.direction
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

    // MARK: identity (the "me" set behind the Who column)

    /// The addresses (and whole-domain rules) that are *me*. Drives the Who
    /// column's other-party + direction resolution. Loaded once at launch;
    /// edited from Settings, which re-lists the open mailbox on each change.
    @Published var me: MeIdentity = MeIdentityStore.load()

    /// Add an exact address ("s@x.com") or a domain rule ("*@musanim.com").
    /// Returns false if it wasn't a usable entry, or was already present.
    @discardableResult
    func addMyIdentity(_ raw: String) -> Bool {
        guard me.insert(raw) else { return false }
        persistAndReapplyIdentity()
        return true
    }

    /// Remove an exact address, or a domain rule (pass "@musanim.com").
    func removeMyIdentity(_ entry: String) {
        guard me.remove(entry) else { return }
        persistAndReapplyIdentity()
    }

    /// Seed from the Out mailbox, where every `From` is me. Returns how many new
    /// addresses were added (0 if Out is missing or held nothing new).
    @discardableResult
    func rescanOutForMyIdentity() -> Int {
        guard let store, let out = base(ofType: .outbox) else { return 0 }
        let before = me.addresses.count
        me.formUnion(store.senderAddresses(at: out))
        let added = me.addresses.count - before
        if added > 0 { persistAndReapplyIdentity() }
        return added
    }

    /// Persist the set, then re-list the open mailbox so its Who column reflects
    /// the change immediately (an in-flight enrichment is cancelled and redone).
    private func persistAndReapplyIdentity() {
        MeIdentityStore.save(me)
        if selectedMailboxID != nil { loadListing(force: true) }
    }

    // MARK: display helpers

    // Who + direction now come from `CorrespondentResolver` (EudoraStore), which
    // replaced this class's old `correspondent`/`displayName` helpers — the
    // per-mailbox "outgoing" guess became a per-message identity test. The
    // resolver keeps the one copy of `displayName`.

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

        // `primaryMessageID`, not `selectedMessageID`. A multi-selection used to
        // preview nothing and show "N messages selected" instead — Mail's
        // convention. But the whole point of ⇧-arrowing through a run of mail is
        // to look at each message as it joins the selection, and a count cannot
        // be looked at. The primary follows the moving end of the extension (see
        // `applyMessageSelection`), so this shows the message just added.
        //
        // Deliberately only the preview. Reply, Forward and mark-as-read still
        // go through `selectedMessageID` and so still refuse a multi-selection:
        // showing a message is safe, acting on one of several is the thing the
        // design decision was actually protecting against.
        guard let store,
              let mid = selectedMailboxID,
              let item = itemsByID[mid], !item.isFolder,
              let index = primaryMessageID else {
            preview = nil
            isLoadingPreview = false
            return
        }

        preview = nil
        isLoadingPreview = true

        let base = item.base
        let root = store.root
        let note = listingSource

        // **By byte offset, not by row index.** `message(at:index:)` reads the
        // entire `.mbx` and scans it for record boundaries, because an index is a
        // position in that list and there is no other way to find one — 613 MB
        // per keystroke on Trash. The row already carries the offset (from the
        // TOC, so it is there before enrichment), and `message(at:offset:)` seeks
        // straight to it and reads a few kilobytes. `loadFindPreview` has always
        // done this; the main preview had no pressing reason to until ⇧-arrow
        // started previewing every row it passes over.
        //
        // The offset is validated on the other side — the reader returns nil
        // unless a record actually starts there — so a stale row can only fail to
        // render, never render the middle of some other message.
        //
        // Falls back to the index path when the row can't be found, which keeps
        // this working for any caller that sets a primary the current `rows`
        // don't contain.
        let row = rowPositionByID[index].flatMap { pos in pos < rows.count ? rows[pos] : nil }
        let offset = row?.offset
        // The listing's date, for a message that carries none of its own — every
        // message Eudora 7 composed. See `MessagePreview.supplyDateIfMissing`.
        let cachedDate = row?.date ?? ""
        if Self.diagnoseSelection {
            print("loadMessage: primary \(index)  offset \(offset as Any)")
        }

        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: selectionSettleDelay)
            guard !Task.isCancelled else { return }

            let rendered = await Task.detached(priority: .userInitiated) { () -> RenderedMessage? in
                let found = offset.flatMap { store.message(at: base, offset: $0) }
                    ?? store.message(at: base, index: index)
                guard let msg = found else { return nil }
                var preview = AppModel.render(msg.part,
                                              sourceNote: note,
                                              locator: AttachmentLocator(mailRoot: root))
                // Read here, on the same background hop, rather than lazily when
                // the toggle is switched on: the read is bounded and cheap
                // (offset-addressed, stops at the blank line), and doing it now
                // keeps the toggle a pure view change. Fetching on demand would
                // put a mailbox read on the main actor behind a menu item.
                preview.rawHeaders = store.rawHeaderBlock(at: base,
                                                          offset: msg.record.offset,
                                                          length: msg.record.length) ?? ""
                preview.supplyDateIfMissing(cachedDate)
                return RenderedMessage(preview: preview, offset: msg.record.offset)
            }.value

            guard !Task.isCancelled, let self else {
                if Self.diagnoseSelection { print("loadMessage: cancelled before render landed") }
                return
            }
            if Self.diagnoseSelection {
                print("loadMessage: rendered offset \(rendered?.offset as Any)")
            }
            self.preview = rendered?.preview
            self.isLoadingPreview = false
            if let offset = rendered?.offset { self.rememberSelection(messageOffset: offset) }
        }
    }


    // MARK: - the Find window's own preview

    /// The message shown in the Find window's preview pane.
    ///
    /// Deliberately separate from `preview`, which belongs to the main window's
    /// selection. Sharing one would mean that arrowing through search results
    /// silently rewrote what the main window was showing — and the reverse, that
    /// clicking in the main window blanked the result you were reading.
    @Published var findPreview: MessagePreview?
    @Published var isLoadingFindPreview = false
    private var findPreviewTask: Task<Void, Never>?

    /// Render a search hit for the Find window's pane, without touching the main
    /// window's selection, listing or preview.
    ///
    /// Addressed by byte offset rather than by row index: a search hit carries an
    /// offset, and resolving it to an index means scanning the mailbox — the
    /// expensive step `openHit` has to take because it must *select* the row.
    /// Reading for display needs no index at all.
    func loadFindPreview(for hit: SearchHit) {
        findPreviewTask?.cancel()

        guard let store, let item = itemsByID[hit.mailbox], !item.isFolder else {
            findPreview = nil
            isLoadingFindPreview = false
            return
        }

        findPreview = nil
        isLoadingFindPreview = true

        let base = item.base
        let root = store.root
        let offset = hit.offset
        let cachedDate = hit.date

        findPreviewTask = Task { [weak self] in
            // The same settle delay the main preview uses, and for the same
            // reason: holding an arrow key down the results list must not queue
            // one full message read per row.
            try? await Task.sleep(nanoseconds: selectionSettleDelay)
            guard !Task.isCancelled else { return }

            let rendered = await Task.detached(priority: .userInitiated) { () -> MessagePreview? in
                guard let msg = store.message(at: base, offset: offset) else { return nil }
                var preview = AppModel.render(msg.part,
                                              sourceNote: "search",
                                              locator: AttachmentLocator(mailRoot: root))
                preview.rawHeaders = store.rawHeaderBlock(at: base,
                                                          offset: msg.record.offset,
                                                          length: msg.record.length) ?? ""
                // The hit carries the index's date — same gap, same fill.
                preview.supplyDateIfMissing(cachedDate)
                return preview
            }.value

            guard !Task.isCancelled, let self else { return }
            self.findPreview = rendered
            self.isLoadingFindPreview = false
        }
    }

    /// Nothing selected in the results table.
    func clearFindPreview() {
        findPreviewTask?.cancel()
        findPreview = nil
        isLoadingFindPreview = false
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
                                  misleadingLinks: rendered.misleadingLinks,
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

    // MARK: mailto: links from outside the app

    /// A `mailto:` that arrived before the app was ready to compose one.
    ///
    /// Clicking a `mailto:` while Eudora is closed launches it *with* the URL,
    /// and the URL is delivered well before the mailbox tree is open — so
    /// `beginCompose` would have nowhere to pre-save the draft and the window
    /// would open carrying an error about Out. Holding it for a moment and
    /// letting the normal launch sequence drain it costs nothing and makes the
    /// cold-launch case behave exactly like the warm one.
    /// An array rather than one optional: two links can arrive together (a
    /// `mailto:` clicked twice, or several handed over at launch), and the
    /// second silently replacing the first would be a message the user asked
    /// for and never saw.
    private var pendingMailtos: [MailtoLink] = []

    /// Whether a draft can be opened *and* saved right now. `rootURL` is set by
    /// `open(_:)`, so this is false through the whole of launch until a tree is
    /// actually open — which is the case the pending list exists for.
    private var canCompose: Bool { presentDraftWindow != nil && rootURL != nil }

    /// A `mailto:` link, from a browser or any other app.
    func handleMailto(_ url: URL) {
        guard let link = MailtoLink.parse(url) else { return }
        pendingMailtos.append(link)
        drainPendingMailtos()
    }

    /// Open a composer for every link that has been waiting.
    ///
    /// Called from three places, all of which are "something just became true":
    /// a link arrived, the tree finished opening at launch, and a folder was
    /// opened by hand. The last is what stops a link being stranded forever when
    /// Eudora launches with no remembered folder — `openDefaultIfAvailable` can
    /// leave `rootURL` nil, and without that third call the click would do
    /// nothing, say nothing, and never come back.
    func drainPendingMailtos(announcingIfBlocked: Bool = false) {
        guard !pendingMailtos.isEmpty else { return }
        guard canCompose else {
            // Only the launch drain announces. Everywhere else this is the
            // ordinary "not yet" and saying so would be noise — but a link that
            // arrives when there is no folder to save a draft into, and no
            // prospect of one, would otherwise vanish without a word.
            if announcingIfBlocked {
                showBanner("A mailto: link is waiting — open a Eudora folder and "
                           + "the message will open.")
            }
            return
        }
        // The splash is a floating panel and sits above everything, including a
        // new compose window, so it has to come down first.
        //
        // The cost is deliberate and worth naming: on a cold launch driven by a
        // mailto, this clears `splashHeldForRestore`, so the main window is
        // revealed with an empty message list under the restored mailbox for as
        // long as that listing takes. That flag exists precisely to hide that
        // moment. Showing it is the lesser evil — the alternative is a compose
        // window the user asked for, sitting invisibly behind the splash.
        if SplashWindow.isShowing {
            splashHeldForRestore = false
            SplashWindow.hide()
        }
        // A window opened into a hidden app appears nowhere, so activate.
        //
        // Deliberately *not* `AppDelegate.revealWindows()`, which also
        // un-minimises every window it can find. That is right for a Dock click,
        // which means "show me Eudora"; clicking a link in a browser means
        // "write this one message", and should not restore windows the user
        // minimised on purpose. The new compose window arrives on its own.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        let links = pendingMailtos
        pendingMailtos = []
        for link in links { beginCompose(draft(from: link)) }
    }

    private func draft(from link: MailtoLink) -> ComposeDraft {
        var draft = ComposeDraft()
        draft.to = recipientField(link.to)
        draft.cc = recipientField(link.cc)
        draft.subject = link.subject
        draft.body = link.body
        // Say what was dropped rather than dropping it silently. A link asking
        // for a Bcc is the case that matters: the composer doesn't show that
        // field prominently, so a recipient added this way could go out unseen.
        if !link.ignoredFields.isEmpty {
            let fields = link.ignoredFields.sorted().joined(separator: ", ")
            draft.openError = "This link also tried to set: \(fields). "
                + "Eudora ignored those — a link from a web page may not choose "
                + "who a message is secretly copied to, or who it claims to be from."
        }
        return draft
    }

    /// Join parsed recipients into the comma-separated string the composer's To
    /// and Cc fields hold.
    ///
    /// A display name containing a comma — `"Doe, Jane" <j@x>` — is reduced to
    /// its bare address on the way in. The parser goes to some trouble to keep
    /// such a name intact (the comma is percent-encoded precisely so it is not a
    /// separator), but `splitAddresses` re-splits this field on every comma
    /// without regard for quoting, so preserving the name here would hand the
    /// composer two broken recipients instead of one good one. Losing a display
    /// name is cosmetic; losing the address is not.
    ///
    /// Only rescues the `Name <addr>` form. A bare `Doe, Jane` with no address
    /// at all is malformed input the parser deliberately admits rather than
    /// swallows, and it still splits in two — visibly, in a field the user reads
    /// before sending.
    private func recipientField(_ addresses: [String]) -> String {
        addresses.map { address -> String in
            guard address.contains(","),
                  let open = address.lastIndex(of: "<"),
                  let close = address.lastIndex(of: ">"),
                  open < close else { return address }
            return String(address[address.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: ", ")
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
        // Default the From line to the account's own identity, unless the caller
        // already set one (a resend keeps the original's). Set before the record
        // is written so the pre-saved draft carries it too. Built raw, not through
        // `formatAddress`, so the editable field shows a human-readable name
        // rather than an RFC-2047-encoded one; assembly re-encodes as needed.
        if draft.from.isEmpty {
            let name = accounts?.account.fromName ?? ""
            let addr = accounts?.account.fromAddress ?? ""
            draft.from = name.isEmpty ? addr : "\(name) <\(addr)>"
        }
        // Fixed now and never regenerated — this is the draft's identity for the
        // rest of its life. `OutgoingMessage.generatedMessageID` builds one from
        // the From domain, so it needs the account, but falls back sensibly.
        draft.messageID = OutgoingMessage(
            fromName: "", fromAddress: accounts?.account.fromAddress ?? "",
            to: [], subject: "", body: "").generatedMessageID()
        do {
            draft.outOffset = try appendDraftRecord(draft)
        } catch {
            // Appended, not assigned: a draft built from a mailto: link may
            // already carry a note about fields the link tried to set, and that
            // is exactly the case where losing it would matter most.
            let note = "Couldn't put this message in Out: "
                + describe(error)
                + " It can still be written and sent; it just isn't saved yet."
            draft.openError = draft.openError.map { $0 + " " + note } ?? note
        }
        openDrafts[draft.id] = draft
        presentDraftWindow?(draft.id)
    }

    /// A compose window has closed. The record in Out stays; only the editing
    /// session ends.
    func closeDraft(_ id: ComposeDraft.ID) {
        openDrafts.removeValue(forKey: id)
        composeLiveState.removeValue(forKey: id)
    }

    // MARK: - unsaved-changes review on Quit

    /// Each open compose window's live content and whether it has unsaved edits.
    ///
    /// **Deliberately not `@Published`.** `ComposeView` pushes here on every
    /// keystroke so a Quit can save the *current* text, and republishing that
    /// would re-render everything observing the model on every character typed
    /// in a compose window. The quit review is the only reader, and it runs on
    /// the main thread like every writer, so a plain dictionary is right.
    private var composeLiveState: [ComposeDraft.ID: (draft: ComposeDraft, isDirty: Bool)] = [:]

    /// `ComposeView` reporting its live state. See `composeLiveState`.
    func noteComposeLiveState(_ draft: ComposeDraft, isDirty: Bool) {
        composeLiveState[draft.id] = (draft, isDirty)
    }

    /// Ask about every compose window with unsaved edits before the app quits,
    /// and say whether the quit may proceed.
    ///
    /// Run synchronously from `applicationShouldTerminate` (via the closure
    /// `AppDelegate.onQuit`), which is why it uses modal `NSAlert`s rather than
    /// SwiftUI dialogs: it has to return a verdict on the same call, and
    /// `runModal()` gives that while the compose windows' own SwiftUI Save prompt
    /// couldn't. Each dirty window is brought to the front so the prompt names
    /// the message it's about.
    ///
    /// The three answers mirror the compose window's own Close prompt: Save
    /// writes the live content to Out, Discard Changes drops them (removing a
    /// never-saved shell, or reverting to the last saved version), Cancel stops
    /// the quit outright.
    @MainActor
    func reviewComposeBeforeQuit() -> NSApplication.TerminateReply {
        // A stable order so the prompts don't jump around between runs.
        let dirtyIDs = composeLiveState
            .filter { $0.value.isDirty }
            .keys
            .sorted { ($0.uuidString) < ($1.uuidString) }
        guard !dirtyIDs.isEmpty else { return .terminateNow }

        for id in dirtyIDs {
            guard let state = composeLiveState[id] else { continue }
            presentDraftWindow?(id)

            let subject = state.draft.subject.trimmingCharacters(in: .whitespaces)
            let alert = NSAlert()
            alert.messageText = "Save changes to \u{201C}"
                + (subject.isEmpty ? "New Message" : subject) + "\u{201D} before quitting?"
            alert.informativeText = "If you don\u{2019}t save, your changes will be lost."
            alert.addButton(withTitle: "Save")             // .alertFirstButtonReturn
            alert.addButton(withTitle: "Cancel")            // .alertSecondButtonReturn
            alert.addButton(withTitle: "Discard Changes")   // .alertThirdButtonReturn

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    try saveComposeLive(id)
                } catch {
                    let fail = NSAlert()
                    fail.messageText = "Couldn\u{2019}t save this message."
                    fail.informativeText = describe(error)
                    fail.addButton(withTitle: "OK")
                    fail.runModal()
                    // Don't quit over a message that couldn't be saved — the
                    // user would lose it with no way back.
                    return .terminateCancel
                }
            case .alertThirdButtonReturn:
                discardComposeChanges(id)
            default:
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    /// Save a compose window's live content to Out, refreshing the record's
    /// location from the model first (as `ComposeView.currentDraft` does, and
    /// for the same reason: an earlier save may have moved it).
    private func saveComposeLive(_ id: ComposeDraft.ID) throws {
        guard var draft = composeLiveState[id]?.draft else { return }
        if let live = openDrafts[id] { draft.outOffset = live.outOffset }
        let saved = try saveDraft(draft)
        composeLiveState[id] = (saved, false)
    }

    /// Drop a compose window's unsaved edits, mirroring the Close prompt's
    /// Don't Save: a never-saved draft's record is the empty shell written on
    /// open, so it goes; a saved one reverts to its last saved version, which is
    /// already what sits in Out.
    private func discardComposeChanges(_ id: ComposeDraft.ID) {
        guard let state = composeLiveState[id] else { return }
        if !state.draft.hasBeenSaved { discardDraft(state.draft) }
        composeLiveState[id] = (state.draft, false)
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
        // HTML only when the user styled something. `styledBody` is nil for an
        // unstyled draft, so `htmlBody` stays nil and `rfc822` takes its
        // original single-part path — the message is byte-for-byte what it was
        // before rich text existed. See `OutgoingMessage.htmlBody`.
        let html = draft.styledBody.map { RichTextHTML.html(from: $0) }
        // The From line the user set (defaulted from the account in
        // `beginCompose`); split back into name + address for assembly. Falls
        // back to the account address only if somehow empty.
        let fromLine = draft.from.isEmpty ? (accounts?.account.fromAddress ?? "") : draft.from
        let (fromName, fromAddress) = OutgoingMessage.splitFrom(fromLine)
        let message = OutgoingMessage(
            fromName: fromName,
            fromAddress: fromAddress,
            to: splitAddresses(draft.to),
            cc: splitAddresses(draft.cc),
            bcc: splitAddresses(draft.bcc),
            subject: draft.subject,
            body: draft.body,
            htmlBody: html,
            attachments: draft.attachments,
            inReplyTo: draft.inReplyTo,
            references: draft.references)
        // The draft's own ID, every time — that's what makes the record
        // identifiable across saves. See `ComposeDraft.messageID`.
        //
        // Empty maps to nil, not to an empty header: `rfc822` writes whatever
        // non-nil value it is handed, and a literal `Message-ID: ` would parse
        // back as "" and defeat the identity check for good.
        //
        // `includeBcc: true` — this is a *local* Out record (an unsent or
        // send-failed draft), so it keeps the Bcc the way a sent message does;
        // only the copy transmitted to recipients omits it. See `SMTPClient.send`.
        return message.rfc822(messageID: draft.messageID.isEmpty ? nil
                                                                 : draft.messageID,
                              includeBcc: true).data
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
    /// **Bcc survives.** The local Out record keeps its `Bcc:` header — only the
    /// copy sent to recipients omits it (see `SMTPClient.send` and
    /// `draftBytes(_:)`, which passes `includeBcc: true`) — so reopening reads the
    /// blind recipients back into the composer. A draft written by an older build,
    /// before that fix, has no stored `Bcc:` and reopens without one.
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

        // A styled draft was written as multipart/alternative with an HTML
        // part; rebuild the styled body from it so reopening restores the
        // formatting rather than flattening it to plain text. `styledBody` is
        // set only when the HTML actually carries styling — a message that
        // happens to be MIME but formats nothing reopens as a plain draft, and
        // so re-saves to today's plain bytes. When there's no HTML part this is
        // nil and everything behaves as it did before rich text.
        let styled = Self.styledBody(of: part)

        var draft = ComposeDraft(
            from: HeaderDecoder.decode(part.header("From") ?? ""),
            to: HeaderDecoder.decode(part.header("To") ?? ""),
            cc: HeaderDecoder.decode(part.header("Cc") ?? ""),
            bcc: HeaderDecoder.decode(part.header("Bcc") ?? ""),
            subject: HeaderDecoder.decode(part.header("Subject") ?? ""),
            body: styled?.plainText ?? Self.plainText(of: part),
            styledBody: styled,
            inReplyTo: part.header("In-Reply-To")?.trimmingCharacters(in: .whitespaces),
            references: (part.header("References") ?? "")
                .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init))
        draft.outOffset = msg.record.offset
        draft.hasBeenSaved = true
        // Pull any attachment parts back into the composer — set before the
        // Message-ID stamping below, so the record it may rewrite keeps them.
        draft.attachments = Self.draftAttachments(from: part)

        let existingID = part.header("Message-ID")?.trimmingCharacters(in: .whitespaces) ?? ""
        if existingID.isEmpty {
            // Some drafts arrive with no Message-ID, and this app's identity
            // check needs one. Without it `locateDraft` fails closed, every save
            // appends another copy, and the count grows without bound.
            //
            // This used to say real Eudora stamps Message-ID only at send time,
            // so a draft it wrote never has one. Not true: a Eudora 7 draft from
            // 2026jul13 in Stephen's Out carries
            // `<7.1.0.9.2.20260713192152.04400040@musanim.com>` — its version
            // number and a timestamp. Which is why this branch tests
            // `existingID.isEmpty` rather than assuming; the assumption was
            // wrong and the code was right anyway.
            //
            // Note what those drafts *don't* carry: a `Date:` header, which
            // Eudora 7 does stamp only at send. So an old draft shows no date in
            // the reader, and the only record of when it was written is the
            // timestamp inside that Message-ID.
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

    /// Whether a listed message (by row id) was successfully sent — the gate the
    /// context menu uses to offer "Send Again".
    func isSentMessage(_ id: MessageRow.ID) -> Bool {
        guard let pos = rowPositionByID[id], pos < rows.count else { return false }
        return rows[pos].isSent
    }

    /// Open a fresh copy of an already-sent message in the composer — same
    /// recipients, subject and body (styling included), ready to send again.
    ///
    /// Unlike `reopenDraft`, this does *not* touch the original record: it goes
    /// through `beginCompose`, which writes a brand-new draft into Out, so the
    /// sent message is left exactly as it was. Works from whatever mailbox the
    /// sent message is filed in — it only reads it. Threading headers
    /// (In-Reply-To / References) are carried across so the resend sits in the
    /// same conversation the original did.
    ///
    /// Bcc comes back too: the local Out copy keeps its `Bcc:` header (only the
    /// copy sent to recipients omits it — see `SMTPClient.send`), so a message
    /// sent with the current build carries its blind recipients into the resend.
    /// A message sent by an older build predating that fix has no stored `Bcc:`,
    /// so for those the `bcc:` line simply resolves to empty.
    func sendAgain(messageIndex: Int) {
        guard let store,
              let mid = selectedMailboxID, let item = itemsByID[mid], !item.isFolder,
              let msg = store.message(at: item.base, index: messageIndex) else { return }
        let part = msg.part
        let styled = Self.styledBody(of: part)
        beginCompose(ComposeDraft(
            from: HeaderDecoder.decode(part.header("From") ?? ""),
            to: HeaderDecoder.decode(part.header("To") ?? ""),
            cc: HeaderDecoder.decode(part.header("Cc") ?? ""),
            bcc: HeaderDecoder.decode(part.header("Bcc") ?? ""),
            subject: HeaderDecoder.decode(part.header("Subject") ?? ""),
            body: styled?.plainText ?? Self.plainText(of: part),
            styledBody: styled,
            attachments: Self.draftAttachments(from: part),
            inReplyTo: part.header("In-Reply-To")?.trimmingCharacters(in: .whitespaces),
            references: (part.header("References") ?? "")
                .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)))
    }

    /// The attachment parts of a parsed message, as composer attachments with
    /// decoded bytes — the reopen/Send-Again inverse of `rfc822`'s multipart/mixed
    /// assembly.
    nonisolated static func draftAttachments(from part: MIMEPart) -> [OutgoingMessage.Attachment] {
        var result: [OutgoingMessage.Attachment] = []
        var i = 0
        for p in part.walk() where !p.isMultipart && p.isAttachment {
            i += 1
            let name = sanitizedFilename(p.filename) ?? "attachment-\(i)"
            result.append(.init(filename: name, mimeType: p.contentType,
                                data: Data(p.decodedPayload())))
        }
        return result
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

    /// Offer a clicked link to the default browser, after showing where it
    /// really goes.
    ///
    /// Design decision 1 said links display but never navigate, and the reason
    /// was that deceptive link text is the classic phishing move. That reason
    /// still holds — which is why this shows the **true destination**, host
    /// first, every time, rather than trusting a check to decide for you. A
    /// dialog you only see when something is wrong is a dialog you will click
    /// through on the day something is wrong.
    ///
    /// Reputation is deliberately not checked here. Handing the URL to the
    /// browser *is* the reputation check: Safari and Chrome both consult Safe
    /// Browsing before rendering, and Safari proxies it through Apple so the
    /// address never reaches Google. Doing it in-app would be worse on privacy,
    /// add a network dependency to a client that has none, and duplicate work
    /// that is already in the path. What this does instead is the part a browser
    /// cannot do, because it never sees the message: judge whether the URL is
    /// built to deceive.
    func openLinkFromMessage(_ raw: String) {
        let assessment = LinkSafety.assess(raw, familiarDomains: familiarDomains())

        if let refusal = assessment.refusal {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Eudora won't open this link."
            switch refusal {
            case .unsupportedScheme(let scheme):
                // Naming the application is far more use than naming the
                // scheme: "this would open Terminal" is a sentence anyone can
                // act on, and this is the one category where a click can do
                // something to the Mac rather than show a page.
                let app = NSWorkspace.shared
                    .urlForApplication(toOpen: URL(string: raw) ?? URL(fileURLWithPath: "/"))
                    .map { FileManager.default.displayName(atPath: $0.path) }
                alert.informativeText = "It uses the “\(scheme)” scheme"
                    + (app.map { ", which would open \($0)" } ?? "")
                    + ". Only web and mail links are opened from a message.\n\n\(raw)"
            case .deceptiveCredentials:
                alert.informativeText = "The part before the “@” in this address is not "
                    + "the site it goes to — it's decoration, and the real destination is "
                    + "after it. That has no honest use in mail.\n\n\(raw)"
            case .malformed:
                alert.informativeText = "It isn't a usable address.\n\n\(raw)"
            }
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Copy Link")
            if alert.runModal() == .alertSecondButtonReturn { copyToPasteboard(raw) }
            return
        }

        // The mismatch between what the link *said* and where it goes. Noted at
        // render time (`RenderedBody.misleadingLinks`) because that is the only
        // moment both are visible, and put first here because it is the
        // strongest signal in the dialog: everything else describes the URL,
        // this one describes an intent to mislead.
        var notes: [String] = []
        if let claimed = preview?.misleadingLinks[raw] {
            notes.append("This link's text says it goes to “\(claimed)”, "
                         + "but it goes to “\(assessment.host)”.")
        }
        notes += assessment.warnings.map(Self.describe)

        let alert = NSAlert()
        alert.alertStyle = notes.isEmpty ? .informational : .critical
        alert.messageText = notes.isEmpty
            ? "Open \(assessment.host)?"
            : "This link may not be what it looks like."
        var body = notes.joined(separator: "\n\n")
        if !body.isEmpty { body += "\n\n" }
        body += raw
        alert.informativeText = body
        // "Open" is not the default button. Return should not open a link.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open in Browser")
        alert.addButton(withTitle: "Copy Link")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
        case .alertThirdButtonReturn:
            copyToPasteboard(raw)
        default:
            break
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showBanner("Link copied: \(text)")
    }

    private static func describe(_ warning: LinkSafety.Warning) -> String {
        switch warning {
        case .credentialsInURL:
            return "The address hides its real destination behind an “@”."
        case .punycodeHost:
            return "The site's name is encoded, which is how a name that *looks* "
                + "like a familiar one is written when it uses letters from another "
                + "alphabet."
        case .mixedScriptHost:
            return "The site's name mixes alphabets — letters that look like ordinary "
                + "ones but aren't."
        case .ipAddressHost:
            return "It goes to a numeric address rather than a named site."
        case .familiarNameAsLabel(let known):
            return "It contains “\(known)”, but that is not where it goes — the real "
                + "site is the end of the name, not the beginning."
        case .lookAlike(let known):
            return "The name is one or two characters away from “\(known)”, which you "
                + "do correspond with. This one is not it."
        }
    }

    /// Domains the user demonstrably deals with, for the look-alike test.
    ///
    /// Taken from the recently-used recipients, which is a real record of who
    /// Stephen writes to and costs nothing to read. Deliberately *not* derived
    /// from the whole archive: the search index stores sender and recipient
    /// header values as text, so building a domain histogram would mean parsing
    /// 232,000 rows on a link click.
    ///
    /// The consequence, and it is a real gap: this knows the domains he *writes
    /// to*, not the ones that write to him — so a look-alike of a bank he has
    /// never emailed won't be caught. Closing it properly means a `domains`
    /// column in the index, populated at rebuild.
    private func familiarDomains() -> Set<String> {
        var out = Set<String>()
        func add(_ address: String) {
            guard let bare = EmailAddress.bareAddress(address),
                  let at = bare.lastIndex(of: "@") else { return }
            let host = String(bare[bare.index(after: at)...])
            if !host.isEmpty { out.insert(LinkSafety.registrableDomain(host)) }
        }
        // Entries are "Name <addr>" as typed, so they go through the same
        // address parser the Who column uses rather than being split by hand.
        for entry in recentRecipients.entries.prefix(200) { add(entry) }
        for address in me.addresses { add(address) }
        for domain in me.domains { out.insert(LinkSafety.registrableDomain(domain)) }
        return out
    }

    /// A mailbox this correspondent's mail has been filed into before.
    struct FilingSuggestion: Identifiable, Equatable {
        let id: MailboxItem.ID
        /// The readable path — "PEOPLE ▸ G ▸ Greg Sandow".
        let path: String
        let count: Int
    }

    /// Where the selected messages' correspondents have been filed before, most
    /// used first.
    ///
    /// The point of this is that a Transfer menu over a real Eudora tree is
    /// thousands of mailboxes deep, and the answer is almost always one of two
    /// or three. Filing is by *person*, so the useful question isn't "where do
    /// you want this" but "where does this person's mail go" — and the archive
    /// has answered that thousands of times already.
    ///
    /// Addresses from all selected messages are merged into one query and the
    /// counts summed, so a mixed selection yields a single ranking rather than
    /// several competing ones.
    ///
    /// Costs one bounded read per selected message (offset and length come from
    /// the listing) plus one indexed query. Nothing here reads a whole `.mbx`.
    func filingSuggestions() -> [FilingSuggestion] {
        // Not while a Find is running. `SearchIndex` is `@unchecked Sendable` on
        // the stated grounds that its one SQLite connection is never used from
        // two threads at once, and `runSearch` moved the search to a detached
        // task — so querying here at the same time is exactly what that
        // invariant forbids. It would also block the main thread for the length
        // of the search, with a menu half-open.
        guard !isSearching, let index = searchIndex,
              let sel = currentSelectionSet() else { return [] }
        // Sampled, not surveyed. This runs synchronously while the menu is
        // opening, and every extra message costs a file read plus a parse; a
        // 500-message selection would hold the menu shut for a visible moment to
        // refine a ranking that the first twenty already settle.
        let chosen = rows.filter { selectedMessageIDs.contains($0.id) }.prefix(20)
        guard !chosen.isEmpty, let store else { return [] }

        // Every address in From/To/Cc that isn't me. Not `CorrespondentResolver`,
        // which answers "whose name goes in the Who column" — one party, for
        // display. Here every counterparty is a legitimate filing hint, and a
        // message addressed to two people may well belong in either's mailbox.
        var addresses = Set<String>()
        /// The raw bytes, kept so the body can be scanned if the headers turn
        /// out to name nobody but the user. Read once either way.
        var bodies: [String] = []
        for row in chosen {
            // 32 KB, not `row.size`. Only the headers are wanted, and reading
            // the record whole means a message with a 20 MB attachment costs
            // tens of megabytes of reading, copying and MIME-parsing to extract
            // three header lines. `MIMEParser.splitHeaderBody` is internal to
            // EudoraStore and can't be reached from here, so bounding the read
            // is the available way to bound the work.
            guard let raw = store.rawMessage(at: sel.item.base, offset: row.offset,
                                             length: min(row.size, 32_768)) else { continue }
            let part = MIMEParser.parse([UInt8](raw))
            // Latin-1, which cannot fail: this is only ever scanned for
            // addresses, which are ASCII, and a message whose encoding we
            // guessed wrong should still give up the addresses inside it.
            bodies.append(String(raw.map { Character(UnicodeScalar($0)) }))
            for field in ["From", "To", "Cc"] {
                // `addresses(in:)` already returns bare addresses — it is
                // `splitList` followed by `bareAddress` — so no second pass.
                for address in EmailAddress.addresses(in: part.header(field) ?? "") {
                    if me.matches(headerValue: address) { continue }
                    addresses.insert(address)
                }
            }
        }
        // Capped for the same reason as the message count above: query cost
        // grows with the number of OR'd phrases, and a wide selection can reach
        // hundreds of addresses. It also limits the damage from a *stale* "me"
        // — an old address of Stephen's that isn't in the identity set yet gets
        // treated as a correspondent, and it matches a large fraction of the
        // archive, which would otherwise turn the ranking into "every mailbox,
        // biggest first".
        func query(_ set: Set<String>) -> [SearchIndex.FilingCount] {
            guard !set.isEmpty else { return [] }
            return (try? index.mailboxesFiledInto(addresses: Array(set.prefix(25)))) ?? []
        }

        var counts = query(addresses)

        // Fall back to addresses found in the *body* when the headers got us
        // nowhere.
        //
        // The case this exists for: a message where every header party is the
        // user. A forward to yourself, or a note to self — `From: stephen@…`,
        // `To: stephen@…` — leaves nothing after the "me" filter, so nothing is
        // asked and no suggestions appear at all. But the person such a message
        // is *about* is usually right there in the quoted headers a forward
        // carries in its body.
        //
        // A fallback rather than an addition, and the asymmetry is deliberate.
        // The index side stays filtered to `sender`/`recipients`, so a hit
        // always means "correspondence with this person lives here". Matching
        // bodies there would make it mean "some message here mentions this
        // person", and every quoted thread, mailing-list footer and signature
        // block names people who have nothing to do with where that mail
        // belongs — noise that would systematically favour big mailboxes full
        // of long threads. Asking about a body address is fine; *answering*
        // from one is not.
        //
        // Only when the header attempt produced nothing, so a case that works
        // today cannot be made worse by it.
        if counts.isEmpty {
            var fromBody = Set<String>()
            for body in bodies {
                for address in EmailAddress.scan(inText: body) {
                    if me.matches(headerValue: address) { continue }
                    fromBody.insert(address)
                }
            }
            counts = query(fromBody)
        }
        return counts.compactMap { hit in
            // Dropped rather than shown when the mailbox no longer exists: the
            // index is a snapshot and a mailbox may have been renamed or deleted
            // since. Also drops the mailbox the messages are already in — moving
            // something to where it already is isn't a suggestion.
            guard hit.mailbox != selectedMailboxID,
                  let item = itemsByID[hit.mailbox], !item.isFolder else { return nil }
            return FilingSuggestion(id: hit.mailbox,
                                    path: readablePath(of: hit.mailbox),
                                    count: hit.count)
        }
    }

    /// A mailbox id rendered as its display path, for a menu label.
    ///
    /// Shares `selectedMailboxPath`'s reasoning — ids are filename paths, and
    /// `_GOVERNMENT.fol` is not what to put in front of someone — but takes an
    /// arbitrary id rather than the selection.
    private func readablePath(of id: MailboxItem.ID) -> String {
        var names: [String] = []
        var prefix = ""
        for component in id.split(separator: "/") {
            prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
            // Falling back to the raw component keeps this honest if a prefix
            // ever fails to resolve — better an odd-looking filename than a
            // silently shortened path that names the wrong mailbox.
            names.append(itemsByID[prefix]?.display ?? String(component))
        }
        return names.joined(separator: " ▸ ")
    }

    /// Forward the selected message as an `.eml` attachment rather than as
    /// quoted text.
    ///
    /// What this is for: reporting. Abuse desks, ISPs and fraud reporting
    /// services all ask for the original *as an attachment*, because an ordinary
    /// forward keeps only the body — the headers that say where a message
    /// actually came from are thrown away by the forwarding, and pasted text
    /// could have been typed by anyone. The attached bytes are the ones that
    /// arrived.
    ///
    /// Nothing is quoted into the body: the recipient is going to open the
    /// attachment, and a quoted copy above it is just a second, worse version of
    /// the same evidence. The body is left empty for whatever the user wants to
    /// say about it.
    func forwardAsAttachment() {
        guard let store, let sel = currentSelectionSet() else {
            showError("Select a message to forward.")
            return
        }
        // Taken from `rows` rather than from the selection set, so the
        // attachments arrive in the order the user sees them rather than in
        // whatever order a `Set` iterates.
        let chosen = rows.filter { selectedMessageIDs.contains($0.id) }

        var attachments: [OutgoingMessage.Attachment] = []
        var firstSubject = ""
        var takenNames = Set<String>()
        for row in chosen {
            // `row.offset` and `row.size` are the record's own offset and
            // length, straight from the listing — so this is one seek and one
            // bounded read per message. Deliberately *not* `message(at:index:)`,
            // which reads and scans the whole `.mbx` for each call: on Trash
            // that would be 613 MB per selected message, on the main actor.
            guard let raw = store.rawMessage(at: sel.item.base,
                                             offset: row.offset,
                                             length: row.size) else { continue }
            // Parsed from the bytes already in hand, not re-read from disk. The
            // `.toc`'s cached subject would have done for a filename, but it is
            // Latin-1 and truncated to 63 characters, and this costs no I/O.
            let subject = HeaderDecoder.decode(
                MIMEParser.parse([UInt8](raw)).header("Subject") ?? "")
            if firstSubject.isEmpty { firstSubject = subject }
            attachments.append(
                OutgoingMessage.Attachment(
                    filename: Self.uniqueFilename(Self.emlFilename(for: subject),
                                                  taken: &takenNames),
                    // **`application/octet-stream`, not `message/rfc822`, and
                    // this is deliberate — don't "fix" it.**
                    //
                    // `message/rfc822` is the obvious type and it is the wrong
                    // one here, because `MessageBuilder` base64-encodes every
                    // attachment. RFC 2046 §5.2.1 permits only 7bit, 8bit or
                    // binary on a `message/*` part, and parsers enforce that in
                    // the worst possible way: Python's `email` package — which
                    // most abuse-desk and ISP intake scripts are built on — sees
                    // `maintype == "message"` and recursively parses the payload
                    // *without* applying the transfer encoding. The base64 blob
                    // becomes a nested "message" of gibberish headers, and the
                    // report arrives containing nothing usable. Apple Mail
                    // mishandles it too, showing an attachment that opens empty.
                    //
                    // Base64 itself is not negotiable: the store holds LF-only
                    // and 8-bit messages, and embedding those verbatim invites
                    // an MTA to rewrite the line endings — corrupting the
                    // evidence in exactly the way attaching the original was
                    // meant to prevent.
                    //
                    // So: an opaque type, which *requires* base64, so every
                    // parser decodes it and gets the bytes back octet-for-octet.
                    // The `.eml` extension is what tells Mail, Thunderbird and
                    // Outlook to open it as a message. The cost is a file icon
                    // rather than an inline attached-message preview, which is a
                    // fair trade for a report that can be read at the other end.
                    mimeType: "application/octet-stream",
                    data: raw))
        }
        guard !attachments.isEmpty else {
            showError("Couldn't read "
                      + (chosen.count == 1 ? "that message" : "those messages")
                      + " from the mailbox.")
            return
        }

        // One message keeps its own subject, which is what makes a single
        // forward read naturally. Several get a count instead: a subject naming
        // one of four messages is worse than no subject at all, because it
        // reads as a report about that one.
        let subject: String
        if attachments.count == 1 {
            subject = firstSubject.lowercased().hasPrefix("fwd:")
                ? firstSubject : "Fwd: \(firstSubject)"
        } else {
            subject = "Fwd: \(attachments.count) messages"
        }
        var draft = ComposeDraft(
            subject: subject,
            // A line of body rather than nothing. An empty body with a single
            // binary attachment is a shape spam filters score badly — a poor way
            // for a report about a scam to be discarded — and it gives the user
            // somewhere to start typing.
            body: attachments.count == 1
                ? "The original message is attached.\n\n"
                : "The original messages are attached.\n\n")
        draft.attachments = attachments
        beginCompose(draft)
    }

    /// A filename not already used by another attachment on this draft.
    ///
    /// Needed because the names come from *subjects*, and the messages worth
    /// forwarding together are exactly the ones likely to share one — four
    /// rounds of the same phishing run arrive as four "Your account has been
    /// suspended". Without this they would all be `Your account…​.eml`, and a
    /// recipient saving them to a folder would keep one.
    private static func uniqueFilename(_ name: String, taken: inout Set<String>) -> String {
        guard taken.contains(name) else {
            taken.insert(name)
            return name
        }
        let stem = name.hasSuffix(".eml") ? String(name.dropLast(4)) : name
        var n = 2
        while taken.contains("\(stem) (\(n)).eml") { n += 1 }
        let unique = "\(stem) (\(n)).eml"
        taken.insert(unique)
        return unique
    }

    /// A filename for the attached original: the subject, made safe, or a
    /// fallback. Ends in `.eml`, which is what tells the recipient's client to
    /// open it as a message — the MIME type deliberately doesn't say so.
    ///
    /// **ASCII only**, which matters more here than for a dragged-in file.
    /// `MessageBuilder` runs filenames through RFC 2047 encoded-word encoding,
    /// and encoded-words are not legal in a MIME `name=` parameter (RFC 2231 is
    /// the mechanism for that). Most clients decode them anyway as a
    /// compatibility hack; a strict one shows the user a literal
    /// `=?utf-8?B?…?=`. Ordinary attachments rarely have non-ASCII names, but
    /// this name comes from a *subject line* — and scam subjects are non-ASCII
    /// more often than not.
    private static func emlFilename(for subject: String) -> String {
        let cleaned = subject
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\r\n\t"))
            .joined(separator: " ")
            .filter { $0.isASCII }
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "Forwarded message" : String(cleaned.prefix(60))
        return base + ".eml"
    }

    /// Build a forward from the selected message.
    ///
    /// The quoted message keeps its formatting — font, size, colour, bold,
    /// italic, the whole of what the composer can hold — carried across as
    /// editable runs, with the "Forwarded message" header lines plain on top.
    /// Anything richer in the source (links, images, tables) flattens, because
    /// the model can't represent it. A forward of an unstyled message stays
    /// plain and so still assembles to today's `text/plain` bytes.
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
        let combined = RichText(runs: [RichTextRun(intro)] + Self.styledText(of: part).runs)
        var draft = ComposeDraft(
            subject: subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)",
            body: combined.plainText)
        draft.styledBody = combined.isStyled ? combined : nil
        beginCompose(draft)
    }

    private func selectedPart() -> MIMEPart? {
        guard let store,
              let mid = selectedMailboxID,
              let item = itemsByID[mid], !item.isFolder,
              let idx = selectedMessageID,
              let msg = store.message(at: item.base, index: idx) else { return nil }
        return msg.part
    }

    // MARK: blacklist a sender

    /// The bare From address of the selected message, for the blacklist prompt.
    func selectedSenderAddress() -> String? {
        guard let part = selectedPart() else { return nil }
        let (_, address) = OutgoingMessage.splitFrom(part.header("From") ?? "")
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Blacklist the selected message's sender. The caller has already confirmed
    /// (this is the point of no return): send the notice reply, add the address to
    /// the blacklist queue, and delete the message. The ISP-side blacklisting
    /// Stephen does by hand, from Tools ▸ Blacklist….
    func blacklistSelectedSender() {
        guard let part = selectedPart() else { return }
        let origFrom = part.header("From") ?? ""
        let (_, address) = OutgoingMessage.splitFrom(origFrom)
        let addr = address.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty else { return }

        sendBlacklistNotice(to: origFrom, address: addr, about: part)

        // Then bin it. Blacklisting a sender and keeping their message is not a
        // combination Stephen has ever wanted, so this saves the second gesture.
        //
        // **After the notice, and that order is load-bearing.**
        // `sendBlacklistNotice` lifts the headers, assembles the reply and quotes
        // the body *before* its `Task` suspends — it never captures `part` at all
        // — so the send holds a finished message and cannot be disturbed by the
        // row going away. Deleting first would build the notice from a message
        // that no longer sits where the selection says it does.
        //
        // **Before queuing the address**, which is the other half of the
        // ordering. `addToBlacklistQueue` takes only a `String` and never
        // touches the message, so it is free to come last — and last is where it
        // belongs, because it raises a banner and the delete's own feedback
        // should not be talked over.
        //
        // **Unconditional, even if the notice failed to send.** The mail is
        // unwanted either way, the address is on the list either way, and the
        // error banner still says what went wrong. This is the same
        // `deleteSelected` the menu's Delete calls, so the message goes to Trash
        // — and, exactly as with Delete, blacklisting something already *in*
        // Trash removes it for good. That consistency is the point; a special
        // case here would be the surprise. The confirmation says so.
        deleteSelected()

        addToBlacklistQueue(addr)
    }

    /// Auto-send the "you've been blacklisted" reply to the sender.
    private func sendBlacklistNotice(to origFrom: String, address: String, about part: MIMEPart) {
        guard let accounts, accounts.account.isConfigured, !accounts.password.isEmpty else {
            showError("Couldn't send the blacklist notice — set up your SMTP account in Settings first. "
                      + "The address was still added to your blacklist, and the message "
                      + "was still deleted.")
            return
        }
        let subject = HeaderDecoder.decode(part.header("Subject") ?? "")
        let msgID = part.header("Message-ID")?.trimmingCharacters(in: .whitespaces)
        var refs = (part.header("References") ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if let m = msgID { refs.append(m) }

        // Stephen's line on top, two blank lines, then the sender's own message
        // left in place below it.
        let body = "I've added \(address) to my email blacklist.\r\n\r\n" + Self.plainText(of: part)

        let account = accounts.account
        let password = accounts.password
        let message = OutgoingMessage(
            fromName: account.fromName, fromAddress: account.fromAddress,
            to: [origFrom], cc: [], bcc: [],
            subject: subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)",
            body: body, htmlBody: nil,
            inReplyTo: msgID, references: refs)

        Task {
            do {
                let sent = try await SMTPClient.send(message, account: account, password: password)
                // File a copy in Trash (not Out — a blacklist notice is disposable
                // by nature), addressed to whoever it went to.
                fileBlacklistCopyInTrash(raw: sent.raw, who: origFrom, subject: message.subject)
                showBanner("Blacklist notice sent to \(address).")
            } catch {
                showError("The blacklist notice to \(address) didn't send: " + describe(error)
                          + " (The address was still added to your blacklist, and the "
                          + "message was still deleted.)")
            }
        }
    }

    /// File a copy of the just-sent blacklist notice in Trash, marked sent.
    private func fileBlacklistCopyInTrash(raw: Data, who: String, subject: String) {
        guard let trash = base(ofType: .trash) else {
            showError("Sent the blacklist notice, but this folder has no Trash to file a copy in.")
            return
        }
        do {
            _ = try Outbox.append(messageData: raw, to: trash,
                                  status: MailboxMutator.statusSent, who: who, subject: subject)
            refreshTrashIfShowing()
        } catch {
            showError("Sent the blacklist notice, but couldn't file a copy in Trash: " + describe(error))
        }
    }

    /// Re-list Trash if it's the mailbox on screen (mirrors `refreshOutIfShowing`).
    ///
    /// **Does nothing while a removal veil is up**, and that guard is not
    /// optional politeness. Blacklisting now deletes the message too, so this
    /// arrives seconds later, in the middle of the delete's own relist. Without
    /// the guard, `loadListing` drops the veil and clears the rows — so the list
    /// goes blank exactly when the veil exists to stop that, the in-flight
    /// listing task is cancelled, and with it the completion that restores the
    /// scroll position. On a 22,000-row Trash that is a blank several seconds
    /// long ending somewhere other than where you were.
    ///
    /// Skipping the refresh costs nothing: the veil's own relist is already
    /// re-reading this mailbox, and the notice copy is a disposable message that
    /// can wait for the next listing. The unconditional `reloadTree()` is inside
    /// the guard for the same reason — republishing 6,699 sidebar nodes on the
    /// main actor while a listing's continuation is queued behind it is the
    /// contention `afterRemoval` measured at four seconds.
    private func refreshTrashIfShowing() {
        guard removalVeil == nil else { return }
        reloadTree()
        if let id = selectedMailboxID, itemsByID[id]?.type == .trash {
            loadListing(force: true)
        }
    }

    /// Add the address to the pending blacklist, and say where it went.
    ///
    /// It used to append to `~/email_blacklist.txt` and open that file in
    /// TextEdit. That put the app and a text editor on one file: blacklist a
    /// second sender while TextEdit holds the first with unsaved edits — which is
    /// what happens, since the drain is edit-then-cut-then-save — and TextEdit
    /// finds its document both modified and stale and refuses to save. The list
    /// lives in the app now; see `BlacklistQueue`.
    ///
    /// The banner carries the count because nothing opens any more: it is the
    /// only standing sign that addresses are waiting.
    private func addToBlacklistQueue(_ address: String) {
        if blacklistQueue.add(address) {
            showBanner("\(address) added to your blacklist — "
                       + "\(blacklistQueue.count) waiting (Tools ▸ Blacklist…).")
        } else {
            showBanner("\(address) was already on your blacklist.")
        }
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
        // `RichTextHTML.parse`, not a tag stripper.
        //
        // This used to walk the HTML dropping anything between `<` and `>`,
        // which removes the tags and leaves everything else exactly as written —
        // so a quoted reply came out full of `that&#39;s` and `&amp;` and
        // `&nbsp;`. Entities are not tags; nothing here was decoding them.
        //
        // The parser that does it properly was already in the project and
        // already used by Forward, which is why forwarding an HTML message read
        // correctly and replying to the same message did not. It also gets the
        // line structure right — `<br>` and `<p>` become real breaks instead of
        // the single space the stripper substituted for every tag, which is what
        // made long quotes arrive as one unbroken paragraph.
        return RichTextHTML.parse(h).plainText
    }

    /// The styled body of a draft record, or nil when it carries no styling.
    ///
    /// Reopening a draft this app wrote as `multipart/alternative` should
    /// restore the formatting, not flatten it. This finds the `text/html`
    /// alternative, parses it back to `RichText`, and returns it **only if it is
    /// actually styled** — an HTML part that formats nothing (or a record with
    /// no HTML part at all) yields nil, so the reopened draft is plain and
    /// re-saves to today's plain-text bytes rather than needlessly staying MIME.
    ///
    /// Restricted to a genuine `multipart/alternative`. A received message
    /// Eudora flattened into a lone `text/html` leaf (the `<x-html>` form) is
    /// somebody else's mail being forwarded/edited, not a draft of ours, and its
    /// arbitrary markup is not something the composer should try to round-trip —
    /// `plainText(of:)` flattens it instead.
    static func styledBody(of part: MIMEPart) -> RichText? {
        // A styled draft that also carries attachments is multipart/mixed with the
        // alternative nested one level down — descend to it, so reopening such a
        // draft recovers its formatting instead of flattening to plain text.
        if part.contentType == "multipart/mixed",
           let alt = part.children.first(where: { $0.contentType == "multipart/alternative" }) {
            return styledBody(of: alt)
        }
        guard part.contentType == "multipart/alternative" else { return nil }
        for p in part.walk() where !p.isMultipart && p.mainType == "text" && p.subType == "html" {
            let text = CharsetDecoder.smartDecode(p.decodedPayload(), declared: p.charset).text
            let rich = RichTextHTML.parse(text)
            return rich.isStyled ? rich : nil
        }
        return nil
    }

    /// A message's body as editable `RichText`, for forwarding.
    ///
    /// Unlike `styledBody(of:)` this is *not* gated on the message being one of
    /// our own drafts, and not on there being any styling: forwarding carries a
    /// received message's formatting across whatever its source. It prefers the
    /// HTML alternative (or a flattened `<x-html>` leaf) and parses it back to
    /// runs — recovering font, size, colour, bold and italic, dropping the rest
    /// — and falls back to the plain text when there is no HTML part. The
    /// tolerant `RichTextHTML.parse` is exactly the same reader that reopens a
    /// draft, so it copes with arbitrary foreign markup without throwing.
    static func styledText(of part: MIMEPart) -> RichText {
        var htmlText: String?
        var plain: String?
        for p in part.walk() where !p.isMultipart && !p.isAttachment && p.mainType == "text" {
            let text = CharsetDecoder.smartDecode(p.decodedPayload(), declared: p.charset).text
            if p.subType == "html" {
                if htmlText == nil { htmlText = text }
            } else if plain == nil {
                plain = text
            }
        }
        if let htmlText { return RichTextHTML.parse(htmlText) }
        return RichText(plain: plain ?? "")
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

    // MARK: recently-used recipients (To/Cc/Bcc auto-fill)

    private static let recentRecipientsKey = "recentRecipients"
    private var recentRecipients = RecentRecipients(
        entries: UserDefaults.standard.stringArray(forKey: AppModel.recentRecipientsKey) ?? [])

    /// Auto-fill matches for the token being typed in a recipient field, most
    /// recently used first.
    func recipientCompletions(prefix: String) -> [String] {
        recentRecipients.matches(prefix: prefix)
    }

    /// Record the addresses a message was just sent *to* — only To feeds the
    /// list, by design — bumping each to the front, and persist.
    func recordSentRecipients(_ recipients: [String]) {
        guard !recipients.isEmpty else { return }
        // Record back-to-front so `record`'s insert-at-front leaves the To field's
        // left-to-right order intact — the first-listed recipient ends up most
        // recent, not least.
        for r in recipients.reversed() { recentRecipients.record(r) }
        UserDefaults.standard.set(recentRecipients.entries, forKey: Self.recentRecipientsKey)
    }

    /// Forget a recipient (the dropdown's Delete action), and persist.
    func removeRecentRecipient(_ recipient: String) {
        recentRecipients.remove(recipient)
        UserDefaults.standard.set(recentRecipients.entries, forKey: Self.recentRecipientsKey)
    }

    // MARK: the user's own auto-correction list

    private static let correctionsKey = "textCorrections"
    /// Published so the Settings list reflects edits live. Typing in the composer
    /// only *reads* this (via `correctionReplacement`), so it never re-renders.
    @Published private var textCorrections = AppModel.loadCorrections()

    private static func loadCorrections() -> TextCorrections {
        guard let data = UserDefaults.standard.data(forKey: correctionsKey),
              let decoded = try? JSONDecoder().decode(TextCorrections.self, from: data)
        else { return TextCorrections() }
        return decoded
    }

    private func persistCorrections() {
        if let data = try? JSONEncoder().encode(textCorrections) {
            UserDefaults.standard.set(data, forKey: Self.correctionsKey)
        }
    }

    /// The correction for a just-completed word, or nil — the editor's hook.
    func correctionReplacement(for word: String) -> String? {
        textCorrections.replacement(for: word)
    }

    /// Add or update a correction (right-click quick-add and Settings), persist.
    func addCorrection(trigger: String, replacement: String) {
        if textCorrections.set(trigger: trigger, replacement: replacement) {
            persistCorrections()
        }
    }

    /// Forget a correction (Settings' delete), persist.
    func removeCorrection(trigger: String) {
        textCorrections.remove(trigger: trigger)
        persistCorrections()
    }

    /// The rules, in order, for the Settings list.
    var correctionRules: [TextCorrections.Rule] { textCorrections.rules }

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
            let (nodes, outboxUnsent, inboxNewestUnread) =
                await Task.detached(priority: .userInitiated) {
                // All off the main thread: the tree walk, the Out scan for the
                // unsent badge (it lists Out's TOC, which is cheap but still I/O,
                // so it has no business on the main actor), and the one-record In
                // read behind the new-mail badge.
                let nodes = store.tree()
                return (nodes,
                        Self.outboxHasUnsent(in: nodes, store: store),
                        Self.inboxNewestIsUnread(in: nodes, store: store))
            }.value
            PerfLog.mark("tree walk done: \(nodes.count) roots")
            guard let self else { return }
            self.treeReloadInFlight = false
            // A different tree may have been opened while this walked. Installing
            // it would put the old folder's mailboxes in the sidebar — the same
            // failure `cancelBackgroundWork` guards against for listings.
            guard self.treeReloadGeneration == generation else { return }
            let items = Self.buildItems(nodes, prefix: "", outboxUnsent: outboxUnsent)
            let shape = Self.shapeSignature(items)
            let identity = Self.identitySignature(items)
            // **These four assignments must stay in one synchronous block.**
            // The sidebar's `.id(treeIdentityVersion)` only protects it if
            // SwiftUI observes the new tree and the new identity in a single
            // update; deferring the bump by so much as a runloop hop would let
            // the new data render under the old identity, which is a diff of a
            // restructured outline — the thing that crashed. See `MailboxTree`.
            self.tree = items
            // In the same block as the tree it was computed from, so the badge and
            // the row it sits on can never disagree by a frame.
            self.inboxHasNewMail = inboxNewestUnread
            self.treeVersion &+= 1
            // Only when the shape actually moved. Hashing 6,699 ids costs
            // microseconds; rebuilding the Move menus costs half a second.
            if shape != self.treeShape {
                self.treeShape = shape
                self.treeStructureVersion &+= 1
            }
            // Updated inside the `if`, like the shape, so the second walk of a
            // coalesced pair sees the same identity and doesn't rebuild twice.
            if identity != self.treeIdentity {
                self.treeIdentity = identity
                self.treeIdentityVersion &+= 1
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

    /// Whether the selection sits in Trash, where `deleteSelected` removes for
    /// good rather than moving.
    ///
    /// Exists so the blacklist confirmation can name the actual fate of the
    /// message instead of saying "delete" and meaning two different things. Reads
    /// the same `currentSelectionSet` the delete itself will read, so the two
    /// can't disagree about which branch is coming.
    var selectionIsInTrash: Bool { currentSelectionSet()?.item.type == .trash }

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

    /// Clear the unread flag on the message the user has just selected.
    ///
    /// Waits out `selectionSettleDelay` — the same 150 ms the preview waits —
    /// and is cancelled by the next selection, so running down the list with the
    /// arrow keys marks only the message you come to rest on, not every one you
    /// pass. Without that, holding an arrow key through fifty unread messages
    /// would be fifty status writes and fifty tree reloads.
    ///
    /// Only for a single selection, and that justification has weakened. It used
    /// to be airtight — shift-clicking twenty rows displayed none of them, so
    /// none had been read. A multi-selection now previews its primary, so a
    /// message *is* on screen and stays marked unread.
    ///
    /// Left as it is on purpose, pending a decision rather than by oversight.
    /// ⇧-arrowing through fifty messages to pick a few to file would otherwise
    /// mark all fifty read, and the unread flag is the more valuable of the two
    /// signals to keep honest. Extending it to the primary of a multi-selection
    /// is a one-line change here if that turns out to be the wrong call.
    private func scheduleMarkSelectedRead() {
        markReadTask?.cancel()
        markReadTask = nil
        // Nothing to do unless exactly one message is selected *and* it is
        // actually unread — checked here so the common case (clicking around
        // among messages already read) costs nothing at all. `selectedMessageID`
        // is nil for a multi-selection, which is the single-selection test.
        //
        // A draft can't pass this: status 9 and 5 both render as a blank glyph,
        // so `isUnread` is false for them and `markSelected`'s draft banner is
        // never reached from here. Clicking a draft stays silent, as it should.
        guard let index = selectedMessageID,
              let pos = rowPositionByID[index], pos < rows.count,
              rows[pos].isUnread else { return }
        let mailbox = selectedMailboxID
        markReadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: selectionSettleDelay)
            guard !Task.isCancelled, let self else { return }
            // Re-checked after the wait: the selection, the rows and the mailbox
            // can all have moved on while it slept. The mailbox especially —
            // `openHit` assigns `selectedMailboxID` directly and its cancelling
            // `loadListing` arrives a runloop hop later, so for that moment an
            // index from the old mailbox is paired with the new one's base URL.
            // Writing then would mark an unrelated message read, in the wrong
            // file, silently.
            //
            // `listedMailboxID` is set when a load *starts*, not when its rows
            // arrive, so it doesn't prove the rows in hand belong to `mailbox`.
            // What does is the row re-check below: `loadListing` empties `rows`
            // in the same turn it reassigns `listedMailboxID`, so a switch
            // leaves nothing at `pos` to find.
            guard self.selectedMailboxID == mailbox,
                  self.listedMailboxID == mailbox,
                  self.selectedMessageID == index,
                  let pos = self.rowPositionByID[index], pos < self.rows.count,
                  self.rows[pos].isUnread else { return }
            self.markSelected(read: true)
        }
    }

    private var markReadTask: Task<Void, Never>?

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
            // Addressed by offset when the row is in hand, which is every case
            // that matters: the offset form never opens the `.mbx`, while the
            // index form reads and scans all of it to work the offset out. The
            // index fallback is only for a status write arriving before the
            // listing has landed.
            let newStatus = read ? MailboxMutator.statusRead : MailboxMutator.statusUnread
            if let pos = rowPositionByID[sel.index], pos < rows.count {
                try MailboxMutator.setStatus(base: sel.item.base,
                                             offset: rows[pos].offset, status: newStatus)
            } else {
                try MailboxMutator.setStatus(base: sel.item.base, index: sel.index,
                                             status: newStatus)
            }
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
                                       offset: r.offset,
                                       statusGlyph: read ? " " : MailStore.unreadGlyph,
                                       status: newStatus,
                                       priority: r.priority,
                                       label: r.label,
                                       size: r.size,
                                       subject: r.subject,
                                       who: r.who,
                                       whoSort: r.whoSort,
                                       direction: r.direction,
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
        do {
            // No completion notice on a delete: the rows sliding up to close
            // the gap is feedback enough that it worked, and a delete's
            // destination is never in question (Trash, or gone). A *move* still
            // gets one — see `moveSelected` — because that names a mailbox the
            // eye can't otherwise see it landed in. Failures still use the
            // banner: they're actionable and shouldn't auto-retire.
            if sel.item.type == .trash {
                try MailboxMutator.removeMany(base: sel.item.base, indices: sel.indices)
                afterRemoval(veil: "Deleting…")
            } else if let trash = base(ofType: .trash) {
                try MailboxMutator.moveMany(from: sel.item.base, indices: sel.indices, to: trash)
                afterRemoval(veil: "Deleting…")
            } else {
                try MailboxMutator.removeMany(base: sel.item.base, indices: sel.indices)
                afterRemoval(veil: "Deleting…")
            }
        } catch {
            showError("Delete failed: \(error.localizedDescription)")
        }
    }

    /// Remove the selected messages outright, from any mailbox — the command
    /// Delete already is *in Trash* and isn't anywhere else.
    ///
    /// Exists for triage: with 19,000 messages in Trash, the workable method is
    /// to move a manageable batch somewhere else and sort it out there. But
    /// Delete in a working mailbox moves to Trash, so everything you decided to
    /// destroy went straight back where it came from. This is the way out.
    ///
    /// **Confirmed, unlike Delete.** Not caution for its own sake: everywhere
    /// else in this app "delete" means "moved to Trash, recoverable", and this
    /// one command breaks that promise. Something that quietly destroys mail
    /// while wearing the same word deserves the one dialog. The count is in the
    /// message because ⇧-click makes a selection whose size is easy to
    /// misjudge — which is the whole point of using it for this job.
    ///
    /// The dangerous button is not the default, so Return cancels, matching the
    /// blacklist confirmation.
    func deletePermanentlySelected() {
        guard let sel = currentSelectionSet() else { return }
        let n = sel.indices.count

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = n == 1
            ? "Delete this message permanently?"
            : "Delete \(n) messages permanently?"
        alert.informativeText =
            "They will not go to Trash, and this can't be undone."
        let yes = alert.addButton(withTitle: n == 1 ? "Delete It" : "Delete Them")
        let cancel = alert.addButton(withTitle: "Cancel")
        yes.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        // At the pointer, not the middle of the screen — this is reached from a
        // right-click on a row, and the hand is already there. Same reasoning as
        // the context menu's centring (see `MessageContextMenu`): the axis that
        // matters is how far the eye and the hand have to travel.
        guard PointerAlert.runModal(alert) == .alertFirstButtonReturn else { return }

        do {
            try MailboxMutator.removeMany(base: sel.item.base, indices: sel.indices)
            // A notice here where an ordinary delete has none: the rows closing
            // is feedback that *something* happened, and the thing worth
            // confirming is which of the two deletes it was.
            afterRemoval(veil: "Deleting…",
                         notice: n == 1 ? "Message deleted permanently."
                                        : "\(n) messages deleted permanently.")
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
    /// says once the veil lifts (a move's "Moved to Family." and friends) —
    /// held here, not shown, until then. Nil for operations that need no
    /// word — a delete, where the closing gap is feedback enough — and the
    /// label spot simply clears when the veil lifts.
    private func afterRemoval(veil: String, notice: String? = nil) {
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
        // Worse than a leak if left: mailbox ids are path-derived, so a mailbox
        // re-created under the same name would inherit the old one's stuck flag
        // and open at its end for no reason anyone could trace.
        viewState.atBottomByMailbox[id] = nil
        viewState.selectedMessageOffsetByMailbox[id] = nil
        if viewState.selectedMailbox == id { viewState.selectedMailbox = nil }
        if let root = rootURL?.path { ViewStateStore.save(viewState, forRoot: root) }

        showBanner("Deleted mailbox \u{201C}\(item.display)\u{201D}.")
        reloadTree()
    }

    /// Sidebar right-click ▸ "Move to group": relocate this mailbox or folder
    /// into another folder (`destinationID`) or the tree root (`nil` = Top
    /// Level). `MailboxTreeMutator.moveInto` does the descmap.pce edits and the
    /// file move and refuses the illegal cases (system mailboxes, a folder into
    /// its own subtree, a name clash); here we resolve the directories, tear down
    /// a selection the move would strand, and rebuild.
    func moveIntoGroup(_ id: MailboxItem.ID, into destinationID: MailboxItem.ID?) {
        guard let item = itemsByID[id] else { return }
        let sourceDir = item.base.deletingLastPathComponent()
        let filename = descmapFilename(of: id)

        let destDir: URL
        let destName: String
        if let destinationID {
            guard let dest = itemsByID[destinationID], dest.isFolder else { return }
            destDir = dest.base            // a folder's base is its .fol directory
            destName = dest.display
        } else {
            guard let rootURL else { return }
            destDir = rootURL
            destName = "the top level"
        }

        let moved: Bool
        do {
            moved = try MailboxTreeMutator.moveInto(filename: filename, from: sourceDir, to: destDir)
        } catch {
            showError("Couldn't move \u{201C}\(item.display)\u{201D}: \(error.localizedDescription)")
            return
        }
        // Already there — nothing changed, so no teardown and no banner.
        guard moved else { return }

        // The move changes this item's id (its path prefix). If it — or, for a
        // folder, anything inside it — was on screen, that selection is about to
        // dangle; tear it down, as delete does. Its stale view-state keys are
        // left to linger harmlessly, keyed on ids nothing can select again.
        if let sel = selectedMailboxID, sel == id || sel.hasPrefix(id + "/") {
            beginMailboxSwitch()
            selectedMailboxID = nil
            listedMailboxID = nil
            selectMessage(nil)
        }

        showBanner("Moved \u{201C}\(item.display)\u{201D} to \(destName).")
        reloadTree()
    }

    // MARK: reordering & folder delete

    /// Whether this mailbox or folder can move up/down — i.e. there is a movable
    /// neighbour on that side. The menu greys the item out otherwise;
    /// `MailboxTreeMutator.moveEntry` is the authority and throws `.atBoundary`
    /// if the courtesy check is ever stale.
    func canMove(_ id: MailboxItem.ID, up: Bool) -> Bool {
        guard let item = itemsByID[id], Self.isMovable(item) else { return false }
        let siblings = siblingList(of: id)
        guard let idx = siblings.firstIndex(where: { $0.id == id }) else { return false }
        // Nearest movable neighbour, stepping over system mailboxes — mirroring
        // `MailboxTreeMutator.moveEntry`, which skips them rather than stopping.
        // The walk matters here for the same reason it does there: `siblingList`
        // reads the full tree, so a hidden Junk sitting in the middle of the file
        // would otherwise grey out a command that will in fact work.
        let step = up ? -1 : 1
        var n = idx + step
        while n >= 0, n < siblings.count, !Self.isMovable(siblings[n]) { n += step }
        return n >= 0 && n < siblings.count
    }

    /// Move a mailbox or folder one place within its group and re-list the tree.
    func moveTreeItem(_ id: MailboxItem.ID, up: Bool) {
        guard let item = itemsByID[id] else { return }
        let filename = descmapFilename(of: id)
        do {
            try MailboxTreeMutator.moveEntry(directory: item.base.deletingLastPathComponent(),
                                             filename: filename, direction: up ? .up : .down)
        } catch {
            showError("Couldn't move \u{201C}\(item.display)\u{201D}: \(error.localizedDescription)")
            return
        }
        reloadTree()
    }

    /// Sort the list this item sits in — its siblings — alphabetically.
    ///
    /// The level, not the item: right-clicking a folder sorts the folder's
    /// siblings, exactly as Move Up and Move Down move the folder among them.
    /// `sortFolderContents` is the separate command for what's *inside* a folder,
    /// named differently because it does a different thing.
    func sortSiblingsAlphabetically(_ id: MailboxItem.ID) {
        guard let item = itemsByID[id] else { return }
        sortEntries(in: item.base.deletingLastPathComponent(), what: "that list")
    }

    /// Sort what's inside a folder alphabetically.
    ///
    /// A folder's `base` *is* its `.fol` directory (see `MailStore.build`), so
    /// this is the same call with a different directory. The wording matters:
    /// "the contents of X" rather than "X", because the two menu items are one
    /// word apart and "Sorted “Projects”" would read like the other one.
    func sortFolderContents(_ id: MailboxItem.ID) {
        guard let item = itemsByID[id], item.isFolder else { return }
        sortEntries(in: item.base, what: "the contents of \u{201C}\(item.display)\u{201D}")
    }

    /// Shared by both sort commands.
    ///
    /// **There is no undo, and the `.bak` is not one.** `MailboxIO.backupOnce`
    /// copies only if no `.bak` exists yet, so by the time anyone sorts, some
    /// earlier create/rename/move has almost certainly consumed it and it holds
    /// an arbitrary older state rather than the order that was just replaced.
    /// Worth knowing before adding any other one-click rearrangement here.
    private func sortEntries(in directory: URL, what: String) {
        do {
            if try MailboxTreeMutator.sortEntries(directory: directory) {
                showBanner("Sorted \(what) alphabetically.")
                reloadTree()
            } else {
                // Said rather than silently doing nothing: a menu item that
                // appears to have been ignored is worse than one that reports it
                // had nothing to do.
                showBanner("\(what.prefix(1).uppercased())\(what.dropFirst()) was already in order.")
            }
        } catch {
            showError("Couldn't sort: \(error.localizedDescription)")
        }
    }

    /// A folder with nothing listed inside it. The menu's grey-out; the mutator
    /// makes the authoritative on-disk check (descmap empty *and* no stray
    /// `.mbx`/`.fol`), so a folder holding orphaned mail is refused there.
    func folderIsDeletablyEmpty(_ id: MailboxItem.ID) -> Bool {
        guard let item = itemsByID[id], item.isFolder else { return false }
        return item.children?.isEmpty ?? true
    }

    /// Sidebar right-click ▸ Delete for a folder — the parallel of
    /// `deleteMailbox`. Only ever reaches an empty folder (the menu gates it),
    /// and the mutator refuses one that isn't, so no mail is destroyed.
    func deleteFolder(_ id: MailboxItem.ID) {
        guard let item = itemsByID[id], item.isFolder else { return }
        let filename = descmapFilename(of: id)
        do {
            try MailboxTreeMutator.deleteEmptyFolder(directory: item.base.deletingLastPathComponent(),
                                                     filename: filename)
        } catch {
            showError("Couldn't delete folder \u{201C}\(item.display)\u{201D}: "
                + error.localizedDescription)
            return
        }
        showBanner("Deleted folder \u{201C}\(item.display)\u{201D}.")
        reloadTree()
    }

    /// Sidebar right-click ▸ Rename. Prompts for a new *display* name and
    /// rewrites the descmap line's first field; the physical `.mbx`/`.fol`
    /// filename — and therefore this id and every descendant id — is left
    /// untouched, so selection, saved view state, and folder children all
    /// survive the rename with no id churn. System mailboxes are refused: their
    /// role is resolved from the display name ("In"→inbox), so renaming one
    /// would demote it to an ordinary mailbox.
    func renameTreeItem(_ id: MailboxItem.ID) {
        guard let item = itemsByID[id], item.isFolder || item.type == .mailbox else { return }
        guard let newName = RenameDialog.run(currentName: item.display,
                                             isFolder: item.isFolder) else { return }
        let filename = descmapFilename(of: id)
        do {
            try MailboxTreeMutator.rename(directory: item.base.deletingLastPathComponent(),
                                          filename: filename, to: newName)
        } catch {
            showError("Couldn't rename \u{201C}\(item.display)\u{201D}: "
                + error.localizedDescription)
            return
        }
        reloadTree()
    }

    /// The descmap filename (second field, extension included) for a tree id —
    /// its last path component, since `buildItems` joins ids from exactly those.
    private func descmapFilename(of id: MailboxItem.ID) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// The siblings an item sits among in tree order: its parent's children, or
    /// the root-level items for a top-level entry.
    private func siblingList(of id: MailboxItem.ID) -> [MailboxItem] {
        if let slash = id.lastIndex(of: "/") {
            return itemsByID[String(id[..<slash])]?.children ?? []
        }
        return tree
    }

    /// A regular mailbox or a folder — anything but a pinned system mailbox.
    ///
    /// The complement of `MailboxTreeMutator.Group.system`, which is the
    /// authority. Mailboxes and folders intermix freely; kinds used to have to
    /// match, and see the note on that enum for why they no longer do.
    private static func isMovable(_ x: MailboxItem) -> Bool {
        x.isFolder || x.type == .mailbox
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
                               // A freshly made mailbox/folder is never Out and
                               // never unsent; the tree walk will confirm it.
                               hasUnsent: false,
                               children: asFolder ? [] : nil)
        itemsByID[id] = item
        reloadTree()
        return item
    }

    /// Mailbox ▸ New… and Mailbox ▸ New Group…: prompt for a name and create a
    /// mailbox or a group (folder) at the top level. It goes in at the top level
    /// (alongside In/Out/Trash, below the separator); to file it inside a group,
    /// use the sidebar's "Move to group" afterwards. Reuses the tested
    /// `createMailbox`, so the name validation and duplicate checks come along.
    func createTopLevel(asFolder: Bool) {
        guard let rootURL else {
            showError("Open a Eudora folder first.")
            return
        }
        let noun = asFolder ? "group" : "mailbox"
        let alert = NSAlert()
        alert.messageText = asFolder ? "New Group" : "New Mailbox"
        alert.informativeText = "Name for the new \(noun), created at the top level."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let created = createMailbox(named: name, inDirectory: rootURL,
                                       idPrefix: nil, asFolder: asFolder) {
            showBanner("Created \(noun) \u{201C}\(created.display)\u{201D}.")
        }
    }

    // MARK: receiving (POP3)

    /// Check mail: fetch new messages from **every** configured incoming account
    /// into the one In box, then — per account, and only where the user opted in
    /// — delete them from that server in a second pass, after they're safely
    /// written locally.
    ///
    /// Accounts are collected one at a time, and each succeeds or fails on its
    /// own: a server that is down, refusing the password, or simply slow must
    /// not cost the other accounts their mail. That is the whole reason the body
    /// below is a loop with the `do`/`catch` *inside* it rather than around it.
    ///
    /// - Parameter automatic: true for a timer-driven check (see
    ///   `configureAutoCheck`). An automatic check stays quiet — no error banner,
    ///   and no "No new mail" toast every interval — surfacing only actual new
    ///   mail (through the list and the sidebar glyph); a manual check reports
    ///   its outcome either way.
    func receiveMail(accounts: AccountStore, automatic: Bool = false) async {
        guard let inbox = base(ofType: .inbox) else {
            if !automatic { showError("No In mailbox in this tree.") }
            return
        }
        let ready = accounts.readyIncoming
        guard !ready.isEmpty else {
            if !automatic {
                showError(accounts.hasPartiallyConfiguredIncoming
                    ? "Incoming mail is only half set up — every account needs a server, "
                      + "a username and a password. Finish it in Settings ▸ Incoming mail, then Save."
                    : "No incoming mail accounts are set up. Add one in "
                      + "Settings ▸ Incoming mail, then Save.")
            }
            return
        }
        guard !isChecking else { return }
        isChecking = true
        checkMailNotice = nil        // spinner only, until this fetch resolves
        defer { isChecking = false }

        var received = 0
        /// Messages fetched, recognised as already in the In box, and discarded.
        /// Counted and reported rather than passed over in silence: the case
        /// this guard exists for is a mis-sequenced cut-over — Gmail polled
        /// directly while it is still forwarding into musanim — and a silent
        /// guard would hide exactly the misconfiguration the user needs to see.
        var duplicates = 0
        /// One entry per account that failed, as "user@host: reason". Collected
        /// rather than thrown so the accounts after it are still collected.
        var failures: [String] = []

        for entry in ready {
            let account = entry.account
            do {
                let known = accounts.knownUIDs(for: account)
                let fetched = try await POP3Client.fetchNew(account: account,
                                                            password: entry.password,
                                                            knownUIDs: known)
                var newKnown = known
                /// UIDs this account has finished with — delivered *or*
                /// recognised as duplicates. Both belong here: a duplicate that
                /// went unrecorded would be re-fetched and re-discarded on every
                /// check for as long as it sat on the server.
                var handled: [String] = []
                /// UIDs actually written to disk — the delete pass reads this,
                /// not `handled`, so a message discarded as a duplicate keeps
                /// its copy on the server.
                ///
                /// This is the one place the design could destroy mail rather
                /// than merely inconvenience the user: a false-positive
                /// duplicate that had also been deleted from the server would be
                /// gone from everywhere, with nothing to say it happened. The
                /// UID set already stops it being re-fetched, so leaving it
                /// there costs nothing but a little server-side clutter — and it
                /// keeps the guard non-destructive, which is what makes it safe
                /// to have switched on during a cut-over.
                var deliveredUIDs: [String] = []
                // Built here, not hoisted out of the account loop, and only when
                // something arrived. Per-account so the second account's batch is
                // checked against what the first one just delivered; skipped
                // entirely on an empty fetch so a quiet automatic check still
                // touches no disk. The scan is cheap next to the delivery it
                // guards — see `MessageIDIndex.init(scanning:)`.
                var seen = fetched.isEmpty ? MessageIDIndex() : MessageIDIndex(scanning: inbox)
                // On the way out of this scope by *any* route, including the
                // throw from `deliverIfNew` below. Whatever was written to
                // disk is recorded as downloaded, so a failure partway through a
                // batch can't leave already-delivered messages looking new and
                // deliver them a second time on the next check.
                // Guarded on something actually having been handled:
                // `newKnown` can only differ from `known` if it was, and
                // without the guard every idle account rewrote its whole UID
                // array to UserDefaults on every tick of a one-minute timer.
                defer {
                    if !handled.isEmpty { accounts.setKnownUIDs(newKnown, for: account) }
                }
                for msg in fetched {
                    // Counted here, per message, not as `fetched.count` after
                    // the loop: a throw partway through would skip that line and
                    // leave `received` at zero while messages were already on
                    // disk — so the In box wouldn't refresh and the sidebar
                    // glyph wouldn't light for mail that had genuinely arrived.
                    // A duplicate counts towards `duplicates`, never `received`:
                    // nothing was written, so there is nothing to refresh to.
                    switch try Delivery.deliverIfNew(messageData: msg.raw, to: inbox,
                                                     seen: &seen) {
                    case .delivered:
                        received += 1
                        deliveredUIDs.append(msg.uid)
                    case .duplicate:
                        duplicates += 1
                    }
                    newKnown.insert(msg.uid)
                    handled.append(msg.uid)
                    // Periodic checkpoint, for the one case the `defer` above
                    // can't cover: the process dying outright. Every 25 rather
                    // than every message because `setKnownUIDs` reads the whole
                    // dictionary, rebuilds an array from the set and
                    // re-serialises the plist — per message that is quadratic in
                    // the batch size. Invisible for a dozen messages, not
                    // invisible for the first sync of a long-untouched account,
                    // which is what adding a new server is. Worst case after a
                    // crash is 24 messages delivered twice.
                    if handled.count % 25 == 0 {
                        accounts.setKnownUIDs(newKnown, for: account)
                    }
                }

                // Delete pass — this account's setting, this account's server,
                // and only after every message from it is stored locally.
                // `deliveredUIDs`, not `handled`: a duplicate was never written
                // here, so deleting it would leave no copy anywhere if the guard
                // was wrong. See the declaration.
                if account.deleteAfterDownload, !deliveredUIDs.isEmpty {
                    try await POP3Client.delete(account: account,
                                                password: entry.password,
                                                uids: Set(deliveredUIDs))
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                failures.append("\(account.username)@\(account.host): \(reason)")
            }
        }

        // Nothing arrived, so nothing changes: no tree walk, no re-list, no
        // glyph. This guard *is* the fix for "the In box repaints on every
        // check" — the reload and the re-list below used to run unconditionally,
        // so a check that found nothing still blanked the list and drew it
        // again. A quiet automatic check must be invisible.
        if received > 0 {
            if let id = selectedMailboxID, itemsByID[id]?.type == .inbox {
                // In is on screen: fold the new mail into the list already
                // showing, without blanking it or moving it. (Reloads the tree
                // itself, once the rows are back.)
                refreshInPlaceAfterDelivery()
            } else {
                // In isn't on screen. Still nothing is *arranged* here — no
                // forced sort, no scroll written — because arriving mail is not
                // entitled to move a list the user positioned. The tree walk is
                // what lights In's unread indicator.
                //
                // Following the bottom needs nothing at this point either, which
                // is the nice property of storing bottom-ness rather than a row
                // index: if In was left at its end, `atBottomByMailbox` already
                // says so, and `loadListing` will reveal the last row whenever In
                // is next selected — by then including whatever arrived in the
                // meantime. A remembered top row would have needed fixing up
                // here, against a mailbox not on screen, on every delivery.
                reloadTree()
            }
            // Nothing lights the sidebar's new-mail glyph here, and nothing needs
            // to: both branches above reload the tree — one directly, one once its
            // rows are back — and the glyph is computed from In's newest message
            // during that walk (`inboxNewestIsUnread`).
            //
            // It used to be set explicitly, right here, which is what made it a
            // piece of session state and gave it two bugs to be found later. The
            // arriving message is unread and it is the newest, so the derived
            // value is already true; saying so twice is how the two copies got a
            // chance to disagree.
            //
            // Still deliberately *not* the same signal as the bold unread name:
            // bold means "In holds unread mail anywhere" and this means "In's most
            // recent message is unread".
        }

        report(received: received, duplicates: duplicates, failures: failures,
               accountCount: ready.count,
               skipped: accounts.partiallyConfigured.count, automatic: automatic)
    }

    /// The outcome of one Check Mail, across however many accounts it covered.
    ///
    /// A manual check always says something. An automatic one speaks only when
    /// mail actually arrived: a silent interval must stay silent, and a server
    /// that is briefly unreachable is not worth interrupting anyone over — it
    /// will be retried in a minute. That deliberately means a *persistently*
    /// broken account can go unnoticed while auto-check is on, which is the
    /// price of a quiet timer; a manual Check Mail is how you find out.
    /// - Parameter skipped: incoming accounts begun but not finished. They are
    ///   not failures — nothing was attempted — but they must be mentioned. The
    ///   case that matters is one working account plus one half-typed: without
    ///   this the new account is dropped in silence and the report says "No new
    ///   mail", which reads as "that server doesn't work" when the truth is
    ///   "you haven't finished setting it up".
    /// - Parameter duplicates: messages fetched and discarded because the In box
    ///   already held their `Message-ID`. This makes an automatic check speak
    ///   when it otherwise wouldn't, which is deliberate: the guard firing means
    ///   two sources are delivering the same mail, and during the Eudora 7
    ///   cut-over that is a misconfiguration to be seen and fixed rather than
    ///   quietly absorbed. A silent guard would let a wrongly-sequenced
    ///   cut-over look like everything was fine.
    private func report(received: Int, duplicates: Int, failures: [String],
                        accountCount: Int, skipped: Int, automatic: Bool) {
        if automatic && received == 0 && duplicates == 0 { return }

        let mail = received == 0
            ? "No new mail"
            : "Received \(received) message\(received == 1 ? "" : "s")"
        let dup = duplicates == 0 ? ""
            : " · \(duplicates) duplicate\(duplicates == 1 ? "" : "s") ignored"
        let note = dup + (skipped == 0 ? ""
            : " · \(skipped) account\(skipped == 1 ? "" : "s") not set up")

        guard !failures.isEmpty else {
            showCheckMailNotice(mail + note)
            return
        }
        // "Check mail failed" only when nothing at all arrived. A partial
        // failure — a delete pass that threw, or a delivery that broke partway
        // through a batch — leaves real mail in the In box, and saying the check
        // failed would contradict the messages the user can see and the glyph
        // that just lit.
        // `duplicates == 0` as well: a check that fetched mail, recognised it as
        // already held and then tripped over a failing delete pass did not fail
        // to check mail. It did its job and hit a snag afterwards.
        let summary = received == 0 && duplicates == 0 && failures.count == accountCount
            ? "Check mail failed"
            : "\(mail) · \(failures.count) of \(accountCount) "
              + "account\(accountCount == 1 ? "" : "s") failed"
        showCheckMailNotice(summary + note)
        if !automatic {
            // Headed to match the notice. Opening "Check mail failed:" when the
            // notice says "Received 3 messages · 1 of 2 accounts failed" is the
            // same contradiction the summary above exists to avoid.
            let heading = received == 0 && failures.count == accountCount
                ? "Check mail failed:"
                : "Check mail: \(failures.count) of \(accountCount) "
                  + "account\(accountCount == 1 ? "" : "s") failed:"
            showError(heading + "\n" + failures.joined(separator: "\n"))
        }
    }

    // MARK: automatic Check Mail

    private var autoCheckTimer: Timer?

    /// (Re)start or stop the automatic Check Mail timer from the incoming-mail
    /// settings. Idempotent — safe to call at launch and on every settings
    /// change; it tears down any existing timer first. Off unless enabled, and
    /// the interval is clamped to at least a minute (`AccountStore` clamps it on
    /// write too, but this is the last guard against a zero-interval timer).
    ///
    /// One timer for the app, not one per account: `receiveMail` collects every
    /// configured account on each tick. See `AccountStore.autoCheckEnabled`.
    ///
    /// Added to the run loop in `.common` mode so a check still fires while the
    /// user is scrolling or holding a menu open. The block hops to the main actor,
    /// reads the account handed over in `ContentView.onAppear` (`self.accounts`),
    /// skips when it isn't ready, and fetches as `automatic` so a quiet interval
    /// stays quiet.
    func configureAutoCheck() {
        autoCheckTimer?.invalidate()
        autoCheckTimer = nil
        guard let accounts, accounts.autoCheckEnabled else { return }
        // Check once right now, then on the interval: turning it on, changing the
        // interval, and launching with it on should all fetch immediately and
        // then start the clock. Silent (`automatic`), and skipped if the account
        // isn't ready or the In box isn't in the tree yet.
        if accounts.isReadyToReceive {
            Task { @MainActor [weak self] in
                guard let self, let accounts = self.accounts else { return }
                await self.receiveMail(accounts: accounts, automatic: true)
            }
        }
        let interval = TimeInterval(max(1, accounts.autoCheckMinutes)) * 60
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let accounts = self.accounts,
                      accounts.isReadyToReceive else { return }
                await self.receiveMail(accounts: accounts, automatic: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoCheckTimer = timer
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
            // **The existing index stays open and queryable.** It used to be
            // dropped here, and `rebuild` begins with `DELETE FROM messages`, so
            // between the two there was no index at all for the length of a
            // rebuild — Find returned nothing and Move To offered no filing
            // suggestions, silently. Worse, interrupting a rebuild (a crash, or
            // quitting while it ran) left the index *destroyed* rather than
            // stale, with nothing to say so.
            //
            // So the new one is built beside it and swapped in at the end. This
            // is the same discipline the mail files already follow — backup,
            // write to a temp, atomically replace — and the search index was the
            // last place still writing destructively in place.

            let scratch = path + ".new"
            // A leftover from a build that died: harmless, but starting from it
            // would mean appending to a half-finished index.
            try? FileManager.default.removeItem(atPath: scratch)

            // Heavy work off the main thread; awaiting keeps the UI responsive.
            let outcome = await Task.detached(priority: .userInitiated) { () -> (Int?, String) in
                do {
                    let idx = try SearchIndex(path: scratch)
                    // The `.toc` date parser, handed down because it lives here
                    // and the index target can't see it. Without it, every
                    // message Eudora 7 composed indexes with no sortable date.
                    try idx.rebuild(from: store,
                                    cachedDateEpoch: { cached in
                                        EudoraDateFormat.tocDate(cached)
                                            .map { Int($0.timeIntervalSince1970) } ?? 0
                                    }) { done, total in
                        Task { @MainActor [weak self] in
                            guard let self, self.indexGeneration == gen else { return }
                            self.indexProgress = IndexProgress(done: done, total: total)
                        }
                    }
                    // The count, not the index itself: the connection has to be
                    // closed before the file can be moved into place, and
                    // letting it die at the end of this scope is how that
                    // happens (`SQLiteDB.deinit` closes the handle).
                    return (try idx.count(), "Indexed \(try idx.count()) messages.")
                } catch {
                    return (nil, "Index error: \(error)")
                }
            }.value

            // Apply only if this build wasn't superseded by a newer one.
            guard self.indexGeneration == gen else {
                try? FileManager.default.removeItem(atPath: scratch)
                return
            }

            if outcome.0 != nil {
                // Close ours before replacing the file underneath it, then
                // reopen. The gap is a few milliseconds, against the minutes the
                // old code spent with no index at all.
                self.searchIndex = nil
                do {
                    _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                              withItemAt: URL(fileURLWithPath: scratch))
                    self.searchIndex = try SearchIndex(path: path)
                    self.searchStatus = outcome.1
                } catch {
                    // The old index is gone from memory but still on disk —
                    // reopening it is better than leaving the app with none.
                    self.searchIndex = try? SearchIndex(path: path)
                    self.searchStatus = "Index built but couldn't be installed: \(error)"
                }
            } else {
                // The build failed. The previous index was never touched, which
                // is the whole point of building beside it.
                try? FileManager.default.removeItem(atPath: scratch)
                self.searchStatus = outcome.1
            }
            self.isIndexing = false
            self.indexingPath = nil
            self.lastIndexBuilt = Date()
        }
    }

    // MARK: - Overnight rebuild

    /// Rebuild the index in the small hours, if the Mac has been left alone.
    ///
    /// The index is a snapshot: mail delivered since the last build isn't in it,
    /// so Find misses recent messages and a new correspondent gets no filing
    /// suggestions. Rebuilding is minutes of disk work on a 12 GB tree, which is
    /// why it isn't done on every delivery — but it is exactly the sort of thing
    /// that should happen while nobody is watching.
    @Published var autoRebuildIndex: Bool =
        UserDefaults.standard.bool(forKey: AppModel.autoRebuildKey) {
        didSet {
            guard autoRebuildIndex != oldValue else { return }
            UserDefaults.standard.set(autoRebuildIndex, forKey: Self.autoRebuildKey)
        }
    }
    private static let autoRebuildKey = "autoRebuildIndexOvernight"

    /// When the index was last built, so the overnight run happens once a night
    /// rather than every time the check fires during the small hours.
    private var lastIndexBuilt: Date?

    private var overnightTimer: Timer?

    /// The hour (local) to rebuild in, and how long the Mac must have been idle.
    private static let overnightHour = 3
    private static let requiredIdle: TimeInterval = 60 * 60

    /// Start watching for the overnight window. Called when a tree is opened.
    func startOvernightRebuildWatch() {
        overnightTimer?.invalidate()
        // Five minutes: the window is an hour wide, so nothing is missed, and an
        // idle check this cheap costs nothing.
        overnightTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.considerOvernightRebuild() }
        }
    }

    private func considerOvernightRebuild() {
        guard autoRebuildIndex, !isIndexing, !isSearching, let root = rootURL else { return }
        guard Calendar.current.component(.hour, from: Date()) == Self.overnightHour else { return }
        // Once a night. Without this the check would fire twelve times during
        // the 3 a.m. hour and start a rebuild each time the previous finished.
        if let last = lastIndexBuilt,
           Calendar.current.isDate(last, inSameDayAs: Date()) { return }

        // System-wide idle, not "idle in Eudora". The question is whether anyone
        // is at the Mac — someone working in another app at 3 a.m. would not
        // thank us for spending the disk on this. `secondsSinceLastEventType`
        // answers exactly that and needs no accessibility permission.
        let idle = CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= Self.requiredIdle else { return }

        startIndexing(for: root)
    }

    /// Menu/command "Rebuild Search Index".
    func rebuildIndex() {
        guard let rootURL else { showError("Open a Eudora folder first."); return }
        guard !isIndexing else { showBanner("Already indexing…"); return }
        showBanner("Rebuilding search index…")
        startIndexing(for: rootURL)
    }

    /// Run a Find query and publish the hits.
    /// True while a search is running, so the Find window can say so.
    ///
    /// This is only meaningful because the search moved off the main actor. It
    /// used to run there, synchronously, which meant the window was frozen for
    /// its duration — a "Searching…" label set beforehand could never be drawn,
    /// because SwiftUI had no turn in which to draw it. A busy indicator and a
    /// blocking call are mutually exclusive.
    @Published private(set) var isSearching = false

    /// Bumped per search, so a slow one finishing after a later one can't
    /// install its results over the newer ones.
    private var searchGeneration = 0

    func runSearch(_ query: SearchQuery) {
        // One at a time. The Search button disables itself while a search runs,
        // but `FindView` also fires this from `.onSubmit` on the query field, so
        // Return could otherwise start a second one over the first.
        //
        // This isn't only tidiness: `SearchIndex` is `@unchecked Sendable` on
        // the stated grounds that its one SQLite connection is "never touched
        // from two threads at once". Two searches in flight would be exactly
        // that. The running search can't be cancelled — `search` is a blocking
        // sqlite call — so the honest options are to refuse the new one or to
        // break that invariant, and refusing is cheap: searches are quick, and
        // the button visibly says why nothing happened.
        guard !isSearching else { return }
        guard let index = searchIndex else {
            searchResults = []
            searchStatus = "No index — open a Eudora folder, or Rebuild Index."
            return
        }
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        searchStatus = "Searching…"

        Task { @MainActor [weak self] in
            // The hits, or a message — not a `Result<_, Error>`: `Error` isn't
            // `Sendable`, and the error is only ever shown as text anyway.
            //
            // `index` is captured rather than read back off `self`: the
            // instance queried must be the one that existed when the search
            // started, or a Rebuild Index landing mid-search would have this
            // finish against a different connection.
            let outcome: ([SearchHit], String?) =
                await Task.detached(priority: .userInitiated) {
                    do { return (try index.search(query), nil) }
                    catch { return ([], "\(error)") }
                }.value

            guard let self, self.searchGeneration == generation else { return }
            self.isSearching = false
            if let failure = outcome.1 {
                self.searchResults = []
                self.searchStatus = "Search error: \(failure)"
                return
            }
            self.searchResults = outcome.0
            let n = outcome.0.count
            self.searchStatus = n == 0 ? "No results." : "\(n) result\(n == 1 ? "" : "s")."
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
        // Bring the main window forward, not just the app. The Find window is
        // usually sitting on top of it — that is where the click came from — so
        // without this, "View in Mailbox" selects a message the user cannot see.
        // `MainWindowAccessor.resolved` is the window SwiftUI actually used,
        // recorded when it appeared; never guessed at by scanning `NSApp.windows`
        // or matching a title, both of which this codebase has been burned by.
        MainWindowAccessor.resolved?.makeKeyAndOrderFront(nil)
        if selectedMailboxID == hit.mailbox {
            // Mailbox already listed; just move the selection (onChange renders it).
            selectMessage(index)
            // And bring it to the middle of the list. `keepSelectionVisible`
            // would do the minimum, which is right when the list is where the
            // user left it — but arriving from a search means the messages
            // around this one are the reason for coming, and a row pinned to the
            // bottom edge shows only the ones before it.
            if let pos = rowPositionByID[index] {
                revealCentered(row: pos)
            } else {
                // The mailbox is listed but its rows aren't on screen yet — a
                // listing still in flight leaves `rowPositionByID` empty. Go
                // through the pending-jump path instead, which runs after the
                // rows land, rather than selecting a message and leaving the
                // list wherever it happened to be.
                pendingMessageID = index
                pendingMessageIsExplicitJump = true
                loadListing(force: true)
            }
        } else {
            pendingMessageID = index
            pendingMessageIsExplicitJump = true
            selectedMailboxID = hit.mailbox   // onChange → loadListing() applies pending
        }
    }
}

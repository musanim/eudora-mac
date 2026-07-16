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
struct MessageRow: Identifiable, Hashable {
    let id: Int             // 1-based message index within the mailbox
    let statusGlyph: String
    let priority: Int       // Eudora: 1=highest … 4=normal … 7=lowest; 0=unknown
    let hasAttachment: Bool
    let label: String       // color-label placeholder (not parsed yet)
    let who: String         // From for incoming, To for outgoing (display name)
    let date: String        // Eudora-style short date/time
    let size: Int
    let subject: String

    /// Size in K, rounded up, minimum 1K — as Eudora showed it.
    var sizeK: String { "\(max(1, (size + 1023) / 1024))K" }
}

/// The rendered preview of a single message.
struct MessagePreview {
    let subject: String
    let from: String
    let to: String
    let date: String
    let isHTML: Bool
    let content: String          // HTML string when isHTML, else plain text
    let images: [String: EmbeddedImage]  // eudora-image:<id> -> bytes (HTML only)
    let attachments: [MessageAttachment]
    let indexSourceNote: String  // shown subtly so we can see toc vs scan
}

/// One attached file whose bytes are present in the message. Carried so the
/// preview can offer **Save As…** (and, for images, View) — never auto-opened,
/// per the "dumb client" stance (design-decisions §3).
struct MessageAttachment: Identifiable, Hashable {
    let id: String            // stable within one rendered message, e.g. "eu-att-1"
    let filename: String      // sanitized display / save name
    let mimeType: String
    let data: Data

    var fileExtension: String { (filename as NSString).pathExtension.lowercased() }

    /// Whether this attachment can open in the existing native image viewer.
    var isImage: Bool {
        if mimeType.lowercased().hasPrefix("image/") { return true }
        return ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff",
                "webp", "heic", "heif", "ico"].contains(fileExtension)
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

// MARK: - App model

@MainActor
final class AppModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var tree: [MailboxItem] = []
    @Published var status: String = "No Eudora folder open."

    // Selected mailbox (sidebar) and message (table), by their ids. Reactions
    // are driven from the view via `.onChange` (see ContentView) rather than
    // `didSet`, so the follow-on @Published mutations happen *after* SwiftUI's
    // view-update pass — not during it (which SwiftUI warns about).
    @Published var selectedMailboxID: MailboxItem.ID?
    @Published var selectedMessageID: MessageRow.ID?

    @Published var rows: [MessageRow] = []
    @Published var listingSource: String = ""
    @Published var mailboxSummary: String = ""
    @Published var preview: MessagePreview?

    /// Non-nil while a compose sheet is open.
    @Published var composing: ComposeDraft?
    /// Transient banner (e.g. "Message sent", or a send error).
    @Published var banner: String?
    /// True while a Check Mail fetch is in flight.
    @Published var isChecking = false

    // MARK: search (Find window)
    /// Hits from the last Find run, newest first.
    @Published var searchResults: [SearchHit] = []
    /// Status line for the Find window ("Indexed N messages.", "12 results.", …).
    @Published var searchStatus: String = ""

    private var store: MailStore?
    private var itemsByID: [MailboxItem.ID: MailboxItem] = [:]

    /// The full-text index for the open tree (nil until a tree is opened/built).
    private var searchIndex: SearchIndex?
    /// When opening a search hit into a not-yet-loaded mailbox, the message to
    /// select once that mailbox's listing has been rebuilt (see loadListing()).
    private var pendingMessageID: MessageRow.ID?

    // MARK: opening a tree

    /// UserDefaults key holding the last-opened Eudora folder path. The app is
    /// non-sandboxed, so a plain path round-trips fine (no security-scoped
    /// bookmark needed).
    private static let lastFolderKey = "EudoraRootPath"

    /// Restore on launch: $EUDORA_ROOT wins (handy for the fixture), otherwise
    /// the last folder opened, if it still exists. Else wait for File ▸ Open.
    func openDefaultIfAvailable() {
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
        UserDefaults.standard.set(url.path, forKey: Self.lastFolderKey)
        let s = MailStore(root: url)
        store = s
        rootURL = url
        let nodes = s.tree()
        tree = Self.buildItems(nodes, prefix: "")
        itemsByID = [:]
        indexItems(tree)
        selectedMailboxID = nil
        selectedMessageID = nil
        rows = []
        preview = nil
        status = tree.isEmpty
            ? "No descmap.pce found at \(url.lastPathComponent)."
            : "\(url.lastPathComponent) — \(itemsByID.values.filter { !$0.isFolder }.count) mailboxes."

        // Build (or rebuild) the search index for this tree. Synchronous for
        // now — instant on the fixture. Backgrounding this for a large real
        // store is a known follow-up (see handoff).
        searchResults = []
        if tree.isEmpty { searchIndex = nil; searchStatus = "" } else { buildIndex(for: url) }
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
    func loadListing() {
        preview = nil
        if let pending = pendingMessageID {
            pendingMessageID = nil
            rebuildRows()
            selectedMessageID = pending
            // Render directly: onChange(selectedMessageID) won't fire if `pending`
            // equals the previously selected index (e.g. row 2 → row 2 in another
            // mailbox), which would otherwise leave the preview blank.
            loadMessage()
        } else {
            selectedMessageID = nil
            rebuildRows()
        }
    }

    /// Rebuild the row list for the current mailbox WITHOUT clearing the message
    /// selection (used after an in-place change like mark-as-read).
    private func rebuildRows() {
        guard let store,
              let id = selectedMailboxID,
              let item = itemsByID[id], !item.isFolder,
              let listing = store.list(at: item.base, name: item.display) else {
            rows = []
            listingSource = ""
            mailboxSummary = ""
            return
        }

        // Parse the messages once so Who and the attachment glyph reflect the
        // real message, not the TOC's cached recipient. Fixture-small; a real
        // store would push this onto a background queue.
        let parts = Dictionary(uniqueKeysWithValues:
            store.loadMessages(at: item.base).map { ($0.index, $0.part) })
        let outgoing = (item.type == .outbox)

        var unread = 0
        rows = listing.rows.map { r in
            let part = parts[r.index]
            let who = part.map { Self.correspondent($0, outgoing: outgoing) } ?? r.who
            let hasAtt = part?.walk().contains { $0.isAttachment } ?? false
            let date = part.flatMap { Self.eudoraDate($0.header("Date")) } ?? r.date
            if r.statusGlyph == "•" { unread += 1 }
            return MessageRow(id: r.index,
                              statusGlyph: r.statusGlyph,
                              priority: Int(r.priority) ?? 0,
                              hasAttachment: hasAtt,
                              label: "",
                              who: who,
                              date: date,
                              size: r.size,
                              subject: r.subject)
        }
        listingSource = listing.source.rawValue
        let sizeK = max(1, (rows.reduce(0) { $0 + $1.size } + 1023) / 1024)
        mailboxSummary = "\(rows.count) messages"
            + (unread > 0 ? ", \(unread) unread" : "")
            + " · \(sizeK)K"
    }

    // MARK: display helpers

    /// From (incoming) or To (outgoing), reduced to a display name.
    static func correspondent(_ part: MIMEPart, outgoing: Bool) -> String {
        let primary = outgoing ? "To" : "From"
        let fallback = outgoing ? "From" : "To"
        let raw = HeaderDecoder.decode(part.header(primary) ?? part.header(fallback) ?? "")
        return displayName(raw)
    }

    /// "Steve Dorner <d@x>" → "Steve Dorner"; "a@b (Name)" → "Name"; else the
    /// address. Strips surrounding quotes.
    static func displayName(_ raw: String) -> String {
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

    private static let rfc822In: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f
    }()
    private static let rfc822InNoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy HH:mm:ss Z"
        return f
    }()
    private static let eudoraOut: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d/yy h:mm a"
        return f
    }()

    /// Parse an RFC-822 Date header and render it Eudora-style ("12/17/02 9:04 AM").
    static func eudoraDate(_ header: String?) -> String? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        let date = rfc822In.date(from: h) ?? rfc822InNoDay.date(from: h)
        return date.map { eudoraOut.string(from: $0) }
    }

    // MARK: rendering one message

    func loadMessage() {
        guard let store,
              let mid = selectedMailboxID,
              let item = itemsByID[mid], !item.isFolder,
              let index = selectedMessageID,
              let msg = store.message(at: item.base, index: index) else {
            preview = nil
            return
        }
        preview = Self.render(msg.part, sourceNote: listingSource)
    }

    /// Choose the best displayable body (prefer text/html, else text/plain),
    /// decode it tolerantly, and collect attachment filenames.
    static func render(_ part: MIMEPart, sourceNote: String) -> MessagePreview {
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

        if let h = htmlPart {
            let dec = CharsetDecoder.smartDecode(h.decodedPayload(), declared: h.charset)
            // Turn every <img> into a safe box and collect the embedded-image
            // bytes the view resolves on an `eudora-image:` click (no network).
            let rendered = BodyRenderer.rewrite(html: dec.text, in: part)
            return MessagePreview(subject: subject, from: from, to: to, date: date,
                                  isHTML: true, content: rendered.html,
                                  images: rendered.images,
                                  attachments: attachments, indexSourceNote: sourceNote)
        }
        let text = textPart.map {
            CharsetDecoder.smartDecode($0.decodedPayload(), declared: $0.charset).text
        } ?? ""
        return MessagePreview(subject: subject, from: from, to: to, date: date,
                              isHTML: false, content: text,
                              images: [:],
                              attachments: attachments, indexSourceNote: sourceNote)
    }

    /// Build an attachment descriptor (with decoded bytes) from a MIME part.
    static func attachment(from part: MIMEPart, index: Int) -> MessageAttachment {
        let name = sanitizedFilename(part.filename) ?? "attachment-\(index)"
        return MessageAttachment(id: "eu-att-\(index)",
                                 filename: name,
                                 mimeType: part.contentType,
                                 data: part.decodedPayload())
    }

    /// Decode (RFC 2047) then strip path separators and control characters from
    /// the attacker-controlled MIME filename, for a safe Save-panel default.
    static func sanitizedFilename(_ raw: String?) -> String? {
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
        if let id = selectedMailboxID, itemsByID[id]?.type == .outbox { loadListing() }
    }

    /// Rebuild the sidebar tree (e.g. after message counts change) without
    /// disturbing the current selection.
    private func reloadTree() {
        guard let store else { return }
        tree = Self.buildItems(store.tree(), prefix: "")
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

    /// Non-folder mailboxes other than the current one — move destinations.
    var moveTargets: [MailboxItem] {
        let current = selectedMailboxID
        return itemsByID.values
            .filter { !$0.isFolder && $0.id != current }
            .sorted { $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending }
    }

    var canActOnMessage: Bool { currentSelection() != nil }

    func markSelected(read: Bool) {
        guard let sel = currentSelection() else { return }
        do {
            try MailboxMutator.setStatus(base: sel.item.base, index: sel.index,
                                         status: read ? MailboxMutator.statusRead
                                                      : MailboxMutator.statusUnread)
            rebuildRows()                 // keep selection + preview
            reloadTree()                  // unread badge may change
        } catch {
            banner = "Couldn't update status: \(error.localizedDescription)"
        }
    }

    /// Delete = move to Trash; if already in Trash, remove permanently.
    func deleteSelected() {
        guard let store, let sel = currentSelection() else { return }
        do {
            if sel.item.type == .trash {
                try MailboxMutator.remove(base: sel.item.base, index: sel.index)
                banner = "Message deleted."
            } else if let trash = store.mailboxBase(ofType: .trash) {
                try MailboxMutator.move(from: sel.item.base, index: sel.index, to: trash)
                banner = "Moved to Trash."
            } else {
                try MailboxMutator.remove(base: sel.item.base, index: sel.index)
                banner = "Message deleted (no Trash mailbox)."
            }
            afterRemoval()
        } catch {
            banner = "Delete failed: \(error.localizedDescription)"
        }
    }

    func moveSelected(to destID: MailboxItem.ID) {
        guard let sel = currentSelection(), let dest = itemsByID[destID] else { return }
        do {
            try MailboxMutator.move(from: sel.item.base, index: sel.index, to: dest.base)
            banner = "Moved to \(dest.display)."
            afterRemoval()
        } catch {
            banner = "Move failed: \(error.localizedDescription)"
        }
    }

    /// The selected message left the current mailbox: clear it and refresh.
    private func afterRemoval() {
        selectedMessageID = nil
        preview = nil
        rebuildRows()
        reloadTree()
    }

    // MARK: receiving (POP3)

    /// Check mail: fetch new messages into the In box, then — only if the user
    /// opted in — delete them from the server in a second pass, after they're
    /// safely written locally.
    func receiveMail(accounts: AccountStore) async {
        guard let store, let inbox = store.mailboxBase(ofType: .inbox) else {
            banner = "No In mailbox in this tree."
            return
        }
        guard accounts.pop.isConfigured else {
            banner = "Incoming mail not set up: server=\"\(accounts.pop.host)\", "
                + "user=\"\(accounts.pop.username)\", port=\(accounts.pop.port). "
                + "Fill these in Settings ▸ Incoming mail (POP3), then Save."
            return
        }
        guard !accounts.incomingPassword.isEmpty else {
            banner = "Incoming password is empty — enter it in Settings ▸ Incoming mail (POP3), then Save."
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
            if let id = selectedMailboxID, itemsByID[id]?.type == .inbox { loadListing() }
            banner = fetched.isEmpty
                ? "No new mail."
                : "Received \(fetched.count) message\(fetched.count == 1 ? "" : "s")."
        } catch {
            banner = "Check mail failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
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

    /// Build (wipe + rebuild) the index for the given tree.
    private func buildIndex(for root: URL) {
        guard let store else { return }
        do {
            let path = indexURL(for: root)?.path ?? ":memory:"
            let idx = try SearchIndex(path: path)
            try idx.rebuild(from: store)
            searchIndex = idx
            searchStatus = "Indexed \(try idx.count()) messages."
        } catch {
            searchIndex = nil
            searchStatus = "Index error: \(error)"
        }
    }

    /// Menu/command "Rebuild Index".
    func rebuildIndex() {
        guard let rootURL else { banner = "Open a Eudora folder first."; return }
        buildIndex(for: rootURL)
        banner = searchStatus
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
            banner = "Couldn't locate that message (index may be stale — try Rebuild Index)."
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

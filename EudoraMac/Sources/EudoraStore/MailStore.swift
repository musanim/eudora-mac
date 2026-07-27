import Foundation

/// A node in the mailbox tree reconstructed from `descmap.pce`.
public struct MailboxNode: Sendable {
    public let entry: DescMapEntry
    public let base: URL        // ".../In" for a mailbox, ".../Projects" for a folder
    public let depth: Int
    public let messageCount: Int
    public let children: [MailboxNode]

    public var isFolder: Bool { entry.type.isFolder }
}

public enum IndexSource: String {
    case toc = "toc"
    case tocCompacted = "toc (deleted hidden)"
    case scanNoToc = "scan (no .toc)"
    case scanStale = "scan (.toc stale — offsets disagree)"
}

public struct ListingRow {
    public let index: Int
    public let statusGlyph: String
    /// The raw Eudora status byte, or -1 when it isn't known.
    ///
    /// Carried alongside the glyph because several states share a glyph — 1
    /// (read), 5 (unsendable), 6 (sendable) and 9 (unsent) all render as a
    /// blank — so the glyph cannot answer "is this a draft?". -1 is the
    /// scan fallback, where there is no `.toc` to read a status from.
    public let status: Int
    public let priority: String
    public let date: String
    public let size: Int
    /// Byte offset of this message's record in the `.mbx` (the envelope line
    /// start). With `size` it locates the record for a later per-message read —
    /// what the message list's enrichment uses to fetch just the messages it
    /// needs instead of re-reading the whole file. See `forEachMessageDigest`.
    public let offset: Int
    public let who: String
    public let subject: String
}

public struct Listing {
    public let name: String
    public let source: IndexSource
    public let rows: [ListingRow]
}

/// The interop facade: reads a Eudora tree in place. `.mbx` is truth; `.toc` is
/// a rebuildable cache that we verify against the mbx and fall back from.
///
/// `Sendable` (it holds only a `URL` and reads files on demand) so the search
/// indexer can build off the main thread from a value copy.
public struct MailStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    // MARK: hierarchy

    public func tree() -> [MailboxNode] { build(directory: root, depth: 0) }

    private func build(directory: URL, depth: Int) -> [MailboxNode] {
        var nodes: [MailboxNode] = []
        for entry in DescMap.read(directory: directory) {
            let child = directory.appendingPathComponent(entry.filename)
            if entry.type.isFolder {
                // A folder is a ".fol" subdirectory (its filename in descmap
                // carries the extension); recurse into it as a directory.
                nodes.append(MailboxNode(entry: entry, base: child, depth: depth,
                                         messageCount: 0,
                                         children: build(directory: child, depth: depth + 1)))
            } else {
                // descmap filenames include the extension (e.g. "In.mbx"); the
                // base used to derive .mbx/.toc is the name *without* it. This is
                // a no-op for fixtures whose filenames carry no extension.
                let base = child.deletingPathExtension()
                nodes.append(MailboxNode(entry: entry, base: base, depth: depth,
                                         messageCount: messageCount(base: base),
                                         children: []))
            }
        }
        return nodes
    }

    // MARK: locate & count

    func mbxURL(_ base: URL) -> URL { base.appendingPathExtension("mbx") }
    func tocURL(_ base: URL) -> URL { base.appendingPathExtension("toc") }

    public func messageCount(base: URL) -> Int {
        // Prefer the .toc's entry count, derived from its file *size* alone
        // ((size − header) / entrySize) — a stat, no file read. This is Eudora's
        // own count (matches the reconciled listing) and avoids reading every
        // .mbx in the tree at launch, which is what made opening a large archive
        // take ~a minute. Only a mailbox with no .toc falls back to a scan.
        if let n = tocEntryCount(base: base) { return n }
        guard let data = try? Data(contentsOf: mbxURL(base)) else { return 0 }
        return Mbox.findRecords([UInt8](data)).count
    }

    /// Message count from the `.toc` file size, without reading its contents.
    ///
    /// `resourceValues(forKeys:)` rather than `attributesOfItem(atPath:)`: the
    /// latter builds a dictionary of every attribute the filesystem knows —
    /// owner, permissions, dates, inode — to answer one question about size.
    /// This runs once per mailbox on every tree walk, which on Stephen's archive
    /// is 6,699 of them, so the difference is not academic.
    private func tocEntryCount(base: URL) -> Int? {
        guard let size = try? tocURL(base)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= Toc.folderSize else { return nil }
        return (size - Toc.folderSize) / Toc.entrySize
    }

    /// Accept "In" or "Projects/Music"; fall back to display/filename match.
    public func locate(_ name: String) -> URL? {
        var url = root
        for c in name.split(separator: "/") { url.appendPathComponent(String(c)) }
        if FileManager.default.fileExists(atPath: mbxURL(url).path) { return url }
        for node in flatten(tree()) where !node.isFolder {
            if node.entry.display == name || node.entry.filename == name { return node.base }
        }
        return nil
    }

    /// Base URL of the first non-folder mailbox with the given role.
    public func mailboxBase(ofType type: MailboxType) -> URL? {
        flatten(tree()).first { $0.entry.type == type && !$0.isFolder }?.base
    }

    /// Base URL of the first Out-type mailbox (for sent-message write-back).
    public func outboxBase() -> URL? { mailboxBase(ofType: .outbox) }

    private func flatten(_ nodes: [MailboxNode]) -> [MailboxNode] {
        var out: [MailboxNode] = []
        for n in nodes { out.append(n); out.append(contentsOf: flatten(n.children)) }
        return out
    }

    // MARK: listing

    /// The glyph for MS_UNREAD, named so callers can test for "never read"
    /// without hard-coding the bullet in several places.
    public static let unreadGlyph = "•"

    /// Message-list glyph for a Eudora status byte (values from the Windows
    /// Eudora source, `summary.h`). The state is a single value per message
    /// (replied implies read, etc.), so one glyph suffices.
    static let statusGlyphs: [Int: String] = [
        0: unreadGlyph,   // MS_UNREAD
        1: " ",   // MS_READ
        2: "R",   // MS_REPLIED
        3: "F",   // MS_FORWARDED
        4: "→",   // MS_REDIRECT
        5: " ",   // MS_UNSENDABLE
        6: " ",   // MS_SENDABLE
        7: "Q",   // MS_QUEUED
        8: "S",   // MS_SENT
        9: " ",   // MS_UNSENT
        12: " ",  // MS_RECOVERED
    ]

    public func list(_ name: String) -> Listing? {
        guard let base = locate(name) else { return nil }
        return list(at: base, name: name)
    }

    /// Same listing, addressed by a mailbox's base URL (as carried on a
    /// `MailboxNode`). Lets the UI bind to the tree it already has without a
    /// name round-trip. `name` is only the human label on the result.
    public func list(at base: URL, name: String? = nil) -> Listing? {
        guard let data = try? Data(contentsOf: mbxURL(base)) else { return nil }
        let label = name ?? base.lastPathComponent
        let bytes = [UInt8](data)
        let recs = Mbox.findRecords(bytes)

        // Each real message's byte offset → its 1-based position in the .mbx.
        var indexByOffset: [Int: Int] = [:]
        for (i, rec) in recs.enumerated() { indexByOffset[rec.offset] = i + 1 }

        let toc = Toc.read(tocURL(base))

        // Trust the .toc when the overwhelming majority of its entries point at
        // a real message (by offset). That covers an exact match, the common
        // "deleted but not compacted" case (the .mbx keeps bodies the .toc no
        // longer lists — we show what Eudora showed, with status, and hide the
        // deleted ghosts), and a valid-but-slightly-stale .toc carrying a
        // handful of dead entries that point into compaction padding rather than
        // at a message. Those dead entries are dropped, not treated as a reason
        // to throw the whole index — and its status and cached dates — away and
        // fall back to a status-less scan.
        //
        // The threshold is a simple majority. A genuinely wrong .toc (belonging
        // to a different .mbx) shares almost no offsets and sits near zero; a
        // real one clears this easily — the worst stale mailbox in the real tree
        // still matches ~71%.
        if let t = toc, !t.isEmpty {
            let matched = t.filter { indexByOffset[$0.offset] != nil }
            if matched.count * 2 > t.count {
                let source: IndexSource =
                    (matched.count == t.count && t.count == recs.count) ? .toc : .tocCompacted
                let rows = matched.map { e -> ListingRow in
                    let idx = indexByOffset[e.offset]!
                    return ListingRow(index: idx,
                                      statusGlyph: Self.statusGlyphs[e.status] ?? "?",
                                      status: e.status,
                                      priority: String(e.priority),
                                      date: e.date, size: recs[idx - 1].length,
                                      offset: recs[idx - 1].offset,
                                      who: e.to, subject: e.subject)
                }
                return Listing(name: label, source: source, rows: rows)
            }
        }

        // No .toc, or one that disagrees with the .mbx → scan the mailbox
        // directly. Read/replied/forwarded status isn't recoverable this way.
        let source: IndexSource = (toc == nil) ? .scanNoToc : .scanStale
        let rows = recs.enumerated().map { (i, rec) -> ListingRow in
            let msg = MIMEParser.parse(Mbox.messageBytes(bytes, rec))
            return ListingRow(index: i + 1,
                              statusGlyph: "?", status: -1, priority: "-",
                              date: msg.header("Date") ?? "",
                              size: rec.length,
                              offset: rec.offset,
                              who: msg.header("From") ?? msg.header("To") ?? "",
                              subject: HeaderDecoder.decode(msg.header("Subject") ?? ""))
        }
        return Listing(name: label, source: source, rows: rows)
    }

    // MARK: enumeration (for indexing)

    /// Every non-folder mailbox as (path-style name, base URL), e.g.
    /// ("In", …), ("Projects/Music", …). Names use on-disk filenames so they
    /// round-trip through `locate(_:)`.
    public func allMailboxes() -> [(name: String, base: URL)] {
        var out: [(name: String, base: URL)] = []
        func recurse(_ nodes: [MailboxNode], _ prefix: String) {
            for n in nodes {
                if n.isFolder {
                    recurse(n.children, prefix + n.entry.filename + "/")
                } else {
                    out.append((name: prefix + n.entry.filename, base: n.base))
                }
            }
        }
        recurse(tree(), "")
        return out
    }

    /// All messages in a mailbox (read once, parsed), 1-based index.
    /// Parse each message in turn, handing it to `body`, which returns false to
    /// stop early.
    ///
    /// Preferred over `loadMessages(at:)` for anything that only needs to *look*
    /// at each message: it holds one `MIMEPart` at a time instead of one per
    /// message, which on a mailbox like the 613 MB / 22,515-message Trash is the
    /// difference between a bounded working set and parsing the lot into memory.
    /// Stopping early also makes it cancellable.
    /// `isCancelled` is consulted before each expensive step as well as between
    /// messages. That matters because the read and the record scan happen *before*
    /// the first callback and are O(file): without a hook here, abandoning a
    /// 613 MB mailbox still costs the full read, and several could overlap.
    public func forEachMessage(at base: URL,
                               isCancelled: () -> Bool = { false },
                               body: (_ index: Int, _ record: MboxRecord, _ part: MIMEPart) -> Bool) {
        if isCancelled() { return }
        guard let data = try? Data(contentsOf: mbxURL(base)) else { return }
        if isCancelled() { return }
        let bytes = [UInt8](data)
        let records = Mbox.findRecords(bytes)
        if isCancelled() { return }
        for (i, rec) in records.enumerated() {
            if !body(i + 1, rec, MIMEParser.parse(Mbox.messageBytes(bytes, rec))) { return }
        }
    }

    /// Hands back a `MessageDigest` — the Who/Date headers and the attachment
    /// flag — for a known set of records, reading each one directly rather than
    /// scanning the whole `.mbx`.
    ///
    /// This is what the message list's background enrichment uses. The listing
    /// already found every live message's byte offset (see `ListingRow.offset`),
    /// so there is no reason to re-read and re-scan the 613 MB file: the mailbox
    /// is memory-mapped (no eager copy) and each record is sliced out by offset.
    /// Crucially it is **cancellable between messages** — the old whole-file
    /// slurp-and-scan couldn't be stopped mid-read, so switching away from a big
    /// mailbox left the abandoned enrichment holding a thread; this stops at the
    /// next record. `records` carries `(index, offset, length)` where `index` is
    /// the row id, `offset` the record's envelope-line start, `length` its size.
    public func forEachMessageDigest(at base: URL,
                                     records: [(index: Int, offset: Int, length: Int)],
                                     isCancelled: () -> Bool = { false },
                                     body: (_ index: Int, _ digest: MessageDigest) -> Bool) {
        if isCancelled() { return }
        guard let data = try? Data(contentsOf: mbxURL(base), options: .mappedIfSafe) else { return }
        let total = data.count
        for r in records {
            if isCancelled() { return }
            let end = r.offset + r.length
            guard r.offset >= 0, r.length > 0, end <= total else { continue }
            let record = [UInt8](data[(data.startIndex + r.offset)..<(data.startIndex + end)])
            if !body(r.index, MessageDigest.parse(Mbox.messageBytes(fromRecord: record))) { return }
        }
    }

    /// Every distinct `From` address in a mailbox, normalized — the one-time
    /// scan behind "seed my identity set from Out", where every sender is you.
    /// Header-only (`MessageDigest`), so even a large Out reads fast; it walks
    /// the whole mailbox on purpose, as the bootstrap is a deliberate action.
    public func senderAddresses(at base: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: mbxURL(base), options: .mappedIfSafe) else {
            return []
        }
        let bytes = [UInt8](data)
        var out: Set<String> = []
        for rec in Mbox.findRecords(bytes) {
            let digest = MessageDigest.parse(Mbox.messageBytes(bytes, rec))
            out.formUnion(EmailAddress.addresses(in: digest.from ?? ""))
        }
        return out
    }

    public func loadMessages(at base: URL) -> [(index: Int, record: MboxRecord, part: MIMEPart)] {
        guard let data = try? Data(contentsOf: mbxURL(base)) else { return [] }
        let bytes = [UInt8](data)
        return Mbox.findRecords(bytes).enumerated().map { (i, rec) in
            (index: i + 1, record: rec, part: MIMEParser.parse(Mbox.messageBytes(bytes, rec)))
        }
    }

    // MARK: single message

    public func message(_ name: String, index: Int) -> (record: MboxRecord, part: MIMEPart)? {
        guard let base = locate(name) else { return nil }
        return message(at: base, index: index)
    }

    /// The 1-based index of the record starting at `offset` in a mailbox, or
    /// nil if no record starts there. Bridges a search hit (which carries a byte
    /// offset) to the 1-based index the listing/message APIs use.
    public func indexOfRecord(at base: URL, offset: Int) -> Int? {
        guard let data = try? Data(contentsOf: mbxURL(base)) else { return nil }
        let recs = Mbox.findRecords([UInt8](data))
        if let i = recs.firstIndex(where: { $0.offset == offset }) { return i + 1 }
        return nil
    }

    /// Single message addressed by a mailbox's base URL. 1-based index.
    public func message(at base: URL, index: Int) -> (record: MboxRecord, part: MIMEPart)? {
        guard let data = try? Data(contentsOf: mbxURL(base)) else { return nil }
        let bytes = [UInt8](data)
        let recs = Mbox.findRecords(bytes)
        guard index >= 1, index <= recs.count else { return nil }
        let rec = recs[index - 1]
        return (rec, MIMEParser.parse(Mbox.messageBytes(bytes, rec)))
    }
}

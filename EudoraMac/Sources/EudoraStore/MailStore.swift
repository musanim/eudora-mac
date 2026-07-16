import Foundation

/// A node in the mailbox tree reconstructed from `descmap.pce`.
public struct MailboxNode {
    public let entry: DescMapEntry
    public let base: URL        // ".../In" for a mailbox, ".../Projects" for a folder
    public let depth: Int
    public let messageCount: Int
    public let children: [MailboxNode]

    public var isFolder: Bool { entry.type.isFolder }
}

public enum IndexSource: String {
    case toc = "toc"
    case scanNoToc = "scan (no .toc)"
    case scanStale = "scan (.toc stale — offsets disagree)"
}

public struct ListingRow {
    public let index: Int
    public let statusGlyph: String
    public let priority: String
    public let date: String
    public let size: Int
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
public struct MailStore {
    public let root: URL
    public init(root: URL) { self.root = root }

    // MARK: hierarchy

    public func tree() -> [MailboxNode] { build(directory: root, depth: 0) }

    private func build(directory: URL, depth: Int) -> [MailboxNode] {
        var nodes: [MailboxNode] = []
        for entry in DescMap.read(directory: directory) {
            let child = directory.appendingPathComponent(entry.filename)
            if entry.type.isFolder {
                nodes.append(MailboxNode(entry: entry, base: child, depth: depth,
                                         messageCount: 0,
                                         children: build(directory: child, depth: depth + 1)))
            } else {
                nodes.append(MailboxNode(entry: entry, base: child, depth: depth,
                                         messageCount: messageCount(base: child),
                                         children: []))
            }
        }
        return nodes
    }

    // MARK: locate & count

    func mbxURL(_ base: URL) -> URL { base.appendingPathExtension("mbx") }
    func tocURL(_ base: URL) -> URL { base.appendingPathExtension("toc") }

    public func messageCount(base: URL) -> Int {
        guard let data = try? Data(contentsOf: mbxURL(base)) else { return 0 }
        return Mbox.findRecords([UInt8](data)).count
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

    static let statusGlyphs: [Int: String] = [0: " ", 1: "•", 2: " ", 3: "R", 4: "D", 8: "S"]

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

        var toc = Toc.read(tocURL(base))
        var source: IndexSource = .toc
        if toc == nil {
            source = .scanNoToc
        } else if toc!.count != recs.count
                    || zip(toc!, recs).contains(where: { $0.0.offset != $0.1.offset }) {
            source = .scanStale
            toc = nil
        }

        var rows: [ListingRow] = []
        for (i, rec) in recs.enumerated() {
            if let t = toc {
                let e = t[i]
                rows.append(ListingRow(index: i + 1,
                                       statusGlyph: Self.statusGlyphs[e.status] ?? "?",
                                       priority: String(e.priority),
                                       date: e.date, size: rec.length,
                                       who: e.to, subject: e.subject))
            } else {
                let msg = MIMEParser.parse(Mbox.messageBytes(bytes, rec))
                rows.append(ListingRow(index: i + 1,
                                       statusGlyph: "?", priority: "-",
                                       date: msg.header("Date") ?? "",
                                       size: rec.length,
                                       who: msg.header("From") ?? msg.header("To") ?? "",
                                       subject: HeaderDecoder.decode(msg.header("Subject") ?? "")))
            }
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

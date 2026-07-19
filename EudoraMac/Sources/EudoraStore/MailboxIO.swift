import Foundation

/// Shared low-level mailbox file operations used by write-back paths (send,
/// move, delete). Keeps the backup + atomic-write + TOC-alignment rules in one
/// place so every mutation is guarded the same way.
enum MailboxIO {

    /// Back up `<name>.mbx` to `<name>.mbx.bak` once (only if the mailbox exists
    /// and no backup is present yet).
    @discardableResult
    static func backupOnce(_ mbx: URL) throws -> Bool {
        let fm = FileManager.default
        let bak = mbx.appendingPathExtension("bak")
        guard fm.fileExists(atPath: mbx.path), !fm.fileExists(atPath: bak.path) else { return false }
        try fm.copyItem(at: mbx, to: bak)
        return true
    }

    /// Append `data` to the end of the file at `url` (creating it if absent),
    /// streaming — without reading the existing (possibly huge) file. O(data).
    static func appendData(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try data.write(to: url)
            return
        }
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.seekToEnd()
        try fh.write(contentsOf: data)
    }

    /// The final byte of a file (or nil if empty/missing), read without loading
    /// the whole file — used to decide whether an appended record needs a
    /// leading CRLF to sit at a line start.
    static func lastByte(of url: URL) -> UInt8? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd(), end > 0,
              (try? fh.seek(toOffset: end - 1)) != nil,
              let d = try? fh.read(upToCount: 1) else { return nil }
        return d.first
    }

    /// Write `data` to `url` via a temp file + atomic replace (or move if the
    /// destination doesn't exist yet).
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }

    /// Is the `.toc` present and aligned 1:1 (by offset) with the mailbox's
    /// records? When false, callers should NOT write a fabricated `.toc` — they
    /// drop it and let the reader rescan, so a mutation never invents status
    /// flags for the other messages.
    static func tocIsValid(mbxBytes: [UInt8], tocURL: URL) -> Bool {
        let recs = Mbox.findRecords(mbxBytes)
        guard let toc = Toc.read(tocURL), toc.count == recs.count else { return false }
        return !zip(toc, recs).contains(where: { $0.0.offset != $0.1.offset })
    }

    /// TOC entries aligned 1:1 with the mailbox's records. Uses the `.toc` cache
    /// when it's valid (offsets agree), otherwise synthesizes entries by parsing
    /// each message — so a mutation always has a consistent status/priority/
    /// date/to/subject model to work from, even for mailboxes without a `.toc`.
    /// (Synthesized statuses are defaults; see `tocIsValid` — don't persist them
    /// as authoritative.)
    static func alignedEntries(mbxBytes: [UInt8], tocURL: URL) -> [TocEntry] {
        let recs = Mbox.findRecords(mbxBytes)
        if let toc = Toc.read(tocURL), toc.count == recs.count,
           !zip(toc, recs).contains(where: { $0.0.offset != $0.1.offset }) {
            return toc
        }
        return recs.map { rec in
            let part = MIMEParser.parse(Mbox.messageBytes(mbxBytes, rec))
            return TocEntry(offset: rec.offset, length: rec.length,
                            status: 2, priority: 4,       // read / normal defaults
                            date: part.header("Date") ?? "",
                            to: part.header("To") ?? part.header("From") ?? "",
                            subject: HeaderDecoder.decode(part.header("Subject") ?? ""))
        }
    }
}

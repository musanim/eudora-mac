import Foundation

/// Message mutations written back to the Eudora tree in native format:
/// mark read/unread (TOC only), remove a message, and move a message between
/// mailboxes. `.mbx` stays the source of truth; the `.toc` is rewritten to
/// match. Every `.mbx` change is backed up once and written atomically.
public enum MailboxMutator {

    public enum MutateError: Error { case notFound, outOfRange, ioError(String) }

    // Eudora status bytes (from summary.h): 0 = unread, 1 = read.
    public static let statusUnread = 0
    public static let statusRead = 1

    /// Set the cached status byte for one message (e.g. read/unread). TOC-only;
    /// the `.mbx` is untouched, so no backup is needed.
    public static func setStatus(base: URL, index: Int, status: Int) throws {
        let mbxURL = base.appendingPathExtension("mbx")
        let tocURL = base.appendingPathExtension("toc")
        guard let data = try? Data(contentsOf: mbxURL) else { throw MutateError.notFound }
        let recs = Mbox.findRecords([UInt8](data))
        guard index >= 1, index <= recs.count else { throw MutateError.outOfRange }
        let targetOffset = recs[index - 1].offset

        // Status is a .toc-only field. Update just this message's entry (found by
        // offset) and rewrite the .toc — never parse the whole mailbox. With no
        // consistent .toc there's nothing to update.
        guard var entries = Toc.read(tocURL), tocConsistent(entries, recs: recs),
              let i = entries.firstIndex(where: { $0.offset == targetOffset }) else { return }
        let e = entries[i]
        entries[i] = TocEntry(offset: e.offset, length: e.length, status: status,
                              priority: e.priority, date: e.date, to: e.to, subject: e.subject)
        do { try TocWriter.data(entries: entries).write(to: tocURL) }
        catch { throw MutateError.ioError(error.localizedDescription) }
    }

    /// Permanently remove one message from a mailbox (used for a message already
    /// in Trash). Returns the removed record bytes + its TOC entry.
    @discardableResult
    public static func remove(base: URL, index: Int) throws -> (record: [UInt8], entry: TocEntry) {
        let mbx = base.appendingPathExtension("mbx")
        let toc = base.appendingPathExtension("toc")
        guard let data = try? Data(contentsOf: mbx) else { throw MutateError.notFound }
        let bytes = [UInt8](data)
        let recs = Mbox.findRecords(bytes)
        guard index >= 1, index <= recs.count else { throw MutateError.outOfRange }

        let rec = recs[index - 1]
        let end = min(rec.offset + rec.length, bytes.count)
        let recordBytes = Array(bytes[rec.offset..<end])
        let removedEntry = oneEntry(bytes: bytes, rec: rec, tocURL: toc)

        // Physically remove the message's bytes from the .mbx (atomic, backed up).
        do {
            try MailboxIO.backupOnce(mbx)
            var newData = Data()
            newData.append(contentsOf: bytes[0..<rec.offset])
            if end < bytes.count { newData.append(contentsOf: bytes[end...]) }
            try MailboxIO.atomicWrite(newData, to: mbx)
        } catch { throw MutateError.ioError(error.localizedDescription) }

        // Keep the .toc consistent when its offsets are a valid (sub)set of the
        // mailbox — drop the removed entry (by offset) and shift every later
        // offset left by the removed span. This preserves status even for a
        // mailbox with deleted ghosts. Only a genuinely inconsistent .toc is
        // dropped (reader rescans). Never parses the whole mailbox.
        if let entries0 = Toc.read(toc), tocConsistent(entries0, recs: recs) {
            var kept: [TocEntry] = []
            kept.reserveCapacity(entries0.count)
            for e in entries0 where e.offset != rec.offset {
                let off = e.offset > rec.offset ? e.offset - rec.length : e.offset
                kept.append(TocEntry(offset: off, length: e.length, status: e.status,
                                     priority: e.priority, date: e.date, to: e.to, subject: e.subject))
            }
            try? TocWriter.data(entries: kept).write(to: toc)
        } else if FileManager.default.fileExists(atPath: toc.path) {
            try? FileManager.default.removeItem(at: toc)
        }
        return (recordBytes, removedEntry)
    }

    /// Move one message from `source` to `dest` (Eudora "delete" = move to
    /// Trash). Appends it to the destination **first**, then removes it from the
    /// source — so an interrupted/failed move can never lose the message (worst
    /// case it lands in both). Carries its status/priority/date/subject.
    public static func move(from source: URL, index: Int, to dest: URL) throws {
        let (recordBytes, entry) = try readRecord(base: source, index: index)
        try appendRecord(recordBytes, entry: entry, to: dest)
        try remove(base: source, index: index)
    }

    /// Read one message's raw record bytes + its TOC entry, without modifying
    /// anything. (Splits the read out of `remove` so `move` can append first.)
    static func readRecord(base: URL, index: Int) throws -> (record: [UInt8], entry: TocEntry) {
        let mbx = base.appendingPathExtension("mbx")
        let toc = base.appendingPathExtension("toc")
        guard let data = try? Data(contentsOf: mbx) else { throw MutateError.notFound }
        let bytes = [UInt8](data)
        let recs = Mbox.findRecords(bytes)
        guard index >= 1, index <= recs.count else { throw MutateError.outOfRange }
        let rec = recs[index - 1]
        let end = min(rec.offset + rec.length, bytes.count)
        let recordBytes = Array(bytes[rec.offset..<end])
        return (recordBytes, oneEntry(bytes: bytes, rec: rec, tocURL: toc))
    }

    /// The TOC entry for a single record — from the `.toc` (matched by offset)
    /// when present, otherwise synthesized by parsing just that one message.
    /// Never parses the whole mailbox.
    static func oneEntry(bytes: [UInt8], rec: MboxRecord, tocURL: URL) -> TocEntry {
        if let toc = Toc.read(tocURL), let e = toc.first(where: { $0.offset == rec.offset }) {
            return e
        }
        let part = MIMEParser.parse(Mbox.messageBytes(bytes, rec))
        return TocEntry(offset: rec.offset, length: rec.length, status: 1, priority: 4,  // read/normal
                        date: part.header("Date") ?? "",
                        to: part.header("To") ?? part.header("From") ?? "",
                        subject: HeaderDecoder.decode(part.header("Subject") ?? ""))
    }

    /// True if every TOC offset points at a real message in `recs` (an exact
    /// match or a deleted-ghost subset) — the same consistency the reader uses.
    static func tocConsistent(_ toc: [TocEntry], recs: [MboxRecord]) -> Bool {
        guard !toc.isEmpty else { return false }
        let offsets = Set(recs.map { $0.offset })
        return toc.allSatisfy { offsets.contains($0.offset) }
    }

    /// Append a raw record (envelope line + message) to a mailbox. Streams the
    /// append — it reads only the destination's *size* and last byte, never the
    /// whole file — and appends a single 218-byte TOC entry. This makes a delete
    /// O(one message) even when the destination (e.g. a huge Trash) is enormous.
    static func appendRecord(_ recordBytes: [UInt8], entry: TocEntry, to dest: URL) throws {
        let mbx = dest.appendingPathExtension("mbx")
        let toc = dest.appendingPathExtension("toc")
        let fm = FileManager.default

        do {
            try MailboxIO.backupOnce(mbx)   // O(1) copy-on-write clone on APFS

            // Append offset = current size, bumped past a CRLF if the file
            // doesn't already end at a line boundary (the envelope separator is
            // only recognized at a line start).
            let size = ((try? fm.attributesOfItem(atPath: mbx.path))?[.size] as? NSNumber)?.intValue ?? 0
            var chunk = Data()
            var newOffset = size
            if size > 0, let last = MailboxIO.lastByte(of: mbx), last != 0x0A, last != 0x0D {
                chunk.append(contentsOf: [0x0D, 0x0A])
                newOffset = size + 2
            }
            chunk.append(contentsOf: recordBytes)
            try MailboxIO.appendData(chunk, to: mbx)

            // Keep the .toc in step by appending one entry (only if a .toc
            // exists). Its offset is valid, so the reader still trusts the .toc
            // (an already-invalid .toc just stays that way and the reader
            // rescans — either way we never rewrite the whole thing).
            if fm.fileExists(atPath: toc.path) {
                let e = TocEntry(offset: newOffset, length: recordBytes.count,
                                 status: entry.status, priority: entry.priority,
                                 date: entry.date, to: entry.to, subject: entry.subject)
                try MailboxIO.appendData(TocWriter.entryBytes(e), to: toc)
            }
        } catch { throw MutateError.ioError(error.localizedDescription) }
    }
}

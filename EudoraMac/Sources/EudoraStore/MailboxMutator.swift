import Foundation

/// Message mutations written back to the Eudora tree in native format:
/// mark read/unread (TOC only), remove a message, and move a message between
/// mailboxes. `.mbx` stays the source of truth; the `.toc` is rewritten to
/// match. Every `.mbx` change is backed up once and written atomically.
public enum MailboxMutator {

    public enum MutateError: Error { case notFound, outOfRange, ioError(String) }

    // Eudora status bytes (subset).
    public static let statusUnread = 1
    public static let statusRead = 2

    /// Set the cached status byte for one message (e.g. read/unread). TOC-only;
    /// the `.mbx` is untouched, so no backup is needed.
    public static func setStatus(base: URL, index: Int, status: Int) throws {
        let mbx = base.appendingPathExtension("mbx")
        let toc = base.appendingPathExtension("toc")
        guard let data = try? Data(contentsOf: mbx) else { throw MutateError.notFound }
        var entries = MailboxIO.alignedEntries(mbxBytes: [UInt8](data), tocURL: toc)
        guard index >= 1, index <= entries.count else { throw MutateError.outOfRange }
        let e = entries[index - 1]
        entries[index - 1] = TocEntry(offset: e.offset, length: e.length,
                                      status: status, priority: e.priority,
                                      date: e.date, to: e.to, subject: e.subject)
        do { try TocWriter.data(entries: entries).write(to: toc) }
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

        let tocValid = MailboxIO.tocIsValid(mbxBytes: bytes, tocURL: toc)
        var entries = MailboxIO.alignedEntries(mbxBytes: bytes, tocURL: toc)
        let rec = recs[index - 1]
        let end = min(rec.offset + rec.length, bytes.count)
        let recordBytes = Array(bytes[rec.offset..<end])
        let removedEntry = entries[index - 1]

        do {
            try MailboxIO.backupOnce(mbx)
            var newData = Data()
            newData.append(contentsOf: bytes[0..<rec.offset])
            if end < bytes.count { newData.append(contentsOf: bytes[end...]) }
            try MailboxIO.atomicWrite(newData, to: mbx)
        } catch { throw MutateError.ioError(error.localizedDescription) }

        // Update the TOC only if it was a valid cache: drop the entry and shift
        // every later offset left by the removed span. If it wasn't valid, drop
        // the file so the reader rescans rather than trusting fabricated status.
        if tocValid {
            entries.remove(at: index - 1)
            let shift = rec.length
            for k in (index - 1)..<entries.count {
                let e = entries[k]
                entries[k] = TocEntry(offset: e.offset - shift, length: e.length,
                                      status: e.status, priority: e.priority,
                                      date: e.date, to: e.to, subject: e.subject)
            }
            try? TocWriter.data(entries: entries).write(to: toc)
        } else if FileManager.default.fileExists(atPath: toc.path) {
            try? FileManager.default.removeItem(at: toc)
        }
        return (recordBytes, removedEntry)
    }

    /// Move one message from `source` to `dest` (Eudora "delete" = move to
    /// Trash). Removes it from the source and appends it to the destination,
    /// carrying its status/priority/date/subject.
    public static func move(from source: URL, index: Int, to dest: URL) throws {
        let (recordBytes, entry) = try remove(base: source, index: index)
        try appendRecord(recordBytes, entry: entry, to: dest)
    }

    /// Append a raw record (envelope line + message) to a mailbox, updating its
    /// TOC. Shared by move.
    static func appendRecord(_ recordBytes: [UInt8], entry: TocEntry, to dest: URL) throws {
        let mbx = dest.appendingPathExtension("mbx")
        let toc = dest.appendingPathExtension("toc")
        var existing = (try? Data(contentsOf: mbx)) ?? Data()
        let tocValid = MailboxIO.tocIsValid(mbxBytes: [UInt8](existing), tocURL: toc)
        var entries = MailboxIO.alignedEntries(mbxBytes: [UInt8](existing), tocURL: toc)

        // Ensure the new record starts at a line boundary (the envelope
        // separator is only recognized at a line start).
        if let last = existing.last, last != 0x0A, last != 0x0D {
            existing.append(contentsOf: [0x0D, 0x0A])
        }
        let newOffset = existing.count

        do {
            try MailboxIO.backupOnce(mbx)
            var grown = existing
            grown.append(contentsOf: recordBytes)
            try MailboxIO.atomicWrite(grown, to: mbx)
        } catch { throw MutateError.ioError(error.localizedDescription) }

        // Only extend an already-valid TOC; otherwise drop it so the reader
        // rescans (never fabricate status for the destination's prior messages).
        if tocValid {
            entries.append(TocEntry(offset: newOffset, length: recordBytes.count,
                                    status: entry.status, priority: entry.priority,
                                    date: entry.date, to: entry.to, subject: entry.subject))
            try? TocWriter.data(entries: entries).write(to: toc)
        } else if FileManager.default.fileExists(atPath: toc.path) {
            try? FileManager.default.removeItem(at: toc)
        }
    }
}

import Foundation

/// Message mutations written back to the Eudora tree in native format:
/// mark read/unread (TOC only), remove a message, and move a message between
/// mailboxes. `.mbx` stays the source of truth; the `.toc` is rewritten to
/// match. Every `.mbx` change is backed up once and written atomically.
public enum MailboxMutator {

    public enum MutateError: Error { case notFound, outOfRange, ioError(String) }

    // Eudora status bytes (from summary.h).
    public static let statusUnread = 0
    public static let statusRead = 1
    /// A message composed but not yet sent — a draft sitting in Out.
    public static let statusUnsent = 9
    /// Delivered. What an unsent message becomes once SMTP accepts it.
    public static let statusSent = 8
    /// Tried to send and couldn't.
    ///
    /// Eudora's own `MS_UNSENDABLE`, reused rather than invented: the status is
    /// a single byte written into a format real Eudora also reads, and picking
    /// an unused value would make these messages display as `?` there. The
    /// meaning is close enough — Eudora used it for a message it would not send,
    /// this uses it for one it could not.
    public static let statusSendError = 5

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

    /// Replace one message's bytes in place, keeping its position in the mailbox.
    ///
    /// This is what editing a draft needs. `setStatus` can only touch the TOC's
    /// cached columns, and append-then-remove would move the message to the end
    /// of Out every time it was saved — so a draft you edited three times would
    /// have wandered past everything queued after it.
    ///
    /// The new record is almost never the same length as the old one, so every
    /// later message's offset shifts. That is the whole difficulty, and it is
    /// handled exactly as `remove` handles it: rewrite the `.mbx` around the
    /// replaced span, then walk the `.toc` adjusting each later entry by the
    /// difference. A `.toc` that doesn't match the mailbox is deleted rather than
    /// patched, so the reader rescans instead of trusting a bad index.
    ///
    /// `messageData` is the assembled RFC-822 body *without* a `From ` envelope
    /// line; this writes one, the same way `Outbox.append` does, so the caller
    /// deals only in message bytes.
    ///
    /// What a replacement did to the mailbox around it.
    public struct ReplaceResult {
        /// The replaced record's 1-based index. Unchanged from the one passed
        /// in — the message stays where it was — but returned so callers read
        /// the invariant rather than assume it.
        public let index: Int
        /// Byte offset of the replaced record. Also unchanged.
        public let offset: Int
        /// How far every record *after* this one moved: positive if the new
        /// version is longer, negative if shorter.
        ///
        /// Callers holding offsets into this mailbox — an open draft window, say
        /// — must add this to any offset greater than `offset`, or they will be
        /// pointing at the wrong bytes. Nothing detects that for them: a stale
        /// offset either fails to resolve or, worse, resolves to a different
        /// real message.
        public let delta: Int
    }

    @discardableResult
    public static func replace(base: URL,
                               index: Int,
                               messageData: Data,
                               status: Int,
                               who: String,
                               subject: String,
                               date: Date = Date()) throws -> ReplaceResult {
        let mbx = base.appendingPathExtension("mbx")
        let toc = base.appendingPathExtension("toc")
        // Refuse if Eudora itself looks to have the mailbox open, the same test
        // `Outbox.append` makes. Rewriting a record underneath a running Eudora
        // would corrupt whatever it later flushed.
        if FileManager.default.fileExists(atPath: base.appendingPathExtension("lck").path) {
            throw MutateError.ioError("the mailbox is locked (a .lck file is next to it)")
        }
        guard let data = try? Data(contentsOf: mbx) else { throw MutateError.notFound }
        let bytes = [UInt8](data)
        let recs = Mbox.findRecords(bytes)
        guard index >= 1, index <= recs.count else { throw MutateError.outOfRange }

        let rec = recs[index - 1]
        let end = min(rec.offset + rec.length, bytes.count)

        let record = Mbox.record(messageData: messageData, date: date)
        let delta = record.count - (end - rec.offset)

        do {
            try MailboxIO.backupOnce(mbx)
            var newData = Data()
            newData.append(contentsOf: bytes[0..<rec.offset])
            newData.append(record)
            if end < bytes.count { newData.append(contentsOf: bytes[end...]) }
            try MailboxIO.atomicWrite(newData, to: mbx)
        } catch { throw MutateError.ioError(error.localizedDescription) }

        if let entries0 = Toc.read(toc), tocConsistent(entries0, recs: recs) {
            let rewritten = entries0.map { e -> TocEntry in
                if e.offset == rec.offset {
                    // The replaced message: new length and new cached columns,
                    // same offset.
                    return TocEntry(offset: e.offset, length: record.count,
                                    status: status, priority: e.priority,
                                    date: Mbox.tocDateString(date),
                                    to: who, subject: subject)
                }
                // Everything after it slides by the size difference. Everything
                // before is untouched — `delta` must not be applied to it.
                let off = e.offset > rec.offset ? e.offset + delta : e.offset
                return TocEntry(offset: off, length: e.length, status: e.status,
                                priority: e.priority, date: e.date,
                                to: e.to, subject: e.subject)
            }
            try? TocWriter.data(entries: rewritten).write(to: toc)
        } else if FileManager.default.fileExists(atPath: toc.path) {
            try? FileManager.default.removeItem(at: toc)
        }
        return ReplaceResult(index: index, offset: rec.offset, delta: delta)
    }

    /// The `Message-ID` header of one record, without parsing the rest of the
    /// mailbox.
    ///
    /// Exists so a caller holding a byte offset can check that it still names
    /// the message it thinks it does. An offset alone is not enough: removing an
    /// earlier record shifts everything after it left, and if the removed
    /// record happened to be the same length as the one being tracked, the stale
    /// offset lands exactly on a *different* real message. Nothing detects that
    /// — `replace` would overwrite someone's mail and `remove` would delete it.
    public static func messageID(base: URL, index: Int) -> String? {
        guard let (record, _) = try? readRecord(base: base, index: index) else { return nil }
        let rec = MboxRecord(offset: 0, length: record.count)
        let part = MIMEParser.parse(Mbox.messageBytes(record, rec))
        return part.header("Message-ID")?.trimmingCharacters(in: .whitespaces)
    }

    /// Permanently remove one message from a mailbox (used for a message already
    /// in Trash). Returns the removed record bytes + its TOC entry.
    ///
    /// The single-message case of `removeMany`, kept as the API every existing
    /// caller uses. One implementation on purpose: the offset-shift arithmetic
    /// is the part of this file that breaks silently when duplicated, so the
    /// batch path is the *only* path.
    @discardableResult
    public static func remove(base: URL, index: Int) throws -> (record: [UInt8], entry: TocEntry) {
        guard let one = try removeMany(base: base, indices: [index]).first else {
            throw MutateError.outOfRange     // unreachable: removeMany validates
        }
        return one
    }

    /// Permanently remove several messages in **one rewrite** of the `.mbx` and
    /// one rewrite of the `.toc`.
    ///
    /// This exists because a loop over `remove` is the offset-shift bug class
    /// this codebase keeps fighting: removing one message shifts every later
    /// record's offset, so the caller's remaining indices silently name
    /// different messages. Taking every index against the *same* snapshot of the
    /// mailbox makes the order the caller passes them in irrelevant — they are
    /// deduplicated, validated together, and cut out in a single ascending pass.
    ///
    /// Returns the removed records + TOC entries **in ascending index order**,
    /// whatever order the indices arrived in.
    @discardableResult
    public static func removeMany(base: URL, indices: [Int]) throws -> [(record: [UInt8], entry: TocEntry)] {
        let unique = Set(indices).sorted()
        guard !unique.isEmpty else { return [] }
        let mbx = base.appendingPathExtension("mbx")
        let toc = base.appendingPathExtension("toc")
        guard let data = try? Data(contentsOf: mbx) else { throw MutateError.notFound }
        let bytes = [UInt8](data)
        let recs = Mbox.findRecords(bytes)
        // Validate the whole batch before touching anything: one bad index must
        // not leave the mailbox half-mutated.
        guard let first = unique.first, first >= 1,
              let last = unique.last, last <= recs.count else { throw MutateError.outOfRange }

        // The .toc read once and keyed by offset, not re-read per message as
        // `oneEntry` would. `uniquingKeysWith` is defensive only — a .toc with
        // duplicate offsets is already inconsistent and gets dropped below.
        let tocByOffset: [Int: TocEntry]? = Toc.read(toc).map { entries in
            Dictionary(entries.map { ($0.offset, $0) }, uniquingKeysWith: { a, _ in a })
        }

        // The byte spans to cut, ascending (unique is sorted and record offsets
        // increase with index), and what they contained.
        var removed: [(record: [UInt8], entry: TocEntry)] = []
        var spans: [(start: Int, end: Int)] = []
        removed.reserveCapacity(unique.count)
        spans.reserveCapacity(unique.count)
        for index in unique {
            let rec = recs[index - 1]
            let end = min(rec.offset + rec.length, bytes.count)
            spans.append((start: rec.offset, end: end))
            let entry = tocByOffset?[rec.offset] ?? synthesizedEntry(bytes: bytes, rec: rec)
            removed.append((record: Array(bytes[rec.offset..<end]), entry: entry))
        }

        // One pass, one atomic write: keep the bytes between the cut spans.
        do {
            try MailboxIO.backupOnce(mbx)
            var newData = Data()
            newData.reserveCapacity(bytes.count)
            var cursor = 0
            for span in spans {
                // `max` defends against overlapping records (a corrupt length
                // running into the next record); it must never crash the slice.
                let start = max(span.start, cursor)
                if start > cursor { newData.append(contentsOf: bytes[cursor..<start]) }
                cursor = max(cursor, span.end)
            }
            if cursor < bytes.count { newData.append(contentsOf: bytes[cursor...]) }
            try MailboxIO.atomicWrite(newData, to: mbx)
        } catch { throw MutateError.ioError(error.localizedDescription) }

        // Keep the .toc consistent when its offsets are a valid (sub)set of the
        // mailbox — drop the removed entries (by offset) and shift every kept
        // offset left by the total length of the removed spans before it. This
        // preserves status even for a mailbox with deleted ghosts. Only a
        // genuinely inconsistent .toc is dropped (reader rescans). Never parses
        // the whole mailbox.
        if let entries0 = Toc.read(toc), tocConsistent(entries0, recs: recs) {
            let removedOffsets = Set(spans.map { $0.start })
            // Prefix sums of the cut lengths, so each kept entry's shift is a
            // binary search rather than a rescan of every span — a mailbox can
            // hold tens of thousands of entries.
            let starts = spans.map { $0.start }
            var prefix: [Int] = [0]
            prefix.reserveCapacity(spans.count + 1)
            for s in spans { prefix.append(prefix[prefix.count - 1] + (s.end - s.start)) }

            var kept: [TocEntry] = []
            kept.reserveCapacity(max(0, entries0.count - removedOffsets.count))
            for e in entries0 where !removedOffsets.contains(e.offset) {
                // How many cut spans start before this offset (they are disjoint
                // from it — the offset survived the removedOffsets test).
                var lo = 0, hi = starts.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if starts[mid] < e.offset { lo = mid + 1 } else { hi = mid }
                }
                kept.append(TocEntry(offset: e.offset - prefix[lo], length: e.length,
                                     status: e.status, priority: e.priority,
                                     date: e.date, to: e.to, subject: e.subject))
            }
            try? TocWriter.data(entries: kept).write(to: toc)
        } else if FileManager.default.fileExists(atPath: toc.path) {
            try? FileManager.default.removeItem(at: toc)
        }
        return removed
    }

    /// Move one message from `source` to `dest` (Eudora "delete" = move to
    /// Trash). Appends it to the destination **first**, then removes it from the
    /// source — so an interrupted/failed move can never lose the message (worst
    /// case it lands in both). Carries its status/priority/date/subject.
    public static func move(from source: URL, index: Int, to dest: URL) throws {
        try moveMany(from: source, indices: [index], to: dest)
    }

    /// Move several messages in one operation: every record is read against the
    /// same snapshot of the source, appended to the destination **in mailbox
    /// order** (so they arrive in the order they sat in the source, not the
    /// order they were clicked), and then removed from the source in a single
    /// `removeMany` rewrite. Same crash-safety as `move`: append first, remove
    /// after, worst case a message lands in both.
    public static func moveMany(from source: URL, indices: [Int], to dest: URL) throws {
        let unique = Set(indices).sorted()
        guard !unique.isEmpty else { return }
        let mbx = source.appendingPathExtension("mbx")
        let toc = source.appendingPathExtension("toc")
        guard let data = try? Data(contentsOf: mbx) else { throw MutateError.notFound }
        let bytes = [UInt8](data)
        let recs = Mbox.findRecords(bytes)
        // Validate before the first append: failing between appends would land
        // *some* of the batch in the destination with all of it still in the
        // source, which reads as duplication rather than safety.
        guard let first = unique.first, first >= 1,
              let last = unique.last, last <= recs.count else { throw MutateError.outOfRange }

        let tocByOffset: [Int: TocEntry]? = Toc.read(toc).map { entries in
            Dictionary(entries.map { ($0.offset, $0) }, uniquingKeysWith: { a, _ in a })
        }
        for index in unique {
            let rec = recs[index - 1]
            let end = min(rec.offset + rec.length, bytes.count)
            let entry = tocByOffset?[rec.offset] ?? synthesizedEntry(bytes: bytes, rec: rec)
            try appendRecord(Array(bytes[rec.offset..<end]), entry: entry, to: dest)
        }
        try removeMany(base: source, indices: unique)
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
        return synthesizedEntry(bytes: bytes, rec: rec)
    }

    /// The fallback half of `oneEntry`: a TOC entry made by parsing just this
    /// one message, for a mailbox with no usable `.toc`. Split out so the batch
    /// operations, which read the `.toc` once up front, can synthesize misses
    /// without re-reading it per message.
    private static func synthesizedEntry(bytes: [UInt8], rec: MboxRecord) -> TocEntry {
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

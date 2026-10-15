import Foundation

/// Write-back into a Eudora mailbox in native format — the first thing that
/// writes to the tree. Used to record a sent message in the Out box.
///
/// Safety stance (matches the architecture doc):
///   • back up the `.mbx` once, before the first write (`<name>.mbx.bak`);
///   • write the new `.mbx` to a temp file and atomically replace;
///   • keep `.mbx` as truth — update `.toc` by appending one entry to the
///     existing (valid) index so prior messages keep their cached status;
///     if the `.toc` is missing or stale, remove it so the reader rebuilds by
///     scanning rather than trusting a mismatched cache.
public enum Outbox {

    public enum WriteError: Error { case locked, ioError(String) }

    public struct AppendResult {
        public let messageIndex: Int   // 1-based position in the mailbox
        /// Byte offset of the new record in the `.mbx`.
        ///
        /// The durable way to refer back to this message. An index is a
        /// position and shifts the moment anything earlier is removed, which is
        /// no good for a draft the user may keep open and edit for an hour; the
        /// offset only changes if an *earlier* record is resized, and
        /// `MailboxMutator.replace` leaves the replaced record's own offset
        /// alone. `MailStore.indexOfRecord(at:offset:)` converts back when an
        /// index is needed for a mutation.
        public let messageOffset: Int
        public let didBackup: Bool
    }

    /// Append `messageData` (assembled RFC-822 bytes, CRLF) to `base`.mbx and
    /// update `base`.toc. `who`/`subject` populate the TOC cache columns.
    public static func append(messageData: Data,
                              to base: URL,
                              status: Int = 8,        // sent
                              priority: Int = 4,      // normal
                              who: String,
                              subject: String,
                              date: Date = Date()) throws -> AppendResult {
        let fm = FileManager.default
        let mbx = base.appendingPathExtension("mbx")
        let toc = base.appendingPathExtension("toc")
        let bak = mbx.appendingPathExtension("bak")

        // Refuse if something looks like an active lock next to the mailbox.
        if fm.fileExists(atPath: base.appendingPathExtension("lck").path) {
            throw WriteError.locked
        }

        let existing = (try? Data(contentsOf: mbx)) ?? Data()

        // One-time backup before the first mutation of this mailbox.
        var didBackup = false
        if !existing.isEmpty, !fm.fileExists(atPath: bak.path) {
            do { try existing.write(to: bak) ; didBackup = true }
            catch { throw WriteError.ioError("backup failed: \(error.localizedDescription)") }
        }

        // Through `Mbox.record` so this and `MailboxMutator.replace` build
        // byte-identical records — same separator, and the same guaranteed line
        // ending, without which the *next* record appended here would be
        // invisible to `findRecords`.
        let record = Mbox.record(messageData: messageData, date: date)

        // Pad if the mailbox we're appending to doesn't itself end at a line
        // boundary, or this record's separator won't be at a line start and
        // `findRecords` won't see it.
        //
        // `Mbox.record` guarantees the terminator of records written from here
        // on; it can say nothing about what is already on disk. That matters
        // concretely: earlier builds of this very code wrote unterminated
        // records, so a real Out mailbox may well end mid-line right now. The
        // consequence is worse than a merged record — the offset returned below
        // wouldn't be a record start, so `indexOfRecord` would never resolve it
        // and every save of that draft would append another copy.
        //
        // Prior TOC offsets are unaffected: the padding goes on the end.
        var grown = existing
        var newOffset = existing.count
        if let last = existing.last, last != 0x0A, last != 0x0D {
            grown.append(contentsOf: [0x0D, 0x0A])
            newOffset += 2
        }
        let newLength = record.count
        grown.append(record)
        do {
            let tmp = mbx.deletingLastPathComponent()
                .appendingPathComponent(".\(mbx.lastPathComponent).tmp-\(UUID().uuidString)")
            try grown.write(to: tmp)
            if fm.fileExists(atPath: mbx.path) {
                _ = try fm.replaceItemAt(mbx, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: mbx)   // first message into a fresh mailbox
            }
        } catch {
            throw WriteError.ioError("mbx write failed: \(error.localizedDescription)")
        }

        // Record counts: before/after append.
        let priorRecords = Mbox.findRecords([UInt8](existing))
        let newEntry = TocEntry(offset: newOffset, length: newLength,
                                status: status, priority: priority,
                                date: Mbox.tocDateString(date),
                                to: who, subject: subject)

        // Update the TOC if the existing one is valid (append, preserving prior
        // cached status); otherwise drop it so the reader scans cleanly.
        //
        // The test is `tocConsistent` — the same subset rule `remove` and
        // `replace` use — and *not* the exact one-entry-per-record equality this
        // used to demand. That stricter rule failed on any mailbox with deleted
        // -but-not-compacted ghosts, which is the ordinary state of real Eudora
        // mail, and the failure branch deletes the `.toc`. That was tolerable
        // when appending only happened on send; now that a record is written
        // every time a message is *opened*, it would have thrown away Out's
        // cached statuses on the first ⌘N.
        if let loaded = Toc.load(toc),
           MailboxMutator.tocConsistent(loaded.entries, recs: priorRecords) {
            let original = loaded.data, prior = loaded.entries
            // Patched, not rebuilt: the prior entries keep the bytes `TocEntry`
            // doesn't model. See `TocWriter.patched`.
            var list: [(source: Int?, entry: TocEntry)] = []
            list.reserveCapacity(prior.count + 1)
            for (k, e) in prior.enumerated() { list.append((source: k, entry: e)) }
            list.append((source: nil, entry: newEntry))
            try? TocWriter.patched(original: original, originalEntries: prior, entries: list).write(to: toc)
        } else if priorRecords.isEmpty {
            // A mailbox with no index yet — usually a brand-new Out. Write one
            // rather than leaving none, or every message in it would be
            // status-less forever and a draft could never be marked unsent.
            //
            // An existing index with no entries — Eudora 7 leaves one for an
            // emptied mailbox — is patched rather than replaced, so its folder
            // header survives.
            if let loaded = Toc.load(toc) {
                try? TocWriter.patched(original: loaded.data, originalEntries: loaded.entries,
                                       entries: [(source: nil, entry: newEntry)]).write(to: toc)
            } else {
                try? TocWriter.data(entries: [newEntry]).write(to: toc)
            }
        } else if fm.fileExists(atPath: toc.path) {
            try? fm.removeItem(at: toc)
        }

        return AppendResult(messageIndex: priorRecords.count + 1,
                            messageOffset: newOffset,
                            didBackup: didBackup)
    }
}

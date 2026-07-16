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
        public let didBackup: Bool
    }

    private static let asctime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"     // Eudora pseudo-envelope date
        return f
    }()
    private static let tocDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d yyyy"              // cached short date, fixture-style
        return f
    }()

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

        // Build the record: pseudo-envelope separator line + message bytes.
        let sep = "From ???@??? \(asctime.string(from: date))\r\n"
        var record = Data(sep.utf8)
        record.append(messageData)

        let newOffset = existing.count
        let newLength = record.count

        // Atomically write the grown mailbox.
        var grown = existing
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
                                date: tocDate.string(from: date),
                                to: who, subject: subject)

        // Update the TOC if the existing one is valid (append, preserving prior
        // cached status); otherwise drop it so the reader scans cleanly.
        if let prior = Toc.read(toc),
           prior.count == priorRecords.count,
           !zip(prior, priorRecords).contains(where: { $0.0.offset != $0.1.offset }) {
            let tocData = TocWriter.data(entries: prior + [newEntry])
            try? tocData.write(to: toc)
        } else if fm.fileExists(atPath: toc.path) {
            try? fm.removeItem(at: toc)
        }

        return AppendResult(messageIndex: priorRecords.count + 1, didBackup: didBackup)
    }
}

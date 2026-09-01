import Foundation

/// Points a message's `X-Attachments:` header at where the file actually is.
///
/// `RecordedAttachment` explains the problem: Eudora 7 recorded a *staging*
/// path for any file dragged in from the Mac, so 696 sends name a per-drag
/// folder under `$TMPDIR` that macOS purged years ago, while the file itself
/// sits untouched somewhere in the home directory. A disk scan matched 370 of
/// those names to a real file. This writes that answer back into the mail, so
/// the knowledge lives with the message rather than in a list beside it.
///
/// **Only staging entries are rewritten.** An entry whose recorded path already
/// names a real place is left byte-for-byte alone — `pathRecordsOrigin` decides,
/// exactly as the display does. That is also what makes this idempotent: a
/// rewritten entry holds a POSIX path, whose staging segments are all
/// backslash-delimited (`\temp\`, `\var\folders\`) and so cannot match, and
/// `Locations.load` refuses a path containing a backslash to keep it that way.
///
/// **Everything else is preserved at the byte level.** Not "re-serialized to the
/// same thing" — the record is spliced, so only the bytes of a replaced entry
/// change. That matters more than it sounds: header values here are CP1252,
/// `MIMEParser.parseHeaders` decodes them as UTF-8, and a decode/re-encode round
/// trip would silently turn every non-ASCII byte in an untouched entry into
/// `EF BF BD`. Separators, whitespace, folding and line endings survive for the
/// same reason. (An *inserted* path is written as UTF-8, which is what our own
/// reader decodes; documented rather than accidental, and it is the only new
/// non-ASCII this writes.)
///
/// **Why this is not a text edit.** `.toc` caches every message's absolute byte
/// offset and length, so changing a header's length shifts every later record in
/// that mailbox. Rewriting the `.mbx` without the `.toc` leaves an index whose
/// offsets name the middle of the wrong message.
///
/// **Why the `.toc` is patched and not rebuilt.** `TocWriter` writes the seven
/// fields `Toc` models and zeroes the rest, and both files say the layout is a
/// reverse-engineering that shouldn't be pointed at real mail unvalidated.
/// Measured over `phaseX`: **97% of entries carry non-zero bytes outside those
/// fields** (a timestamp at 8-11, flags at 14-15, more at 178-212), a second
/// timestamp sits in the tail of the 32-byte date field at 46-49, and 116 of 120
/// sampled `.toc` folder headers are non-empty. Regenerating an index would
/// blank all of that for every message in the mailbox, not just the changed
/// ones. So this rewrites four bytes of offset and four of length per entry and
/// leaves the other 210 alone.
///
/// **Why not `MailboxMutator.replace`.** It is built for drafts: it writes a
/// fresh `From ` envelope line at today's date and rebuilds the `.toc` through
/// `TocWriter`. Correct for a message being re-saved, wrong for a 2014 archive,
/// where the only bytes that should change are inside one header.
public enum RecordedAttachmentRelink {

    // MARK: - What a run does

    /// One header rewritten, or that would be.
    public struct Change {
        /// 1-based record index in the mailbox, for reporting.
        public let index: Int
        /// Byte offset of the record before the rewrite.
        public let offset: Int
        /// Recorded name → the path it is being pointed at. A header can carry
        /// several attachments and relink only some of them.
        public let relinked: [(name: String, path: String)]
        /// Bytes this record grew by, negative if it shrank.
        public let delta: Int
    }

    public enum Disposition: Equatable {
        /// No message in this mailbox names a file we can place.
        case nothingToDo
        /// A dry run that found work.
        case wouldRewrite
        case rewritten
        /// The `.toc` does not describe the `.mbx`, so the offsets could not be
        /// patched. Skipped rather than rebuilt — see `Outcome.tocPatched`.
        case skippedTocMismatch
        /// A previous run's backup is still there. Refusing rather than
        /// overwriting the only pristine copy.
        case skippedBackupExists(String)
    }

    public struct Outcome {
        public let base: URL
        public let disposition: Disposition
        public let recordCount: Int
        public let changes: [Change]
        /// Bytes the mailbox grew by, negative if it shrank.
        public let delta: Int
        /// Whether the `.toc`'s offsets were patched. False when the mailbox has
        /// no `.toc` at all, and false when the patch could not be written — in
        /// which case the `.toc` has been removed and the reader will rescan.
        public let tocPatched: Bool
        /// Set when the `.toc` had to be removed because its patched form could
        /// not be written. Not an error — the reader rescans — but worth saying.
        public let tocRemoved: Bool

        public var isEmpty: Bool { changes.isEmpty }
    }

    public enum RelinkError: Error, CustomStringConvertible {
        case locked(String)
        case unreadable(String)
        case ioError(String)

        public var description: String {
            switch self {
            case .locked(let s):     return "mailbox locked (a .lck is next to it): \(s)"
            case .unreadable(let s): return "cannot read: \(s)"
            case .ioError(let s):    return "write failed: \(s)"
            }
        }
    }

    /// Suffix of the copy taken before a mailbox is first rewritten.
    ///
    /// Deliberately not `MailboxIO.backupOnce`'s `.bak`: that one skips silently
    /// when a backup already exists, and the real tree already has `.mbx.bak`
    /// files from ordinary draft edits, so it would have quietly protected
    /// nothing. This name is ours, and its presence is a refusal, not a skip.
    public static let backupSuffix = "prerelink"

    // MARK: - Locations

    /// Recorded filename → the file's real location, from the curated list.
    /// Lookup is by name, because for these entries the name is the only thing
    /// the header got right.
    public struct Locations {
        private var exact: [String: String] = [:]
        /// Names given two different locations. Refused rather than guessed at:
        /// duplicate basenames are the likely case in a whole-disk scan, and the
        /// cost of guessing is one file's location written into another file's
        /// message.
        private var conflicted: Set<String> = []
        /// Paths rejected by `load`, with the reason, for the caller to report.
        public private(set) var rejected: [(name: String, path: String, why: String)] = []

        public init(_ pairs: [(name: String, path: String)] = []) {
            for (name, path) in pairs { insert(name: name, path: path) }
        }

        /// Validates here rather than only in `load`, because `init` and this
        /// are both public doors into the same table and idempotence rests on
        /// nothing unwritable ever reaching a header.
        public mutating func insert(name: String, path: String) {
            if let why = Self.objection(to: path) {
                rejected.append((name: name, path: path, why: why))
                return
            }
            let key = RecordedAttachmentRelink.normalize(name)
            if let existing = exact[key], existing != path {
                conflicted.insert(key)
                rejected.append((name: name, path: path,
                                 why: "two different locations for this name, "
                                    + "so neither will be used"))
                return
            }
            exact[key] = path
        }

        public var count: Int { exact.count - conflicted.count }
        public var conflictedNames: [String] { Array(conflicted) }

        /// The usable pairs, so a caller can check the locations still exist
        /// before writing any of them into the mail.
        public var pairs: [(name: String, path: String)] {
            exact.filter { !conflicted.contains($0.key) }
                 .map { (name: $0.key, path: $0.value) }
                 .sorted { $0.name < $1.name }
        }

        /// Drop one name. For the caller that has just found its file gone: a
        /// location that isn't there is worse than the staging path it would
        /// replace, which at least says honestly that it was a copy.
        public mutating func remove(name: String) {
            let key = RecordedAttachmentRelink.normalize(name)
            exact.removeValue(forKey: key)
            conflicted.remove(key)
        }

        /// The location recorded for `name`, or nil.
        ///
        /// The loose second pass exists because the *header* can be mangled, not
        /// the list. `MIMEParser.parseHeaders` decodes header bytes as UTF-8
        /// though Eudora wrote CP1252, so every non-ASCII byte in a filename
        /// arrives as U+FFFD: `CarterCaténaires.png` reaches us as
        /// `CarterCat<?>naires.png` and matches nothing. One CP1252 byte becomes
        /// exactly one replacement character, so it is matched as a
        /// single-character wildcard — and only against a non-ASCII character,
        /// since an ASCII byte could never have produced it. (The decode is a
        /// real bug and affects display too; see `RecordedAttachment`.)
        public func lookup(_ name: String) -> String? {
            let key = RecordedAttachmentRelink.normalize(name)
            if conflicted.contains(key) { return nil }
            if let hit = exact[key] { return hit }
            guard key.unicodeScalars.contains("\u{FFFD}") else { return nil }

            var found: String?
            for candidate in exact.keys where matchesLoosely(key, candidate) {
                if conflicted.contains(candidate) { return nil }
                if let found, found != exact[candidate] { return nil }
                found = exact[candidate]
            }
            return found
        }

        /// Equal length, equal wherever the header has no replacement character,
        /// and every wildcard standing for a non-ASCII character.
        private func matchesLoosely(_ header: String, _ candidate: String) -> Bool {
            let h = Array(header), c = Array(candidate)
            guard h.count == c.count else { return false }
            for i in 0..<h.count {
                if h[i] == "\u{FFFD}" {
                    guard let scalar = c[i].unicodeScalars.first,
                          !scalar.isASCII || c[i].unicodeScalars.count > 1
                    else { return false }
                    continue
                }
                if h[i] != c[i] { return false }
            }
            return true
        }

        /// A path this tool is willing to write into a header.
        ///
        /// A `;` would be split into two entries by `recordedPaths` on the next
        /// run — permanently corrupting the header and breaking idempotence —
        /// and a CR or LF would break the record itself. Both are legal in macOS
        /// filenames. A backslash is refused so a written path can never later
        /// look like a Windows staging path.
        static func objection(to path: String) -> String? {
            if !path.hasPrefix("/") { return "not an absolute path" }
            if path.contains(";") { return "contains a semicolon, which separates entries" }
            if path.contains("\\") { return "contains a backslash" }
            if path.contains(where: \.isNewline) { return "contains a line break" }
            return nil
        }

        /// Load the tab-separated `name<TAB>path` list. Blank lines and lines
        /// beginning `#` are ignored, so the file can carry a header comment.
        ///
        /// Split on any newline and trimmed with `.whitespacesAndNewlines`: a
        /// CRLF file would otherwise give every path a trailing CR, which would
        /// then be spliced into a header line.
        public static func load(contentsOf url: URL) throws -> Locations {
            let text = try String(contentsOf: url, encoding: .utf8)
            var out = Locations()
            for line in text.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("#") { continue }
                let cells = line.split(separator: "\t", maxSplits: 1,
                                       omittingEmptySubsequences: false)
                guard cells.count == 2 else { continue }
                let name = cells[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let path = cells[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !path.isEmpty else { continue }
                out.insert(name: name, path: path)      // validates; see `insert`
            }
            return out
        }
    }

    /// One spelling for one filename.
    ///
    /// NFC because macOS hands back decomposed names from `readdir` while the
    /// mail header holds whatever Eudora wrote; lowercased because the volume is
    /// case-insensitive; NBSP folded to a space because at least one filename on
    /// disk carries one where the header has a plain space, which is why the
    /// original disk scan missed that file entirely.
    static func normalize(_ name: String) -> String {
        String(name.map { $0 == "\u{00A0}" ? " " : $0 })
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    // MARK: - Splicing one header value

    /// A `;`-separated entry's byte span within the header value, trimmed of
    /// surrounding whitespace and line breaks so the separators and any folding
    /// stay where they are.
    private struct EntrySpan {
        let start: Int
        let end: Int
        var isEmpty: Bool { start >= end }
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    /// The entries in `bytes[range]`, split on `;` and trimmed.
    private static func entrySpans(_ bytes: [UInt8], in range: Range<Int>) -> [EntrySpan] {
        var spans: [EntrySpan] = []
        var start = range.lowerBound
        var i = range.lowerBound
        while i <= range.upperBound {
            if i == range.upperBound || bytes[i] == 0x3B {          // ';'
                var s = start, e = i
                while s < e, isSpace(bytes[s]) { s += 1 }
                while e > s, isSpace(bytes[e - 1]) { e -= 1 }
                if s < e { spans.append(EntrySpan(start: s, end: e)) }
                start = i + 1
            }
            i += 1
        }
        return spans
    }

    /// The record with its `X-Attachments` entries repointed, or nil when there
    /// is nothing to change. Only the bytes of a replaced entry differ.
    static func rewrittenRecord(_ record: [UInt8], using locations: Locations)
        -> (record: [UInt8], relinked: [(name: String, path: String)])? {

        guard let span = headerValueSpan(record, name: RecordedAttachment.headerName)
        else { return nil }

        var substitutions: [(EntrySpan, [UInt8])] = []
        var relinked: [(name: String, path: String)] = []

        for entry in entrySpans(record, in: span) {
            // Decoding here is for *matching* only; an entry's bytes are never
            // re-encoded unless it is the one being replaced.
            //
            // CP1252 first, because that is what Eudora wrote and it loses
            // nothing. The UTF-8 reading is tried second because it is what the
            // *display* does, so a name recorded in the list from a screen or a
            // previous UTF-8 pass still matches; the wildcard inside `lookup` is
            // the last resort for the same reason.
            let bytes = Array(record[entry.start..<entry.end])
            let viaCP1252 = CP1252.decode(bytes)
            guard !RecordedAttachment.pathRecordsOrigin(viaCP1252) else { continue }

            let viaUTF8 = String(decoding: bytes, as: UTF8.self)
            let trueName = RecordedAttachment.displayName(fromRecordedPath: viaCP1252)
            let shownName = RecordedAttachment.displayName(fromRecordedPath: viaUTF8)
            guard let located = locations.lookup(trueName)
                    ?? locations.lookup(shownName) else { continue }
            substitutions.append((entry, Array(located.utf8)))
            relinked.append((name: trueName, path: located))
        }
        guard !substitutions.isEmpty else { return nil }

        var out: [UInt8] = []
        out.reserveCapacity(record.count)
        var cursor = 0
        for (entry, replacement) in substitutions {
            out.append(contentsOf: record[cursor..<entry.start])
            out.append(contentsOf: replacement)
            cursor = entry.end
        }
        out.append(contentsOf: record[cursor...])
        return (out, relinked)
    }

    // MARK: - Finding the header

    /// Byte range of the `X-Attachments` *value* inside one record: from just
    /// after the colon to the end of its last folded continuation line. Nil when
    /// the header is absent, or when the record has no header/body separator at
    /// all — a record whose body would otherwise be scanned as headers.
    ///
    /// Byte-level rather than via `MIMEParser` because the record has to come
    /// back out identical except for the entries being replaced.
    static func headerValueSpan(_ record: [UInt8], name: String) -> Range<Int>? {
        let target = Array(name.lowercased().utf8)
        guard let bodyStart = headerBlockEnd(record) else { return nil }

        // Skip the `From ???@??? …` envelope line; headers start after it.
        var i = lineEnd(record, from: 0).next
        while i < bodyStart {
            let (end, next) = lineEnd(record, from: i)
            let isContinuation = end > i && (record[i] == 0x20 || record[i] == 0x09)
            if !isContinuation, matchesHeaderName(record, at: i, end: end, target) {
                var contentEnd = end
                var j = next
                while j < bodyStart {
                    let (e2, n2) = lineEnd(record, from: j)
                    guard e2 > j, record[j] == 0x20 || record[j] == 0x09 else { break }
                    contentEnd = e2
                    j = n2
                }
                guard let colon = record[i..<end].firstIndex(of: 0x3A) else { return nil }
                let valueStart = min(colon + 1, contentEnd)
                return valueStart..<contentEnd
            }
            i = next
        }
        return nil
    }

    /// True when the line at `i` is `<target>:` case-insensitively.
    private static func matchesHeaderName(_ record: [UInt8], at i: Int, end: Int,
                                          _ target: [UInt8]) -> Bool {
        guard i + target.count < end else { return false }
        for (k, byte) in target.enumerated() {
            let here = record[i + k]
            let lower = (here >= 0x41 && here <= 0x5A) ? here + 0x20 : here
            if lower != byte { return false }
        }
        return record[i + target.count] == 0x3A     // ':'
    }

    /// Index of the blank line separating headers from body, or nil when the
    /// record has none. Nil rather than "the whole record is headers": without a
    /// separator we cannot tell a header from a body line beginning
    /// `X-Attachments:`, and guessing wrong rewrites message text.
    private static func headerBlockEnd(_ record: [UInt8]) -> Int? {
        var i = lineEnd(record, from: 0).next
        while i < record.count {
            let (end, next) = lineEnd(record, from: i)
            if end == i { return i }
            i = next
        }
        return nil
    }

    /// `(end, next)` for the line beginning at `i`: `end` is the index of its
    /// terminator (or the record's end), `next` the start of the following line.
    /// Handles CRLF, LF and lone CR, because a tree this old holds all three.
    private static func lineEnd(_ record: [UInt8], from i: Int) -> (end: Int, next: Int) {
        var j = i
        while j < record.count, record[j] != 0x0A, record[j] != 0x0D { j += 1 }
        guard j < record.count else { return (record.count, record.count) }
        if record[j] == 0x0D, j + 1 < record.count, record[j + 1] == 0x0A {
            return (j, j + 2)
        }
        return (j, j + 1)
    }

    // MARK: - Whole mailboxes

    /// Relink one mailbox. With `apply` false nothing is written, and the
    /// returned changes are exactly what a later `apply: true` would do.
    ///
    /// A dry run scans but never assembles the new mailbox: over a 12 GB tree
    /// that would be 12 GB of pointless copying, and the peak for a single 613 MB
    /// Trash would be three times the file.
    ///
    /// Refuses while a `.lck` file is present, the same test `Outbox.append` and
    /// `MailboxMutator.replace` make: rewriting records underneath a running
    /// Eudora would corrupt whatever it later flushed.
    @discardableResult
    public static func run(base: URL, locations: Locations, apply: Bool) throws -> Outcome {
        let mbx = base.appendingPathExtension("mbx")
        let toc = base.appendingPathExtension("toc")
        let fm = FileManager.default

        if fm.fileExists(atPath: base.appendingPathExtension("lck").path) {
            throw RelinkError.locked(base.lastPathComponent)
        }
        guard let data = try? Data(contentsOf: mbx) else {
            throw RelinkError.unreadable(mbx.lastPathComponent)
        }
        let bytes = [UInt8](data)
        let recs = Mbox.findRecords(bytes)

        // `out` is assembled only when there is something to write; on a dry run
        // the loop tracks offsets and lengths and copies nothing.
        var out: [UInt8] = []
        if apply { out.reserveCapacity(bytes.count) }
        var moved: [Int: (offset: Int, length: Int)] = [:]
        var changes: [Change] = []
        var cursor = 0
        var runningOffset = 0

        for (k, rec) in recs.enumerated() {
            if rec.offset > cursor {
                // Anything between records (there should be nothing) is carried
                // across untouched rather than dropped.
                if apply { out.append(contentsOf: bytes[cursor..<rec.offset]) }
                runningOffset += rec.offset - cursor
            }
            let end = min(rec.offset + rec.length, bytes.count)
            guard rec.offset < end else { continue }
            var record = Array(bytes[rec.offset..<end])
            if let r = rewrittenRecord(record, using: locations) {
                changes.append(Change(index: k + 1, offset: rec.offset,
                                      relinked: r.relinked,
                                      delta: r.record.count - record.count))
                record = r.record
            }
            moved[rec.offset] = (offset: runningOffset, length: record.count)
            if apply { out.append(contentsOf: record) }
            runningOffset += record.count
            cursor = end
        }
        if cursor < bytes.count {
            if apply { out.append(contentsOf: bytes[cursor...]) }
            runningOffset += bytes.count - cursor
        }

        let delta = runningOffset - bytes.count

        func outcome(_ d: Disposition, tocPatched: Bool = false,
                     tocRemoved: Bool = false) -> Outcome {
            Outcome(base: base, disposition: d, recordCount: recs.count,
                    changes: changes, delta: delta,
                    tocPatched: tocPatched, tocRemoved: tocRemoved)
        }

        // Ahead of every other check, so a mailbox with nothing to do is never
        // reported as blocked by a previous run's backup.
        guard !changes.isEmpty else { return outcome(.nothingToDo) }

        // A `.toc` whose entries don't line up with the mailbox cannot have its
        // offsets patched. Deleting it would be the easy answer and the wrong
        // one: it caches read/replied status, which exists nowhere else, and the
        // reader tolerates a far staler index than this check accepts. So the
        // mailbox is skipped and reported, and nothing is lost.
        let tocData = try? Data(contentsOf: toc)
        let newToc = tocData.flatMap { patchedToc($0, moved: moved) }
        if tocData != nil, newToc == nil { return outcome(.skippedTocMismatch) }

        // Checked before the dry run returns, not after: this tool is meant to
        // be re-run as the list grows, and every mailbox touched by an earlier
        // run has a backup sitting next to it. A report that promised work the
        // apply would then refuse would be a lie on every second run.
        let backup = mbx.appendingPathExtension(backupSuffix)
        let tocBackup = toc.appendingPathExtension(backupSuffix)
        if fm.fileExists(atPath: backup.path)
            || (tocData != nil && fm.fileExists(atPath: tocBackup.path)) {
            return outcome(.skippedBackupExists(backup.lastPathComponent))
        }
        guard apply else { return outcome(.wouldRewrite) }

        do {
            try fm.copyItem(at: mbx, to: backup)
            if tocData != nil { try fm.copyItem(at: toc, to: tocBackup) }
        } catch { throw RelinkError.ioError("backup: \(error.localizedDescription)") }

        // Order matters for the crash window, in two ways.
        //
        // The new mailbox is staged in full *before* anything is removed, so a
        // disk-full or permission failure costs nothing — in particular it must
        // not cost the `.toc`, whose read/replied flags exist nowhere else.
        //
        // Then the `.toc` goes before the `.mbx` is replaced, so an interruption
        // leaves "no index" — the reader rescans — rather than an index whose
        // offsets name the middle of the wrong message, which nothing detects
        // and which `MailStore` would still trust.
        let staged = mbx.deletingLastPathComponent()
            .appendingPathComponent(".\(mbx.lastPathComponent).relink-\(UUID().uuidString)")
        do {
            try Data(out).write(to: staged)
        } catch { throw RelinkError.ioError(error.localizedDescription) }

        do {
            if tocData != nil { try? fm.removeItem(at: toc) }
            _ = try fm.replaceItemAt(mbx, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw RelinkError.ioError(error.localizedDescription)
        }

        var patched = false
        var removed = false
        if let newToc {
            do {
                try MailboxIO.atomicWrite(newToc, to: toc)
                patched = true
            } catch {
                removed = true          // already gone; the reader will rescan
            }
        }
        return outcome(.rewritten, tocPatched: patched, tocRemoved: removed)
    }

    /// The `.toc` with each entry's offset and length updated, or nil when an
    /// entry does not name a record — in which case the index does not describe
    /// this mailbox and must not be patched.
    ///
    /// Four bytes of offset and four of length per entry. Every other byte of
    /// the 218, and the whole 104-byte folder header, is copied through: they
    /// carry timestamps, flags and window state that `Toc` does not model and
    /// that a rebuild would blank. See the type comment.
    static func patchedToc(_ data: Data, moved: [Int: (offset: Int, length: Int)]) -> Data? {
        var bytes = [UInt8](data)
        guard bytes.count >= Toc.folderSize else { return nil }
        let count = (bytes.count - Toc.folderSize) / Toc.entrySize
        guard count > 0 else { return nil }

        for k in 0..<count {
            let base = Toc.folderSize + k * Toc.entrySize
            let offset = Int(Toc.readU32LE(bytes, base))
            guard let m = moved[offset],
                  m.offset <= 0xFFFF_FFFF, m.length <= 0xFFFF_FFFF else { return nil }
            TocWriter.writeU32LE(&bytes, base, UInt32(m.offset))
            TocWriter.writeU32LE(&bytes, base + 4, UInt32(m.length))
        }
        return Data(bytes)
    }
}

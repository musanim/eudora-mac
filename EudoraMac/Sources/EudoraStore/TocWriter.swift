import Foundation

/// Writes the binary `.toc` index in the same layout `Toc` reads (104-byte
/// header + N × 218-byte entries, little-endian). Field offsets match `Toc`
/// exactly: offset@0, length@4, status@12, priority@16, date@18(32),
/// to@50(64), subject@114(64).
///
/// Same caveat as `Toc`: this layout is the eudora2unix reverse-engineering,
/// self-consistent with our reader/fixture but not yet field-validated against
/// a genuine Eudora `.toc`. Fine for the synthetic tree; treat with care before
/// pointing write-back at real mail.
///
/// **Two ways to write, and only one is for an existing index.** `data(entries:)`
/// builds an index from nothing: zeroed header, and each entry the seven
/// modelled fields over 211 zero bytes. That is right for a mailbox that has no
/// `.toc` yet and wrong for one that has: over `phaseX`, 97% of real entries and
/// 116 of 120 folder headers carry data outside those fields — Eudora 7's
/// timestamps, flags, label and window state, recorded nowhere else. Eudora 8
/// doesn't read them, so a rebuild breaks nothing visible; it just erases them,
/// once per status change. `patched(original:originalEntries:entries:)` is the
/// write for an existing index.
public enum TocWriter {
    /// A whole new index. For a mailbox with no `.toc` — never to rewrite one
    /// that exists; use `patched` for that.
    public static func data(entries: [TocEntry]) -> Data {
        var out = Data(count: Toc.folderSize)     // zeroed header; reader ignores it
        for e in entries { out.append(entryBytes(e)) }
        return out
    }

    /// Rewrite an existing index, keeping every byte the model doesn't cover.
    ///
    /// `original` is the `.toc` as read (`Toc.load`). Each output entry names
    /// the `source` it came from — its position among `original`'s entries —
    /// or nil for one that is new. A sourced entry starts as that entry's 218
    /// original bytes, and only the fields that **differ** from what was read
    /// are written over them; an unchanged field is not rewritten at all, so
    /// even the bytes after a string's terminator survive. A new entry is
    /// `entryBytes`. The 104-byte folder header is carried across unchanged.
    ///
    /// The order of `entries` is the order written, so dropping an entry is
    /// leaving it out and moving one is listing it elsewhere. A source index
    /// out of range is treated as new rather than trapping.
    ///
    /// The folder header is not adjusted. If Eudora 7 kept a count there it
    /// goes stale on an add or remove — as it already did, and worse, when the
    /// header was zeroed.
    ///
    /// `originalEntries`, when given, must be what `original` parses as — the
    /// pair `Toc.load` returns. It only saves a second parse, which on a big
    /// Trash is 22,000 entries' worth of string decoding per click.
    public static func patched(original: Data,
                               originalEntries: [TocEntry]? = nil,
                               entries: [(source: Int?, entry: TocEntry)]) -> Data {
        let src = [UInt8](original)
        guard src.count >= Toc.folderSize,
              let old = originalEntries ?? Toc.parse(src) else {
            return data(entries: entries.map { $0.entry })
        }
        // A mismatched pair would make "write only what differs" skip a write
        // that was needed — a stale offset, silently — so refuse it in debug.
        // The bounds check below still keeps a release build from trapping.
        assert(old.count == (src.count - Toc.folderSize) / Toc.entrySize,
               "originalEntries does not match original")
        var out = [UInt8]()
        out.reserveCapacity(Toc.folderSize + entries.count * Toc.entrySize)
        out.append(contentsOf: src[0..<Toc.folderSize])
        for (source, e) in entries {
            guard let k = source, k >= 0, k < old.count,
                  Toc.folderSize + (k + 1) * Toc.entrySize <= src.count else {
                out.append(contentsOf: entryBytes(e))
                continue
            }
            let start = Toc.folderSize + k * Toc.entrySize
            var b = Array(src[start..<(start + Toc.entrySize)])
            patch(&b, from: old[k], to: e)
            out.append(contentsOf: b)
        }
        return Data(out)
    }

    /// Write into one entry's bytes only the fields where `new` differs from
    /// `old`, which must be what those bytes parse as.
    ///
    /// Strings are compared decoded. That is the right test: an unchanged
    /// field is left byte-for-byte alone, including any CP1252 byte that
    /// wouldn't survive a decode and re-encode.
    static func patch(_ b: inout [UInt8], from old: TocEntry, to new: TocEntry) {
        if new.offset != old.offset {
            writeU32LE(&b, 0, UInt32(truncatingIfNeeded: max(0, new.offset)))
        }
        if new.length != old.length {
            writeU32LE(&b, 4, UInt32(truncatingIfNeeded: max(0, new.length)))
        }
        if new.status != old.status { b[12] = UInt8(truncatingIfNeeded: new.status) }
        if new.priority != old.priority { b[16] = UInt8(truncatingIfNeeded: new.priority) }
        if new.date != old.date { overwriteString(&b, at: 18, len: 32, new.date) }
        if new.to != old.to { overwriteString(&b, at: 50, len: 64, new.to) }
        if new.subject != old.subject { overwriteString(&b, at: 114, len: 64, new.subject) }
    }

    static func entryBytes(_ e: TocEntry) -> Data {
        var b = [UInt8](repeating: 0, count: Toc.entrySize)
        writeU32LE(&b, 0, UInt32(truncatingIfNeeded: max(0, e.offset)))
        writeU32LE(&b, 4, UInt32(truncatingIfNeeded: max(0, e.length)))
        b[12] = UInt8(truncatingIfNeeded: e.status)
        b[16] = UInt8(truncatingIfNeeded: e.priority)
        putString(&b, at: 18, len: 32, e.date)
        putString(&b, at: 50, len: 64, e.to)
        putString(&b, at: 114, len: 64, e.subject)
        return Data(b)
    }

    static func writeU32LE(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
        b[i]     = UInt8(v & 0xFF)
        b[i + 1] = UInt8((v >> 8) & 0xFF)
        b[i + 2] = UInt8((v >> 16) & 0xFF)
        b[i + 3] = UInt8((v >> 24) & 0xFF)
    }

    /// CP1252 encode into a fixed-width, NUL-padded field (truncating, leaving
    /// at least a terminating NUL when it fits).
    ///
    /// CP1252 rather than Latin-1 both because that is what Eudora 7 wrote and
    /// because Latin-1 has no curly apostrophe, so every `You’ve` in a subject
    /// line became `You?ve` in the message list. Truncation is safe at any byte:
    /// the encoding is single-byte throughout.
    static func putString(_ b: inout [UInt8], at start: Int, len: Int, _ s: String) {
        let bytes = CP1252.encode(s)
        let count = min(bytes.count, max(0, len - 1))   // keep a trailing NUL
        for k in 0..<count { b[start + k] = bytes[k] }
        // remaining bytes stay 0 (already zero-filled)
    }

    /// `putString` for a field that already holds something: the new string
    /// and its terminating NUL, and nothing past that.
    ///
    /// The bytes after the terminator are left as they were, not zeroed. Real
    /// entries have data there — `testTocBytesOutsideTheModelledFieldsSurvive`
    /// pokes the date field's tail because `phaseX` showed it populated — and
    /// whether that is leftover text or a field of its own isn't known. Leaving
    /// it is harmless either way: every reader stops at the NUL.
    static func overwriteString(_ b: inout [UInt8], at start: Int, len: Int, _ s: String) {
        let bytes = CP1252.encode(s)
        let count = min(bytes.count, max(0, len - 1))
        for k in 0..<count { b[start + k] = bytes[k] }
        b[start + count] = 0
    }
}

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
public enum TocWriter {
    public static func data(entries: [TocEntry]) -> Data {
        var out = Data(count: Toc.folderSize)     // zeroed header; reader ignores it
        for e in entries { out.append(entryBytes(e)) }
        return out
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

    /// Latin-1 encode into a fixed-width, NUL-padded field (truncating, leaving
    /// at least a terminating NUL when it fits).
    static func putString(_ b: inout [UInt8], at start: Int, len: Int, _ s: String) {
        let bytes = Array(s.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(0x3F) }) // '?'
        let count = min(bytes.count, len - 1)       // keep a trailing NUL
        for k in 0..<count { b[start + k] = bytes[k] }
        // remaining bytes stay 0 (already zero-filled)
    }
}

import Foundation

/// One cached message row from a `.toc` index.
public struct TocEntry: Equatable {
    public let offset: Int
    public let length: Int
    public let status: Int
    public let priority: Int
    public let date: String
    public let to: String
    public let subject: String
}

/// Parser for Eudora's binary `.toc` index (Windows layout).
///
/// Layout (little-endian) from the eudora2unix reverse-engineering:
///   - 104-byte folder header
///   - N × 218-byte entries
/// Entry field offsets used here:
///   0  UInt32 offset into .mbx
///   4  UInt32 length
///   12 UInt8  status
///   16 UInt8  priority
///   18 char[32] date   (NUL-terminated)
///   50 char[64] to
///   114 char[64] subject
///
/// IMPORTANT: these sizes are a best-guess reverse-engineering. They are
/// self-consistent with our fixture, but every field must be validated against
/// a real `.toc` before any write-back (Phase 3).
public enum Toc {
    static let folderSize = 104
    static let entrySize = 218

    public static func read(_ url: URL) -> [TocEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        if bytes.count < folderSize { return nil }

        var entries: [TocEntry] = []
        var pos = folderSize
        while pos + entrySize <= bytes.count {
            let base = pos
            let offset = readU32LE(bytes, base + 0)
            let length = readU32LE(bytes, base + 4)
            let status = Int(bytes[base + 12])
            let priority = Int(bytes[base + 16])
            let date = cString(bytes, base + 18, 32)
            let to = cString(bytes, base + 50, 64)
            let subject = cString(bytes, base + 114, 64)
            entries.append(TocEntry(offset: Int(offset), length: Int(length),
                                    status: status, priority: priority,
                                    date: date, to: to, subject: subject))
            pos += entrySize
        }
        return entries
    }

    static func readU32LE(_ b: [UInt8], _ i: Int) -> UInt32 {
        return UInt32(b[i])
            | (UInt32(b[i + 1]) << 8)
            | (UInt32(b[i + 2]) << 16)
            | (UInt32(b[i + 3]) << 24)
    }

    static func cString(_ b: [UInt8], _ start: Int, _ len: Int) -> String {
        let endBound = min(start + len, b.count)
        var slice = Array(b[start..<endBound])
        if let z = slice.firstIndex(of: 0) { slice = Array(slice[0..<z]) }
        return String(bytes: slice, encoding: .isoLatin1) ?? ""
    }
}

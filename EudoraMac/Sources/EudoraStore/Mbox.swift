import Foundation

/// A message's byte range within a `.mbx` file.
public struct MboxRecord: Equatable {
    public let offset: Int
    public let length: Int
}

/// Reads Eudora's modified-mbox `.mbx` format. The `.mbx` is the source of
/// truth; the `.toc` is only a cache. Records are split on the Eudora
/// pseudo-envelope separator `From ???@??? ` occurring at a line start.
public enum Mbox {
    static let separator: [UInt8] = Array("From ???@??? ".utf8)

    public static func findRecords(_ bytes: [UInt8]) -> [MboxRecord] {
        var starts: [Int] = []
        var i = 0
        while let idx = Bytes.find(separator, in: bytes, from: i) {
            let atLineStart = (idx == 0) || bytes[idx - 1] == 0x0a || bytes[idx - 1] == 0x0d
            if atLineStart { starts.append(idx) }
            i = idx + 1
        }
        var recs: [MboxRecord] = []
        for (k, start) in starts.enumerated() {
            let end = (k + 1 < starts.count) ? starts[k + 1] : bytes.count
            recs.append(MboxRecord(offset: start, length: end - start))
        }
        return recs
    }

    /// The RFC-822 message bytes for one record, with the leading
    /// `From ???@???` separator line stripped.
    public static func messageBytes(_ bytes: [UInt8], _ rec: MboxRecord) -> [UInt8] {
        let end = min(rec.offset + rec.length, bytes.count)
        guard rec.offset < end else { return [] }
        let slice = Array(bytes[rec.offset..<end])
        if let nl = slice.firstIndex(of: 0x0a) { return Array(slice[(nl + 1)...]) }
        return slice
    }
}

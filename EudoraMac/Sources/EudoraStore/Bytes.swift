import Foundation

/// Small byte-search helpers. We work on `[UInt8]` throughout the interop layer
/// because the reasoning (offsets, line starts, boundaries) is simpler and less
/// error-prone than juggling `Data` slice indices.
enum Bytes {
    /// First index of `needle` in `hay` at or after `from`, or nil.
    static func find(_ needle: [UInt8], in hay: [UInt8], from: Int = 0) -> Int? {
        if needle.isEmpty || hay.count < needle.count { return nil }
        var i = max(0, from)
        let last = hay.count - needle.count
        while i <= last {
            var j = 0
            while j < needle.count && hay[i + j] == needle[j] { j += 1 }
            if j == needle.count { return i }
            i += 1
        }
        return nil
    }

    /// All indices of `needle` in `hay` (non-overlapping by +1 stepping).
    static func findAll(_ needle: [UInt8], in hay: [UInt8]) -> [Int] {
        var out: [Int] = []
        var i = 0
        while let idx = find(needle, in: hay, from: i) {
            out.append(idx)
            i = idx + 1
        }
        return out
    }
}

extension String {
    /// Right-pad/truncate to a fixed width for column output.
    public func padded(_ width: Int) -> String {
        if count >= width { return String(prefix(width)) }
        return self + String(repeating: " ", count: width - count)
    }
}

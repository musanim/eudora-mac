import Foundation

/// Small byte-search helpers. We work on `[UInt8]` throughout the interop layer
/// because the reasoning (offsets, line starts, boundaries) is simpler and less
/// error-prone than juggling `Data` slice indices.
enum Bytes {
    /// First index of `needle` in `hay` at or after `from`, or nil.
    ///
    /// **Why the pointer dance instead of `hay[i + j]`.** This is the parser's
    /// innermost primitive — it scans the whole `.mbx` for record separators and
    /// every message body for Eudora's `<x-html>`/`<x-flowed>` markers — so on a
    /// big mailbox it runs over hundreds of megabytes. A profile of a 613 MB
    /// Trash listing showed nearly all the enrichment time here, almost none of
    /// it comparing bytes: it was `Array` subscript overhead (bounds checks,
    /// value-witness calls, bridge retain/release), which an unoptimised Debug
    /// build pays on *every* element access.
    ///
    /// Two changes fix it. Raw buffer pointers drop the per-byte overhead in
    /// both Debug and Release; and `memchr` — SIMD in libc — skips straight to
    /// the next byte that even *could* start a match, rather than stepping one at
    /// a time. Behaviour is identical to the naive loop it replaces.
    static func find(_ needle: [UInt8], in hay: [UInt8], from: Int = 0) -> Int? {
        let n = needle.count
        let h = hay.count
        if n == 0 || h < n { return nil }
        let start = max(0, from)
        let last = h - n
        if start > last { return nil }
        return needle.withUnsafeBufferPointer { np -> Int? in
            hay.withUnsafeBufferPointer { hp -> Int? in
                let hb = hp.baseAddress!
                let nb = np.baseAddress!
                let first = nb[0]
                var i = start
                while i <= last {
                    // Jump to the next occurrence of the needle's first byte in
                    // i…last; if there is none, the needle can't be here.
                    guard let hit = memchr(hb + i, Int32(first), last - i + 1) else { return nil }
                    i = UnsafeRawPointer(hit) - UnsafeRawPointer(hb)
                    var j = 1
                    while j < n && hb[i + j] == nb[j] { j += 1 }
                    if j == n { return i }
                    i += 1
                }
                return nil
            }
        }
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

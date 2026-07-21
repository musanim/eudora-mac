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

    // MARK: writing

    /// The pseudo-envelope line that begins every record, terminator included.
    ///
    /// Here rather than in the writers because there are now two of them —
    /// `Outbox.append` and `MailboxMutator.replace` — and a record whose
    /// separator differed by a byte from what `findRecords` looks for would
    /// simply not be a record.
    public static func envelopeLine(date: Date) -> String {
        "From ???@??? \(asctime.string(from: date))\r\n"
    }

    /// One complete `.mbx` record: envelope line, message bytes, and a
    /// guaranteed line ending.
    ///
    /// **The terminator is not a nicety.** `findRecords` only accepts a
    /// separator that begins a line, so a record whose last byte isn't a line
    /// ending makes the *next* record invisible — the two silently merge into
    /// one, every cached offset after them stops naming a record, and the next
    /// mutation throws the whole `.toc` away because it no longer matches.
    ///
    /// This is easy to hit and gives no warning: `OutgoingMessage.rfc822`
    /// appends nothing after the body, so a message whose author didn't press
    /// Return at the end is enough to do it. Any code that writes a record must
    /// come through here.
    public static func record(messageData: Data, date: Date) -> Data {
        var record = Data(envelopeLine(date: date).utf8)
        record.append(messageData)
        if let last = record.last, last != 0x0A, last != 0x0D {
            record.append(contentsOf: [0x0D, 0x0A])
        }
        return record
    }

    /// The short date Eudora caches in the `.toc`'s 32-byte date field.
    ///
    /// **This format was wrong until now**, and the mistake mattered. `Outbox`
    /// wrote `"EEE MMM d yyyy"` ("Mon Jul 20 2026"), which is not what Eudora
    /// writes and not what anything reads: sampling all 245,671 TOC entries in
    /// the real tree found this time-first shape in 94% of them and nothing
    /// resembling the old one. A message sent by this app therefore showed a
    /// date the Date column couldn't parse, so it sorted as undated and
    /// displayed in a format unlike every other row until the background parse
    /// replaced it. See `EudoraDateFormat.tocDate`, which reads this back.
    public static func tocDateString(_ date: Date) -> String { tocDate.string(from: date) }

    /// Configured once and never mutated — the shape `DateFormatter`'s
    /// thread-safety guarantee covers. Don't make these `var`.
    private static let asctime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"     // Eudora pseudo-envelope date
        return f
    }()

    private static let tocDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "hh:mm a M/d/yyyy"
        return f
    }()
}

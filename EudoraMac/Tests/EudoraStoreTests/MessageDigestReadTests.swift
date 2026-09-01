import XCTest
@testable import EudoraStore

/// The offset-based `forEachMessageDigest`: enrichment reads each message
/// directly from the `.mbx` by the offset the listing found, instead of
/// re-scanning the file. These build a real mailbox, list it to get the
/// offsets, and confirm the read lands on the right message every time — a wrong
/// offset would silently read a neighbouring record — and that its attachment
/// verdict still matches the full parse.
final class MessageDigestReadTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-digest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var base: URL { root.appendingPathComponent("Box") }

    private func message(from: String, date: String, extraHeaders: String = "",
                         body: String) -> Data {
        var lines = ["From: \(from)", "To: you@x.com", "Date: \(date)", "Subject: s"]
        if !extraHeaders.isEmpty { lines.append(extraHeaders) }
        lines.append("")
        lines.append(body)
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func append(_ data: Data) throws {
        _ = try Outbox.append(messageData: data, to: base,
                              status: MailboxMutator.statusSent, who: "x", subject: "s")
    }

    func testReadsTheRightMessageAtEachOffset() throws {
        try append(message(from: "Alice <a@x>", date: "Wed, 1 Jan 2020 09:00:00 +0000", body: "hi"))
        try append(message(from: "Bob <b@x>", date: "Thu, 2 Jan 2020 09:00:00 +0000",
                           extraHeaders: "Content-Type: application/pdf\r\n"
                               + "Content-Disposition: attachment; filename=\"r.pdf\"",
                           body: "%PDF-1.4"))
        try append(message(from: "Cara <c@x>", date: "Fri, 3 Jan 2020 09:00:00 +0000",
                           body: "see file\r\nAttachment Converted: \"C:\\\\x\\\\p.jpg\""))

        let store = MailStore(root: root)
        guard let listing = store.list(at: base) else { return XCTFail("no listing") }
        XCTAssertEqual(listing.rows.count, 3)

        let records = listing.rows.map { (index: $0.index, offset: $0.offset, length: $0.size) }
        var digest: [Int: MessageDigest] = [:]
        store.forEachMessageDigest(at: base, records: records) { i, d in digest[i] = d; return true }
        XCTAssertEqual(digest.count, 3)

        let r = listing.rows
        // Right message at each offset — From/Date lifted from the correct record.
        XCTAssertEqual(digest[r[0].index]?.from, "Alice <a@x>")
        XCTAssertEqual(digest[r[1].index]?.from, "Bob <b@x>")
        XCTAssertEqual(digest[r[2].index]?.from, "Cara <c@x>")
        XCTAssertEqual(digest[r[0].index]?.date, "Wed, 1 Jan 2020 09:00:00 +0000")
        XCTAssertEqual(digest[r[2].index]?.date, "Fri, 3 Jan 2020 09:00:00 +0000")

        // Attachment flags, cross-checked against the full parse of each message.
        var full: [Int: Bool] = [:]
        store.forEachMessage(at: base) { i, _, part in
            full[i] = part.walk().contains { $0.isAttachment }
                || DetachedAttachment.isPresent(in: part)
                || RecordedAttachment.isPresent(inHeaderValue: part.header(RecordedAttachment.headerName))
            return true
        }
        XCTAssertEqual(digest[r[0].index]?.hasAttachment, false)
        XCTAssertEqual(digest[r[1].index]?.hasAttachment, true)
        XCTAssertEqual(digest[r[2].index]?.hasAttachment, true)
        for row in listing.rows {
            XCTAssertEqual(digest[row.index]?.hasAttachment, full[row.index],
                           "digest disagreed with full parse for row \(row.index)")
        }
    }

    /// Cancellation is checked between messages, so an abandoned enrichment stops
    /// promptly instead of finishing the mailbox.
    func testStopsWhenCancelled() throws {
        for i in 1...5 {
            try append(message(from: "x@y", date: "Wed, \(i) Jan 2020 09:00:00 +0000", body: "b"))
        }
        let store = MailStore(root: root)
        let records = store.list(at: base)!.rows.map { (index: $0.index, offset: $0.offset, length: $0.size) }

        var seen = 0
        store.forEachMessageDigest(at: base, records: records, isCancelled: { seen >= 2 }) { _, _ in
            seen += 1
            return true
        }
        // The 3rd iteration's top-of-loop check sees `seen == 2` and returns.
        XCTAssertEqual(seen, 2)
    }
}

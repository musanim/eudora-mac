import XCTest
import Foundation
@testable import EudoraStore

/// Tests for `Delivery.deliverIncoming`, the write side of Check Mail.
///
/// These exist because of a bug that nothing else could have caught. Delivery
/// passed `status: 1` with the comment `// unread` beside it, but 1 is MS_READ —
/// MS_UNREAD is 0. Every message Eudora 8 ever received was marked read the
/// instant it arrived, so no bullet was drawn in the list and the mailbox's
/// unread count never moved. It survived because it is a plausible-looking
/// literal next to a comment asserting the opposite, and because every *other*
/// caller in the app uses the named constants, so nothing else disagreed with
/// it. The obvious lesson is about literals; the useful one is that the write
/// side of delivery had no tests at all.
///
/// So these check the state a delivered message lands in, not just that the
/// bytes arrived.
final class DeliveryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-delivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: the state a delivered message arrives in

    /// The regression test. A message that arrives is unread — in the TOC byte,
    /// in the glyph the list draws, and in what the row reports.
    func testDeliveredMessageIsUnread() throws {
        try Delivery.deliverIncoming(messageData: incoming(subject: "Hello"), to: base)

        let entries = Toc.read(base.appendingPathExtension("toc"))
        XCTAssertEqual(entries?.first?.status, MailboxMutator.statusUnread,
                       "delivery must write MS_UNREAD (0); MS_READ (1) is the bug this test exists for")

        let row = try XCTUnwrap(MailStore(root: root).list(at: base, name: "In")?.rows.first)
        XCTAssertEqual(row.statusGlyph, MailStore.unreadGlyph,
                       "an arrived message draws the unread bullet")
    }

    /// Every message in a multi-message check is unread, not just the first —
    /// the status is passed per append, so a loop could in principle diverge.
    func testEveryMessageInABatchIsUnread() throws {
        for n in 1...3 {
            try Delivery.deliverIncoming(messageData: incoming(subject: "M\(n)"), to: base)
        }
        let listing = try XCTUnwrap(MailStore(root: root).list(at: base, name: "In"))
        XCTAssertEqual(listing.rows.count, 3)
        XCTAssertEqual(listing.rows.map(\.statusGlyph),
                       Array(repeating: MailStore.unreadGlyph, count: 3))
    }

    // MARK: the cached columns

    /// The TOC caches Who and Subject so the list can be drawn without parsing
    /// every message. Delivery decodes them from the headers, so an encoded
    /// header has to survive into the cache.
    func testWhoAndSubjectAreCachedFromTheHeaders() throws {
        try Delivery.deliverIncoming(messageData: incoming(subject: "Lunch?"), to: base)
        let row = try XCTUnwrap(MailStore(root: root).list(at: base, name: "In")?.rows.first)
        XCTAssertEqual(row.subject, "Lunch?")
        XCTAssertTrue(row.who.contains("them@example.com"), "got \(row.who)")
    }

    /// NOTE for anyone extending this: the TOC's cached fields are written and
    /// read as **CP1252** (see `CP1252.swift`), so ö and é round-trip exactly,
    /// as do the curly quotes, dashes and ellipsis Windows Eudora 7 stored
    /// there. A Cyrillic or CJK name still comes back as question marks — that
    /// is the format's limit, not a bug — so a test using one would fail for a
    /// reason that has nothing to do with decoding.
    func testEncodedWordHeadersAreDecodedBeforeCaching() throws {
        let raw = Data([
            "From: =?utf-8?Q?Bj=C3=B6rn?= <bjorn@example.com>",
            "To: me@example.com",
            "Subject: =?utf-8?Q?Caf=C3=A9?=",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "hello",
            "",
        ].joined(separator: "\r\n").utf8)

        try Delivery.deliverIncoming(messageData: raw, to: base)
        let row = try XCTUnwrap(MailStore(root: root).list(at: base, name: "In")?.rows.first)
        XCTAssertEqual(row.subject, "Café")
        XCTAssertTrue(row.who.contains("Björn"), "got \(row.who)")
    }

    /// A message with neither header must still deliver — the cache is a
    /// convenience, and a malformed message is not a reason to lose mail.
    func testMessageWithNoFromOrSubjectStillDelivers() throws {
        let raw = Data("Content-Type: text/plain\r\n\r\nbody only\r\n".utf8)
        try Delivery.deliverIncoming(messageData: raw, to: base)
        let listing = try XCTUnwrap(MailStore(root: root).list(at: base, name: "In"))
        XCTAssertEqual(listing.rows.count, 1)
        XCTAssertEqual(listing.rows[0].statusGlyph, MailStore.unreadGlyph)
    }

    // MARK: the mailbox around it

    /// Delivery appends. Nothing already in the mailbox may be renumbered —
    /// `AppModel.refreshInPlaceAfterDelivery` hands each listed row's parsed
    /// values to its replacement keyed by index, so a renumbering delivery
    /// would silently attach every row's Who and date to the wrong message.
    func testDeliveryAppendsWithoutRenumbering() throws {
        try Delivery.deliverIncoming(messageData: incoming(subject: "First"), to: base)
        try Delivery.deliverIncoming(messageData: incoming(subject: "Second"), to: base)
        let before = try XCTUnwrap(MailStore(root: root).list(at: base, name: "In")).rows

        try Delivery.deliverIncoming(messageData: incoming(subject: "Third"), to: base)
        let after = try XCTUnwrap(MailStore(root: root).list(at: base, name: "In")).rows

        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(Array(after.prefix(2)).map(\.index), before.map(\.index),
                       "an append must not renumber the messages already listed")
        XCTAssertEqual(Array(after.prefix(2)).map(\.subject), ["First", "Second"])
        XCTAssertEqual(after[2].subject, "Third")
    }

    /// The returned index is what the caller uses to find the message again;
    /// it must name the record just written.
    func testReturnedIndexNamesTheDeliveredMessage() throws {
        _ = try Delivery.deliverIncoming(messageData: incoming(subject: "One"), to: base)
        let second = try Delivery.deliverIncoming(messageData: incoming(subject: "Two"), to: base)

        let listing = try XCTUnwrap(MailStore(root: root).list(at: base, name: "In"))
        let row = try XCTUnwrap(listing.rows.first { $0.index == second })
        XCTAssertEqual(row.subject, "Two")
    }

    /// Delivery must leave the TOC describing the mailbox. If it doesn't, the
    /// reader falls back to a status-less scan and every message loses its
    /// read/unread state — which would defeat the fix above by another route.
    func testTocStillDescribesTheMailboxAfterDelivery() throws {
        for n in 1...3 {
            try Delivery.deliverIncoming(messageData: incoming(subject: "M\(n)"), to: base)
        }
        let listing = try XCTUnwrap(MailStore(root: root).list(at: base, name: "In"))
        XCTAssertEqual(listing.source, .toc,
                       "delivery that invalidates the TOC costs every message its status")

        let entries = try XCTUnwrap(Toc.read(base.appendingPathExtension("toc")))
        let recs = Mbox.findRecords([UInt8](try Data(contentsOf: base.appendingPathExtension("mbx"))))
        XCTAssertEqual(entries.map(\.offset), recs.map(\.offset))
        XCTAssertEqual(entries.map(\.length), recs.map(\.length))
    }

    // MARK: fixture

    private var base: URL { root.appendingPathComponent("In") }

    private func incoming(subject: String) -> Data {
        Data([
            "From: Them <them@example.com>",
            "To: me@example.com",
            "Subject: \(subject)",
            "Date: Mon, 27 Jul 2026 09:15:00 -0700",
            "Content-Type: text/plain; charset=us-ascii",
            "",
            "body of \(subject)",
            "",
        ].joined(separator: "\r\n").utf8)
    }
}

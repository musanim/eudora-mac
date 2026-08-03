import XCTest
@testable import EudoraStore

/// `MailStore.message(at:offset:)` — the chunked, seek-to-the-offset reader the
/// Find window's preview pane uses instead of reading a 612 MB `.mbx` per arrow
/// key.
///
/// Its contract is not "find the end of the message" but something stricter:
/// **end it exactly where `findRecords` would**, so the preview pane and the
/// main window never disagree about what one message is. Every test here is
/// therefore the same assertion — read the file both ways and demand the same
/// answer — applied to the arrangements where a chunked reader can drift from a
/// whole-file scan:
///
/// - a record longer than one chunk (truncation),
/// - a boundary whose separator is split across the seam between two reads,
/// - a boundary whose separator arrives whole but whose *envelope date* runs
///   past the seam (the case that motivated the `+ envelopeDateLength` overlap;
///   with a separator-sized overlap the reader steps past that boundary and
///   never looks at it again, silently gluing two messages into one),
/// - a separator embedded in a body, which `findRecords` treats as a boundary
///   and this must too,
/// - the last record, which ends at EOF rather than at a separator.
///
/// The fixtures are written as raw bytes rather than through `Outbox.append`
/// deliberately: `Mbox.record` guarantees a trailing line ending, and the glued
/// non-line-start separator that the date test exists for cannot occur in a file
/// written that way. It occurs in the real tree — see `findRecords`' comment.
final class MailStoreOffsetReadTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-offset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var base: URL { root.appendingPathComponent("Box") }

    // MARK: fixture building

    /// The asctime shape `looksLikeEnvelopeDate` accepts, and Eudora writes.
    private static let envelopeDate = "Thu Nov 19 17:23:56 2009"

    /// One `.mbx` record of an *exact* byte length, padded in the body.
    ///
    /// Exactness is the point: the seams these tests aim at are absolute file
    /// offsets (64K, then 320K, then 1344K as the chunk quadruples), so a record
    /// has to be able to end at a chosen byte.
    ///
    /// `terminated: false` leaves the record without a line ending, which is how
    /// a following separator ends up glued to it and not at a line start.
    private func record(exactLength total: Int,
                        subject: String,
                        tail: String = "",
                        terminated: Bool = true) -> [UInt8] {
        var out = Array("""
            From ???@??? \(Self.envelopeDate)\r
            From: a@x.com\r
            To: you@x.com\r
            Subject: \(subject)\r
            Date: Thu, 19 Nov 2009 17:23:56 +0000\r
            \r

            """.utf8)
        let terminator = terminated ? Array("\r\n".utf8) : []
        let pad = total - out.count - tail.utf8.count - terminator.count
        precondition(pad >= 0, "record(exactLength:) too short to hold its headers, tail and terminator")
        out += Array(repeating: UInt8(ascii: "x"), count: pad)
        out += Array(tail.utf8)
        out += terminator
        precondition(out.count == total)
        return out
    }

    /// A small, ordinary record; length is whatever it comes to.
    private func record(subject: String, body: String) -> [UInt8] {
        Array("""
            From ???@??? \(Self.envelopeDate)\r
            From: a@x.com\r
            To: you@x.com\r
            Subject: \(subject)\r
            Date: Thu, 19 Nov 2009 17:23:56 +0000\r
            \r
            \(body)\r

            """.utf8)
    }

    @discardableResult
    private func write(_ records: [[UInt8]]) throws -> [UInt8] {
        let bytes = records.flatMap { $0 }
        try Data(bytes).write(to: base.appendingPathExtension("mbx"))
        return bytes
    }

    // MARK: the shared assertion

    /// Read every record in the file both ways and demand they agree.
    ///
    /// `findRecords` over the whole file is the reference implementation — not
    /// because it is right in the abstract (it splits on separators inside
    /// quoted bodies) but because it is what the main window uses, and agreement
    /// is the actual requirement. Compares the record's byte range *and* the
    /// parsed body, so a message truncated at a chunk boundary or glued to its
    /// successor fails here.
    @discardableResult
    private func assertBothReadersAgree(expectedRecords: Int? = nil,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) throws -> [MboxRecord] {
        let bytes = [UInt8](try Data(contentsOf: base.appendingPathExtension("mbx")))
        let expected = Mbox.findRecords(bytes)
        if let n = expectedRecords {
            XCTAssertEqual(expected.count, n,
                           "fixture did not parse into the intended number of records",
                           file: file, line: line)
        }
        XCTAssertFalse(expected.isEmpty, "fixture produced no records", file: file, line: line)

        let store = MailStore(root: root)
        for (k, rec) in expected.enumerated() {
            guard let byOffset = store.message(at: base, offset: rec.offset) else {
                XCTFail("record \(k + 1) at offset \(rec.offset) read back as nil",
                        file: file, line: line)
                continue
            }
            XCTAssertEqual(byOffset.record, rec,
                           "record \(k + 1): offset reader disagreed about the byte range",
                           file: file, line: line)

            guard let byIndex = store.message(at: base, index: k + 1) else {
                XCTFail("record \(k + 1) missing from the index reader", file: file, line: line)
                continue
            }
            XCTAssertEqual(byOffset.part.body, byIndex.part.body,
                           "record \(k + 1): body differs between the two readers "
                               + "(\(byOffset.part.body.count) vs \(byIndex.part.body.count) bytes)",
                           file: file, line: line)
            XCTAssertEqual(byOffset.part.header("Subject"), byIndex.part.header("Subject"),
                           "record \(k + 1): subject differs between the two readers",
                           file: file, line: line)
        }
        return expected
    }

    // MARK: ordinary case

    func testSmallMessagesAgreeWithTheIndexReader() throws {
        try write([
            record(subject: "one", body: "first body"),
            record(subject: "two", body: "second body"),
            record(subject: "three", body: "third body"),
        ])
        let recs = try assertBothReadersAgree(expectedRecords: 3)

        // And the subject really is the one asked for, not a neighbour's — the
        // failure a wrong offset produces silently.
        let store = MailStore(root: root)
        XCTAssertEqual(store.message(at: base, offset: recs[1].offset)?.part.header("Subject"), "two")
    }

    // MARK: chunk boundaries
    //
    // The reader starts at 64 KB and quadruples, so cumulative reads land at
    // 65_536, then 327_680, then 1_376_256. These fixtures put a record end just
    // past each of those. (`read(upToCount:)` is permitted to return short, in
    // which case the seams move — the assertions stay valid either way, they
    // just stop being aimed at the exact seam.)

    func testMessageSpanningTheFirstChunkBoundary() throws {
        try write([
            record(exactLength: 100_000, subject: "long", tail: "-END-"),
            record(subject: "after", body: "b"),
        ])
        try assertBothReadersAgree(expectedRecords: 2)

        // Explicitly: the long one came back whole, not cut at 64 KB.
        let store = MailStore(root: root)
        let first = try XCTUnwrap(store.message(at: base, offset: 0))
        XCTAssertEqual(first.record.length, 100_000)
        XCTAssertTrue(String(decoding: first.part.body, as: UTF8.self).contains("-END-"),
                      "body was truncated before its final bytes")
    }

    func testMessageSpanningSeveralChunkBoundaries() throws {
        try write([
            record(exactLength: 1_500_000, subject: "very long", tail: "-END-"),
            record(subject: "after", body: "b"),
        ])
        try assertBothReadersAgree(expectedRecords: 2)

        let store = MailStore(root: root)
        let first = try XCTUnwrap(store.message(at: base, offset: 0))
        XCTAssertEqual(first.record.length, 1_500_000)
        XCTAssertTrue(String(decoding: first.part.body, as: UTF8.self).contains("-END-"))
    }

    /// The next record's separator straddles the seam: six of its thirteen bytes
    /// arrive in the first read, the rest in the second. Found only because the
    /// second pass re-searches from behind the seam.
    func testBoundarySeparatorSplitAcrossTheSeam() throws {
        let firstLength = 65_536 - 6      // separator occupies 65_530 ..< 65_543
        try write([
            record(exactLength: firstLength, subject: "before the seam", tail: "-END-"),
            record(subject: "after the seam", body: "b"),
        ])
        try assertBothReadersAgree(expectedRecords: 2)

        let store = MailStore(root: root)
        XCTAssertEqual(store.message(at: base, offset: 0)?.record.length, firstLength,
                       "the split separator was missed and two records merged into one")
    }

    /// The regression the `+ Mbox.envelopeDateLength` overlap exists for.
    ///
    /// The first record is *unterminated*, so the next record's separator is
    /// glued to it and is not at a line start — it counts as a boundary only if a
    /// genuine envelope date follows. Here the separator arrives whole in the
    /// first read while its date runs past the seam, so the first pass's date
    /// test reads off the end and fails. With an overlap of only the separator's
    /// length the second pass would start *after* that separator and never
    /// reconsider it: the two messages silently become one.
    func testGluedBoundaryWhoseEnvelopeDateRunsPastTheSeam() throws {
        let firstLength = 65_510          // separator 65_510 ..< 65_523, date 65_523 ..< 65_547
        XCTAssertLessThan(firstLength + Mbox.separator.count, 65_536,
                          "fixture must put the whole separator inside the first read")
        XCTAssertGreaterThan(firstLength + Mbox.separator.count + Mbox.envelopeDateLength, 65_536,
                             "fixture must push the envelope date past the seam")
        try write([
            record(exactLength: firstLength, subject: "unterminated", tail: "-END-",
                   terminated: false),
            record(subject: "glued on", body: "b"),
        ])
        try assertBothReadersAgree(expectedRecords: 2)

        let store = MailStore(root: root)
        XCTAssertEqual(store.message(at: base, offset: 0)?.record.length, firstLength,
                       "the glued boundary was lost across the seam and the records merged")
        XCTAssertEqual(store.message(at: base, offset: firstLength)?.part.header("Subject"),
                       "glued on")
    }

    // MARK: agreeing about where a message ends

    /// A separator at a line start *inside a body* is a record boundary to
    /// `findRecords` — 26 of them in the real In.mbx. The offset reader copies
    /// that rule rather than a better one, on purpose.
    func testSeparatorEmbeddedInABodyEndsTheMessage() throws {
        let quoted = "he wrote:\r\nFrom ???@??? \(Self.envelopeDate)\r\nquoted text"
        try write([
            record(subject: "quoting", body: quoted),
            record(subject: "next", body: "b"),
        ])
        // findRecords splits the quoted separator out as its own record: 3, not 2.
        let recs = try assertBothReadersAgree(expectedRecords: 3)

        let store = MailStore(root: root)
        let first = try XCTUnwrap(store.message(at: base, offset: 0))
        XCTAssertEqual(first.record.length, recs[0].length)
        XCTAssertFalse(String(decoding: first.part.body, as: UTF8.self).contains("quoted text"),
                       "the offset reader ran past a boundary the main window honours")
    }

    func testLastRecordRunsToEndOfFile() throws {
        let bytes = try write([
            record(subject: "one", body: "a"),
            record(subject: "last", body: "trailing content with no separator after it"),
        ])
        let recs = try assertBothReadersAgree(expectedRecords: 2)

        let store = MailStore(root: root)
        let last = try XCTUnwrap(store.message(at: base, offset: recs[1].offset))
        XCTAssertEqual(last.record.length, bytes.count - recs[1].offset)
        XCTAssertTrue(String(decoding: last.part.body, as: UTF8.self)
            .contains("trailing content with no separator after it"))
    }

    /// A long final record: the chunk loop has to fall out of its `while` on a
    /// short read rather than find a separator, and still return everything.
    func testLongLastRecordRunsToEndOfFile() throws {
        try write([
            record(subject: "one", body: "a"),
            record(exactLength: 400_000, subject: "long last", tail: "-END-"),
        ])
        let recs = try assertBothReadersAgree(expectedRecords: 2)

        let store = MailStore(root: root)
        let last = try XCTUnwrap(store.message(at: base, offset: recs[1].offset))
        XCTAssertEqual(last.record.length, 400_000)
        XCTAssertTrue(String(decoding: last.part.body, as: UTF8.self).contains("-END-"))
    }

    // MARK: refusing a bad offset

    /// A stale offset must come back nil rather than render the middle of some
    /// other message as though it were the hit.
    func testOffsetNotAtARecordStartIsRefused() throws {
        try write([
            record(subject: "one", body: "first body"),
            record(subject: "two", body: "second body"),
        ])
        let recs = try assertBothReadersAgree(expectedRecords: 2)

        let store = MailStore(root: root)
        XCTAssertNil(store.message(at: base, offset: recs[0].offset + 5),
                     "an offset inside a separator was accepted")
        XCTAssertNil(store.message(at: base, offset: recs[1].offset - 4),
                     "an offset inside a body was accepted")
        XCTAssertNil(store.message(at: base, offset: -1))
    }

    func testOffsetPastEndOfFileIsRefused() throws {
        let bytes = try write([record(subject: "one", body: "a")])
        let store = MailStore(root: root)
        XCTAssertNil(store.message(at: base, offset: bytes.count))
        XCTAssertNil(store.message(at: base, offset: bytes.count + 1_000))
    }

    func testMissingMailboxIsRefused() {
        let store = MailStore(root: root)
        XCTAssertNil(store.message(at: root.appendingPathComponent("NoSuchBox"), offset: 0))
    }

    // MARK: indexOfRecord(at:offset:), which pairs with this

    func testIndexOfRecordMatchesTheOffsetReader() throws {
        try write([
            record(subject: "one", body: "a"),
            record(exactLength: 100_000, subject: "two", tail: "-END-"),
            record(subject: "three", body: "c"),
        ])
        let recs = try assertBothReadersAgree(expectedRecords: 3)

        let store = MailStore(root: root)
        for (k, rec) in recs.enumerated() {
            XCTAssertEqual(store.indexOfRecord(at: base, offset: rec.offset), k + 1)
        }
        XCTAssertNil(store.indexOfRecord(at: base, offset: recs[1].offset + 3))
    }
}

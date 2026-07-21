import XCTest
import Foundation
@testable import EudoraStore

/// Tests for `MailboxMutator.replace`, the primitive that lets a draft in Out be
/// edited without moving.
///
/// The interesting case is not "did the bytes change" but **what happens to
/// every message after the one replaced**. A replacement is almost never the
/// same length as what it replaces, so each later record's offset shifts, and
/// the `.toc` caches those offsets. Get the shift wrong and nothing throws:
/// the mailbox still parses, the message list still draws, and the rows quietly
/// describe the wrong messages. So these tests replace a record in the *middle*
/// of a mailbox, with both a longer and a shorter body, and check the
/// neighbours rather than the target.
final class MailboxReplaceTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-replace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: the shift

    func testReplaceWithLongerBodyKeepsNeighboursIntact() throws {
        try buildOut(bodies: ["first", "second", "third"])

        try MailboxMutator.replace(base: base, index: 2,
                                   messageData: message(subject: "Two", body: String(repeating: "x", count: 500)),
                                   status: MailboxMutator.statusUnsent,
                                   who: "you@example.com", subject: "Two")

        let listing = MailStore(root: root).list(at: base, name: "Out")!
        XCTAssertEqual(listing.rows.count, 3, "replacing must not add or drop a record")
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "Two", "S3"])
        XCTAssertEqual(bodyOfRecord(2).contains(String(repeating: "x", count: 500)), true)
        // The neighbours are the point: if the offsets shifted wrongly these
        // come back truncated, merged, or as the wrong message entirely.
        XCTAssertTrue(bodyOfRecord(1).contains("first"))
        XCTAssertTrue(bodyOfRecord(3).contains("third"))
    }

    func testReplaceWithShorterBodyKeepsNeighboursIntact() throws {
        try buildOut(bodies: ["first", String(repeating: "y", count: 400), "third"])

        try MailboxMutator.replace(base: base, index: 2,
                                   messageData: message(subject: "Two", body: "tiny"),
                                   status: MailboxMutator.statusUnsent,
                                   who: "you@example.com", subject: "Two")

        let listing = MailStore(root: root).list(at: base, name: "Out")!
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "Two", "S3"])
        XCTAssertTrue(bodyOfRecord(1).contains("first"))
        XCTAssertTrue(bodyOfRecord(3).contains("third"))
    }

    /// The TOC must still describe the mailbox afterwards, or the reader falls
    /// back to a status-less scan and every message silently loses its state.
    func testTocStaysConsistentAfterReplace() throws {
        try buildOut(bodies: ["first", "second", "third"])

        try MailboxMutator.replace(base: base, index: 1,
                                   messageData: message(subject: "One", body: String(repeating: "z", count: 300)),
                                   status: MailboxMutator.statusSent,
                                   who: "you@example.com", subject: "One")

        let listing = MailStore(root: root).list(at: base, name: "Out")!
        XCTAssertEqual(listing.source, .toc,
                       "a replace that invalidates the TOC would fall back to scanning")

        let entries = Toc.read(base.appendingPathExtension("toc"))!
        let recs = Mbox.findRecords([UInt8](try Data(contentsOf: base.appendingPathExtension("mbx"))))
        XCTAssertEqual(entries.map(\.offset), recs.map(\.offset),
                       "every cached offset must still name a real record")
        XCTAssertEqual(entries.map(\.length), recs.map(\.length))
    }

    // MARK: status and cached columns

    func testStatusAndSubjectAreUpdated() throws {
        try buildOut(bodies: ["draft"])

        try MailboxMutator.replace(base: base, index: 1,
                                   messageData: message(subject: "Now sent", body: "body"),
                                   status: MailboxMutator.statusSent,
                                   who: "them@example.com", subject: "Now sent")

        let row = MailStore(root: root).list(at: base, name: "Out")!.rows[0]
        XCTAssertEqual(row.subject, "Now sent")
        XCTAssertEqual(row.who, "them@example.com")
        XCTAssertEqual(row.statusGlyph, "S", "status 8 is MS_SENT")
    }

    /// Unsent is the state a draft sits in, and it has to survive the round trip
    /// through the TOC — otherwise a draft reads back as an ordinary message.
    func testUnsentStatusRoundTrips() throws {
        try buildOut(bodies: ["draft"])
        try MailboxMutator.replace(base: base, index: 1,
                                   messageData: message(subject: "Still a draft", body: "wip"),
                                   status: MailboxMutator.statusUnsent,
                                   who: "them@example.com", subject: "Still a draft")

        let entries = Toc.read(base.appendingPathExtension("toc"))!
        XCTAssertEqual(entries[0].status, MailboxMutator.statusUnsent)
    }

    // MARK: safety

    func testBacksUpOnceBeforeFirstWrite() throws {
        try buildOut(bodies: ["first", "second"])
        let bak = base.appendingPathExtension("mbx").appendingPathExtension("bak")
        // Building the fixture through `Outbox.append` makes its own backup on
        // the second message. Clear it, so this tests `replace`'s behaviour and
        // not the fixture's.
        try? FileManager.default.removeItem(at: bak)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bak.path))

        try MailboxMutator.replace(base: base, index: 1,
                                   messageData: message(subject: "One", body: "changed"),
                                   status: MailboxMutator.statusUnsent,
                                   who: "you@example.com", subject: "One")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bak.path))
        let afterFirst = try Data(contentsOf: bak)

        // A second replace must not overwrite the backup — it is the original
        // mailbox, not the previous one.
        try MailboxMutator.replace(base: base, index: 1,
                                   messageData: message(subject: "One", body: "changed again"),
                                   status: MailboxMutator.statusUnsent,
                                   who: "you@example.com", subject: "One")
        XCTAssertEqual(try Data(contentsOf: bak), afterFirst)
    }

    func testOutOfRangeIndexThrows() throws {
        try buildOut(bodies: ["only"])
        XCTAssertThrowsError(try MailboxMutator.replace(
            base: base, index: 2, messageData: message(subject: "x", body: "y"),
            status: MailboxMutator.statusUnsent, who: "a", subject: "x"))
        XCTAssertThrowsError(try MailboxMutator.replace(
            base: base, index: 0, messageData: message(subject: "x", body: "y"),
            status: MailboxMutator.statusUnsent, who: "a", subject: "x"))
    }

    /// Repeated saves are the normal case for a draft, so the mailbox must not
    /// drift: three edits in a row should leave exactly as many records as it
    /// started with, with the neighbours still readable.
    func testRepeatedReplacesDoNotDrift() throws {
        try buildOut(bodies: ["first", "second", "third"])
        for n in 1...3 {
            try MailboxMutator.replace(
                base: base, index: 2,
                messageData: message(subject: "Draft \(n)",
                                     body: String(repeating: "e", count: n * 137)),
                status: MailboxMutator.statusUnsent,
                who: "you@example.com", subject: "Draft \(n)")
        }
        let listing = MailStore(root: root).list(at: base, name: "Out")!
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "Draft 3", "S3"])
        XCTAssertTrue(bodyOfRecord(1).contains("first"))
        XCTAssertTrue(bodyOfRecord(3).contains("third"))
    }

    // MARK: record boundaries

    /// A body the user didn't end with a newline must not swallow the next
    /// message.
    ///
    /// `OutgoingMessage.rfc822` appends nothing after the body, so this is the
    /// ordinary case of typing "Hello" and clicking Send — and without a
    /// terminator the following record's `From ???@??? ` separator is no longer
    /// at a line start, `findRecords` doesn't see it, and the two messages merge
    /// into one. Nothing throws; the mailbox simply loses a message.
    func testRecordWithUnterminatedBodySurvivesTheNextAppend() throws {
        try buildOut(bodies: ["first"])
        _ = try Outbox.append(messageData: unterminated(subject: "S2", body: "no newline here"),
                              to: base, status: MailboxMutator.statusUnsent,
                              who: "you@example.com", subject: "S2")
        _ = try Outbox.append(messageData: message(subject: "S3", body: "third"),
                              to: base, status: MailboxMutator.statusSent,
                              who: "you@example.com", subject: "S3")

        let listing = MailStore(root: root).list(at: base, name: "Out")!
        XCTAssertEqual(listing.rows.count, 3, "an unterminated body must not merge two records")
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "S2", "S3"])
    }

    func testReplaceWithUnterminatedBodyKeepsTheFollowingRecord() throws {
        try buildOut(bodies: ["first", "second", "third"])
        try MailboxMutator.replace(base: base, index: 2,
                                   messageData: unterminated(subject: "Two", body: "abrupt"),
                                   status: MailboxMutator.statusUnsent,
                                   who: "you@example.com", subject: "Two")

        let listing = MailStore(root: root).list(at: base, name: "Out")!
        XCTAssertEqual(listing.rows.count, 3)
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "Two", "S3"])
        XCTAssertTrue(bodyOfRecord(3).contains("third"))
    }

    // MARK: fixture

    private var base: URL { root.appendingPathComponent("Out") }

    /// A mailbox of N messages with subjects S1…SN, plus a matching `.toc`.
    /// Built through `Outbox.append` rather than by hand, so the records and the
    /// index are written by the same code the app uses.
    private func buildOut(bodies: [String]) throws {
        for (i, body) in bodies.enumerated() {
            _ = try Outbox.append(messageData: message(subject: "S\(i + 1)", body: body),
                                  to: base,
                                  status: MailboxMutator.statusSent,
                                  who: "you@example.com",
                                  subject: "S\(i + 1)")
        }
    }

    private func message(subject: String, body: String) -> Data {
        Data([
            "From: me@example.com",
            "To: you@example.com",
            "Subject: \(subject)",
            "Content-Type: text/plain; charset=us-ascii",
            "",
            body,
            "",
        ].joined(separator: "\r\n").utf8)
    }

    /// The same message, but with no trailing line ending — what
    /// `OutgoingMessage.rfc822` produces for a body the user didn't end with
    /// Return.
    private func unterminated(subject: String, body: String) -> Data {
        Data([
            "From: me@example.com",
            "To: you@example.com",
            "Subject: \(subject)",
            "Content-Type: text/plain; charset=us-ascii",
            "",
            body,
        ].joined(separator: "\r\n").utf8)
    }

    /// The decoded body of the nth (1-based) record, straight from the `.mbx`.
    private func bodyOfRecord(_ index: Int) -> String {
        let data = (try? Data(contentsOf: base.appendingPathExtension("mbx"))) ?? Data()
        let bytes = [UInt8](data)
        let recs = Mbox.findRecords(bytes)
        guard index >= 1, index <= recs.count else { return "" }
        return String(decoding: Mbox.messageBytes(bytes, recs[index - 1]), as: UTF8.self)
    }
}

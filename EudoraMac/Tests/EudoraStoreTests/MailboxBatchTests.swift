import XCTest
import Foundation
@testable import EudoraStore

/// Tests for `MailboxMutator.removeMany` / `moveMany`, the batch primitives
/// behind multi-selection delete and move.
///
/// The bug class under test is the same one `MailboxReplaceTests` guards
/// against, multiplied: removing one message shifts every later record's
/// offset, so a naïve loop over a selection corrupts the indices of the
/// not-yet-processed messages — nothing throws, the mailbox still parses, and
/// the rows quietly describe the wrong messages. So these tests remove and move
/// *non-adjacent* messages from the middle of a mailbox and assert on the
/// **survivors** — their subjects, their bodies, and the `.toc`'s offsets —
/// rather than on the messages that left.
final class MailboxBatchTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: removeMany

    func testRemoveManyKeepsSurvivorsIntact() throws {
        try build(bodies: ["first", "second", "third", "fourth", "fifth"])

        let removed = try MailboxMutator.removeMany(base: base, indices: [2, 4])

        XCTAssertEqual(removed.count, 2)
        let listing = MailStore(root: root).list(at: base, name: "Box")!
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "S3", "S5"])
        // The survivors are the point: a wrong shift truncates, merges, or
        // swaps them without throwing.
        XCTAssertTrue(bodyOfRecord(1).contains("first"))
        XCTAssertTrue(bodyOfRecord(2).contains("third"))
        XCTAssertTrue(bodyOfRecord(3).contains("fifth"))
    }

    /// The order the indices arrive in must not matter — the selection set the
    /// app hands over is unordered.
    func testRemoveManyIsOrderIndependent() throws {
        try build(bodies: ["first", "second", "third", "fourth", "fifth"])
        try MailboxMutator.removeMany(base: base, indices: [4, 2])

        let listing = MailStore(root: root).list(at: base, name: "Box")!
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "S3", "S5"])
        XCTAssertTrue(bodyOfRecord(2).contains("third"))
    }

    func testRemoveManyDeduplicatesIndices() throws {
        try build(bodies: ["first", "second", "third"])
        let removed = try MailboxMutator.removeMany(base: base, indices: [2, 2, 2])

        XCTAssertEqual(removed.count, 1, "a duplicated index is one message, not three")
        let listing = MailStore(root: root).list(at: base, name: "Box")!
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "S3"])
    }

    func testRemoveManyOfAdjacentRecords() throws {
        try build(bodies: ["first", "second", "third", "fourth"])
        try MailboxMutator.removeMany(base: base, indices: [2, 3])

        let listing = MailStore(root: root).list(at: base, name: "Box")!
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "S4"])
        XCTAssertTrue(bodyOfRecord(2).contains("fourth"))
    }

    func testRemoveManyIncludingFirstAndLast() throws {
        try build(bodies: ["first", "second", "third"])
        try MailboxMutator.removeMany(base: base, indices: [1, 3])

        let listing = MailStore(root: root).list(at: base, name: "Box")!
        XCTAssertEqual(listing.rows.map(\.subject), ["S2"])
        XCTAssertTrue(bodyOfRecord(1).contains("second"))
    }

    func testRemoveManyOfEverything() throws {
        try build(bodies: ["first", "second"])
        try MailboxMutator.removeMany(base: base, indices: [1, 2])

        let listing = MailStore(root: root).list(at: base, name: "Box")!
        XCTAssertEqual(listing.rows.count, 0)
    }

    /// The TOC must still describe the mailbox afterwards, or the reader falls
    /// back to a status-less scan and every message silently loses its state.
    func testTocStaysConsistentAfterRemoveMany() throws {
        try build(bodies: ["first", "second", "third", "fourth", "fifth"])
        try MailboxMutator.removeMany(base: base, indices: [1, 3])

        let listing = MailStore(root: root).list(at: base, name: "Box")!
        XCTAssertEqual(listing.source, .toc,
                       "a removal that invalidates the TOC would fall back to scanning")

        let entries = Toc.read(base.appendingPathExtension("toc"))!
        let recs = Mbox.findRecords([UInt8](try Data(contentsOf: base.appendingPathExtension("mbx"))))
        XCTAssertEqual(entries.map(\.offset), recs.map(\.offset),
                       "every cached offset must still name a real record")
        XCTAssertEqual(entries.map(\.length), recs.map(\.length))
    }

    func testRemoveManyReturnsRecordsInAscendingIndexOrder() throws {
        try build(bodies: ["first", "second", "third"])
        let removed = try MailboxMutator.removeMany(base: base, indices: [3, 1])

        XCTAssertEqual(removed.count, 2)
        XCTAssertTrue(String(decoding: removed[0].record, as: UTF8.self).contains("first"))
        XCTAssertTrue(String(decoding: removed[1].record, as: UTF8.self).contains("third"))
    }

    func testRemoveManyValidatesTheWholeBatchBeforeMutating() throws {
        try build(bodies: ["first", "second"])
        XCTAssertThrowsError(try MailboxMutator.removeMany(base: base, indices: [1, 3]))

        // The valid half of the batch must not have been applied.
        let listing = MailStore(root: root).list(at: base, name: "Box")!
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "S2"],
                       "a batch with one bad index must leave the mailbox untouched")
    }

    func testRemoveManyWithNoIndicesIsANoOp() throws {
        try build(bodies: ["first"])
        let before = try Data(contentsOf: base.appendingPathExtension("mbx"))
        let removed = try MailboxMutator.removeMany(base: base, indices: [])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathExtension("mbx")), before)
    }

    // MARK: moveMany

    func testMoveManyCarriesMessagesInMailboxOrder() throws {
        try build(bodies: ["first", "second", "third", "fourth", "fifth"])
        try seedDest()
        // Passed backwards on purpose: the destination must receive them in the
        // order they sat in the source, not the order they were clicked.
        try MailboxMutator.moveMany(from: base, indices: [4, 2], to: dest)

        let store = MailStore(root: root)
        XCTAssertEqual(store.list(at: base, name: "Box")!.rows.map(\.subject), ["S1", "S3", "S5"])
        XCTAssertEqual(store.list(at: dest, name: "Dest")!.rows.map(\.subject), ["D0", "S2", "S4"])
        XCTAssertTrue(bodyOfRecord(2).contains("third"))
    }

    func testMoveManyAppendsToANonEmptyDestination() throws {
        try build(bodies: ["first", "second", "third"])
        try seedDest()

        try MailboxMutator.moveMany(from: base, indices: [1, 3], to: dest)

        let store = MailStore(root: root)
        XCTAssertEqual(store.list(at: base, name: "Box")!.rows.map(\.subject), ["S2"])
        XCTAssertEqual(store.list(at: dest, name: "Dest")!.rows.map(\.subject), ["D0", "S1", "S3"])
    }

    /// Status is a `.toc`-only fact, so it survives a move only if the entries
    /// travel with the records.
    func testMoveManyCarriesStatus() throws {
        try build(bodies: ["first", "second"])
        try seedDest()
        try MailboxMutator.setStatus(base: base, index: 2, status: MailboxMutator.statusUnread)

        try MailboxMutator.moveMany(from: base, indices: [1, 2], to: dest)

        let entries = Toc.read(dest.appendingPathExtension("toc"))!
        XCTAssertEqual(entries.map(\.status),
                       [MailboxMutator.statusRead,
                        MailboxMutator.statusSent, MailboxMutator.statusUnread])
    }

    func testMoveManyTocsStayConsistentOnBothSides() throws {
        try build(bodies: ["first", "second", "third", "fourth"])
        try seedDest()
        try MailboxMutator.moveMany(from: base, indices: [2, 3], to: dest)

        let store = MailStore(root: root)
        XCTAssertEqual(store.list(at: base, name: "Box")!.source, .toc)
        XCTAssertEqual(store.list(at: dest, name: "Dest")!.source, .toc)
    }

    func testMoveManyValidatesBeforeAppendingAnything() throws {
        try build(bodies: ["first", "second"])
        XCTAssertThrowsError(try MailboxMutator.moveMany(from: base, indices: [2, 9], to: dest))

        // Nothing may have landed in the destination: a partial append with no
        // removal reads as duplication.
        let listing = MailStore(root: root).list(at: dest, name: "Dest")
        XCTAssertTrue(listing == nil || listing!.rows.isEmpty,
                      "a batch with one bad index must not deliver the valid half")
        XCTAssertEqual(MailStore(root: root).list(at: base, name: "Box")!.rows.count, 2)
    }

    // MARK: single-message paths still behave (they delegate to the batch now)

    func testSingleRemoveStillKeepsNeighbours() throws {
        try build(bodies: ["first", "second", "third"])
        let (record, _) = try MailboxMutator.remove(base: base, index: 2)

        XCTAssertTrue(String(decoding: record, as: UTF8.self).contains("second"))
        let listing = MailStore(root: root).list(at: base, name: "Box")!
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "S3"])
        XCTAssertEqual(listing.source, .toc)
    }

    func testSingleMoveStillCarriesTheMessage() throws {
        try build(bodies: ["first", "second"])
        try seedDest()
        try MailboxMutator.move(from: base, index: 1, to: dest)

        let store = MailStore(root: root)
        XCTAssertEqual(store.list(at: base, name: "Box")!.rows.map(\.subject), ["S2"])
        XCTAssertEqual(store.list(at: dest, name: "Dest")!.rows.map(\.subject), ["D0", "S1"])
    }

    // MARK: fixture

    private var base: URL { root.appendingPathComponent("Box") }
    private var dest: URL { root.appendingPathComponent("Dest") }

    /// Give the destination one existing message ("D0") and, with it, a valid
    /// `.toc`. `MailboxMutator.appendRecord` appends a TOC entry only when a
    /// `.toc` already exists — the app only ever moves into real mailboxes —
    /// so a destination built empty would list by scan and lose the very
    /// statuses these tests assert on.
    private func seedDest() throws {
        _ = try Outbox.append(messageData: message(subject: "D0", body: "already here"),
                              to: dest, status: MailboxMutator.statusRead,
                              who: "you@example.com", subject: "D0")
    }

    /// A mailbox of N messages with subjects S1…SN, plus a matching `.toc`.
    /// Built through `Outbox.append` rather than by hand, so the records and the
    /// index are written by the same code the app uses.
    private func build(bodies: [String]) throws {
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

    /// The decoded body of the nth (1-based) record, straight from the `.mbx`.
    private func bodyOfRecord(_ index: Int) -> String {
        let data = (try? Data(contentsOf: base.appendingPathExtension("mbx"))) ?? Data()
        let bytes = [UInt8](data)
        let recs = Mbox.findRecords(bytes)
        guard index >= 1, index <= recs.count else { return "" }
        return String(decoding: Mbox.messageBytes(bytes, recs[index - 1]), as: UTF8.self)
    }
}

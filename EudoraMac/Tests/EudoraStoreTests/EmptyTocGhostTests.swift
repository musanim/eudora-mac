import XCTest
import Foundation
@testable import EudoraStore

/// An emptied mailbox must stay empty when it still holds deleted-but-not-
/// compacted ghosts.
///
/// The bug (2026oct23): In carried 26 records from July that its `.toc` didn't
/// list — ordinary Eudora 7 ghosts. Deleting every listed message left a `.toc`
/// with no entries. The next delivery judged that index "inconsistent" and
/// deleted it, so the listing fell back to scanning the `.mbx` and showed all
/// 26 ghosts plus the new message, every one with status "?".
final class EmptyTocGhostTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-emptytoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var base: URL { root.appendingPathComponent("In") }
    private var toc: URL { base.appendingPathExtension("toc") }

    /// Three records; the `.toc` lists only the last two, so record 1 is a ghost.
    private func buildWithGhost() throws {
        for i in 1...3 {
            _ = try Outbox.append(messageData: message(subject: "S\(i)"), to: base,
                                  status: MailboxMutator.statusRead,
                                  who: "me@example.com", subject: "S\(i)")
        }
        let loaded = try XCTUnwrap(Toc.load(toc))
        let kept = loaded.entries.enumerated().dropFirst().map { (source: Optional($0.offset), entry: $0.element) }
        try TocWriter.patched(original: loaded.data, originalEntries: loaded.entries,
                              entries: kept).write(to: toc)
        XCTAssertEqual(MailStore(root: root).list(at: base)?.rows.map(\.subject), ["S2", "S3"])
    }

    func testDeletingEveryListedMessageLeavesAnEmptyListing() throws {
        try buildWithGhost()
        try MailboxMutator.removeMany(base: base, indices: [2, 3])

        XCTAssertEqual(Toc.read(toc)?.count, 0, "the index should survive, empty")
        let listing = try XCTUnwrap(MailStore(root: root).list(at: base))
        XCTAssertEqual(listing.rows.count, 0, "the ghost must not reappear")
    }

    func testDeliveryIntoAnEmptiedMailboxShowsOnlyTheNewMessage() throws {
        try buildWithGhost()
        try MailboxMutator.removeMany(base: base, indices: [2, 3])

        _ = try Delivery.deliverIncoming(messageData: message(subject: "New"), to: base)

        let entries = try XCTUnwrap(Toc.read(toc), "delivery must not delete the index")
        XCTAssertEqual(entries.count, 1)
        let listing = try XCTUnwrap(MailStore(root: root).list(at: base))
        XCTAssertEqual(listing.rows.map(\.subject), ["New"])
        XCTAssertEqual(listing.rows.first?.status, MailboxMutator.statusUnread)
    }

    /// A missing `.toc` still means "scan": the empty-index rule must not swallow it.
    func testMissingTocStillScans() throws {
        try buildWithGhost()
        try FileManager.default.removeItem(at: toc)
        XCTAssertEqual(MailStore(root: root).list(at: base)?.rows.count, 3)
    }

    /// A mailbox that has lost its `.toc` heals once it is emptied: the next
    /// message moved into it starts a fresh index, so it has a status again.
    func testMoveIntoEmptyMailboxWithNoTocStartsAnIndex() throws {
        try buildWithGhost()
        try FileManager.default.removeItem(at: toc)
        try MailboxMutator.removeMany(base: base, indices: [1, 2, 3])
        XCTAssertNil(Toc.read(toc))

        let other = root.appendingPathComponent("Other")
        _ = try Outbox.append(messageData: message(subject: "Back"), to: other,
                              status: MailboxMutator.statusRead,
                              who: "me@example.com", subject: "Back")
        try MailboxMutator.moveMany(from: other, indices: [1], to: base)

        XCTAssertEqual(Toc.read(toc)?.count, 1)
        let listing = try XCTUnwrap(MailStore(root: root).list(at: base))
        XCTAssertEqual(listing.rows.map(\.subject), ["Back"])
        XCTAssertEqual(listing.rows.first?.status, MailboxMutator.statusRead)
    }

    private func message(subject: String) -> Data {
        Data([
            "From: someone@example.com",
            "To: me@example.com",
            "Subject: \(subject)",
            "Content-Type: text/plain; charset=us-ascii",
            "",
            "body of \(subject)",
            "",
        ].joined(separator: "\r\n").utf8)
    }
}

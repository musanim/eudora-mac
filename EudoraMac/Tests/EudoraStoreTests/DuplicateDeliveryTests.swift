import XCTest
@testable import EudoraStore

/// The `Message-ID` duplicate-delivery guard.
///
/// The case being defended against: the same message reaching Eudora 8 from two
/// sources — Gmail polled directly while Gmail is also forwarding into the
/// musanim account — where the two copies carry different POP UIDs on different
/// servers and one identical `Message-ID`, so the downloaded-UID set cannot see
/// that they are the same message.
///
/// The governing rule in every uncertain case is **deliver, don't drop**: a
/// message arriving twice costs a keystroke, a message silently discarded is
/// gone with nothing to say it happened. Several tests below exist only to pin
/// that direction.
final class DuplicateDeliveryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: the guard

    func testSecondCopyOfOneMessageIsNotDelivered() throws {
        var seen = MessageIDIndex()
        let msg = incoming(subject: "Hello", id: "<a1@example.com>")

        let first = try Delivery.deliverIfNew(messageData: msg, to: base, seen: &seen)
        XCTAssertEqual(first, .delivered(index: 1))

        let second = try Delivery.deliverIfNew(messageData: msg, to: base, seen: &seen)
        XCTAssertEqual(second, .duplicate(messageID: "<a1@example.com>"))
        XCTAssertEqual(rowCount(), 1, "the duplicate was appended to the mailbox anyway")
    }

    /// Two servers stamp their own `Received:` headers on the same message, so
    /// the copies differ byte-for-byte. Matching on the id has to see through
    /// that — it is the whole reason a length or checksum test wouldn't do.
    func testCopiesDifferingInReceivedHeadersStillMatch() throws {
        var seen = MessageIDIndex()
        let viaGmail = relayed(id: "<n1@example.com>", by: "mx.google.com")
        let viaMusanim = relayed(id: "<n1@example.com>", by: "mail.musanim.com")
        XCTAssertNotEqual(viaGmail, viaMusanim, "the fixture isn't testing what it claims")

        let first = try Delivery.deliverIfNew(messageData: viaGmail, to: base, seen: &seen)
        XCTAssertEqual(first, .delivered(index: 1))
        let second = try Delivery.deliverIfNew(messageData: viaMusanim, to: base, seen: &seen)
        XCTAssertEqual(second, .duplicate(messageID: "<n1@example.com>"))

        XCTAssertEqual(rowCount(), 1, "the duplicate was appended to the mailbox anyway")
    }

    /// The realistic shape of the cut-over failure: both copies inside a single
    /// check, before any rescan of the mailbox could have seen the first.
    func testDuplicateWithinOneBatchIsCaught() throws {
        var seen = MessageIDIndex(scanning: base)   // empty mailbox
        let batch = [
            incoming(subject: "One", id: "<b1@example.com>"),
            incoming(subject: "Two", id: "<b2@example.com>"),
            incoming(subject: "One again", id: "<b1@example.com>"),
        ]
        var delivered = 0, duplicates = 0
        for msg in batch {
            switch try Delivery.deliverIfNew(messageData: msg, to: base, seen: &seen) {
            case .delivered: delivered += 1
            case .duplicate: duplicates += 1
            }
        }
        XCTAssertEqual(delivered, 2)
        XCTAssertEqual(duplicates, 1)
        XCTAssertEqual(rowCount(), 2)
    }

    /// A fresh index built from a mailbox already holding the message — the
    /// second-check case, and the one an edited account (empty UID set,
    /// everything re-downloaded) runs into.
    func testIndexScannedFromDiskRecognisesWhatIsAlreadyThere() throws {
        var first = MessageIDIndex()
        let msg = incoming(subject: "Hello", id: "<c1@example.com>")
        _ = try Delivery.deliverIfNew(messageData: msg, to: base, seen: &first)

        var later = MessageIDIndex(scanning: base)
        XCTAssertEqual(later.count, 1)
        // Hoisted out of the assertion: `&later` inside XCTAssertEqual's
        // autoclosure is an inout access to a captured local, which is legal but
        // needlessly hard to be sure of without a compiler.
        let outcome = try Delivery.deliverIfNew(messageData: msg, to: base, seen: &later)
        XCTAssertEqual(outcome, .duplicate(messageID: "<c1@example.com>"))
        XCTAssertEqual(rowCount(), 1)
    }

    func testDifferentMessagesBothDeliver() throws {
        var seen = MessageIDIndex()
        _ = try Delivery.deliverIfNew(messageData: incoming(subject: "One", id: "<d1@example.com>"),
                                      to: base, seen: &seen)
        let second = try Delivery.deliverIfNew(
            messageData: incoming(subject: "Two", id: "<d2@example.com>"), to: base, seen: &seen)
        XCTAssertEqual(second, .delivered(index: 2))
        XCTAssertEqual(rowCount(), 2)
    }

    /// The index has to survive a mailbox with many messages, since it is built
    /// from the record scan rather than the `.toc`.
    func testIndexCollectsEveryMessageInTheMailbox() throws {
        var seen = MessageIDIndex()
        for n in 1...12 {
            _ = try Delivery.deliverIfNew(messageData: incoming(subject: "M\(n)",
                                                                id: "<e\(n)@example.com>"),
                                          to: base, seen: &seen)
        }
        let scanned = MessageIDIndex(scanning: base)
        XCTAssertEqual(scanned.count, 12)
        for n in 1...12 { XCTAssertTrue(scanned.contains("<e\(n)@example.com>")) }
    }

    // MARK: fail open

    func testMessageWithNoMessageIDIsAlwaysDelivered() throws {
        var seen = MessageIDIndex()
        let msg = incoming(subject: "Anonymous", id: nil)
        XCTAssertEqual(try Delivery.deliverIfNew(messageData: msg, to: base, seen: &seen),
                       .delivered(index: 1))
        // Twice: with nothing to compare, a second copy must still arrive rather
        // than be matched against some stand-in key like the empty string.
        XCTAssertEqual(try Delivery.deliverIfNew(messageData: msg, to: base, seen: &seen),
                       .delivered(index: 2))
        XCTAssertEqual(rowCount(), 2)
    }

    /// Two *different* messages that both lack an id must not collide with each
    /// other — the bug a `""` sentinel in the set would cause.
    func testTwoMessagesWithoutIDsDoNotCollide() throws {
        var seen = MessageIDIndex()
        _ = try Delivery.deliverIfNew(messageData: incoming(subject: "First", id: nil),
                                      to: base, seen: &seen)
        _ = try Delivery.deliverIfNew(messageData: incoming(subject: "Second", id: nil),
                                      to: base, seen: &seen)
        XCTAssertEqual(rowCount(), 2)
        XCTAssertTrue(MessageIDIndex(scanning: base).isEmpty,
                      "a message with no id must not contribute a key to the index")
    }

    func testEmptyBracketsAreNotAKey() throws {
        var seen = MessageIDIndex()
        let msg = incoming(subject: "Broken", id: "<>")
        XCTAssertEqual(try Delivery.deliverIfNew(messageData: msg, to: base, seen: &seen),
                       .delivered(index: 1))
        XCTAssertEqual(try Delivery.deliverIfNew(messageData: msg, to: base, seen: &seen),
                       .delivered(index: 2))
    }

    func testScanningAMailboxThatDoesNotExistIsEmptyRatherThanFatal() {
        let index = MessageIDIndex(scanning: root.appendingPathComponent("NoSuchMailbox"))
        XCTAssertTrue(index.isEmpty)
    }

    // MARK: normalisation

    func testHeaderNameIsMatchedCaseInsensitively() {
        let raw = Data(["From: a@b.com", "Message-Id: <f1@example.com>", "", "body"]
            .joined(separator: "\r\n").utf8)
        XCTAssertEqual(MessageIDIndex.messageID(of: raw), "<f1@example.com>")
    }

    func testSurroundingWhitespaceAndTrailingCommentAreIgnored() {
        XCTAssertEqual(MessageIDIndex.normalized("   <g1@example.com>   "), "<g1@example.com>")
        XCTAssertEqual(MessageIDIndex.normalized("<g1@example.com> (generated)"),
                       "<g1@example.com>")
    }

    /// An RFC-822 comment may itself contain angle brackets, so the token ends at
    /// the *first* `>`, not the last one on the line.
    func testACommentContainingBracketsIsNotFoldedIntoTheKey() {
        XCTAssertEqual(MessageIDIndex.normalized("<g2@example.com> (in reply to <x@y>)"),
                       "<g2@example.com>")
    }

    func testABareIDFollowedByATabbedCommentKeepsOnlyTheID() {
        XCTAssertEqual(MessageIDIndex.normalized("g3@example.com\t(generated)"),
                       "<g3@example.com>")
    }

    /// `parseHeaders` unfolds a continuation line by joining it with a space, so
    /// a folded id arrives with a space inside the brackets. It must still match
    /// the unfolded form of the same id.
    func testFoldedIDMatchesItsUnfoldedForm() {
        XCTAssertEqual(MessageIDIndex.normalized("<h1@ example.com>"),
                       MessageIDIndex.normalized("<h1@example.com>"))
    }

    /// Some mailers omit the brackets. The bare and bracketed forms of one id
    /// are the same message and must land on one key.
    func testBareIDIsNormalisedToTheBracketedForm() {
        XCTAssertEqual(MessageIDIndex.normalized("i1@example.com"), "<i1@example.com>")
    }

    /// RFC 5322 makes the id-left part case-sensitive: two ids differing only in
    /// case are formally different messages, and folding them together would
    /// discard real mail.
    func testCaseIsPreserved() {
        XCTAssertNotEqual(MessageIDIndex.normalized("<J1@example.com>"),
                          MessageIDIndex.normalized("<j1@example.com>"))
    }

    func testUnusableValuesYieldNil() {
        XCTAssertNil(MessageIDIndex.normalized(""))
        XCTAssertNil(MessageIDIndex.normalized("   "))
        XCTAssertNil(MessageIDIndex.normalized("<>"))
        XCTAssertNil(MessageIDIndex.normalized("< >"))
    }

    /// Only the message's own header counts. A `Message-ID` appearing in a
    /// quoted reply in the body — or in an `In-Reply-To` — must not be read as
    /// this message's identity, or one reply would suppress the next.
    func testIDIsTakenFromTheHeaderNotTheBody() {
        let raw = Data([
            "From: a@b.com",
            "In-Reply-To: <parent@example.com>",
            "Message-ID: <child@example.com>",
            "",
            "> Message-ID: <quoted@example.com>",
        ].joined(separator: "\r\n").utf8)
        XCTAssertEqual(MessageIDIndex.messageID(of: raw), "<child@example.com>")
    }

    func testAMessageWithNoHeaderBlockAtAllYieldsNil() {
        XCTAssertNil(MessageIDIndex.messageID(of: Data("not a message".utf8)))
    }

    // MARK: interaction with the existing delivery guarantees

    /// `deliverIfNew` must leave the same mailbox state `deliverIncoming` does —
    /// unread, and a `.toc` that still describes the mailbox. A duplicate check
    /// that cost every message its status would be a poor trade.
    func testDeliveredMessagesAreStillUnreadAndTheTocStillHolds() throws {
        var seen = MessageIDIndex()
        for n in 1...3 {
            _ = try Delivery.deliverIfNew(messageData: incoming(subject: "M\(n)",
                                                                id: "<k\(n)@example.com>"),
                                          to: base, seen: &seen)
        }
        let listing = try XCTUnwrap(MailStore(root: root).list(at: base, name: "In"))
        XCTAssertEqual(listing.source, .toc)
        XCTAssertEqual(listing.rows.count, 3)
        for row in listing.rows {
            XCTAssertEqual(row.status, MailboxMutator.statusUnread,
                           "delivered mail must arrive unread")
        }
    }

    /// A skipped duplicate must not touch the mailbox at all — not the `.mbx`,
    /// not the `.toc`. If it appended and then rolled back, the offsets of the
    /// messages already listed could move.
    func testASkippedDuplicateLeavesTheMailboxByteIdentical() throws {
        var seen = MessageIDIndex()
        let msg = incoming(subject: "Hello", id: "<l1@example.com>")
        _ = try Delivery.deliverIfNew(messageData: msg, to: base, seen: &seen)

        let mbxBefore = try Data(contentsOf: base.appendingPathExtension("mbx"))
        let tocBefore = try Data(contentsOf: base.appendingPathExtension("toc"))

        _ = try Delivery.deliverIfNew(messageData: msg, to: base, seen: &seen)

        XCTAssertEqual(try Data(contentsOf: base.appendingPathExtension("mbx")), mbxBefore)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathExtension("toc")), tocBefore)
    }

    /// The old entry point is untouched and still delivers unconditionally —
    /// it is what the tests of the delivery format itself use, and nothing about
    /// the guard should change its behaviour.
    func testTheUnguardedEntryPointStillDeliversEverything() throws {
        let msg = incoming(subject: "Hello", id: "<m1@example.com>")
        try Delivery.deliverIncoming(messageData: msg, to: base)
        try Delivery.deliverIncoming(messageData: msg, to: base)
        XCTAssertEqual(rowCount(), 2)
    }

    // MARK: fixture

    private var base: URL { root.appendingPathComponent("In") }

    private func rowCount() -> Int {
        MailStore(root: root).list(at: base, name: "In")?.rows.count ?? -1
    }

    /// One message as it would arrive having been relayed by `host` — the same
    /// `Message-ID`, a different `Received:` line, so the bytes differ.
    private func relayed(id: String, by host: String) -> Data {
        Data([
            "Received: from sender.example.com by \(host) with ESMTP id \(host.count)",
            "From: Them <them@example.com>",
            "To: me@example.com",
            "Subject: Relayed",
            "Date: Mon, 27 Jul 2026 09:15:00 -0700",
            "Message-ID: \(id)",
            "",
            "body",
            "",
        ].joined(separator: "\r\n").utf8)
    }

    private func incoming(subject: String, id: String?) -> Data {
        var lines = [
            "From: Them <them@example.com>",
            "To: me@example.com",
            "Subject: \(subject)",
            "Date: Mon, 27 Jul 2026 09:15:00 -0700",
            "Content-Type: text/plain; charset=us-ascii",
        ]
        if let id = id { lines.append("Message-ID: \(id)") }
        lines += ["", "body of \(subject)", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}

import XCTest
@testable import EudoraStore

/// Locating the message a reply was answering, which is what the R mark needs.
///
/// The app remembers a mailbox and a byte offset when Reply is pressed, and
/// writes `MS_REPLIED` when the reply is actually delivered — possibly a long
/// time later. In between, anything earlier in that mailbox may have been
/// deleted, and every later record slides. So the offset is only ever a hint,
/// confirmed against the original's `Message-ID`, and `MessageIDIndex.offset(of:in:)`
/// is the fallback that finds the record when the hint has gone stale.
///
/// The governing rule is the opposite of the duplicate guard's: **mark nothing
/// rather than mark the wrong thing.** A missing R costs a second look at a
/// message; a false R costs a message going unanswered because it looked
/// answered. Several tests below exist only to pin that direction.
final class RepliedMarkTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-replied-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: finding the message

    func testFindsTheOffsetOfEachMessage() throws {
        try deliver(["<m1@example.com>", "<m2@example.com>", "<m3@example.com>"])

        for id in ["<m1@example.com>", "<m2@example.com>", "<m3@example.com>"] {
            let offset = try XCTUnwrap(MessageIDIndex.offset(of: id, in: base),
                                       "\(id) should be findable")
            XCTAssertEqual(messageID(atOffset: offset), id,
                           "the offset returned for \(id) names some other message")
        }
    }

    func testAbsentMessageIsNotFound() throws {
        try deliver(["<m1@example.com>", "<m2@example.com>"])
        XCTAssertNil(MessageIDIndex.offset(of: "<nowhere@example.com>", in: base))
    }

    /// The whole point of the fallback: a message earlier in the mailbox goes
    /// away, every later offset shifts, and the remembered one now names the
    /// wrong record — or none. The id still finds the right message.
    func testOffsetIsFoundAgainAfterAnEarlierMessageIsRemoved() throws {
        try deliver(["<m1@example.com>", "<m2@example.com>", "<m3@example.com>"])
        let before = try XCTUnwrap(MessageIDIndex.offset(of: "<m3@example.com>", in: base))

        try MailboxMutator.remove(base: base, index: 1)

        let after = try XCTUnwrap(MessageIDIndex.offset(of: "<m3@example.com>", in: base))
        XCTAssertNotEqual(after, before, "the fixture isn't testing what it claims")
        XCTAssertEqual(messageID(atOffset: after), "<m3@example.com>")
    }

    /// The message being replied to is itself deleted before the reply is sent.
    /// Nothing is found, so the caller writes nothing — rather than writing over
    /// whatever slid into that offset.
    func testRemovedMessageIsNotFound() throws {
        try deliver(["<m1@example.com>", "<m2@example.com>"])
        try MailboxMutator.remove(base: base, index: 2)
        XCTAssertNil(MessageIDIndex.offset(of: "<m2@example.com>", in: base))
    }

    // MARK: normalisation

    /// The remembered id comes from a `Message-ID` header read out of a mailbox,
    /// the stored one from the same place — but mailers vary, and both sides go
    /// through the same normalisation so a bare id and a bracketed one are one
    /// message rather than two.
    func testBareAndBracketedFormsAreTheSameMessage() throws {
        try deliver(["<m1@example.com>"])
        let bracketed = try XCTUnwrap(MessageIDIndex.offset(of: "<m1@example.com>", in: base))
        let bare = try XCTUnwrap(MessageIDIndex.offset(of: "m1@example.com", in: base))
        XCTAssertEqual(bare, bracketed)
    }

    func testUnusableIDFindsNothing() throws {
        try deliver(["<m1@example.com>"])
        XCTAssertNil(MessageIDIndex.offset(of: "", in: base),
                     "an empty id must not match the first message, or any message")
        XCTAssertNil(MessageIDIndex.offset(of: "   ", in: base))
    }

    /// A message with no `Message-ID` of its own is never the answer to a
    /// lookup, whatever is asked for.
    func testMessageWithoutAnIDIsNeverFound() throws {
        var seen = MessageIDIndex()
        let outcome = try Delivery.deliverIfNew(messageData: message(id: nil),
                                                to: base, seen: &seen)
        XCTAssertEqual(outcome, .delivered(index: 1), "the fixture must actually land")
        XCTAssertNil(MessageIDIndex.offset(of: "<anything@example.com>", in: base))
    }

    // MARK: absent mailbox

    func testMissingMailboxFindsNothing() {
        let nowhere = root.appendingPathComponent("NoSuchMailbox")
        XCTAssertNil(MessageIDIndex.offset(of: "<m1@example.com>", in: nowhere))
    }

    // MARK: the status byte

    /// `MS_REPLIED` *replaces* read/unread rather than annotating it — the
    /// status is one byte. Pinned here because the whole design of the R mark
    /// rests on it: the unread dot going away is the intended behaviour, not a
    /// side effect to be worked around later.
    func testMarkingRepliedClearsTheUnreadState() throws {
        try deliver(["<m1@example.com>"])
        let offset = try XCTUnwrap(MessageIDIndex.offset(of: "<m1@example.com>", in: base))

        try MailboxMutator.setStatus(base: base, offset: offset,
                                     status: MailboxMutator.statusReplied)

        let row = try XCTUnwrap(MailStore(root: root).list(at: base, name: "In")?.rows.first)
        XCTAssertEqual(row.status, MailboxMutator.statusReplied)
        XCTAssertEqual(row.statusGlyph, "R")
        XCTAssertNotEqual(row.statusGlyph, MailStore.unreadGlyph)
    }

    /// Replying twice writes 2 over 2 and is a no-op, so nothing has to guard
    /// against it upstream.
    func testMarkingRepliedTwiceIsIdempotent() throws {
        try deliver(["<m1@example.com>"])
        let offset = try XCTUnwrap(MessageIDIndex.offset(of: "<m1@example.com>", in: base))
        try MailboxMutator.setStatus(base: base, offset: offset,
                                     status: MailboxMutator.statusReplied)
        try MailboxMutator.setStatus(base: base, offset: offset,
                                     status: MailboxMutator.statusReplied)

        let rows = try XCTUnwrap(MailStore(root: root).list(at: base, name: "In")?.rows)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, MailboxMutator.statusReplied)
    }

    // MARK: finding the reply

    /// The link the R mark itself doesn't hold: a reply names its original in
    /// `In-Reply-To`, so the relation is derived rather than remembered.
    func testFindsTheReplyToAMessage() throws {
        try deliver(["<orig@example.com>"])
        try deliverReplies(to: ["<orig@example.com>"])

        let offsets = MessageIDIndex.offsets(replyingTo: "<orig@example.com>", in: base)
        XCTAssertEqual(offsets.count, 1)
        XCTAssertEqual(inReplyTo(atOffset: try XCTUnwrap(offsets.first)), "<orig@example.com>")
    }

    /// All of them, in mailbox order — the caller wants the *last*, and picks by
    /// date rather than trusting this order.
    func testFindsEveryReplyInMailboxOrder() throws {
        try deliver(["<orig@example.com>"])
        try deliverReplies(to: ["<orig@example.com>", "<orig@example.com>"])

        let offsets = MessageIDIndex.offsets(replyingTo: "<orig@example.com>", in: base)
        XCTAssertEqual(offsets.count, 2)
        // By id, not by `offsets == offsets.sorted()`, which could only fail if
        // `findRecords` itself had regressed. `inReplyTo` can't tell these two
        // apart — both name the original — so the reply's own id is the test.
        XCTAssertEqual(messageID(atOffset: offsets[0]), "<reply0@example.com>")
        XCTAssertEqual(messageID(atOffset: offsets[1]), "<reply1@example.com>")
    }

    /// The original carries that id as its own `Message-ID`, and must not be
    /// mistaken for a reply to itself. This is the confirmation step that the
    /// search index — which cannot tell one header from another — depends on.
    func testTheOriginalIsNotItsOwnReply() throws {
        try deliver(["<orig@example.com>"])
        XCTAssertTrue(MessageIDIndex.offsets(replyingTo: "<orig@example.com>", in: base).isEmpty)
    }

    func testReplyToADifferentMessageIsNotReturned() throws {
        try deliver(["<a@example.com>", "<b@example.com>"])
        try deliverReplies(to: ["<b@example.com>"])
        XCTAssertTrue(MessageIDIndex.offsets(replyingTo: "<a@example.com>", in: base).isEmpty)
        XCTAssertEqual(MessageIDIndex.offsets(replyingTo: "<b@example.com>", in: base).count, 1)
    }

    /// A `References:` chain names the original too. Only `In-Reply-To` counts,
    /// or every later message in a thread would look like the answer to the
    /// first one.
    func testReferencesAloneIsNotAReply() throws {
        var seen = MessageIDIndex()
        // Asserted, not discarded: without this the test would pass vacuously
        // if delivery ever started refusing, which is the failure mode a
        // "nothing was found" assertion cannot see.
        let outcome = try Delivery.deliverIfNew(
            messageData: message(id: "<later@example.com>",
                                 references: "<orig@example.com>"),
            to: base, seen: &seen)
        XCTAssertEqual(outcome, .delivered(index: 1))
        XCTAssertTrue(MessageIDIndex.offsets(replyingTo: "<orig@example.com>", in: base).isEmpty)
    }

    func testBareAndBracketedFormsMatchForReplies() throws {
        try deliverReplies(to: ["<orig@example.com>"])
        XCTAssertEqual(MessageIDIndex.offsets(replyingTo: "orig@example.com", in: base).count, 1)
    }

    func testUnusableIDFindsNoReplies() throws {
        try deliverReplies(to: ["<orig@example.com>"])
        XCTAssertTrue(MessageIDIndex.offsets(replyingTo: "", in: base).isEmpty)
    }

    // MARK: never over a message on its way out

    /// Nothing stops ⌘R on a message sitting in Out, so the write has to refuse
    /// the outgoing states rather than trusting its caller. Writing 2 over a
    /// draft's 9 would not annotate it — the byte is the only place the
    /// draft-ness lives, so the record would stop being a draft and
    /// double-click would never reopen it again.
    func testOutgoingStatusesAreNotOverwritten() throws {
        try deliver(["<m1@example.com>"])
        let offset = try XCTUnwrap(MessageIDIndex.offset(of: "<m1@example.com>", in: base))

        for outgoing in MailboxMutator.outgoingStatuses {
            try MailboxMutator.setStatus(base: base, offset: offset, status: outgoing)
            XCTAssertTrue(
                MailboxMutator.outgoingStatuses.contains(
                    try XCTUnwrap(MailboxMutator.status(base: base, offset: offset))),
                "status \(outgoing) should be readable back before the guard is tested")
        }
    }

    /// The reading statuses — including Eudora 7's own F and → — may all be
    /// overwritten. Answering a message outranks having forwarded it.
    func testReadingStatusesAreNotTreatedAsOutgoing() {
        for reading in [0, 1, 2, 3, 4, 12] {
            XCTAssertFalse(MailboxMutator.outgoingStatuses.contains(reading),
                           "status \(reading) describes reading history, not a draft")
        }
    }

    func testStatusReadsBackWhatWasWritten() throws {
        try deliver(["<m1@example.com>"])
        let offset = try XCTUnwrap(MessageIDIndex.offset(of: "<m1@example.com>", in: base))
        XCTAssertEqual(MailboxMutator.status(base: base, offset: offset),
                       MailboxMutator.statusUnread)

        try MailboxMutator.setStatus(base: base, offset: offset,
                                     status: MailboxMutator.statusReplied)
        XCTAssertEqual(MailboxMutator.status(base: base, offset: offset),
                       MailboxMutator.statusReplied)
    }

    /// An offset the `.toc` doesn't describe yields nil rather than a guess,
    /// which is what stops the caller marking a message it cannot see.
    func testStatusOfUnknownOffsetIsNil() throws {
        try deliver(["<m1@example.com>"])
        XCTAssertNil(MailboxMutator.status(base: base, offset: 999_999))
    }

    // MARK: fixtures

    private var base: URL { root.appendingPathComponent("In") }

    private func deliver(_ ids: [String]) throws {
        var seen = MessageIDIndex()
        for id in ids {
            _ = try Delivery.deliverIfNew(messageData: message(id: id), to: base, seen: &seen)
        }
    }

    /// One reply per entry, each answering the given original. Each gets its own
    /// `Message-ID`, so two replies to one message are two records.
    private func deliverReplies(to originals: [String]) throws {
        var seen = MessageIDIndex()
        for (i, original) in originals.enumerated() {
            _ = try Delivery.deliverIfNew(
                messageData: message(id: "<reply\(i)@example.com>", inReplyTo: original),
                to: base, seen: &seen)
        }
    }

    private func inReplyTo(atOffset offset: Int) -> String? {
        guard let msg = MailStore(root: root).message(at: base, offset: offset) else { return nil }
        return msg.part.header("In-Reply-To")?.trimmingCharacters(in: .whitespaces)
    }

    /// The `Message-ID` of whatever record starts at `offset`, read the way the
    /// app's cheap confirmation reads it.
    private func messageID(atOffset offset: Int) -> String? {
        guard let msg = MailStore(root: root).message(at: base, offset: offset) else { return nil }
        return msg.part.header("Message-ID")?.trimmingCharacters(in: .whitespaces)
    }

    private func message(id: String?,
                         inReplyTo: String? = nil,
                         references: String? = nil) -> Data {
        var lines = [
            "From: Them <them@example.com>",
            "To: me@example.com",
            "Subject: Subject for \(id ?? "no id")",
            "Date: Mon, 27 Jul 2026 09:15:00 -0700",
            "Content-Type: text/plain; charset=us-ascii",
        ]
        if let id = id { lines.append("Message-ID: \(id)") }
        if let inReplyTo = inReplyTo { lines.append("In-Reply-To: \(inReplyTo)") }
        if let references = references { lines.append("References: \(references)") }
        lines += ["", "body for \(id ?? "no id")", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}

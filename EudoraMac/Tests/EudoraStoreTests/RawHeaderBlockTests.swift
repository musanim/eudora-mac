import XCTest
@testable import EudoraStore

/// `MailStore.rawHeaderBlock(at:offset:)` — the data behind "Blah Blah Blah".
///
/// The point of a raw view is that it has not tidied anything, so most of these
/// tests are about what must *survive*: folding, duplicate header names, odd
/// ordering, bytes that aren't valid UTF-8. A view that quietly normalised those
/// would be useless for the job it exists to do, which is answering "what
/// actually arrived?" when something looks wrong.
final class RawHeaderBlockTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-rawhdr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReturnsTheHeaderBlockWithoutTheEnvelopeLineOrTheBody() throws {
        let offset = try deliverAndOffset(incoming(subject: "Hello"))
        let block = try XCTUnwrap(store.rawHeaderBlock(at: base, offset: offset))

        XCTAssertFalse(block.contains("From ???@???"),
                       "the Eudora envelope line is storage, not a header")
        XCTAssertFalse(block.contains("body"), "the body must not be included")
        XCTAssertTrue(block.contains("Subject: Hello"))
        XCTAssertTrue(block.contains("From: Them <them@example.com>"))
    }

    /// The reason not to rebuild the block from `MIMEPart.headers`: the parser
    /// unfolds continuation lines, and a `Received:` chain is mostly folded.
    func testFoldedHeadersKeepTheirFoldingAndIndentation() throws {
        let raw = message(headers: [
            "Received: from mxa2.tigertech.net (mxa2.tigertech.net [208.80.4.162])",
            "\tby localhost with ESMTP id 4abc123",
            "\tfor <stephen@musanim.com>; Thu, 30 Jul 2026 10:28:47 -0700",
            "Subject: Folded",
        ])
        let offset = try deliverAndOffset(raw)
        let block = try XCTUnwrap(store.rawHeaderBlock(at: base, offset: offset))

        XCTAssertTrue(block.contains("\tby localhost with ESMTP id 4abc123"),
                      "a raw view that unfolds is not a raw view")
        XCTAssertTrue(block.contains("\tfor <stephen@musanim.com>;"))
    }

    /// A message that has crossed several hops carries several `Received:`
    /// headers. All of them must show, in order — that ordering *is* the route.
    func testEveryReceivedHeaderSurvivesInOrder() throws {
        let raw = message(headers: [
            "Received: from third.example.com",
            "Received: from second.example.com",
            "Received: from first.example.com",
            "Subject: Routed",
        ])
        let offset = try deliverAndOffset(raw)
        let block = try XCTUnwrap(store.rawHeaderBlock(at: base, offset: offset))

        let order = ["third", "second", "first"].map { block.range(of: $0)?.lowerBound }
        XCTAssertFalse(order.contains(where: { $0 == nil }), "a Received line went missing")
        XCTAssertTrue(zip(order.compactMap { $0 }, order.compactMap { $0 }.dropFirst())
            .allSatisfy { $0 < $1 }, "the hops are out of order")
    }

    /// Encoded words stay encoded: the decoded forms are already on screen in the
    /// summary above, and the raw block exists to show what the decoder was
    /// given.
    func testEncodedWordsAreNotDecoded() throws {
        let raw = message(headers: [
            "Subject: =?utf-8?B?SGVsbG8sIHfDtnJsZA==?=",
        ])
        let offset = try deliverAndOffset(raw)
        let block = try XCTUnwrap(store.rawHeaderBlock(at: base, offset: offset))
        XCTAssertTrue(block.contains("=?utf-8?B?SGVsbG8sIHfDtnJsZA==?="))
    }

    /// Headers are supposed to be ASCII and sometimes aren't. A raw view that
    /// refused to render a malformed message would fail exactly when needed.
    func testInvalidUTF8InAHeaderStillRenders() throws {
        var raw = Data("From: Them <them@example.com>\r\nSubject: caf".utf8)
        raw.append(0xE9)                       // Latin-1 'é', invalid as UTF-8
        raw.append(contentsOf: Data("\r\n\r\nbody\r\n".utf8))
        let offset = try deliverAndOffset(raw)

        let block = try XCTUnwrap(store.rawHeaderBlock(at: base, offset: offset))
        XCTAssertTrue(block.contains("Subject: caf"))
        XCTAssertTrue(block.hasSuffix("é"), "byte 0xE9 should read back as Latin-1 é")
    }

    func testLFOnlyHeaderBodySeparatorIsHandled() throws {
        let raw = Data("From: a@b.com\nSubject: Unix\n\nbody\n".utf8)
        let offset = try deliverAndOffset(raw)
        let block = try XCTUnwrap(store.rawHeaderBlock(at: base, offset: offset))
        XCTAssertTrue(block.contains("Subject: Unix"))
        XCTAssertFalse(block.contains("body"))
    }

    // MARK: refusing rather than guessing

    /// A stale offset must yield nil, not the middle of some other message
    /// rendered as though it were this one's headers.
    func testAnOffsetThatIsNotARecordBoundaryYieldsNil() throws {
        let offset = try deliverAndOffset(incoming(subject: "Hello"))
        XCTAssertNil(store.rawHeaderBlock(at: base, offset: offset + 7))
    }

    func testOffsetPastTheEndYieldsNil() throws {
        _ = try deliverAndOffset(incoming(subject: "Hello"))
        let size = try Data(contentsOf: base.appendingPathExtension("mbx")).count
        XCTAssertNil(store.rawHeaderBlock(at: base, offset: size + 1))
        XCTAssertNil(store.rawHeaderBlock(at: base, offset: -1))
    }

    func testMissingMailboxYieldsNil() {
        XCTAssertNil(store.rawHeaderBlock(at: root.appendingPathComponent("Nope"), offset: 0))
    }

    /// The second message's offset must give the second message's headers — the
    /// whole reason this is addressed by offset rather than by index.
    func testTheOffsetSelectsTheRightMessage() throws {
        _ = try deliverAndOffset(incoming(subject: "First"))
        let second = try deliverAndOffset(incoming(subject: "Second"))
        let block = try XCTUnwrap(store.rawHeaderBlock(at: base, offset: second))
        XCTAssertTrue(block.contains("Subject: Second"))
        XCTAssertFalse(block.contains("Subject: First"))
    }

    /// A message with no blank line at all is all headers — show what there is
    /// rather than nothing.
    func testAMessageWithNoBodySeparatorStillYieldsItsHeaders() throws {
        let offset = try deliverAndOffset(Data("From: a@b.com\r\nSubject: Truncated".utf8))
        let block = try XCTUnwrap(store.rawHeaderBlock(at: base, offset: offset))
        XCTAssertTrue(block.contains("Subject: Truncated"))
    }

    /// …and it must stop at the end of its own record. Without the length clamp
    /// a separator-less message runs on into whatever follows it in the `.mbx`,
    /// showing the *next* messages' bytes as though they were this one's
    /// headers. Which is precisely the malformed message someone opens this
    /// panel to investigate, so the failure would land in its own use case.
    func testASeparatorlessMessageDoesNotRunOnIntoTheNextRecord() throws {
        let offset = try deliverAndOffset(Data("From: a@b.com\r\nSubject: Truncated".utf8))
        _ = try deliverAndOffset(incoming(subject: "TheNextOne"))

        let length = try XCTUnwrap(recordLength(atOffset: offset))
        let block = try XCTUnwrap(store.rawHeaderBlock(at: base, offset: offset, length: length))
        XCTAssertTrue(block.contains("Subject: Truncated"))
        XCTAssertFalse(block.contains("TheNextOne"),
                       "the block ran past the end of its own record")
    }

    /// Unclamped — the caller passing no length — is still bounded by
    /// `headerReadLimit`, and on a well-formed message gives the same answer,
    /// since the blank line arrives long before the limit.
    func testOmittingTheLengthStillWorksForAWellFormedMessage() throws {
        let offset = try deliverAndOffset(incoming(subject: "Normal"))
        _ = try deliverAndOffset(incoming(subject: "Following"))
        let block = try XCTUnwrap(store.rawHeaderBlock(at: base, offset: offset))
        XCTAssertTrue(block.contains("Subject: Normal"))
        XCTAssertFalse(block.contains("Following"))
    }

    // MARK: fixture

    private var store: MailStore { MailStore(root: root) }
    private var base: URL { root.appendingPathComponent("In") }

    /// Deliver `raw` and hand back the byte offset of the record it landed in.
    private func deliverAndOffset(_ raw: Data) throws -> Int {
        let index = try Delivery.deliverIncoming(messageData: raw, to: base)
        let listing = try XCTUnwrap(store.list(at: base, name: "In"))
        return try XCTUnwrap(listing.rows.first(where: { $0.index == index })).offset
    }

    /// The byte length of the record starting at `offset`, straight from the
    /// `.mbx` — the same number `MailStore.message(at:index:)` hands the app as
    /// `record.length`.
    private func recordLength(atOffset offset: Int) throws -> Int? {
        let bytes = [UInt8](try Data(contentsOf: base.appendingPathExtension("mbx")))
        return Mbox.findRecords(bytes).first(where: { $0.offset == offset })?.length
    }

    private func message(headers: [String]) -> Data {
        Data((headers + ["", "body", ""]).joined(separator: "\r\n").utf8)
    }

    private func incoming(subject: String) -> Data {
        message(headers: [
            "From: Them <them@example.com>",
            "To: me@example.com",
            "Subject: \(subject)",
            "Date: Mon, 27 Jul 2026 09:15:00 -0700",
        ])
    }
}

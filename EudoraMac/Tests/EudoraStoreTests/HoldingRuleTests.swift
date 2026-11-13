import XCTest
@testable import EudoraStore

/// `HoldingRule` — which arriving mail is at a watched domain, and what counts
/// as having dealt with a sender before.
final class HoldingRuleTests: XCTestCase {

    private let watched: Set<String> = ["libero.it"]

    // MARK: watchedSender

    func testSenderAtWatchedDomain() {
        XCTAssertEqual(HoldingRule.watchedSender(fromHeader: "Helena <someone_new@libero.it>",
                                                 watchedDomains: watched),
                       "someone_new@libero.it")
    }

    func testDomainMatchIgnoresCase() {
        XCTAssertEqual(HoldingRule.watchedSender(fromHeader: "X@Libero.IT", watchedDomains: watched),
                       "x@libero.it")
    }

    func testSubdomainIsWatched() {
        XCTAssertNotNil(HoldingRule.watchedSender(fromHeader: "a@mail.libero.it",
                                                  watchedDomains: watched))
    }

    func testLookalikeDomainIsNot() {
        XCTAssertNil(HoldingRule.watchedSender(fromHeader: "a@notlibero.it", watchedDomains: watched))
        XCTAssertNil(HoldingRule.watchedSender(fromHeader: "a@libero.it.example", watchedDomains: watched))
    }

    func testOtherDomainIsNot() {
        XCTAssertNil(HoldingRule.watchedSender(fromHeader: "Friend <f@example.com>",
                                               watchedDomains: watched))
    }

    /// The address that decides is the real one, after the display name.
    func testAddressInDisplayNameDoesNotDecide() {
        XCTAssertNil(HoldingRule.watchedSender(
            fromHeader: "\"x@libero.it\" <someone@example.com>", watchedDomains: watched))
        XCTAssertEqual(HoldingRule.watchedSender(
            fromHeader: "\"Friend <f@example.com>\" <spam@libero.it>", watchedDomains: watched),
            "spam@libero.it")
    }

    // MARK: keptAnywhere

    func testFiledInAPeopleMailboxIsKept() {
        XCTAssertTrue(HoldingRule.keptAnywhere(["PEOPLE.fol/A.FOL/Someone"],
                                               excluding: ["SCAMS", "HOLDING"]))
    }

    func testOnlyInUnwantedMailboxesIsNotKept() {
        XCTAssertFalse(HoldingRule.keptAnywhere(["SCAMS", "HOLDING"], excluding: ["SCAMS", "HOLDING"]))
        XCTAssertFalse(HoldingRule.keptAnywhere([], excluding: ["SCAMS", "HOLDING"]))
    }

    // MARK: correspondents(inMailboxAt:)

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoldingRuleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mailbox(_ messages: [String]) throws -> URL {
        let base = dir.appendingPathComponent("Box")
        let text = messages.map { "From ???@??? Fri Nov 13 12:00:00 2026\r\n" + $0 + "\r\n" }.joined()
        try Data(text.utf8).write(to: base.appendingPathExtension("mbx"))
        return base
    }

    func testFindsAddressInFrom() throws {
        let base = try mailbox(["From: Friend <Friend@Libero.it>\r\nSubject: hi\r\n\r\nBody\r\n"])
        XCTAssertEqual(HoldingRule.correspondents(inMailboxAt: base), ["friend@libero.it"])
    }

    func testFindsAddressesInToAndCc() throws {
        let base = try mailbox(["From: me@musanim.com\r\nTo: a@b.example, friend@libero.it\r\n"
                                + "Cc: other@libero.it\r\n\r\nBody\r\n"])
        XCTAssertEqual(HoldingRule.correspondents(inMailboxAt: base),
                       ["me@musanim.com", "a@b.example", "friend@libero.it", "other@libero.it"])
    }

    /// Only headers count: an address quoted in a body is not a correspondent.
    func testIgnoresAddressInBody() throws {
        let base = try mailbox(["From: other@example.com\r\n\r\nWrite to friend@libero.it\r\n"])
        XCTAssertEqual(HoldingRule.correspondents(inMailboxAt: base), ["other@example.com"])
    }

    func testSeveralRecords() throws {
        let base = try mailbox(["From: one@libero.it\r\n\r\nA\r\n",
                                "From: two@libero.it\r\n\r\nB\r\n"])
        XCTAssertEqual(HoldingRule.correspondents(inMailboxAt: base), ["one@libero.it", "two@libero.it"])
    }

    /// Unreadable is "can't tell", never "nobody".
    func testMissingMailboxIsNil() {
        XCTAssertNil(HoldingRule.correspondents(inMailboxAt: dir.appendingPathComponent("Nope")))
    }
}

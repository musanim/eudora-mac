import XCTest
@testable import EudoraStore

/// Reply / Reply to All / Reply to All as To.
final class ReplyRecipientsTests: XCTestCase {

    private let me = MeIdentity(["stephen@musanim.com", "stephen.malinowski@gmail.com"])

    private func reply(from: String, to: String, cc: String = "",
                       _ mode: ReplyRecipients.Mode) -> (to: [String], cc: [String]) {
        ReplyRecipients.compute(from: from, to: to, cc: cc, me: me, mode: mode)
    }

    func testPlainReplyIsTheFromLineUntouched() {
        let r = reply(from: "Ann <ann@x.com>", to: "stephen@musanim.com, bob@y.com", .sender)
        XCTAssertEqual(r.to, ["Ann <ann@x.com>"])
        XCTAssertEqual(r.cc, [])
    }

    func testReplyAllPutsTheOthersInCcWithoutMe() {
        let r = reply(from: "Ann <ann@x.com>",
                      to: "Stephen <stephen@musanim.com>, Bob <bob@y.com>",
                      cc: "carol@z.com", .all)
        XCTAssertEqual(r.to, ["Ann <ann@x.com>"])
        XCTAssertEqual(r.cc, ["Bob <bob@y.com>", "carol@z.com"])
    }

    func testReplyAllAsToPutsEveryoneInTo() {
        let r = reply(from: "Ann <ann@x.com>",
                      to: "stephen@musanim.com, Bob <bob@y.com>",
                      cc: "carol@z.com", .allAsTo)
        XCTAssertEqual(r.to, ["Ann <ann@x.com>", "Bob <bob@y.com>", "carol@z.com"])
        XCTAssertEqual(r.cc, [])
    }

    func testNobodyTwiceComparedByAddress() {
        let r = reply(from: "Ann <ann@x.com>",
                      to: "ANN@x.com, Bob <bob@y.com>",
                      cc: "bob@y.com, Stephen <STEPHEN.MALINOWSKI@gmail.com>", .all)
        XCTAssertEqual(r.to, ["Ann <ann@x.com>"])
        XCTAssertEqual(r.cc, ["Bob <bob@y.com>"])
    }

    func testEntriesWithNoAddressAreDropped() {
        let r = reply(from: "ann@x.com", to: "undisclosed-recipients:;", .all)
        XCTAssertEqual(r.to, ["ann@x.com"])
        XCTAssertEqual(r.cc, [])
    }

    /// A quoted name with a comma is one entry, kept whole and undecoded.
    func testQuotedAndEncodedNamesStayWhole() {
        let r = reply(from: "ann@x.com",
                      to: "\"Andrews, Cody\" <c@a.com>, =?utf-8?B?TcO8bGxlciwgSsO2cmc=?= <j@x.com>",
                      .all)
        XCTAssertEqual(r.cc, ["\"Andrews, Cody\" <c@a.com>",
                              "=?utf-8?B?TcO8bGxlciwgSsO2cmc=?= <j@x.com>"])
    }

    func testReplyingToMyOwnMessageAnswersThePeopleIWroteTo() {
        let r = reply(from: "Stephen <stephen@musanim.com>",
                      to: "Ann <ann@x.com>, bob@y.com", cc: "carol@z.com", .all)
        XCTAssertEqual(r.to, ["Ann <ann@x.com>", "bob@y.com"])
        XCTAssertEqual(r.cc, ["carol@z.com"])
    }

    func testANoteToMyselfFallsBackToTheFromLine() {
        let r = reply(from: "stephen@musanim.com", to: "stephen.malinowski@gmail.com", .allAsTo)
        XCTAssertEqual(r.to, ["stephen@musanim.com"])
        XCTAssertEqual(r.cc, [])
    }

    /// A domain rule broad enough to match the sender must not empty To.
    func testTheSenderIsKeptEvenIfMeMatchesThemWhenTheyAreNotAllMe() {
        let broad = MeIdentity(["@musanim.com"])
        let r = ReplyRecipients.compute(from: "ann@x.com", to: "info@musanim.com, bob@y.com",
                                        cc: "", me: broad, mode: .all)
        XCTAssertEqual(r.to, ["ann@x.com"])
        XCTAssertEqual(r.cc, ["bob@y.com"])
    }

    func testWithNoIdentityNothingIsDroppedButDuplicates() {
        let r = ReplyRecipients.compute(from: "ann@x.com", to: "stephen@musanim.com, ann@x.com",
                                        cc: "", me: MeIdentity(), mode: .all)
        XCTAssertEqual(r.to, ["ann@x.com"])
        XCTAssertEqual(r.cc, ["stephen@musanim.com"])
    }
}

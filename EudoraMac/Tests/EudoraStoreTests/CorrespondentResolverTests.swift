import XCTest
@testable import EudoraStore

/// The per-message Who + direction decision. One rule for the name — first
/// non-me scanning From → To → Cc → Bcc — with direction and the `+N` overflow
/// layered on top. The awkward cases (bulk Bcc with me in To, notes to self,
/// mailing-list mail where neither end is me) are pinned here.
final class CorrespondentResolverTests: XCTestCase {

    let me = MeIdentity(["stephen@musanim.com", "@musanim.com", "s@gmail.com"])

    private func who(from: String?, to: String? = nil,
                     cc: String? = nil, bcc: String? = nil) -> ResolvedWho {
        CorrespondentResolver.resolve(from: from, to: to, cc: cc, bcc: bcc, me: me)
    }

    func testIncomingShowsSender() {
        let r = who(from: "Alice <alice@a.com>", to: "Stephen <s@gmail.com>")
        XCTAssertEqual(r.name, "Alice")
        XCTAssertEqual(r.sortKey, "Alice")
        XCTAssertEqual(r.direction, .toMe)
    }

    func testOutgoingShowsRecipient() {
        let r = who(from: "s@gmail.com", to: "Bob <bob@b.com>")
        XCTAssertEqual(r.name, "Bob")
        XCTAssertEqual(r.direction, .fromMe)
    }

    func testOutgoingManyRecipientsGetsOverflow() {
        let r = who(from: "stephen@musanim.com",
                    to: "Bob <bob@b.com>, carol@c.com, dave@d.com")
        XCTAssertEqual(r.name, "Bob +2")
        XCTAssertEqual(r.sortKey, "Bob")           // sort ignores the overflow
        XCTAssertEqual(r.direction, .fromMe)
    }

    func testBulkBccWithMeInTo() {
        // The case Stephen flagged: me in To, audience hidden in Bcc, a visible
        // Cc. First non-me scanning From→To→Cc→Bcc is the Cc name.
        let r = who(from: "stephen@musanim.com",
                    to: "stephen@musanim.com",
                    cc: "Alice <alice@a.com>",
                    bcc: "bob@b.com, carol@c.com")
        XCTAssertEqual(r.name, "Alice +2")         // Alice, then two Bcc'd
        XCTAssertEqual(r.direction, .fromMe)
    }

    func testBulkBccNoCcFallsToBcc() {
        let r = who(from: "s@gmail.com",
                    to: "s@gmail.com",
                    bcc: "Bob <bob@b.com>, carol@c.com")
        XCTAssertEqual(r.name, "Bob +1")
        XCTAssertEqual(r.direction, .fromMe)
    }

    func testNoteToSelfShowsMe() {
        let r = who(from: "Stephen <s@gmail.com>", to: "s@gmail.com")
        XCTAssertEqual(r.name, "Stephen")
        XCTAssertEqual(r.direction, .selfToSelf)
    }

    func testNeitherEndIsMe() {
        // Filed third-party mail / a list whose address isn't in my set.
        let r = who(from: "Alice <alice@a.com>", to: "list@group.org")
        XCTAssertEqual(r.name, "Alice")
        XCTAssertEqual(r.direction, .neither)
    }

    func testDomainRuleCountsAsMe() {
        // Any @musanim.com is me, so this is an ordinary outgoing message.
        let r = who(from: "marketing@musanim.com", to: "Bob <bob@b.com>")
        XCTAssertEqual(r.name, "Bob")
        XCTAssertEqual(r.direction, .fromMe)
    }

    func testMeInCcCountsAsRecipient() {
        let r = who(from: "Alice <alice@a.com>",
                    to: "team@x.com", cc: "s@gmail.com")
        XCTAssertEqual(r.name, "Alice")
        XCTAssertEqual(r.direction, .toMe)         // I'm only in Cc, still incoming
    }

    func testDuplicateRecipientCountedOnce() {
        let r = who(from: "s@gmail.com",
                    to: "Bob <bob@b.com>", cc: "bob@b.com")
        XCTAssertEqual(r.name, "Bob")              // no "+1" — same person
        XCTAssertEqual(r.direction, .fromMe)
    }
}

import XCTest
@testable import EudoraStore

/// The identity set that tells the Who column which end is me: normalization on
/// the way in, membership against From/To values, Codable round-trip (it's
/// persisted app-side), and the Out-harvest seed.
final class MeIdentityTests: XCTestCase {

    func testInitNormalizesAndDedups() {
        // Raw entries and bare addresses, mixed case, same person twice.
        let me = MeIdentity(["Steve <S@X.com>", "s@x.com", "other@y.com"])
        XCTAssertEqual(me.addresses, ["s@x.com", "other@y.com"])
    }

    func testInsertRemoveNormalize() {
        var me = MeIdentity()
        XCTAssertTrue(me.insert("Steve Dorner <s@x.com>"))
        XCTAssertFalse(me.insert("S@X.COM"))          // same address, already present
        XCTAssertFalse(me.insert("not an address"))   // nothing to add
        XCTAssertTrue(me.contains(address: "s@x.com"))
        XCTAssertTrue(me.remove("<S@X.com>"))
        XCTAssertTrue(me.isEmpty)
    }

    func testMatchesHeaderValues() {
        let me = MeIdentity(["s@x.com"])
        XCTAssertTrue(me.matches(headerValue: "Steve Dorner <s@x.com>"))
        XCTAssertTrue(me.matches(headerValue: "alice@a.com, S@X.com, bob@b.com")) // me in a To list
        XCTAssertFalse(me.matches(headerValue: "alice@a.com, bob@b.com"))
        XCTAssertFalse(me.matches(headerValue: nil))
        XCTAssertFalse(me.matches(headerValue: "no-address-here"))
    }

    func testDomainRuleMatchesAnyLocalPart() {
        let me = MeIdentity(["@musanim.com", "s@x.com"])
        XCTAssertEqual(me.domains, ["musanim.com"])
        XCTAssertEqual(me.addresses, ["s@x.com"])
        XCTAssertTrue(me.matches(headerValue: "Stephen <anything@musanim.com>"))
        XCTAssertTrue(me.matches(headerValue: "billing@Musanim.com"))   // case-insensitive
        XCTAssertTrue(me.contains(address: "zzz@musanim.com"))
        XCTAssertFalse(me.matches(headerValue: "someone@notme.com"))
    }

    func testStarDomainFormAndRemoval() {
        var me = MeIdentity(["*@musanim.com"])
        XCTAssertEqual(me.domains, ["musanim.com"])
        XCTAssertTrue(me.matches(headerValue: "x@musanim.com"))
        XCTAssertTrue(me.remove("@musanim.com"))               // either form removes it
        XCTAssertFalse(me.matches(headerValue: "x@musanim.com"))
    }

    func testClassifyRejectsBareDomainWithoutAt() {
        // "musanim.com" with no "@" is a name, not a domain rule — dropped.
        var me = MeIdentity()
        XCTAssertFalse(me.insert("musanim.com"))
        XCTAssertTrue(me.isEmpty)
    }

    func testMatchesAnyOf() {
        let me = MeIdentity(["s@x.com"])
        XCTAssertTrue(me.matches(anyOf: [nil, "alice@a.com", "S@X.com"]))   // me in Cc slot
        XCTAssertFalse(me.matches(anyOf: [nil, "alice@a.com", "bob@b.com"]))
    }

    func testCodableRoundTrip() throws {
        let me = MeIdentity(["s@x.com", "old-me@y.com", "@musanim.com"])
        let data = try JSONEncoder().encode(me)
        let back = try JSONDecoder().decode(MeIdentity.self, from: data)
        XCTAssertEqual(me, back)
        XCTAssertEqual(back.domains, ["musanim.com"])
    }

    func testHarvestSenders() {
        let seed = MeIdentityHarvest.senders(fromHeaders: [
            "Steve Dorner <s@x.com>",
            "Steve <S@X.com>",                 // same address, different name/case
            "old-me@y.com (Steve)",
            nil,
            "",
        ])
        XCTAssertEqual(seed, ["s@x.com", "old-me@y.com"])
    }
}

import XCTest
@testable import EudoraStore

final class RecentRecipientsTests: XCTestCase {

    func testRecordMovesToFrontAndDedupesByAddress() {
        var r = RecentRecipients()
        r.record("Bob Smith <bob@x.com>")
        r.record("alice@y.com")
        r.record("bob@x.com")            // same person, bare form
        // Bob is now most recent, and appears once (the newest form wins).
        XCTAssertEqual(r.entries, ["bob@x.com", "alice@y.com"])
    }

    func testRecordIgnoresAddresslessOrBlank() {
        var r = RecentRecipients()
        r.record("")
        r.record("   ")
        r.record("Just A Name")          // no address, no '@'
        XCTAssertTrue(r.entries.isEmpty)
    }

    func testMatchesOnAddressAndNameWordsMRUOrder() {
        var r = RecentRecipients()
        r.record("Bob Smith <bob@example.com>")
        r.record("Barbara Jones <barb@example.com>")   // most recent
        // Prefix "b" matches both (address + name), Barbara first (more recent).
        XCTAssertEqual(r.matches(prefix: "b"),
                       ["Barbara Jones <barb@example.com>", "Bob Smith <bob@example.com>"])
        // "smith" matches Bob by a name word; Barbara doesn't.
        XCTAssertEqual(r.matches(prefix: "smith"), ["Bob Smith <bob@example.com>"])
        // "barb" matches Barbara by name and by address prefix.
        XCTAssertEqual(r.matches(prefix: "barb"), ["Barbara Jones <barb@example.com>"])
        // Empty prefix matches nothing.
        XCTAssertEqual(r.matches(prefix: ""), [])
        // A prefix nobody matches pares down to empty.
        XCTAssertEqual(r.matches(prefix: "zzz"), [])
    }

    func testRemoveByAddressWhateverTheName() {
        var r = RecentRecipients()
        r.record("Bob Smith <bob@x.com>")
        r.record("alice@y.com")
        r.remove("bob@x.com")            // bare form removes the named entry
        XCTAssertEqual(r.entries, ["alice@y.com"])
    }

    func testCodableRoundTrip() throws {
        var r = RecentRecipients()
        r.record("a@x.com"); r.record("b@x.com")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(RecentRecipients.self, from: data)
        XCTAssertEqual(back, r)
    }
}

import XCTest
@testable import EudoraStore

/// Pulling bare addresses out of the header forms real mail uses. The Who
/// column's "is this end me?" test rests on these, so the awkward cases —
/// commas inside quoted display names, `(comment)` addresses, name-only entries
/// with no address — are pinned here.
final class EmailAddressTests: XCTestCase {

    func testBareAddressForms() {
        XCTAssertEqual(EmailAddress.bareAddress("Steve Dorner <D@X.com>"), "d@x.com")
        XCTAssertEqual(EmailAddress.bareAddress("a@b.com"), "a@b.com")
        XCTAssertEqual(EmailAddress.bareAddress("a@b.com (Steve)"), "a@b.com")
        XCTAssertEqual(EmailAddress.bareAddress("\"Doe, Jane\" <j@x.com>"), "j@x.com")
        XCTAssertEqual(EmailAddress.bareAddress("  <A@B.com> "), "a@b.com")
    }

    func testBareAddressRejectsNonAddresses() {
        XCTAssertNil(EmailAddress.bareAddress("Steve Dorner"))     // name only, no address
        XCTAssertNil(EmailAddress.bareAddress(""))
        XCTAssertNil(EmailAddress.bareAddress("undisclosed-recipients:;"))
        XCTAssertNil(EmailAddress.bareAddress("not an address"))
    }

    func testSplitListRespectsQuotesAndAngles() {
        XCTAssertEqual(EmailAddress.splitList("a@b, c@d").count, 2)
        XCTAssertEqual(EmailAddress.splitList("a@b; c@d").count, 2)
        // The comma inside the quoted name must NOT split the one address.
        let mixed = EmailAddress.splitList("\"Doe, Jane\" <j@x>, bob@y")
        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(mixed.first, "\"Doe, Jane\" <j@x>")
    }

    func testAddressesInList() {
        XCTAssertEqual(
            EmailAddress.addresses(in: "Steve <s@x>, \"Doe, Jane\" <j@y>, bob@z"),
            ["s@x", "j@y", "bob@z"])
        // Entries carrying no address are dropped, not represented as empties.
        XCTAssertEqual(
            EmailAddress.addresses(in: "A List:;, real@addr.com"),
            ["real@addr.com"])
    }
}

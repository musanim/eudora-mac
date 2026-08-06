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

    /// The composer's To/Cc/Bcc split, which is this function, decides what goes
    /// to `RCPT TO`. These are the forms that actually arrive in Stephen's mail —
    /// of 1,360 distinct quoted display names in In and Trash, 49 carry a comma —
    /// and the first one here is the bug: the old every-comma split asked the
    /// server to accept `"Andrews`, and the send failed.
    func testSplitListKeepsCommaBearingNamesWhole() {
        XCTAssertEqual(EmailAddress.splitList("\"Andrews, Cody Kathy\" <thu586973@gmail.com>"),
                       ["\"Andrews, Cody Kathy\" <thu586973@gmail.com>"])
        XCTAssertEqual(EmailAddress.splitList("\"Charles Schwab & Co., Inc.\" <d@mail.schwab.com>"),
                       ["\"Charles Schwab & Co., Inc.\" <d@mail.schwab.com>"])
        // The reply-all shape: a comma name alongside ordinary entries.
        XCTAssertEqual(
            EmailAddress.splitList("\"Cassar, Salvatore\" <s@ms.com>, bob@y.com; \"Plain\" <p@z.com>"),
            ["\"Cassar, Salvatore\" <s@ms.com>", "bob@y.com", "\"Plain\" <p@z.com>"])
        // Nested quotes, as Outlook sends them — seen on a real Cc.
        XCTAssertEqual(EmailAddress.splitList("\"'Matias Help Desk'\" <help@matias.ca>"),
                       ["\"'Matias Help Desk'\" <help@matias.ca>"])
    }

    /// The unquoted forms must keep splitting exactly as they did, or this fix
    /// would have traded one broken send for another.
    func testSplitListStillSplitsOrdinaryLists() {
        XCTAssertEqual(EmailAddress.splitList("a@b.com, c@d.com"), ["a@b.com", "c@d.com"])
        XCTAssertEqual(EmailAddress.splitList("Steve <s@x.com>, Jane <j@y.com>"),
                       ["Steve <s@x.com>", "Jane <j@y.com>"])
        XCTAssertEqual(EmailAddress.splitList(""), [])
        XCTAssertEqual(EmailAddress.splitList("   "), [])
        // Stray separators and runs of them collapse rather than yielding blanks.
        XCTAssertEqual(EmailAddress.splitList(",a@b.com,,c@d.com,"), ["a@b.com", "c@d.com"])
    }

    /// An unbalanced quote — a half-finished hand-edit of a recipient field —
    /// stops splitting rather than inventing an address. Pinned because it is a
    /// deliberate choice between two bad outcomes, not an accident.
    func testSplitListWithUnbalancedQuoteDoesNotInventRecipients() {
        XCTAssertEqual(EmailAddress.splitList("\"Andrews, Cody <a@b.com>, bob@y.com"),
                       ["\"Andrews, Cody <a@b.com>, bob@y.com"])
    }

    /// A backslash-escaped quote inside a display name must not end the quoted
    /// run and let the comma after it split. `OutgoingMessage.quotedIfNeeded`
    /// writes exactly this form, so without it the app would generate headers
    /// its own splitter tore in two.
    func testSplitListHonoursBackslashEscapes() {
        XCTAssertEqual(EmailAddress.splitList("\"5\\\" nails, sharp\" <n@x.com>"),
                       ["\"5\\\" nails, sharp\" <n@x.com>"])
        XCTAssertEqual(
            EmailAddress.splitList("\"Krick \\(via Dropbox\\), C\" <d@x.com>, bob@y.com"),
            ["\"Krick \\(via Dropbox\\), C\" <d@x.com>", "bob@y.com"])
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

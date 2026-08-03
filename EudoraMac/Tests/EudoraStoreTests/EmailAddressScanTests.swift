import XCTest
@testable import EudoraStore

/// `EmailAddress.scan(inText:)` — finding addresses in prose rather than in a
/// header.
///
/// It exists for filing suggestions on a message whose headers name nobody but
/// the user: a forward to yourself, where the person it is actually about
/// appears only in the quoted headers carried in the body.
final class EmailAddressScanTests: XCTestCase {

    func testFindsAnAddressInRunningText() {
        XCTAssertEqual(EmailAddress.scan(inText: "please write to a@b.com about it"),
                       ["a@b.com"])
    }

    /// The real case: a forward's quoted headers.
    func testFindsAddressesInQuotedHeaders() {
        let body = """
        <html><body><blockquote type=cite cite="">
        X-Original-To: stephen@musanim.com<br>
        To: Douglas George &lt;douglasclydegeorge@gmail.com&gt;<br>
        </blockquote></body></html>
        """
        let found = EmailAddress.scan(inText: body)
        XCTAssertTrue(found.contains("douglasclydegeorge@gmail.com"))
        XCTAssertTrue(found.contains("stephen@musanim.com"))
    }

    /// Angle brackets, quotes and commas are boundaries, not part of an address.
    func testStripsSurroundingPunctuation() {
        XCTAssertEqual(EmailAddress.scan(inText: "<a@b.com>"), ["a@b.com"])
        XCTAssertEqual(EmailAddress.scan(inText: "\"a@b.com\","), ["a@b.com"])
        XCTAssertEqual(EmailAddress.scan(inText: "to a@b.com."), ["a@b.com"],
                       "a full stop ending a sentence is not part of the domain")
    }

    func testNormalisesCaseAndDeduplicates() {
        XCTAssertEqual(EmailAddress.scan(inText: "A@B.com and again a@b.COM"),
                       ["a@b.com"])
    }

    func testKeepsOrderOfFirstAppearance() {
        XCTAssertEqual(EmailAddress.scan(inText: "z@z.com then a@a.com then z@z.com"),
                       ["z@z.com", "a@a.com"])
    }

    // MARK: what must not be picked up

    /// A domain needs a dot. Without this, `foo@bar` in prose — or a mangled
    /// quote — becomes a query term that matches nothing at best.
    func testRequiresADotInTheDomain() {
        XCTAssertTrue(EmailAddress.scan(inText: "user@localhost").isEmpty)
    }

    func testRequiresBothSidesOfTheAt() {
        XCTAssertTrue(EmailAddress.scan(inText: "@nobody.com").isEmpty)
        XCTAssertTrue(EmailAddress.scan(inText: "nobody@").isEmpty)
        XCTAssertTrue(EmailAddress.scan(inText: "a@@b.com").isEmpty)
    }

    func testIgnoresTextWithNoAddresses() {
        XCTAssertTrue(EmailAddress.scan(inText: "No addresses here at all.").isEmpty)
        XCTAssertTrue(EmailAddress.scan(inText: "").isEmpty)
    }

    /// Plus-addressing and dotted local parts are ordinary and must survive.
    func testKeepsRealisticLocalParts() {
        XCTAssertEqual(EmailAddress.scan(inText: "first.last+tag@sub.example.com"),
                       ["first.last+tag@sub.example.com"])
    }
}

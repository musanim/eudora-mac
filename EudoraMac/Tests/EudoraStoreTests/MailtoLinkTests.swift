import XCTest
@testable import EudoraStore

/// `mailto:` links arrive from outside Eudora — a click in a browser — so the
/// parser is as much a boundary check as a convenience.
final class MailtoLinkTests: XCTestCase {

    func parse(_ s: String, file: StaticString = #filePath, line: UInt = #line) throws -> MailtoLink {
        let url = try XCTUnwrap(URL(string: s), file: file, line: line)
        return try XCTUnwrap(MailtoLink.parse(url), file: file, line: line)
    }

    // MARK: the ordinary cases

    func testBareAddress() throws {
        let link = try parse("mailto:greg@gregsandow.com")
        XCTAssertEqual(link.to, ["greg@gregsandow.com"])
        XCTAssertEqual(link.subject, "")
        XCTAssertEqual(link.body, "")
        XCTAssertTrue(link.cc.isEmpty)
    }

    func testSubjectAndBody() throws {
        let link = try parse("mailto:a@b.com?subject=Rite%20of%20Spring&body=Hello%20there")
        XCTAssertEqual(link.to, ["a@b.com"])
        XCTAssertEqual(link.subject, "Rite of Spring")
        XCTAssertEqual(link.body, "Hello there")
    }

    func testSeveralRecipientsAndCC() throws {
        let link = try parse("mailto:a@b.com,c@d.com?cc=e@f.com,g@h.com")
        XCTAssertEqual(link.to, ["a@b.com", "c@d.com"])
        XCTAssertEqual(link.cc, ["e@f.com", "g@h.com"])
    }

    /// RFC 6068 allows the recipient in the query as well as before it.
    func testToInTheQueryAddsToTheRecipients() throws {
        let link = try parse("mailto:a@b.com?to=c@d.com")
        XCTAssertEqual(link.to, ["a@b.com", "c@d.com"])
    }

    func testEmptyMailtoOpensAnEmptyComposer() throws {
        let link = try parse("mailto:")
        XCTAssertTrue(link.isEmpty)
        XCTAssertTrue(link.to.isEmpty)
    }

    func testMultilineBodySurvives() throws {
        let link = try parse("mailto:a@b.com?body=line%20one%0Aline%20two")
        XCTAssertEqual(link.body, "line one\nline two")
    }

    func testCRLFInTheBodyIsNormalised() throws {
        let link = try parse("mailto:a@b.com?body=one%0D%0Atwo%0Dthree")
        XCTAssertEqual(link.body, "one\ntwo\nthree")
    }

    // MARK: the boundary

    /// The attack this parser exists to stop: a newline in the subject becomes a
    /// real header when the message is assembled.
    func testNewlinesAreStrippedFromTheSubject() throws {
        let link = try parse("mailto:a@b.com?subject=hi%0ABcc:%20thief@evil.example")
        XCTAssertEqual(link.subject, "hi Bcc: thief@evil.example",
                       "the text may stay, as a space-joined single line; "
                        + "the newline may not")
        XCTAssertFalse(link.subject.contains("\n"))
        XCTAssertFalse(link.subject.contains("\r"))
    }

    /// A right-to-left override in a To field can display an address that is not
    /// the one being written.
    func testBidiOverridesAreRemoved() throws {
        let link = try parse("mailto:a@b.com?subject=inv%E2%80%AEfdp.exe")
        XCTAssertEqual(link.subject, "invfdp.exe")
    }

    func testPathologicalLinksAreCapped() throws {
        let many = (0..<200).map { "a\($0)@b.com" }.joined(separator: ",")
        let link = try parse("mailto:" + many)
        XCTAssertEqual(link.to.count, MailtoLink.maxRecipients)
    }

    func testNewlinesAreStrippedFromAddresses() throws {
        let link = try parse("mailto:a@b.com%0ABcc:%20thief@evil.example")
        XCTAssertEqual(link.to.count, 1)
        XCTAssertFalse(link.to[0].contains("\n"))
    }

    /// `bcc` is legal in a mailto and deliberately refused: it is the field a
    /// reader is least likely to notice before hitting Send.
    func testBCCIsIgnoredButReported() throws {
        let link = try parse("mailto:a@b.com?bcc=silent@evil.example&subject=hi")
        XCTAssertEqual(link.subject, "hi")
        XCTAssertEqual(link.ignoredFields, ["bcc"])
    }

    func testFromAndOtherHeadersAreIgnored() throws {
        let link = try parse("mailto:a@b.com?from=someone@else.com&reply-to=x@y.com")
        XCTAssertTrue(link.to == ["a@b.com"])
        XCTAssertEqual(link.ignoredFields.sorted(), ["from", "reply-to"])
    }

    /// A plus is a plus. Form decoders turn it into a space, which would break
    /// every tagged address.
    func testPlusInAnAddressIsNotASpace() throws {
        let link = try parse("mailto:first.last+eudora@example.com")
        XCTAssertEqual(link.to, ["first.last+eudora@example.com"])
    }

    /// A comma inside a display name is percent-encoded precisely so it is not a
    /// separator, which only holds if the split happens before the decode.
    func testPercentEncodedCommaIsNotASeparator() throws {
        let link = try parse("mailto:?to=%22Doe%2C%20Jane%22%20%3Cjane@example.com%3E")
        XCTAssertEqual(link.to, ["\"Doe, Jane\" <jane@example.com>"])
    }

    /// Decoding must happen exactly once, or an escaped percent unravels.
    func testValuesAreDecodedOnlyOnce() throws {
        let link = try parse("mailto:a@b.com?subject=100%2520off")
        XCTAssertEqual(link.subject, "100%20off")
    }

    func testNonMailtoURLsAreRejected() {
        XCTAssertNil(MailtoLink.parse(URL(string: "https://example.com/")!))
        XCTAssertNil(MailtoLink.parse(URL(string: "file:///etc/passwd")!))
    }

    func testSchemeIsMatchedCaseInsensitively() throws {
        let link = try parse("MAILTO:a@b.com")
        XCTAssertEqual(link.to, ["a@b.com"])
    }

    func testAQueryWithNoValueDoesNotCrash() throws {
        let link = try parse("mailto:a@b.com?subject=&body")
        XCTAssertEqual(link.subject, "")
        XCTAssertEqual(link.body, "")
    }

    func testUnicodeInTheSubject() throws {
        let link = try parse("mailto:a@b.com?subject=caf%C3%A9%20%E2%80%94%20today")
        XCTAssertEqual(link.subject, "café — today")
    }
}

import XCTest
@testable import EudoraStore

/// Link text that names one destination while the `href` goes to another — the
/// classic phishing move, and the one signal neither the browser nor the
/// navigation delegate can see.
final class MisleadingLinkTests: XCTestCase {

    // MARK: what counts as a claim

    func testABareHostInTheTextIsAClaim() {
        XCTAssertEqual(LinkSafety.claimedHost(inAnchorText: "paypal.com"), "paypal.com")
        XCTAssertEqual(LinkSafety.claimedHost(inAnchorText: "https://paypal.com/login"),
                       "paypal.com")
    }

    /// Prose claims nothing, and must not — otherwise ordinary mail warns until
    /// the warning is wallpaper.
    func testProseIsNotAClaim() {
        XCTAssertNil(LinkSafety.claimedHost(inAnchorText: "click here"))
        XCTAssertNil(LinkSafety.claimedHost(inAnchorText: "your account"))
        XCTAssertNil(LinkSafety.claimedHost(inAnchorText: "PayPal"))
        XCTAssertNil(LinkSafety.claimedHost(inAnchorText: "Read more…"))
        XCTAssertNil(LinkSafety.claimedHost(inAnchorText: ""))
    }

    /// A mailto's text is an address and its href is that same address.
    func testAnEmailAddressIsNotAHostClaim() {
        XCTAssertNil(LinkSafety.claimedHost(inAnchorText: "greg@gregsandow.com"))
    }

    func testSomethingWithNoTLDIsNotAClaim() {
        XCTAssertNil(LinkSafety.claimedHost(inAnchorText: "paypal"))
        XCTAssertNil(LinkSafety.claimedHost(inAnchorText: "3.14"))
    }

    // MARK: the comparison

    func testTextAndHrefDisagreeing() {
        XCTAssertEqual(
            LinkSafety.textMisleads(anchorText: "paypal.com",
                                    href: "https://paypa1-secure.ru/login"),
            "paypal.com")
    }

    func testAgreementIsSilent() {
        XCTAssertNil(LinkSafety.textMisleads(anchorText: "paypal.com",
                                             href: "https://paypal.com/login"))
        XCTAssertNil(LinkSafety.textMisleads(anchorText: "www.paypal.com",
                                             href: "https://paypal.com/"))
    }

    /// The case that decides whether this is usable. Newsletters route links
    /// through a tracking host on their own domain, and warning about every one
    /// would destroy the signal.
    func testATrackingRedirectOnTheSameDomainIsNotAMismatch() {
        XCTAssertNil(LinkSafety.textMisleads(anchorText: "nytimes.com",
                                             href: "https://click.e.nytimes.com/abc123"))
    }

    func testProseOverAnyHrefIsSilent() {
        XCTAssertNil(LinkSafety.textMisleads(anchorText: "Click here",
                                             href: "https://anywhere.example/x"))
    }

    // MARK: scanning real HTML

    func testFindsTheMismatchInHTML() {
        let html = """
        <p>Hello — please <a href="https://evil.example/login">paypal.com</a> now.</p>
        <p><a href="https://good.example/x">Read more</a></p>
        """
        let found = BodyRenderer.misleadingLinks(in: html)
        XCTAssertEqual(found["https://evil.example/login"], "paypal.com")
        XCTAssertEqual(found.count, 1, "the honest link must not be reported")
    }

    /// Styled link text is at least as common as bare text.
    func testTagsInsideTheAnchorAreStripped() {
        let html = "<a href=\"https://evil.example/\"><b>paypal.com</b></a>"
        XCTAssertEqual(BodyRenderer.misleadingLinks(in: html)["https://evil.example/"],
                       "paypal.com")
    }

    /// `&#112;aypal.com` renders as `paypal.com`, and would otherwise sail past.
    func testNumericEntitiesAreDecoded() {
        let html = "<a href=\"https://evil.example/\">&#112;aypal&#46;com</a>"
        XCTAssertEqual(BodyRenderer.misleadingLinks(in: html)["https://evil.example/"],
                       "paypal.com")
    }

    func testSingleQuotedAndUnquotedHrefs() {
        // The subscript is bound to a local rather than chained across a line
        // break: Swift reads a `[...]` at the start of a line as a new array
        // literal, not as indexing what came before it.
        let quoted = BodyRenderer.misleadingLinks(
            in: "<a href='https://evil.example/'>paypal.com</a>")
        XCTAssertEqual(quoted["https://evil.example/"], "paypal.com")

        let bare = BodyRenderer.misleadingLinks(
            in: "<a href=https://evil.example/ >paypal.com</a>")
        XCTAssertEqual(bare["https://evil.example/"], "paypal.com")
    }

    func testAnchorsWithoutHrefAreIgnored() {
        XCTAssertTrue(BodyRenderer.misleadingLinks(in: "<a name=\"top\">paypal.com</a>").isEmpty)
    }

    func testMalformedHTMLDoesNotHang() {
        // Unterminated anchor: the scan must end rather than loop.
        XCTAssertTrue(BodyRenderer.misleadingLinks(in: "<a href=\"https://x.example/\">oops")
                        .isEmpty)
    }

    /// Eudora's own image boxes are `<a href>` to the real remote URL, with
    /// Eudora's wording as their text. That wording claims no host, so they must
    /// pass silently.
    func testTheBlockedImageBoxIsNotReported() {
        let html = "<a class=\"eu-remote\" href=\"https://tracker.example/pixel.gif\">"
            + "REMOTE IMAGE (not loaded)</a>"
        XCTAssertTrue(BodyRenderer.misleadingLinks(in: html).isEmpty)
    }
}

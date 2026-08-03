import XCTest
@testable import EudoraStore

/// What can be said about a link without asking anyone.
///
/// Reputation is deliberately not tested here because it is deliberately not
/// done here — handing the URL to the browser is the reputation check. These
/// cover the part a browser cannot do, since it never sees the message: whether
/// the URL is built to deceive.
final class LinkSafetyTests: XCTestCase {
    private let familiar: Set<String> = ["paypal.com", "apple.com", "musanim.com"]

    // MARK: refusals

    /// The one category where a click can do something to the Mac rather than
    /// show a page.
    func testOnlyWebAndMailSchemesAreOffered() {
        for raw in ["file:///etc/passwd", "javascript:alert(1)",
                    "data:text/html,<h1>hi", "ftp://x.com/f", "x-man-page://ls"] {
            guard case .unsupportedScheme = LinkSafety.assess(raw).refusal else {
                return XCTFail("\(raw) should be refused")
            }
        }
        XCTAssertNil(LinkSafety.assess("https://example.com").refusal)
        XCTAssertNil(LinkSafety.assess("http://example.com").refusal)
        XCTAssertNil(LinkSafety.assess("mailto:a@b.com").refusal)
    }

    /// `https://apple.com@evil.example` goes to evil.example. There is no
    /// honest use of this in mail, so it is refused rather than warned about.
    func testCredentialsInTheURLAreRefused() {
        XCTAssertEqual(LinkSafety.assess("https://apple.com@evil.example/x").refusal,
                       .deceptiveCredentials)
    }

    func testMalformedIsRefused() {
        XCTAssertEqual(LinkSafety.assess("not a url").refusal, .malformed)
        XCTAssertEqual(LinkSafety.assess("https://").refusal, .malformed)
    }

    // MARK: warnings

    func testPunycodeHostWarns() {
        let a = LinkSafety.assess("https://xn--pple-43d.com/login")
        XCTAssertTrue(a.warnings.contains(.punycodeHost))
        XCTAssertNil(a.refusal, "worth flagging, not worth refusing")
    }

    func testMixedScriptHostWarns() {
        let a = LinkSafety.assess("https://аpple.com/")
        XCTAssertTrue(a.warnings.contains(.mixedScriptHost))
        // Exactly one name warning. Foundation IDNA-encodes this host on the way
        // in, so `url.host` is the punycode form and testing that would say the
        // same thing a second time under a different name.
        XCTAssertFalse(a.warnings.contains(.punycodeHost))
    }

    /// A single-script non-Latin domain warns too, and this is the case that
    /// makes the name tests a cascade rather than a straight swap: as written
    /// there is no `xn--` and no Latin letters to mix, so reading only the raw
    /// authority would leave it with no warning at all. The `xn--` appears only
    /// after Foundation normalises it.
    func testSingleScriptInternationalHostStillWarns() {
        let a = LinkSafety.assess("https://пример.рф/")
        XCTAssertTrue(a.warnings.contains(.punycodeHost))
        XCTAssertFalse(a.warnings.contains(.mixedScriptHost))
        XCTAssertNil(a.refusal, "worth flagging, not worth refusing")
    }

    func testNumericHostWarns() {
        XCTAssertTrue(LinkSafety.assess("http://192.168.1.1/x").warnings.contains(.ipAddressHost))
        XCTAssertTrue(LinkSafety.assess("http://[::1]/x").warnings.contains(.ipAddressHost))
    }

    /// The check that a blocklist cannot make, because it doesn't know who you
    /// deal with.
    func testALookAlikeOfAFamiliarDomainWarns() {
        let a = LinkSafety.assess("https://paypa1.com/verify", familiarDomains: familiar)
        XCTAssertTrue(a.warnings.contains(.lookAlike(of: "paypal.com")))
    }

    func testAFamiliarNameBuriedAsALabelWarns() {
        let a = LinkSafety.assess("https://apple.com.security-check.ru/login",
                                  familiarDomains: familiar)
        XCTAssertTrue(a.warnings.contains(.familiarNameAsLabel("apple.com")))
        XCTAssertEqual(a.host, "apple.com.security-check.ru")
    }

    // MARK: what must stay quiet

    /// The domain itself must never be reported as an impostor of itself.
    func testTheRealDomainIsNotFlagged() {
        XCTAssertTrue(LinkSafety.assess("https://paypal.com/account",
                                        familiarDomains: familiar).warnings.isEmpty)
        XCTAssertTrue(LinkSafety.assess("https://www.paypal.com/account",
                                        familiarDomains: familiar).warnings.isEmpty)
    }

    /// An ordinary unrelated site is not similar to anything and must pass
    /// without comment — otherwise the warning becomes wallpaper.
    func testAnUnrelatedSiteIsQuiet() {
        let a = LinkSafety.assess("https://www.theguardian.com/uk", familiarDomains: familiar)
        XCTAssertTrue(a.warnings.isEmpty)
        XCTAssertNil(a.refusal)
    }

    func testHostIsReportedForTheDialog() {
        XCTAssertEqual(LinkSafety.assess("https://Example.COM/a/b?c=d").host, "example.com")
    }

    // MARK: helpers

    func testRegistrableDomainTakesTheLastTwoLabels() {
        XCTAssertEqual(LinkSafety.registrableDomain("www.paypal.com"), "paypal.com")
        XCTAssertEqual(LinkSafety.registrableDomain("paypal.com"), "paypal.com")
        XCTAssertEqual(LinkSafety.registrableDomain("localhost"), "localhost")
        // Known and accepted crudeness: no public-suffix list, so a two-part TLD
        // reduces to the suffix. Costs a missed look-alike, never a false alarm.
        XCTAssertEqual(LinkSafety.registrableDomain("www.bbc.co.uk"), "co.uk")
    }

    func testEditDistance() {
        XCTAssertEqual(LinkSafety.editDistance("paypal.com", "paypa1.com"), 1)
        XCTAssertEqual(LinkSafety.editDistance("apple.com", "apple.com"), 0)
        XCTAssertEqual(LinkSafety.editDistance("", "abc"), 3)
    }
}

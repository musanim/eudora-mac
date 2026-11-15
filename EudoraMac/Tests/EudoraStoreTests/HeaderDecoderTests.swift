import XCTest
@testable import EudoraStore

final class HeaderDecoderTests: XCTestCase {

    func testPlainHeadersPassThrough() {
        XCTAssertEqual(HeaderDecoder.decode("Re: another variant"), "Re: another variant")
        XCTAssertEqual(HeaderDecoder.decode(""), "")
    }

    func testQuotedPrintableAndBase64Words() {
        XCTAssertEqual(HeaderDecoder.decode("=?UTF-8?Q?You=E2=80=99ve?="), "You\u{2019}ve")
        XCTAssertEqual(HeaderDecoder.decode("=?utf-8?B?SGVsbG8gd29ybGQ=?="), "Hello world")
    }

    /// RFC 2047 §6.2. A long subject is folded across lines *mid-word*, and the
    /// whitespace at the seam belongs to the folding, not to the text.
    ///
    /// From a real message: Apple's `...developer respo?= =?UTF-8?Q?nse...`,
    /// which read "developer respo nse" until this was fixed.
    func testWhitespaceBetweenAdjacentWordsIsDropped() {
        let folded = "=?UTF-8?Q?You=E2=80=99ve_received_a_developer_respo?="
            + " =?UTF-8?Q?nse_to_your_review_of_SpectrumView?="
        XCTAssertEqual(HeaderDecoder.decode(folded),
                       "You\u{2019}ve received a developer response to your review of SpectrumView")
    }

    func testAFoldedSeamWithTabsAndNewlinesToo() {
        XCTAssertEqual(HeaderDecoder.decode("=?UTF-8?Q?respo?=\r\n\t=?UTF-8?Q?nse?="), "response")
    }

    /// The other half of the rule: whitespace between an encoded-word and
    /// ordinary text is real and must survive.
    func testWhitespaceAroundPlainTextIsKept() {
        XCTAssertEqual(HeaderDecoder.decode("Re: =?UTF-8?Q?caf=C3=A9?= today"), "Re: café today")
        XCTAssertEqual(HeaderDecoder.decode("=?UTF-8?Q?caf=C3=A9?= and =?UTF-8?Q?th=C3=A9?="),
                       "café and thé")
    }

    /// Non-whitespace between two words is text, however short.
    func testPunctuationBetweenWordsSurvives() {
        XCTAssertEqual(HeaderDecoder.decode("=?UTF-8?Q?a?=, =?UTF-8?Q?b?="), "a, b")
    }

    /// A word that fails to decode is emitted verbatim, so it is ordinary text —
    /// and the space after it is then real, not a fold artefact.
    func testAnUndecodableWordDoesNotSwallowTheFollowingSpace() {
        // A name CoreFoundation cannot resolve, so `decodeWord` returns nil.
        let value = "=?definitely-not-a-charset?Q?abc?= =?UTF-8?Q?def?="
        XCTAssertEqual(HeaderDecoder.decode(value), "=?definitely-not-a-charset?Q?abc?= def")
    }

    func testUnterminatedWordIsLeftAlone() {
        XCTAssertEqual(HeaderDecoder.decode("Subject =?UTF-8?Q?oops"), "Subject =?UTF-8?Q?oops")
    }

    /// Q text that starts with an encoded byte puts `?=` right after the
    /// encoding letter (`Q?=C3`), which the closing search used to stop at.
    func testQWordStartingWithAnEncodedByte() {
        XCTAssertEqual(HeaderDecoder.decode("=?UTF-8?Q?=C3=89lodie_Martin?="), "Élodie Martin")
        XCTAssertEqual(HeaderDecoder.decode("Re: =?utf-8?q?=E2=80=9Cquoted=E2=80=9D?= x"),
                       "Re: \u{201C}quoted\u{201D} x")
    }

    /// A malformed word must not swallow the well-formed one after it.
    func testMalformedWordDoesNotSwallowTheNext() {
        XCTAssertEqual(HeaderDecoder.decode("=?x?= =?UTF-8?Q?caf=C3=A9?="), "=?x?= café")
    }
}

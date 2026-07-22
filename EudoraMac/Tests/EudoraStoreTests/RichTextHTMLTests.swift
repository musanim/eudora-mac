import XCTest
@testable import EudoraStore

/// The composer's styled-text model and its wire format.
///
/// Two very different obligations are tested here and it is worth keeping them
/// apart. **Generation** is a contract: the exact document is asserted, because
/// it is what recipients see and what saved drafts are rebuilt from. **Parsing**
/// is best-effort recovery from whatever is in Out, so those tests assert what
/// must survive rather than an exact result.
final class RichTextHTMLTests: XCTestCase {

    // MARK: - the model

    func testPlainTextIsNotStyled() {
        XCTAssertFalse(RichText(plain: "just typing").isStyled)
        XCTAssertFalse(RichText(plain: "").isStyled)
        XCTAssertFalse(RichText(runs: [RichTextRun("a"), RichTextRun("b")]).isStyled)
    }

    func testAnyOverrideMakesItStyled() {
        XCTAssertTrue(RichText(runs: [RichTextRun("a", style: RichTextStyle(bold: true))]).isStyled)
        XCTAssertTrue(RichText(runs: [RichTextRun("a", style: RichTextStyle(italic: true))]).isStyled)
        XCTAssertTrue(RichText(runs: [RichTextRun("a", style: RichTextStyle(face: "Courier"))]).isStyled)
        XCTAssertTrue(RichText(runs: [RichTextRun("a", style: RichTextStyle(size: 18))]).isStyled)
        XCTAssertTrue(RichText(runs: [RichTextRun("a", style: RichTextStyle(color: .black))]).isStyled)
    }

    /// An empty run carrying a style would report a message as styled when the
    /// user can see no styling in it — and quietly turn it into MIME.
    func testEmptyStyledRunDoesNotMakeAMessageStyled() {
        let rich = RichText(runs: [RichTextRun("hello"),
                                   RichTextRun("", style: RichTextStyle(bold: true))])
        XCTAssertFalse(rich.isStyled)
        XCTAssertEqual(rich.plainText, "hello")
    }

    /// `NSAttributedString` enumeration readily produces adjacent runs with
    /// identical attributes; they must not survive as separate runs, or the same
    /// typing would produce different HTML depending on the editing history.
    func testAdjacentRunsWithTheSameStyleMerge() {
        let bold = RichTextStyle(bold: true)
        let rich = RichText(runs: [RichTextRun("Hel", style: bold),
                                   RichTextRun("lo", style: bold),
                                   RichTextRun(" there")])
        XCTAssertEqual(rich.runs.count, 2)
        XCTAssertEqual(rich.runs[0].text, "Hello")
        XCTAssertEqual(rich.plainText, "Hello there")
    }

    func testPlainTextIsTheConcatenationOfTheRuns() {
        let rich = RichText(runs: [RichTextRun("one "),
                                   RichTextRun("two", style: RichTextStyle(italic: true)),
                                   RichTextRun(" three")])
        XCTAssertEqual(rich.plainText, "one two three")
    }

    // MARK: - colour

    func testColourHexRoundTrips() {
        XCTAssertEqual(RichTextColor(r: 255, g: 0, b: 0).hex, "#ff0000")
        XCTAssertEqual(RichTextColor(r: 0, g: 0, b: 0).hex, "#000000")
        XCTAssertEqual(RichTextColor(r: 18, g: 52, b: 86).hex, "#123456")
        XCTAssertEqual(RichTextColor.parse("#123456"), RichTextColor(r: 18, g: 52, b: 86))
        XCTAssertEqual(RichTextColor.parse("#F00"), RichTextColor(r: 255, g: 0, b: 0))
        XCTAssertEqual(RichTextColor.parse("rgb(255, 0, 0)"), RichTextColor(r: 255, g: 0, b: 0))
        XCTAssertEqual(RichTextColor.parse("red"), RichTextColor(r: 255, g: 0, b: 0))
        XCTAssertEqual(RichTextColor.parse("NAVY"), RichTextColor(r: 0, g: 0, b: 128))
    }

    /// Quantising in `init` is what lets a colour that has been through the wire
    /// compare equal to the one the colour panel produced — without it, every
    /// reopened draft would report itself as edited.
    func testColourQuantisesToTheResolutionTheWireHas() {
        let fromPanel = RichTextColor(red: 0.5000001, green: 0, blue: 0)
        let fromWire = RichTextColor.parse(fromPanel.hex)
        XCTAssertEqual(fromWire, fromPanel)
    }

    func testUnparseableColourIsNilRatherThanBlack() {
        XCTAssertNil(RichTextColor.parse("chartreusish"))
        XCTAssertNil(RichTextColor.parse("#12345"))
        XCTAssertNil(RichTextColor.parse(""))
    }

    // MARK: - generation

    func testUnstyledBodyGeneratesBareEscapedText() {
        let html = RichTextHTML.html(from: RichText(plain: "a < b & c"))
        XCTAssertTrue(html.contains(">a &lt; b &amp; c</body>"), html)
        XCTAssertFalse(html.contains("<span"), "a plain run needs no span")
    }

    func testStyledRunsBecomeSpans() {
        let rich = RichText(runs: [
            RichTextRun("plain "),
            RichTextRun("bold", style: RichTextStyle(bold: true)),
            RichTextRun(" and "),
            RichTextRun("red", style: RichTextStyle(color: RichTextColor(r: 255, g: 0, b: 0))),
        ])
        let body = bodyOf(RichTextHTML.html(from: rich))
        XCTAssertEqual(body, "plain <span style=\"font-weight: bold\">bold</span>"
                             + " and <span style=\"color: #ff0000\">red</span>")
    }

    /// Declaration order is fixed so the same style always produces the same
    /// bytes — otherwise a draft would look edited every time it was saved.
    func testDeclarationsAreEmittedInAFixedOrder() {
        let style = RichTextStyle(bold: true, italic: true, face: "Courier New", size: 14,
                                  color: RichTextColor(r: 0, g: 0, b: 255))
        XCTAssertEqual(RichTextHTML.declarations(for: style),
                       "font-family: 'Courier New'; font-size: 14pt; "
                       + "font-weight: bold; font-style: italic; color: #0000ff")
    }

    func testPlainStyleHasNoDeclarations() {
        XCTAssertNil(RichTextHTML.declarations(for: .plain))
    }

    /// The outgoing face is Arial whatever the composer is displaying locally.
    func testTheWireAlwaysDeclaresArial() {
        let html = RichTextHTML.html(from: RichText(runs: [
            RichTextRun("x", style: RichTextStyle(bold: true))]))
        XCTAssertTrue(html.contains("font-family: Arial, sans-serif"), html)
    }

    /// A body tag followed by a newline would render as a blank first line under
    /// `pre-wrap`, and be read back in — so a draft would grow a line every time
    /// it was saved and reopened.
    func testNoStrayNewlinesAroundTheBody() {
        let html = RichTextHTML.html(from: RichText(plain: "hello"))
        XCTAssertTrue(html.contains("pre-wrap\">hello</body>"), html)
    }

    func testFontFamilyIsQuotedOnlyWhenItNeedsToBe() {
        XCTAssertEqual(RichTextHTML.cssFamily("Helvetica"), "Helvetica")
        XCTAssertEqual(RichTextHTML.cssFamily("Courier New"), "'Courier New'")
    }

    /// The family name ends up inside a `style="…"` attribute in a document
    /// about to be sent to someone else.
    func testFontFamilyCannotBreakOutOfTheAttribute() {
        let escaped = RichTextHTML.cssFamily("Evil\"; behavior: url(x); font-family: \"A")
        XCTAssertFalse(escaped.contains("\""))
        XCTAssertFalse(escaped.contains(";"))
    }

    func testSizesLoseTheirPointlessDecimal() {
        XCTAssertEqual(RichTextHTML.points(12), "12")
        XCTAssertEqual(RichTextHTML.points(13.5), "13.5")
    }

    // MARK: - round trip

    /// The property the whole `pre-wrap` decision was made to get: whatever the
    /// user typed comes back exactly, including the whitespace.
    func testRoundTripPreservesAwkwardText() {
        let cases = [
            "hello",
            "",
            "line one\nline two\n",
            "\n\n\nleading blank lines",
            "trailing spaces   \nand more",
            "    indented with spaces",
            "\ttab indented\t\tdouble",
            "double  spaces   everywhere",
            "angle < brackets > and & ampersands",
            "a &amp; that is literal text",
            "</body></html> in the body",
            "unicode: café — naïve — 日本語 — 🎹",
            "a\u{00A0}non-breaking space",
        ]
        for text in cases {
            let rich = RichText(plain: text)
            let back = RichTextHTML.parse(RichTextHTML.html(from: rich))
            XCTAssertEqual(back.plainText, text, "round trip changed \(String(reflecting: text))")
            XCTAssertEqual(back, rich, "round trip changed the runs of \(String(reflecting: text))")
        }
    }

    func testRoundTripPreservesStyling() {
        let rich = RichText(runs: [
            RichTextRun("The "),
            RichTextRun("quick", style: RichTextStyle(bold: true)),
            RichTextRun(" brown "),
            RichTextRun("fox", style: RichTextStyle(italic: true, face: "Courier New", size: 18,
                                                   color: RichTextColor(r: 0, g: 128, b: 0))),
            RichTextRun("\njumps over\n"),
            RichTextRun("it", style: RichTextStyle(bold: true, italic: true)),
        ])
        XCTAssertEqual(RichTextHTML.parse(RichTextHTML.html(from: rich)), rich)
    }

    /// CR is normalised on the way out, so the same typing produces the same
    /// bytes whichever line ending the editor hands over.
    func testCarriageReturnsAreNormalised() {
        XCTAssertEqual(RichTextHTML.parse(RichTextHTML.html(from: RichText(plain: "a\r\nb\rc"))).plainText,
                       "a\nb\nc")
    }

    // MARK: - parsing foreign HTML

    /// What reopening a draft that real Eudora 7 wrote has to cope with.
    func testFontTagsAreUnderstood() {
        let rich = RichTextHTML.parse(
            "<html><body><font face=\"Arial\" size=\"4\" color=\"#ff0000\">"
            + "<b>Hello</b></font></body></html>")
        XCTAssertEqual(rich.plainText, "Hello")
        XCTAssertEqual(rich.runs.count, 1)
        XCTAssertEqual(rich.runs[0].style.face, "Arial")
        XCTAssertEqual(rich.runs[0].style.size, 14)
        XCTAssertEqual(rich.runs[0].style.color, RichTextColor(r: 255, g: 0, b: 0))
        XCTAssertTrue(rich.runs[0].style.bold)
    }

    func testNestedStylesInherit() {
        let rich = RichTextHTML.parse("<body><b>bold <i>and italic</i></b></body>")
        XCTAssertEqual(rich.runs.count, 2)
        XCTAssertTrue(rich.runs[0].style.bold)
        XCTAssertFalse(rich.runs[0].style.italic)
        XCTAssertTrue(rich.runs[1].style.bold)
        XCTAssertTrue(rich.runs[1].style.italic)
    }

    /// Without `white-space` in force, HTML's own whitespace rules apply —
    /// otherwise a pretty-printed document would come back full of the newlines
    /// its author used for indentation.
    func testWhitespaceCollapsesInAnOrdinaryDocument() {
        let rich = RichTextHTML.parse("<body>\n  <p>one   two</p>\n  <p>three</p>\n</body>")
        XCTAssertEqual(rich.plainText, "one two\nthree\n")
    }

    /// A block's closing tag ends its line, so a document that ends in one ends
    /// in a newline. Deliberate: dropping it would mean guessing which trailing
    /// break the author meant to keep.
    func testBreaksAndBlocksBecomeNewlines() {
        XCTAssertEqual(RichTextHTML.parse("<body>a<br>b<br/>c</body>").plainText, "a\nb\nc")
        XCTAssertEqual(RichTextHTML.parse("<body><div>a</div><div>b</div></body>").plainText,
                       "a\nb\n")
    }

    /// A part on the wire has CRLF endings, so the HTML read back out of a saved
    /// draft has CRLF where the author typed one newline — and `pre-wrap` would
    /// otherwise preserve every CR. The window would show them, and `isDirty`
    /// would report unsaved changes the instant the draft opened.
    func testCRLFInTheSourceIsOneLineBreak() {
        let rich = RichText(plain: "one\ntwo\n")
        let onTheWire = RichTextHTML.html(from: rich)
            .replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(RichTextHTML.parse(onTheWire), rich)
    }

    func testNbspIndentationSurvivesCollapsing() {
        XCTAssertEqual(RichTextHTML.parse("<body>&nbsp;&nbsp;&nbsp;indented</body>").plainText,
                       "   indented")
    }

    /// Markup must never surface as if it were text.
    func testHeadStyleAndScriptContentsAreDropped() {
        let rich = RichTextHTML.parse(
            "<html><head><title>Nope</title><style>p { color: red }</style></head>"
            + "<body>visible<script>alert('no')</script></body></html>")
        XCTAssertEqual(rich.plainText, "visible")
    }

    func testEntitiesAreDecodedAndBareAmpersandsSurvive() {
        XCTAssertEqual(RichTextHTML.parse("<body>AT&T &amp; co &mdash; caf&eacute;</body>").plainText,
                       "AT&T & co — café")
        XCTAssertEqual(RichTextHTML.parse("<body>&#65;&#x42;</body>").plainText, "AB")
    }

    /// Unbalanced markup is the normal state of mail HTML; a stray closing tag
    /// must not unwind the style stack.
    func testStrayClosingTagsAreIgnored() {
        let rich = RichTextHTML.parse("<body><b>still bold</td> here</b></body>")
        XCTAssertEqual(rich.plainText, "still bold here")
        XCTAssertTrue(rich.runs.allSatisfy(\.style.bold))
    }

    func testAFragmentWithNoBodyStillParses() {
        XCTAssertEqual(RichTextHTML.parse("<b>hi</b>").plainText, "hi")
    }

    func testCommentsAreSkipped() {
        XCTAssertEqual(RichTextHTML.parse("<body>a<!-- not <b>this</b> -->b</body>").plainText, "ab")
    }

    /// A `<` that isn't a tag is the character it plainly is — real mail does
    /// this constantly.
    func testABareAngleBracketIsText() {
        XCTAssertEqual(RichTextHTML.parse("<body>5 < 6</body>").plainText, "5 < 6")
    }

    func testUnrecognisableInputYieldsItsTextRatherThanNothing() {
        let rich = RichTextHTML.parse("no markup at all")
        XCTAssertEqual(rich.plainText, "no markup at all")
        XCTAssertFalse(rich.isStyled)
    }

    // MARK: - helper

    /// The contents of `<body>`, for asserting on generated markup.
    private func bodyOf(_ html: String) -> String {
        guard let open = html.range(of: "pre-wrap\">"),
              let close = html.range(of: "</body>") else {
            XCTFail("generated document has no body: \(html)")
            return ""
        }
        return String(html[open.upperBound..<close.lowerBound])
    }
}

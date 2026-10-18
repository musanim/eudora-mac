import XCTest
@testable import EudoraStore

/// Paragraph alignment: the model's one-alignment-per-paragraph rule, the
/// `<div align>` the generator writes, and reading it (and foreign markup) back.
///
/// As in `RichTextHTMLTests`, generation asserts the exact markup — it is what a
/// recipient's reader gets — and the round trips assert the runs come back equal,
/// since a draft that reopened different would report itself as edited.
final class RichTextAlignmentTests: XCTestCase {

    private let center = RichTextStyle(alignment: .center)

    // MARK: - the model

    func testAlignmentAloneMakesABodyStyled() {
        XCTAssertTrue(RichText(runs: [RichTextRun("x", style: center)]).isStyled)
        XCTAssertFalse(RichText(runs: [RichTextRun("x", style: RichTextStyle(alignment: .left))]).isStyled)
    }

    /// The paragraph's first run decides, and a run straddling a paragraph
    /// boundary is split where the alignment changes.
    func testAParagraphTakesTheAlignmentOfItsFirstRun() {
        let rich = RichText(runs: [
            RichTextRun("ab", style: center),
            RichTextRun("cd\nef"),
        ])
        XCTAssertEqual(rich.runs.map(\.text), ["abcd\n", "ef"])
        XCTAssertEqual(rich.runs.map(\.style.alignment), [.center, .left])
    }

    /// A left-aligned terminator after a centred line — what foreign HTML hands
    /// the parser — is pulled into the centred paragraph.
    func testTheTerminatorBelongsToTheParagraphItEnds() {
        let rich = RichText(runs: [RichTextRun("x", style: center), RichTextRun("\ny")])
        XCTAssertEqual(rich.runs.map(\.text), ["x\n", "y"])
        XCTAssertEqual(rich.runs.map(\.style.alignment), [.center, .left])
    }

    func testAnImageTakesItsParagraphsAlignment() {
        let image = RichTextImage(mimeType: "image/png", data: Data([1, 2, 3]))
        let rich = RichText(runs: [RichTextRun("a", style: center), RichTextRun(image: image)])
        XCTAssertEqual(rich.runs.map(\.style.alignment), [.center, .center])
        XCTAssertEqual(rich.runs.count, 2, "an image never merges into text")
    }

    // MARK: - generation

    func testALeftAlignedBodyHasNoDiv() {
        XCTAssertFalse(RichTextHTML.html(from: RichText(plain: "a\nb")).contains("<div"))
    }

    /// Eudora 7's own shape: the paragraph's `<br>` inside the div.
    func testACentredParagraphIsADivWithItsBreakInside() {
        let rich = RichText(runs: [
            RichTextRun("a\n"),
            RichTextRun("b\n", style: center),
            RichTextRun("c"),
        ])
        XCTAssertEqual(bodyOf(RichTextHTML.html(from: rich)),
                       "a<br><div align=\"center\">b<br></div>c")
    }

    func testAdjacentParagraphsShareOneDiv() {
        let rich = RichText(runs: [
            RichTextRun("one\ntwo\n", style: center),
            RichTextRun("three", style: RichTextStyle(alignment: .right)),
        ])
        XCTAssertEqual(bodyOf(RichTextHTML.html(from: rich)),
                       "<div align=\"center\">one<br>two<br></div><div align=\"right\">three</div>")
    }

    func testStylingInsideACentredParagraph() {
        let rich = RichText(runs: [
            RichTextRun("big ", style: RichTextStyle(bold: true, alignment: .center)),
            RichTextRun("news", style: center),
        ])
        XCTAssertEqual(bodyOf(RichTextHTML.html(from: rich)),
                       "<div align=\"center\"><b>big </b>news</div>")
    }

    // MARK: - round trips

    func testRoundTrips() {
        let cases: [RichText] = [
            RichText(runs: [RichTextRun("a\n"), RichTextRun("b\n", style: center), RichTextRun("c")]),
            // A blank line before a centred last paragraph with no terminator:
            // neither the blank line nor the absence of a trailing newline may
            // change.
            RichText(runs: [RichTextRun("a\n\n"), RichTextRun("b", style: center)]),
            RichText(runs: [RichTextRun("b\n", style: center), RichTextRun("\nc")]),
            RichText(runs: [RichTextRun("only", style: RichTextStyle(alignment: .justify))]),
            RichText(runs: [RichTextRun("\n", style: center), RichTextRun("after")]),
            RichText(runs: [
                RichTextRun("Title\n", style: RichTextStyle(bold: true, size: 18, alignment: .center)),
                RichTextRun("sub\n", style: center),
                RichTextRun("body "),
                RichTextRun("text", style: RichTextStyle(italic: true)),
            ]),
        ]
        for rich in cases {
            let html = RichTextHTML.html(from: rich)
            XCTAssertEqual(RichTextHTML.parse(html), rich, "round trip changed: \(html)")
        }
    }

    func testACentredImageRoundTrips() {
        let image = RichTextImage(mimeType: "image/png", data: Data([9, 8, 7]))
        let rich = RichText(runs: [
            RichTextRun("Title\n", style: center),
            RichTextRun(image: image, alignment: .center),
            RichTextRun("\n", style: center),
            RichTextRun("body"),
        ])
        let html = RichTextHTML.html(from: rich)
        XCTAssertEqual(bodyOf(html),
                       "<div align=\"center\">Title<br><img src=\"cid:\(image.id)\" alt=\"\"><br></div>body")
        let back = RichTextHTML.parse(html) { $0 == "cid:\(image.id)" ? image : nil }
        XCTAssertEqual(back, rich)
    }

    // MARK: - foreign markup

    func testForeignAlignmentForms() {
        func aligned(_ html: String) -> [RichTextAlignment] {
            RichTextHTML.parse(html).runs.map(\.style.alignment)
        }
        XCTAssertEqual(aligned("<body><p align=center>Hello</p>World</body>"), [.center, .left])
        XCTAssertEqual(aligned("<body><center>x</center></body>"), [.center])
        XCTAssertEqual(aligned("<body><div style=\"text-align: right\">x</div></body>"), [.right])
        XCTAssertEqual(aligned("<body><DIV ALIGN=\"Justify\">x</DIV></body>"), [.justify])
        // `align` on a table cell is layout, not paragraph alignment.
        XCTAssertEqual(Set(aligned("<body><table><tr><td align=\"center\">x</td></tr></table></body>")),
                       [.left])
        // Nor is Outlook's CSS spelling of the same thing, or one on a span.
        XCTAssertEqual(Set(aligned("<body><table><tr><td style=\"text-align:center\">x</td></tr></table></body>")),
                       [.left])
        XCTAssertEqual(aligned("<body><span style=\"text-align:center\">x</span></body>"), [.left])
    }

    func testCRLFEndsAParagraph() {
        let rich = RichText(runs: [RichTextRun("x", style: center), RichTextRun("\r\ny")])
        XCTAssertEqual(rich.runs.map(\.style.alignment), [.center, .left])
    }

    func testForeignCentredParagraphKeepsItsTextAndBreak() {
        let rich = RichTextHTML.parse("<body><p align=center>Hello</p>World</body>")
        XCTAssertEqual(rich.plainText, "Hello\nWorld")
        XCTAssertEqual(rich.runs.first?.text, "Hello\n")
    }

    /// The exception for a final aligned block is narrow: an unaligned block at
    /// the end still ends in a newline, as `testBreaksAndBlocksBecomeNewlines`
    /// requires.
    func testOnlyAnAlignedFinalBlockLosesItsTrailingBreak() {
        XCTAssertEqual(RichTextHTML.parse("<body><div>a</div></body>").plainText, "a\n")
        XCTAssertEqual(RichTextHTML.parse("<body><div align=\"center\">a</div></body>").plainText, "a")
    }

    // MARK: - helpers

    private func bodyOf(_ html: String) -> String {
        guard let open = html.range(of: "<body>"),
              let close = html.range(of: "</body>", range: open.upperBound..<html.endIndex)
        else { return "" }
        return String(html[open.upperBound..<close.lowerBound])
    }
}

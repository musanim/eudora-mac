import XCTest
@testable import EudoraStore

/// Flattening an HTML message to the text a reply quotes.
///
/// The reply path used to strip anything between `<` and `>` and keep the rest
/// verbatim, so quoted mail arrived reading `that&#39;s` — entities are not
/// tags, and nothing was decoding them. Forward went through `RichTextHTML`
/// and read correctly, which is why the same message behaved differently
/// depending on which button you pressed.
final class HTMLToPlainTextTests: XCTestCase {

    private func flatten(_ html: String) -> String {
        RichTextHTML.parse(html).plainText
    }

    func testNumericEntitiesBecomeCharacters() {
        XCTAssertEqual(flatten("<p>that&#39;s fine</p>").trimmingCharacters(in: .whitespacesAndNewlines),
                       "that's fine")
    }

    func testNamedEntitiesBecomeCharacters() {
        let out = flatten("<p>Tom &amp; Jerry &lt;tag&gt; &quot;quoted&quot;</p>")
        XCTAssertTrue(out.contains("Tom & Jerry"))
        XCTAssertTrue(out.contains("<tag>"))
        XCTAssertTrue(out.contains("\"quoted\""))
        XCTAssertFalse(out.contains("&amp;"), "an entity survived into the quoted text")
    }

    func testTagsAreRemoved() {
        XCTAssertFalse(flatten("<b>bold</b> and <i>italic</i>").contains("<"))
        XCTAssertTrue(flatten("<b>bold</b> and <i>italic</i>").contains("bold"))
    }

    /// The other half of the old bug: every tag became a single space, so a
    /// long message arrived as one unbroken paragraph and the `>` quoting had
    /// nothing to attach to.
    func testLineBreaksSurvive() {
        let out = flatten("one<br>two<br>three")
        XCTAssertTrue(out.contains("\n"), "<br> must produce a real line break")
        XCTAssertEqual(out.split(separator: "\n").count, 3)
    }

    func testParagraphsSeparate() {
        let out = flatten("<p>first</p><p>second</p>")
        XCTAssertTrue(out.contains("first"))
        XCTAssertTrue(out.contains("second"))
        XCTAssertTrue(out.contains("\n"))
    }

    func testScriptAndStyleContentIsNotQuoted() {
        let out = flatten("<style>p{color:red}</style><p>hello</p>")
        XCTAssertTrue(out.contains("hello"))
        XCTAssertFalse(out.contains("color:red"),
                       "stylesheet text is not part of the message")
    }

    func testPlainTextPassesThroughUnharmed() {
        XCTAssertEqual(flatten("just words").trimmingCharacters(in: .whitespacesAndNewlines),
                       "just words")
    }

    func testEmptyInput() {
        XCTAssertEqual(flatten(""), "")
    }
}

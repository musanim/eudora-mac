import XCTest
@testable import EudoraStore

/// Mail that Eudora 7 *composed*, which is stored differently from mail it
/// received.
///
/// Received mail gets `<x-html>…</x-html>`. Its own outgoing messages get a bare
/// `<html>` body, Eudora's private `<x-tab>` markup, and no `Content-Type`
/// header — so with nothing declared the parser fell back to text/plain and the
/// reader displayed the HTML source. Everything in Out composed before the
/// cut-over looked like that.
final class EudoraComposedBodyTests: XCTestCase {

    /// The real shape, taken from a message in Stephen's Out mailbox.
    ///
    /// The blank line before the closing delimiter is load-bearing: Swift drops
    /// the newline that precedes `"""`, so without it this ends in a lone CR and
    /// `testTheWholeBodyIsKept`'s suffix check can never match. A stored record
    /// always ends with a line ending — `Mbox.record` guarantees it — so the
    /// blank line is also the more faithful fixture.
    private let composed = Data("""
    To: stephen on GMAIL <stephen.malinowski@gmail.com>\r
    From: Stephen Malinowski <stephen@musanim.com>\r
    Subject: Fwd: You have a message from App Review\r
    Message-Id: <7.1.0.9.2.20260728145618.02b86d18@musanim.com>\r
    X-Eudora-Signature: <<No Default>>\r
    \r
    <html>\r
    <body>\r
    <br>\r
    <blockquote type=cite class=cite cite="">hello<br>\r
    </blockquote></body>\r
    </html>\r

    """.utf8)

    func testAComposedMessageIsTreatedAsHTML() {
        let part = MIMEParser.parse([UInt8](composed))
        XCTAssertEqual(part.eudoraContentType, "text/html",
                       "a bare <html> body with no Content-Type is Eudora 7's own")
    }

    func testTheWholeBodyIsKept() {
        let part = MIMEParser.parse([UInt8](composed))
        let text = String(decoding: part.body, as: UTF8.self)
        XCTAssertTrue(text.contains("<blockquote"))
        XCTAssertTrue(text.contains("hello"))
        XCTAssertTrue(text.hasSuffix("</html>\r\n") || text.hasSuffix("</html>"))
    }

    // MARK: what must NOT be swept up

    /// A sender who genuinely declares text/plain and happens to write markup is
    /// sending markup. Respect the declaration.
    func testADeclaredPlainTextMessageIsLeftAlone() {
        let raw = Data("""
        From: a@b.com\r
        Content-Type: text/plain; charset=us-ascii\r
        \r
        <html> is how you open an HTML document.\r
        """.utf8)
        XCTAssertNil(MIMEParser.parse([UInt8](raw)).eudoraContentType,
                     "an explicit text/plain must not be reinterpreted")
    }

    /// `<html>` further down is quoted markup inside a message, not a document.
    func testHTMLLaterInTheBodyDoesNotCount() {
        XCTAssertNil(EudoraBody.detect(Array("Look at this:\r\n<html>\r\n".utf8),
                                       declaresContentType: false))
    }

    func testLeadingBlankLinesAreIgnored() {
        XCTAssertEqual(EudoraBody.detect(Array("\r\n\r\n  <HTML>\r\nhi".utf8),
                                         declaresContentType: false)?.contentType,
                       "text/html")
    }

    func testADoctypeCounts() {
        XCTAssertEqual(EudoraBody.detect(Array("<!DOCTYPE html>\r\n<html>".utf8),
                                         declaresContentType: false)?.contentType,
                       "text/html")
    }

    func testPlainTextWithNoContentTypeStaysPlain() {
        XCTAssertNil(EudoraBody.detect(Array("Just a note.\r\nNo markup here.\r\n".utf8),
                                       declaresContentType: false))
    }

    /// The received-mail wrappers still win, and still take precedence over the
    /// bare-`<html>` rule.
    func testTheXHTMLWrapperIsStillPreferred() {
        let r = EudoraBody.detect(Array("<x-html><html>hi</html></x-html>trailer".utf8),
                                  declaresContentType: false)
        XCTAssertEqual(r?.contentType, "text/html")
        XCTAssertEqual(String(decoding: r!.trailer, as: UTF8.self), "trailer",
                       "the trailer carries Eudora's Attachment Converted notes")
    }

    func testXFlowedIsStillPlain() {
        XCTAssertEqual(EudoraBody.detect(Array("<x-flowed>hi</x-flowed>".utf8),
                                         declaresContentType: false)?.contentType,
                       "text/plain")
    }
}

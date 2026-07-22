import XCTest
@testable import EudoraStore

/// The bytes `OutgoingMessage` puts on the wire and into Out.
///
/// The point of this file is the first test. Rich text added a second way to
/// assemble a message, and the promise made when it did was that a message with
/// no styling would produce **exactly** what it produced before — so that is
/// asserted whole, byte for byte, rather than by spot-checking headers.
final class MessageBuilderTests: XCTestCase {

    /// The `Date` header depends on the machine's time zone, so it is taken from
    /// the result rather than hard-coded; everything else is pinned.
    private let date = Date(timeIntervalSince1970: 1_784_000_000)
    private let messageID = "<fixed@example.com>"

    private func plainMessage(body: String) -> OutgoingMessage {
        OutgoingMessage(fromName: "Stephen", fromAddress: "stephen@example.com",
                        to: ["you@example.com"], subject: "Hello", body: body)
    }

    // MARK: - the guarantee

    func testUnstyledMessageIsExactlyTheBytesItAlwaysWas() {
        let (data, mid, dateHeader) = plainMessage(body: "Hi there").rfc822(date: date,
                                                                            messageID: messageID)
        let expected = [
            "Date: \(dateHeader)",
            "From: Stephen <stephen@example.com>",
            "To: you@example.com",
            "Subject: Hello",
            "Message-ID: \(messageID)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=us-ascii",
            "Content-Transfer-Encoding: 7bit",
            "",
            "Hi there",
        ].joined(separator: "\r\n")

        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
        XCTAssertEqual(mid, messageID)
    }

    func testUnstyledNonASCIIMessageIsStillASingleQuotedPrintablePart() {
        let (data, _, _) = plainMessage(body: "Caf\u{e9}").rfc822(date: date, messageID: messageID)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Type: text/plain; charset=utf-8"), text)
        XCTAssertTrue(text.contains("Content-Transfer-Encoding: quoted-printable"), text)
        XCTAssertFalse(text.contains("multipart"), text)
        XCTAssertTrue(text.hasSuffix("Caf=C3=A9"), text)
    }

    /// An empty string is not styling. Belt as well as the caller's own check —
    /// `nil` and `""` must not mean different things here, because a composer
    /// that produced an empty HTML alternative would otherwise send an empty
    /// `text/html` part in preference to the real body.
    func testEmptyHTMLFallsBackToThePlainPath() {
        var message = plainMessage(body: "Hi there")
        message.htmlBody = ""
        let (data, _, _) = message.rfc822(date: date, messageID: messageID)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("multipart"), text)
        XCTAssertTrue(text.contains("Content-Type: text/plain; charset=us-ascii"), text)
    }

    // MARK: - the styled path

    func testStyledMessageIsMultipartAlternative() {
        var message = plainMessage(body: "Hi there")
        message.htmlBody = "<html><body>Hi <b>there</b></body></html>"
        let (data, _, dateHeader) = message.rfc822(date: date, messageID: messageID,
                                                   boundary: "BOUND")
        let expected = [
            "Date: \(dateHeader)",
            "From: Stephen <stephen@example.com>",
            "To: you@example.com",
            "Subject: Hello",
            "Message-ID: \(messageID)",
            "MIME-Version: 1.0",
            "Content-Type: multipart/alternative; boundary=\"BOUND\"",
            "",
            "--BOUND",
            "Content-Type: text/plain; charset=us-ascii",
            "Content-Transfer-Encoding: 7bit",
            "",
            "Hi there",
            "--BOUND",
            "Content-Type: text/html; charset=us-ascii",
            "Content-Transfer-Encoding: 7bit",
            "",
            "<html><body>Hi <b>there</b></body></html>",
            "--BOUND--",
            "",
        ].joined(separator: "\r\n")

        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
    }

    /// RFC 2046 §5.1.4: the richest alternative goes last, because that is how
    /// readers choose which one to show. Backwards would mean every styled
    /// message displayed as plain text.
    func testPlainComesBeforeHTML() {
        var message = plainMessage(body: "plain body")
        message.htmlBody = "<html><body>html body</body></html>"
        let (data, _, _) = message.rfc822(date: date, messageID: messageID, boundary: "B")
        let text = String(decoding: data, as: UTF8.self)
        let plainAt = text.range(of: "text/plain")!.lowerBound
        let htmlAt = text.range(of: "text/html")!.lowerBound
        XCTAssertLessThan(plainAt, htmlAt)
    }

    /// Read back with this project's own parser, which is what will actually
    /// have to reopen the draft from Out.
    ///
    /// **The newlines and the run of spaces are the point.** Every body written
    /// to Out is normalised to CRLF, so this is the path where a reopened draft
    /// would come back with a literal CR on every line — and where the composer
    /// would announce unsaved changes the moment the window appeared. A version
    /// of this test with a single-line body passed while that bug was live.
    func testAStyledMessageParsesBackIntoTwoParts() {
        let rich = RichText(runs: [RichTextRun("Hi\n  there\n"),
                                   RichTextRun("bold", style: RichTextStyle(bold: true)),
                                   RichTextRun("\n")])
        var message = plainMessage(body: rich.plainText)
        message.htmlBody = RichTextHTML.html(from: rich)
        let (data, _, _) = message.rfc822(date: date, messageID: messageID, boundary: "B")

        let part = MIMEParser.parse(Array(data))
        XCTAssertEqual(part.contentType, "multipart/alternative")
        XCTAssertEqual(part.children.count, 2)
        XCTAssertEqual(part.children[0].contentType, "text/plain")
        XCTAssertEqual(part.children[1].contentType, "text/html")

        let plain = String(decoding: part.children[0].decodedPayload(), as: UTF8.self)
        XCTAssertEqual(plain, rich.plainText.replacingOccurrences(of: "\n", with: "\r\n"))

        let html = String(decoding: part.children[1].decodedPayload(), as: UTF8.self)
        XCTAssertEqual(RichTextHTML.parse(html), rich, "the draft must come back as it went in")
    }

    func testEachPartIsEncodedForItsOwnContent() {
        var message = plainMessage(body: "Caf\u{e9}")
        message.htmlBody = "<html><body>plain ascii</body></html>"
        let (data, _, _) = message.rfc822(date: date, messageID: messageID, boundary: "B")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Type: text/plain; charset=utf-8"), text)
        XCTAssertTrue(text.contains("Content-Type: text/html; charset=us-ascii"), text)
    }

    /// Nothing about a styled message may leak into the plain path, and nothing
    /// about it may change how a record is terminated — `Mbox.record` adds the
    /// line ending, and it must still have something sane to add it to.
    func testTheAssembledMessageEndsWithTheClosingBoundary() {
        var message = plainMessage(body: "body")
        message.htmlBody = "<html><body>body</body></html>"
        let (data, _, _) = message.rfc822(date: date, messageID: messageID, boundary: "B")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("--B--\r\n"))
    }

    func testGeneratedBoundariesAreUnique() {
        let a = OutgoingMessage.generatedBoundary()
        let b = OutgoingMessage.generatedBoundary()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("=_Eudora_"))
    }
}

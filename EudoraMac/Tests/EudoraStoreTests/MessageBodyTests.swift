import XCTest
@testable import EudoraStore

/// `MessageBody` — which parts of a message are its readable body.
///
/// The first test is the one that matters: the shape Apple Mail produces when
/// someone types, drops in an attachment, and keeps typing. Until 2026sep21 the
/// message view, reply quoting and Forward all showed only the text before the
/// attachment. The rest pin the RFC 2046 rules the fix depends on, and that the
/// ordinary single-body message comes back exactly as before.
final class MessageBodyTests: XCTestCase {

    // MARK: - building messages

    private let CRLF = "\r\n"

    private func part(_ type: String, _ body: String, extra: [String] = []) -> String {
        (["Content-Type: \(type)"] + extra).joined(separator: CRLF) + CRLF + CRLF + body
    }

    private func multipart(_ subtype: String, _ boundary: String, _ parts: [String],
                           params: String = "") -> String {
        var s = "Content-Type: multipart/\(subtype); boundary=\"\(boundary)\"\(params)" + CRLF + CRLF
        for p in parts { s += "--\(boundary)" + CRLF + p + CRLF }
        return s + "--\(boundary)--" + CRLF
    }

    private func message(_ top: String) -> MIMEPart {
        MIMEParser.parse(Array(("From: a@example.com" + CRLF + "Subject: t" + CRLF + top).utf8))
    }

    private let attachment = "Content-Type: audio/midi; name=\"take.mid\"\r\n"
        + "Content-Disposition: attachment; filename=\"take.mid\"\r\n"
        + "Content-Transfer-Encoding: base64\r\n\r\nTVRoZAAAAAY="

    // MARK: - the bug

    func testTextAfterAnAttachmentIsPartOfTheBody() {
        let m = message(multipart("mixed", "B", [
            part("text/plain", "Before the attachment."),
            attachment,
            part("text/plain", "After the attachment."),
        ]))
        let segs = MessageBody.segments(of: m, preferring: .html)
        XCTAssertEqual(segs.map(\.text), ["Before the attachment.", "After the attachment."])
        XCTAssertFalse(segs.contains(where: \.isHTML))

        let plain = MessageBody.combinedPlain(segs)
        XCTAssertTrue(plain.contains("Before the attachment."), plain)
        XCTAssertTrue(plain.contains("After the attachment."), plain)
        XCTAssertLessThan(plain.range(of: "Before")!.lowerBound,
                          plain.range(of: "After")!.lowerBound)
    }

    /// The part after the attachment in the real message was quoted-printable
    /// with soft line breaks; it has to come back as one readable paragraph.
    func testAQuotedPrintableSecondPartDecodes() {
        let m = message(multipart("mixed", "B", [
            part("text/plain", "Here:"),
            attachment,
            part("text/plain", "This line was wrapped by =\r\nthe sender=E2=80=99s mailer.",
                 extra: ["Content-Transfer-Encoding: quoted-printable"]),
        ]))
        let plain = MessageBody.combinedPlain(MessageBody.segments(of: m, preferring: .plain))
        XCTAssertTrue(plain.contains("This line was wrapped by the sender\u{2019}s mailer."), plain)
    }

    func testTheAttachmentItselfIsNeverABodySegment() {
        let m = message(multipart("mixed", "B", [part("text/plain", "x"), attachment]))
        XCTAssertEqual(MessageBody.leaves(of: m, preferring: .html).count, 1)
    }

    // MARK: - nothing changes for the ordinary message

    func testASingleBodyComesBackExactlyAsDecoded() {
        let body = "Line one.\r\n\r\nLine two, with trailing space.   \r\n"
        let m = message(part("text/plain", body))
        XCTAssertEqual(MessageBody.combinedPlain(MessageBody.segments(of: m, preferring: .plain)),
                       body)
    }

    func testASingleHTMLBodyIsNotRewrapped() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>hi</p></body></html>"
        let m = message(part("text/html", html))
        XCTAssertEqual(MessageBody.combinedHTML(MessageBody.segments(of: m, preferring: .html)),
                       html)
    }

    // MARK: - RFC 2046

    func testAnAlternativeIsOneBodyNotTwo() {
        let m = message(multipart("alternative", "A", [
            part("text/plain", "plain version"),
            part("text/html", "<p>html version</p>"),
        ]))
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .html).map(\.text),
                       ["<p>html version</p>"])
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .plain).map(\.text),
                       ["plain version"])
    }

    /// Apple Mail with rich text: an alternative, the attachment, another
    /// alternative. Each alternative contributes one piece.
    func testTwoAlternativesAroundAnAttachmentGiveTwoPieces() {
        let alt1 = multipart("alternative", "A1", [part("text/plain", "p1"), part("text/html", "<b>h1</b>")])
        let alt2 = multipart("alternative", "A2", [part("text/plain", "p2"), part("text/html", "<b>h2</b>")])
        let m = message(multipart("mixed", "B", [alt1, attachment, alt2]))
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .html).map(\.text), ["<b>h1</b>", "<b>h2</b>"])
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .plain).map(\.text), ["p1", "p2"])
    }

    func testARelatedRootIsTheBodyAndItsImagesAreNot() {
        let image = "Content-Type: image/png\r\nContent-ID: <img1>\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\niVBORw0KGgo="
        let m = message(multipart("related", "R", [part("text/html", "<img src=\"cid:img1\">"), image]))
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .html).map(\.text),
                       ["<img src=\"cid:img1\">"])
    }

    /// The old code preferred HTML across the whole message, so plain text
    /// followed by an HTML signature displayed only the signature.
    func testPlainTextFollowedByHTMLKeepsTheText() {
        let m = message(multipart("mixed", "B", [
            part("text/plain", "The actual message."),
            part("text/html", "<p>-- signature</p>"),
        ]))
        let segs = MessageBody.segments(of: m, preferring: .html)
        XCTAssertEqual(segs.count, 2)
        let html = MessageBody.combinedHTML(segs)
        XCTAssertTrue(html.contains("The actual message."), html)
        XCTAssertTrue(html.contains("-- signature"), html)
    }

    // MARK: - stitching

    func testPlainTextStitchedIntoHTMLIsEscaped() {
        let m = message(multipart("mixed", "B", [
            part("text/html", "<p>html</p>"),
            part("text/plain", "a < b & c > d"),
        ]))
        let html = MessageBody.combinedHTML(MessageBody.segments(of: m, preferring: .html))
        XCTAssertTrue(html.contains("a &lt; b &amp; c &gt; d"), html)
        XCTAssertFalse(html.contains("a < b"), html)
    }

    /// Outlook puts the whole message's look in a head `<style>`; stitching
    /// two HTML pieces must not throw it away.
    func testHeadStylesSurviveStitching() {
        let m = message(multipart("mixed", "B", [
            part("text/html", "<html><head><style>.x{color:blue}</style></head><body><p class=x>one</p></body></html>"),
            attachment,
            part("text/html", "<html><body><p>two</p></body></html>"),
        ]))
        let html = MessageBody.combinedHTML(MessageBody.segments(of: m, preferring: .html))
        XCTAssertTrue(html.contains("<style>.x{color:blue}</style>"), html)
        XCTAssertTrue(html.contains("<p class=x>one</p>"), html)
        XCTAssertTrue(html.contains("<p>two</p>"), html)
        // One document, not two pasted together.
        XCTAssertEqual(html.components(separatedBy: "<body").count - 1, 1, html)
    }

    func testABlankPieceBetweenAttachmentsLeavesNoGap() {
        let m = message(multipart("mixed", "B", [
            part("text/plain", "first"),
            attachment,
            part("text/plain", "  \r\n  "),
            attachment,
            part("text/plain", "last"),
        ]))
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .plain).map(\.text), ["first", "last"])
    }

    // MARK: - text that is data, not body (the review's catches)

    /// Google Calendar and Outlook invites. "Last non-HTML alternative" picked
    /// the calendar, and a reply quoted raw iCalendar.
    func testAnInviteQuotesItsTextNotItsCalendar() {
        let m = message(multipart("alternative", "A", [
            part("text/plain", "You are invited."),
            part("text/html", "<p>You are invited.</p>"),
            part("text/calendar; method=REQUEST", "BEGIN:VCALENDAR\r\nEND:VCALENDAR"),
        ]))
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .plain).map(\.text), ["You are invited."])
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .html).map(\.text), ["<p>You are invited.</p>"])
    }

    func testGmailAMPIsNotMistakenForHTMLOrPlain() {
        let m = message(multipart("alternative", "A", [
            part("text/plain", "plain"),
            part("text/x-amp-html", "<html amp4email>amp</html>"),
            part("text/html", "<p>html</p>"),
        ]))
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .plain).map(\.text), ["plain"])
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .html).map(\.text), ["<p>html</p>"])
    }

    /// A bounce's copy of the original headers is evidence, not message.
    func testABounceShowsItsExplanationNotTheReturnedHeaders() {
        let m = message(multipart("report", "R", [
            part("text/plain", "Your message could not be delivered."),
            part("message/delivery-status", "Reporting-MTA: dns; mx.example.com"),
            part("text/rfc822-headers", "From: a@example.com\r\nSubject: t"),
        ], params: "; report-type=delivery-status"))
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .html).map(\.text),
                       ["Your message could not be delivered."])
    }

    /// With nothing that qualifies as body, the old first-text-part rule.
    func testAMessageThatIsOnlyEnrichedTextStillShowsIt() {
        let m = message(part("text/enriched", "<bold>hi</bold>"))
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .html).map(\.text), ["<bold>hi</bold>"])
    }

    /// An image-only HTML piece has no text, and must not count as blank.
    func testAnImageOnlyHTMLPieceIsKeptBesideATextFooter() {
        let m = message(multipart("mixed", "B", [
            part("text/html", "<html><body><img src=\"cid:flyer\"></body></html>"),
            part("text/plain", "To unsubscribe, reply STOP."),
        ]))
        let segs = MessageBody.segments(of: m, preferring: .html)
        XCTAssertEqual(segs.count, 2)
        XCTAssertTrue(MessageBody.combinedHTML(segs).contains("cid:flyer"))
    }

    // MARK: - Forward, which reads the stitched HTML with RichTextHTML.parse

    /// `RichTextHTML.parse` honours `white-space` only on `<body>`, so a plain
    /// piece stitched in as a `pre-wrap` div came out as one paragraph.
    func testForwardKeepsThePlainPiecesLineBreaks() {
        let m = message(multipart("mixed", "B", [
            part("text/html", "<p>intro</p>"),
            part("text/plain", "line one\r\nline two\r\n    indented"),
        ]))
        let rich = RichTextHTML.parse(MessageBody.combinedHTML(MessageBody.segments(of: m, preferring: .html)))
        let text = rich.plainText
        XCTAssertTrue(text.contains("line one\nline two"), text)
        XCTAssertTrue(text.contains("    indented"), text)
    }

    /// List managers append their footer after `</body>`, and a browser shows it.
    func testContentAfterTheClosingBodyTagIsKept() {
        let m = message(multipart("mixed", "B", [
            part("text/html", "<html><body><p>main</p></body></html><p>list footer</p>"),
            part("text/plain", "more"),
        ]))
        let html = MessageBody.combinedHTML(MessageBody.segments(of: m, preferring: .html))
        XCTAssertTrue(html.contains("list footer"), html)
    }

    func testAnEmptyMessageStillHasItsOneEmptyPiece() {
        let m = message(part("text/plain", ""))
        XCTAssertEqual(MessageBody.segments(of: m, preferring: .plain).count, 1)
    }
}

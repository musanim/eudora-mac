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

    // MARK: - Bcc: the local copy keeps it, the wire copy doesn't

    func testBccOmittedByDefaultButEmittedWhenRequested() {
        var message = plainMessage(body: "Hi there")
        message.cc = ["cc@example.com"]
        message.bcc = ["blind@example.com"]

        // Wire copy (default): no Bcc header, so a blind copy stays blind.
        let wire = String(decoding: message.rfc822(date: date, messageID: messageID).data,
                          as: UTF8.self)
        XCTAssertFalse(wire.contains("Bcc:"), wire)
        XCTAssertFalse(wire.contains("blind@example.com"), wire)

        // Local archive copy: Bcc header present, right after Cc.
        let archive = String(decoding: message.rfc822(date: date, messageID: messageID,
                                                      includeBcc: true).data, as: UTF8.self)
        XCTAssertTrue(archive.contains("Cc: cc@example.com\r\nBcc: blind@example.com\r\n"), archive)
    }

    func testBccHeaderSkippedWhenEmptyEvenWhenIncluded() {
        // No blind recipients → no Bcc header even with includeBcc, so a message
        // without a Bcc is byte-identical whichever way it's built.
        let plain = plainMessage(body: "Hi there")
        let a = plain.rfc822(date: date, messageID: messageID).data
        let b = plain.rfc822(date: date, messageID: messageID, includeBcc: true).data
        XCTAssertEqual(a, b)
    }

    // MARK: - From parsing (editable From field)

    func testSplitFromParsesNameAndAddress() {
        let a = OutgoingMessage.splitFrom("Stephen Malinowski <stephen@musanim.com>")
        XCTAssertEqual(a.name, "Stephen Malinowski")
        XCTAssertEqual(a.address, "stephen@musanim.com")

        let b = OutgoingMessage.splitFrom("bare@example.com")
        XCTAssertEqual(b.name, "")
        XCTAssertEqual(b.address, "bare@example.com")

        let c = OutgoingMessage.splitFrom("  \"Quoted Name\" <q@example.com> ")
        XCTAssertEqual(c.name, "Quoted Name")
        XCTAssertEqual(c.address, "q@example.com")
    }

    /// A From typed into the composer round-trips through `splitFrom` →
    /// `OutgoingMessage` → the `From:` header.
    func testEditedFromAppearsInHeader() {
        let (name, address) = OutgoingMessage.splitFrom("Alter Ego <alter@example.com>")
        var message = plainMessage(body: "Hi")
        message.fromName = name
        message.fromAddress = address
        let text = String(decoding: message.rfc822(date: date, messageID: messageID).data,
                          as: UTF8.self)
        XCTAssertTrue(text.contains("From: Alter Ego <alter@example.com>"), text)
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

    // MARK: - attachments

    private let sampleBytes = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x41, 0x42])

    func testAttachmentWrapsInMultipartMixedWithBodyFirst() {
        var message = plainMessage(body: "See attached.")
        message.attachments = [.init(filename: "hi.dat",
                                     mimeType: "application/octet-stream", data: sampleBytes)]
        let text = String(decoding: message.rfc822(date: date, messageID: messageID,
                                                   boundary: "MIX").data, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Type: multipart/mixed; boundary=\"MIX\""), text)
        XCTAssertTrue(text.contains("Content-Transfer-Encoding: base64"), text)
        XCTAssertTrue(text.contains("Content-Disposition: attachment; filename=\"hi.dat\""), text)
        // Body part precedes the attachment part.
        let bodyAt = text.range(of: "See attached.")!.lowerBound
        let attAt = text.range(of: "Content-Disposition: attachment")!.lowerBound
        XCTAssertLessThan(bodyAt, attAt)
        XCTAssertTrue(text.hasSuffix("--MIX--\r\n"), text)
    }

    /// Round-trips through this project's own parser — the one that reopens a
    /// draft from Out — and the bytes come back intact.
    func testAttachmentRoundTripsThroughTheParser() {
        var message = plainMessage(body: "See attached.")
        message.attachments = [.init(filename: "hi.dat",
                                     mimeType: "application/octet-stream", data: sampleBytes)]
        let part = MIMEParser.parse(Array(message.rfc822(date: date, messageID: messageID).data))
        XCTAssertEqual(part.contentType, "multipart/mixed")
        XCTAssertEqual(part.children.count, 2)
        XCTAssertEqual(part.children[0].contentType, "text/plain")
        XCTAssertEqual(Data(part.children[1].decodedPayload()), sampleBytes)
        XCTAssertEqual(part.children[1].filename, "hi.dat")
    }

    /// Styled body + an attachment: the alternative nests inside the mixed.
    func testStyledMessageWithAttachmentNestsAlternativeInsideMixed() {
        var message = plainMessage(body: "plain")
        message.htmlBody = "<html><body>plain</body></html>"
        message.attachments = [.init(filename: "note.txt", mimeType: "text/plain",
                                     data: Data("x".utf8))]
        let part = MIMEParser.parse(Array(message.rfc822(date: date, messageID: messageID).data))
        XCTAssertEqual(part.contentType, "multipart/mixed")
        XCTAssertEqual(part.children.count, 2)
        XCTAssertEqual(part.children[0].contentType, "multipart/alternative")
        XCTAssertEqual(part.children[0].children.count, 2)
        XCTAssertEqual(part.children[1].contentType, "text/plain")   // the attachment
    }

    /// A payload past one base64 line (>57 raw bytes → >76 base64 chars) must
    /// wrap at 76 columns and still round-trip byte-for-byte.
    func testLargerAttachmentWrapsAndRoundTrips() {
        let big = Data((0..<200).map { UInt8($0 & 0xFF) })
        var message = plainMessage(body: "See attached.")
        message.attachments = [.init(filename: "big.bin",
                                     mimeType: "application/octet-stream", data: big)]
        let (data, _, _) = message.rfc822(date: date, messageID: messageID, boundary: "MIX")
        // The base64 block has at least one full 76-char line.
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        XCTAssertTrue(lines.contains { $0.count == 76 }, "expected a wrapped 76-column base64 line")
        // And it comes back intact.
        let part = MIMEParser.parse(Array(data))
        XCTAssertEqual(Data(part.children[1].decodedPayload()), big)
    }

    func testEmptyAttachmentsStaysOnThePlainPath() {
        // Belt: an empty attachments array must not trigger multipart/mixed, so a
        // message without attachments is byte-identical to before this feature.
        var message = plainMessage(body: "Hi there")
        message.attachments = []
        XCTAssertFalse(String(decoding: message.rfc822(date: date, messageID: messageID).data,
                              as: UTF8.self).contains("multipart"))
    }
}

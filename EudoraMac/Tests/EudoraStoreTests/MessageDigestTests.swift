import XCTest
@testable import EudoraStore

/// `MessageDigest` is the fast per-message read the message list runs instead of
/// a full parse. Its whole justification is that it agrees with the full parse,
/// so these tests assert exactly that: the Who/Date headers it lifts, and — the
/// part that could have gone wrong — that its attachment verdict matches
/// `part.walk().contains(isAttachment) || DetachedAttachment.isPresent` on the
/// same bytes, across the shapes real mail takes.
final class MessageDigestTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// The verdict the full parse gives, for cross-checking the digest.
    ///
    /// The `X-Attachments` term is here rather than only in the digest because
    /// this function is the *definition* of "has an attachment" that the digest
    /// is being held to. Leaving it out would not test the digest's shortcut; it
    /// would just assert that the two disagree.
    private func fullParseAttachment(_ msg: [UInt8]) -> Bool {
        let part = MIMEParser.parse(msg)
        return part.walk().contains { $0.isAttachment }
            || DetachedAttachment.isPresent(in: part)
            || RecordedAttachment.isPresent(inHeaderValue: part.header(RecordedAttachment.headerName))
    }

    private func assertMatchesFullParse(_ s: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let msg = bytes(s)
        XCTAssertEqual(MessageDigest.parse(msg).hasAttachment, fullParseAttachment(msg),
                       "digest disagreed with the full parse", file: file, line: line)
    }

    // MARK: headers

    func testLiftsHeaders() {
        let d = MessageDigest.parse(bytes(
            "From: Steve Dorner <d@x.com>\r\nTo: you@y.com\r\nDate: Wed, 1 Jan 2020 09:00:00 +0000\r\n"
            + "Subject: hi\r\n\r\nbody"))
        XCTAssertEqual(d.from, "Steve Dorner <d@x.com>")
        XCTAssertEqual(d.to, "you@y.com")
        XCTAssertEqual(d.date, "Wed, 1 Jan 2020 09:00:00 +0000")
    }

    func testMissingHeadersAreNil() {
        let d = MessageDigest.parse(bytes("Subject: no addresses\r\n\r\nbody"))
        XCTAssertNil(d.from)
        XCTAssertNil(d.to)
        XCTAssertNil(d.date)
    }

    // MARK: attachment — fast path, cross-checked against the full parse

    func testPlainMessageHasNoAttachment() {
        let s = "From: a@b\r\nSubject: hi\r\nContent-Type: text/plain\r\n\r\njust text"
        XCTAssertFalse(MessageDigest.parse(bytes(s)).hasAttachment)
        assertMatchesFullParse(s)
    }

    func testContentDispositionAttachment() {
        let s = "From: a@b\r\nContent-Type: application/pdf\r\n"
            + "Content-Disposition: attachment; filename=\"report.pdf\"\r\n\r\n%PDF-1.4"
        XCTAssertTrue(MessageDigest.parse(bytes(s)).hasAttachment)
        assertMatchesFullParse(s)
    }

    func testContentTypeNameParam() {
        let s = "From: a@b\r\nContent-Type: application/octet-stream; name=\"data.bin\"\r\n\r\nxxxx"
        XCTAssertTrue(MessageDigest.parse(bytes(s)).hasAttachment)
        assertMatchesFullParse(s)
    }

    func testDetachedMarkerInBody() {
        let s = "From: a@b\r\nContent-Type: text/plain\r\n\r\n"
            + "See attached.\r\nAttachment Converted: \"C:\\\\mail\\\\photo.jpg\"\r\n"
        XCTAssertTrue(MessageDigest.parse(bytes(s)).hasAttachment)
        assertMatchesFullParse(s)
    }

    func testDetachedMarkerMustStartALine() {
        // Mentioned mid-sentence, not at a line start — not a real marker.
        let s = "From: a@b\r\nContent-Type: text/plain\r\n\r\n"
            + "I wrote Attachment Converted: in a sentence.\r\n"
        XCTAssertFalse(MessageDigest.parse(bytes(s)).hasAttachment)
        assertMatchesFullParse(s)
    }

    func testFilenameInHtmlBodyIsNotAnAttachment() {
        // The false-positive class the fast path avoids: `filename=` in body text
        // (a quoted mail, an HTML form) must NOT flag an attachment on a
        // non-multipart message.
        let s = "From: a@b\r\nContent-Type: text/html\r\n\r\n"
            + "<form><input type=file name=\"x\"> filename=oops.txt </form>"
        XCTAssertFalse(MessageDigest.parse(bytes(s)).hasAttachment)
        assertMatchesFullParse(s)
    }

    // MARK: attachment — slow path (genuine multipart)

    func testRealMultipartWithAttachmentTakesTheFullPath() {
        let s = "From: a@b\r\nContent-Type: multipart/mixed; boundary=\"B\"\r\n\r\n"
            + "--B\r\nContent-Type: text/plain\r\n\r\nhello\r\n"
            + "--B\r\nContent-Type: application/pdf; name=\"a.pdf\"\r\n"
            + "Content-Disposition: attachment; filename=\"a.pdf\"\r\n\r\n%PDF\r\n"
            + "--B--\r\n"
        XCTAssertTrue(MessageDigest.parse(bytes(s)).hasAttachment)
        assertMatchesFullParse(s)
    }

    func testRealMultipartWithoutAttachment() {
        let s = "From: a@b\r\nContent-Type: multipart/alternative; boundary=\"B\"\r\n\r\n"
            + "--B\r\nContent-Type: text/plain\r\n\r\nhello\r\n"
            + "--B\r\nContent-Type: text/html\r\n\r\n<b>hello</b>\r\n"
            + "--B--\r\n"
        XCTAssertFalse(MessageDigest.parse(bytes(s)).hasAttachment)
        assertMatchesFullParse(s)
    }

    /// Claims multipart but the boundary never appears in the body — a Eudora-
    /// flattened message. Must take the fast path, not the full parse, and get
    /// the same answer.
    func testFlattenedMultipartClaimTakesFastPath() {
        let s = "From: a@b\r\nContent-Type: multipart/mixed; boundary=\"NEVER-APPEARS\"\r\n\r\n"
            + "flattened body with no delimiters\r\n"
            + "Attachment Converted: \"C:\\\\x\\\\doc.pdf\"\r\n"
        XCTAssertFalse(MessageDigest.isRealMultipart(
            contentType: "multipart/mixed; boundary=\"NEVER-APPEARS\"", body: bytes("flattened body")))
        XCTAssertTrue(MessageDigest.parse(bytes(s)).hasAttachment)   // via the marker
        assertMatchesFullParse(s)
    }

    // MARK: attachment — the outgoing record (`X-Attachments`)

    /// The shape that was invisible until `RecordedAttachment` existed, and the
    /// commonest one in a real tree: my own sent copy, with no MIME part and no
    /// marker — the header is the only evidence.
    func testRecordedAttachmentHeaderAloneCounts() {
        let s = "From: me@x\r\nTo: you@y\r\n"
            + #"X-Attachments: \\Mac\Home\Documents\report.pdf;"# + "\r\n"
            + "\r\nSee attached.\r\n"
        XCTAssertTrue(MessageDigest.parse(bytes(s)).hasAttachment)
        assertMatchesFullParse(s)
    }

    /// The empty header is on tens of thousands of messages and must never count.
    func testEmptyRecordedAttachmentHeaderDoesNotCount() {
        let s = "From: me@x\r\nTo: you@y\r\nX-Attachments: \r\n\r\nno files here\r\n"
        XCTAssertFalse(MessageDigest.parse(bytes(s)).hasAttachment)
        assertMatchesFullParse(s)
        // Eudora's trailing semicolon with nothing before it is equally empty.
        let t = "From: me@x\r\nX-Attachments: ;\r\n\r\nstill nothing\r\n"
        XCTAssertFalse(MessageDigest.parse(bytes(t)).hasAttachment)
        assertMatchesFullParse(t)
    }

    /// The header is read on the slow path too, so a genuine multipart carrying
    /// one gets the same verdict as a flattened message would.
    func testRecordedAttachmentOnRealMultipartTakesTheFullPath() {
        let s = "From: me@x\r\nContent-Type: multipart/alternative; boundary=\"B\"\r\n"
            + #"X-Attachments: \\Mac\Home\Documents\report.pdf;"# + "\r\n\r\n"
            + "--B\r\nContent-Type: text/plain\r\n\r\nhello\r\n"
            + "--B\r\nContent-Type: text/html\r\n\r\n<b>hello</b>\r\n"
            + "--B--\r\n"
        XCTAssertTrue(MessageDigest.isRealMultipart(
            contentType: "multipart/alternative; boundary=\"B\"", body: bytes("--B\r\nx")))
        XCTAssertTrue(MessageDigest.parse(bytes(s)).hasAttachment)
        assertMatchesFullParse(s)
    }

    /// A message quoting the header in its body has no attachment: the header
    /// block ends at the blank line, and nothing scans the body for this one.
    func testRecordedAttachmentTextInBodyDoesNotCount() {
        let s = "From: me@x\r\n\r\nhe wrote:\r\n"
            + #"X-Attachments: \\Mac\Home\Documents\report.pdf;"# + "\r\n"
        XCTAssertFalse(MessageDigest.parse(bytes(s)).hasAttachment)
        assertMatchesFullParse(s)
    }
}

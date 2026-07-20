import XCTest
import Foundation
@testable import EudoraStore

/// Covers the "Attachment Converted:" markers Windows Eudora leaves behind when
/// it detaches a received attachment to disk. Shapes here are taken from a real
/// Eudora tree, including the CRLF line endings and the `<x-html>` wrapper.
final class DetachedAttachmentTests: XCTestCase {

    private func parse(_ raw: String) -> MIMEPart {
        MIMEParser.parse(Array(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    // The shape of 8 of the 9 marker-bearing messages in phaseX/In.mbx: the
    // Content-Type still claims multipart, but Eudora has flattened the body to
    // <x-html> and appended the markers AFTER the closing tag. Those trailing
    // bytes used to be discarded by the parser, which made detached attachments
    // undetectable — this test is the regression guard for that.
    func testFindsMarkersAfterEudoraHTMLBody() {
        let msg = parse("""
        From: Archion <info@archion.de>
        Subject: Please confirm your profile creation request
        Content-Type: multipart/mixed; boundary="000000000000e6ec9e064888f920"

        <x-html>
        <html><body><p>hello</p></body></html>
        </x-html>

        Attachment Converted: "Y:\\Documents\\Active\\Eudora\\Attachments\\Archion-invoice_2623804.pdf"

        Attachment Converted: "Y:\\Documents\\Active\\Eudora\\Attachments\\AGB-Archion-EN.pdf"
        """)

        XCTAssertTrue(DetachedAttachment.isPresent(in: msg))
        XCTAssertEqual(DetachedAttachment.filenames(in: msg),
                       ["Archion-invoice_2623804.pdf", "AGB-Archion-EN.pdf"])
        // The markers must not have leaked into the displayable body.
        let shown = String(decoding: msg.decodedPayload(), as: UTF8.self)
        XCTAssertFalse(shown.contains(DetachedAttachment.marker))
        XCTAssertTrue(shown.contains("hello"))
    }

    // The 9th real case: Content-Type claims multipart but the body carries no
    // boundary delimiters at all. The parser salvages that into a text leaf, and
    // the marker is found whether it ends up in the body or the trailer.
    func testFindsMarkerInDegenerateMultipart() {
        let msg = parse("""
        Subject: history
        Content-Type: multipart/mixed; boundary="----=_NextPart_000_0029_01DCA4B5"

        Here is the picture.

        Attachment Converted: "Y:\\Documents\\Active\\Eudora\\Attachments\\history.jpg"
        """)

        XCTAssertTrue(DetachedAttachment.isPresent(in: msg))
        XCTAssertEqual(DetachedAttachment.filenames(in: msg), ["history.jpg"])
    }

    // Eudora truncates the recorded name relative to the original MIME filename,
    // so the recorded path is worth keeping in full.
    func testRecordedPathsKeepTheDirectory() {
        let msg = parse("""
        Content-Type: text/plain

        Attachment Converted: "Y:\\Documents\\Active\\Eudora\\Attachments\\menu.pdf"
        """)

        XCTAssertEqual(DetachedAttachment.recordedPaths(in: msg),
                       ["Y:\\Documents\\Active\\Eudora\\Attachments\\menu.pdf"])
    }

    // Plain text mail, unquoted path — older Eudora omitted the quotes.
    func testUnquotedPath() {
        let msg = parse("""
        Content-Type: text/plain

        See attached.

        Attachment Converted: C:\\Eudora\\Attach\\history.jpg
        """)

        XCTAssertEqual(DetachedAttachment.filenames(in: msg), ["history.jpg"])
    }

    // A message that merely talks about the phrase must not count: the marker is
    // only recognised at the start of a line.
    func testPhraseMidSentenceIsNotAMarker() {
        let msg = parse("""
        Content-Type: text/plain

        Eudora writes Attachment Converted: "foo.pdf" at the end of the body.
        """)

        XCTAssertFalse(DetachedAttachment.isPresent(in: msg))
        XCTAssertTrue(DetachedAttachment.filenames(in: msg).isEmpty)
    }

    func testNoMarkersMeansNoAttachment() {
        let msg = parse("""
        Content-Type: text/plain

        Just a note, nothing attached.
        """)

        XCTAssertFalse(DetachedAttachment.isPresent(in: msg))
        XCTAssertTrue(DetachedAttachment.filenames(in: msg).isEmpty)
    }

    // Markers inside a real multipart message are still found, and binary leaves
    // are skipped: without the type exclusion the base64 leaf below would decode
    // to a second marker and be counted.
    func testFindsMarkerInMultipartTextLeaf() {
        let msg = parse("""
        Content-Type: multipart/mixed; boundary=SEP

        --SEP
        Content-Type: text/plain

        body text

        Attachment Converted: "Y:\\Eudora\\Attachments\\Untitled.ics"
        --SEP
        Content-Type: application/octet-stream
        Content-Transfer-Encoding: base64

        QXR0YWNobWVudCBDb252ZXJ0ZWQ6ICJub3BlLmJpbiI=
        --SEP--
        """)

        XCTAssertEqual(DetachedAttachment.filenames(in: msg), ["Untitled.ics"])
    }

    // Defensive rather than observed: Eudora strips the transfer encoding when it
    // flattens a message, so no real detached-attachment message in phaseX/In.mbx
    // carries one. Covers mail Eudora never processed.
    func testQuotedPrintableBodyIsDecodedBeforeScanning() {
        let msg = parse("""
        Content-Type: text/plain
        Content-Transfer-Encoding: quoted-printable

        caf=C3=A9

        Attachment Converted: "Y:\\Eudora\\Attachments\\menu.pdf"
        """)

        XCTAssertEqual(DetachedAttachment.filenames(in: msg), ["menu.pdf"])
    }

    func testFilenameExtraction() {
        let f = DetachedAttachment.filename(fromRecordedPath:)
        XCTAssertEqual(f("\"Y:\\a\\b\\c.pdf\""), "c.pdf")
        XCTAssertEqual(f("Y:\\a\\b\\c.pdf"), "c.pdf")
        XCTAssertEqual(f("/Users/x/Attachments/c.pdf"), "c.pdf")
        XCTAssertEqual(f("c.pdf"), "c.pdf")
        // Spaces are common in these names and must survive.
        XCTAssertEqual(f("\"Y:\\a\\MALINOWSKI - Full Invoice Report.pdf\""),
                       "MALINOWSKI - Full Invoice Report.pdf")
    }
}

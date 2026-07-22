import XCTest
import Foundation
@testable import EudoraNet

/// Line splitting for the POP3 client. The regression these pin down is real and
/// cost weeks: Gmail POP, reached via the wrong host, separated its UIDL lines
/// with a bare CR, and the old CRLF-only reader returned the whole 21-message
/// listing as a single "line" — parsed as one message with a nonsense
/// concatenated UID, so nothing ever downloaded.
final class POP3LineParsingTests: XCTestCase {

    /// Drain `buffer` into the lines `extractLine` yields, as UTF-8 strings.
    private func lines(_ s: String) -> [String] {
        var buf = Data(s.utf8)
        var out: [String] = []
        while let line = POP3Client.extractLine(from: &buf) {
            out.append(String(decoding: line, as: UTF8.self))
        }
        return out
    }

    // MARK: the bug

    func testBareCRSeparatedListingSplitsIntoLines() {
        // The exact shape of the Gmail UIDL that collapsed: bare-CR between
        // entries, a real CRLF only at the very end.
        let input = "1 GmailIdAAA\r2 GmailIdBBB\r3 GmailIdCCC\r\n"
        XCTAssertEqual(lines(input), ["1 GmailIdAAA", "2 GmailIdBBB", "3 GmailIdCCC"])
    }

    // MARK: the other endings

    func testCRLF() {
        XCTAssertEqual(lines("a\r\nb\r\n"), ["a", "b"])
    }

    func testBareLF() {
        XCTAssertEqual(lines("a\nb\n"), ["a", "b"])
    }

    // MARK: edges that must not regress

    func testEmptyLineIsReturnedNotSkipped() {
        // The blank line between a message's headers and body is significant —
        // it must come back as an empty line, not vanish.
        var buf = Data("head\r\n\r\nbody\r\n".utf8)
        XCTAssertEqual(POP3Client.extractLine(from: &buf).map { String(decoding: $0, as: UTF8.self) }, "head")
        XCTAssertEqual(POP3Client.extractLine(from: &buf).map { String(decoding: $0, as: UTF8.self) }, "")
        XCTAssertEqual(POP3Client.extractLine(from: &buf).map { String(decoding: $0, as: UTF8.self) }, "body")
    }

    func testDotTerminatorLineIsASingleDot() {
        // readMultiline detects end-of-body by `line.count == 1 && line.first == 0x2E`.
        var buf = Data(".\r\n".utf8)
        let line = POP3Client.extractLine(from: &buf)
        XCTAssertEqual(line, Data([0x2E]))
    }

    func testCRLFSplitAcrossReadsIsNotBrokenIntoTwoLines() {
        // The CR arrives at the end of one network chunk, the LF at the start of
        // the next. The reader must wait rather than emit a line + a spurious
        // empty one.
        var buf = Data("a\r".utf8)
        XCTAssertNil(POP3Client.extractLine(from: &buf), "a trailing lone CR must be held back")
        buf.append(Data("\nb\r\n".utf8))
        XCTAssertEqual(POP3Client.extractLine(from: &buf).map { String(decoding: $0, as: UTF8.self) }, "a")
        XCTAssertEqual(POP3Client.extractLine(from: &buf).map { String(decoding: $0, as: UTF8.self) }, "b")
    }

    func testNoTerminatorYetReturnsNil() {
        var buf = Data("partial line no ending".utf8)
        XCTAssertNil(POP3Client.extractLine(from: &buf))
    }

    func testNoBytesDroppedAcrossMixedEndings() {
        // A blank bare-CR line in the middle must survive as an empty line.
        XCTAssertEqual(lines("x\r\ry\n"), ["x", "", "y"])
    }

    // MARK: UIDL parsing — the actual collapse bug

    func testParseUIDLWithCRLFBodyYieldsOnePairPerLine() {
        // The bug that cost days: a CRLF-delimited UIDL listing collapsed into
        // one entry because `String.split` on the Character "\n" never matched
        // ("\r\n" is a single grapheme). Parsing in bytes must give one pair per
        // line. This is the exact shape Gmail returns.
        let body = Data("1 GmailIdAAA\r\n2 GmailIdBBB\r\n3 GmailIdCCC\r\n".utf8)
        let pairs = POP3Client.parseUIDL(body)
        XCTAssertEqual(pairs.map { $0.num }, [1, 2, 3])
        XCTAssertEqual(pairs.map { $0.uid }, ["GmailIdAAA", "GmailIdBBB", "GmailIdCCC"])
    }

    func testParseUIDLBareLFAlsoWorks() {
        let body = Data("1 A\n2 B\n".utf8)
        XCTAssertEqual(POP3Client.parseUIDL(body).map { $0.uid }, ["A", "B"])
    }

    func testParseUIDLSingleEntry() {
        let body = Data("1 OnlyOne\r\n".utf8)
        let pairs = POP3Client.parseUIDL(body)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.uid, "OnlyOne")
    }

    func testParseUIDLIgnoresMalformedLines() {
        // A line without a "num uid" shape is skipped, not crashed on.
        let body = Data("1 A\r\ngarbage\r\n2 B\r\n".utf8)
        XCTAssertEqual(POP3Client.parseUIDL(body).map { $0.uid }, ["A", "B"])
    }
}

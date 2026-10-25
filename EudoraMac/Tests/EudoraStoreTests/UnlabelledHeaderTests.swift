import XCTest
import Foundation
@testable import EudoraStore

/// Raw 8-bit bytes with no charset label: header lines, and the
/// `Attachment Converted:` lines Eudora writes into bodies. Both UTF-8 and
/// CP1252 occur there for real, sometimes on one line, so each well-formed
/// UTF-8 sequence is read as UTF-8 and every other byte as CP1252. Before
/// 2026oct23 everything was read as UTF-8 and every CP1252 accent became U+FFFD.
final class UnlabelledHeaderTests: XCTestCase {

    /// One byte per scalar, for spelling CP1252/Latin-1 bytes as a string.
    /// Only for scalars below U+0100, which is all these tests use.
    private func singleByte(_ s: String) -> [UInt8] {
        s.unicodeScalars.map { UInt8($0.value) }
    }

    private func headers(_ bytes: [UInt8]) -> [String: String] {
        var out: [String: String] = [:]
        for h in MIMEParser.parseHeaders(bytes) where out[h.name] == nil { out[h.name] = h.value }
        return out
    }

    // MARK: the decoding rule

    func testInvalidUTF8IsReadAsCP1252() {
        XCTAssertEqual(CP1252.decodeUnlabelled(singleByte("Graça")), "Graça")
        // A C1 byte, where CP1252 and Latin-1 differ: 0xAE is ® in both, 0x99 ™ only in CP1252.
        XCTAssertEqual(CP1252.decodeUnlabelled([0x41, 0x99]), "A™")
    }

    func testValidUTF8IsReadAsUTF8() {
        XCTAssertEqual(CP1252.decodeUnlabelled(Array("Söderström".utf8)), "Söderström")
        XCTAssertEqual(CP1252.decodeUnlabelled(Array("Greg’s Substack".utf8)), "Greg’s Substack")
    }

    /// Only sequences Unicode calls well-formed count as UTF-8. An overlong
    /// (C0 AF) and an encoded surrogate (ED A0 80) are CP1252 bytes instead.
    func testIllFormedSequencesFallBackToCP1252() {
        XCTAssertEqual(CP1252.decodeUnlabelled([0xC0, 0xAF]), "À¯")
        XCTAssertEqual(CP1252.decodeUnlabelled([0xED, 0xA0, 0x80]), "í\u{A0}€")
        // Truncated at the end of the input.
        XCTAssertEqual(CP1252.decodeUnlabelled([0x61, 0xC3]), "aÃ")
    }

    /// Four-byte sequences survive, so an emoji in a subject that also holds a
    /// stray CP1252 byte is not shredded.
    func testEmojiBesideACP1252ByteSurvives() {
        let bytes = Array("Sale 🔥 ".utf8) + [0x80] + Array("20".utf8)
        XCTAssertEqual(CP1252.decodeUnlabelled(bytes), "Sale 🔥 €20")
    }

    /// The case that rules out deciding per line: `RecordedAttachmentRelink`
    /// writes its inserted path as UTF-8 beside entries still in Eudora's
    /// CP1252. Both must read correctly, or the relinked file isn't found.
    func testOneLineMayHoldBothEncodings() {
        let bytes = singleByte("X-Attachments: C:\\Café\\a.pdf;")
            + Array("/Users/s/Café/x.pdf;\r\n".utf8)
        XCTAssertEqual(headers(bytes)["X-Attachments"], "C:\\Café\\a.pdf;/Users/s/Café/x.pdf;")
    }

    // MARK: parseHeaders

    /// The shape from `phaseX`: a Portuguese name written in Windows ANSI.
    func testCP1252HeaderDecodes() {
        let h = headers(singleByte("From: Marina Estela Graça <m@example.pt>\r\nSubject: hi\r\n"))
        XCTAssertEqual(h["From"], "Marina Estela Graça <m@example.pt>")
        XCTAssertEqual(h["Subject"], "hi")
    }

    /// A CP1252 line cannot drag a UTF-8 line next to it into mojibake, nor the
    /// other way round.
    func testMixedBlockDecodesLineByLine() {
        let bytes = singleByte("To: Jan Fülscher <jan@example.ch>\r\n")
            + Array("Cc: Charlotte Söderström <c@example.com>\r\n".utf8)
        let h = headers(bytes)
        XCTAssertEqual(h["To"], "Jan Fülscher <jan@example.ch>")
        XCTAssertEqual(h["Cc"], "Charlotte Söderström <c@example.com>")
    }

    /// A folded continuation line is a line of its own and is decoded as one.
    func testFoldedCP1252ContinuationDecodes() {
        let h = headers(singleByte("Subject: Your package from\r\n   U.S. Postal Service®\r\n"))
        XCTAssertEqual(h["Subject"], "Your package from U.S. Postal Service®")
    }

    /// The fast path. ASCII and valid UTF-8 come out exactly as a plain UTF-8
    /// decode would give them — this is what nearly every message takes.
    func testUTF8BlockIsUnchanged() {
        let bytes = Array("Subject: café ‘quoted’\r\nFrom: a@b.c\r\n".utf8)
        XCTAssertEqual(MIMEParser.headerText(bytes), String(decoding: bytes, as: UTF8.self))
    }

    /// A header that really contains U+FFFD (valid UTF-8, EF BF BD) sends the
    /// block down the slow path, which must keep it.
    func testGenuineReplacementCharacterSurvives() {
        let bytes = Array("Subject: a\u{FFFD}b\r\n".utf8) + singleByte("From: Ménard <p@example.ca>\r\n")
        let h = headers(bytes)
        XCTAssertEqual(h["Subject"], "a\u{FFFD}b")
        XCTAssertEqual(h["From"], "Ménard <p@example.ca>")
    }

    /// LF-only and CRLF lines both survive the slow path, since the parser's
    /// own line handling runs afterwards.
    func testLineEndingsAreUntouched() {
        let bytes = singleByte("A: é\nB: è\r\nC: plain")
        let h = headers(bytes)
        XCTAssertEqual(h["A"], "é")
        XCTAssertEqual(h["B"], "è")
        XCTAssertEqual(h["C"], "plain")
    }

    // MARK: consumers

    func testFullParseSeesTheDecodedHeader() {
        let part = MIMEParser.parse(singleByte("Subject: Feliz Año\r\n\r\nbody\r\n"))
        XCTAssertEqual(part.header("Subject"), "Feliz Año")
    }

    func testRescueCopyNameIsNotMangled() {
        let record = singleByte("From ???@??? Fri Sep 19 14:22:05 2026\r\n"
                                + "From: Frédéric <f@example.fr>\r\n"
                                + "Subject: Evénements\r\n\r\nbody\r\n")
        let d = DeletedMessageArchive.descriptor(for: record)
        XCTAssertEqual(d.from, "Frédéric")
        XCTAssertEqual(d.subject, "Evénements")
    }

    // MARK: Attachment Converted

    private let szam = "Attachment Converted: \"Y:\\Documents\\Active\\Eudora\\Attachments\\04 Szám 4.mp3\"\r\n"

    func testDetachedFilenameInCP1252Decodes() {
        let part = MIMEParser.parse(singleByte("Subject: x\r\n\r\nbody\r\n\r\n" + szam))
        XCTAssertEqual(DetachedAttachment.filenames(in: part), ["04 Szám 4.mp3"])
    }

    func testDetachedFilenameInUTF8StillDecodes() {
        let part = MIMEParser.parse(Array(("Subject: x\r\n\r\nbody\r\n\r\n" + szam).utf8))
        XCTAssertEqual(DetachedAttachment.filenames(in: part), ["04 Szám 4.mp3"])
    }

    /// The point of the fix for detached attachments: the file is on disk under
    /// its real name, and a mangled name could never find it.
    func testLocatorFindsACP1252NamedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnlabelledHeaderTests-\(UUID().uuidString)")
        let attachments = root.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = attachments.appendingPathComponent("04 Szám 4.mp3")
        try Data("x".utf8).write(to: file)

        let part = MIMEParser.parse(singleByte("Subject: x\r\n\r\nbody\r\n\r\n" + szam))
        let found = AttachmentLocator(mailRoot: root).locateAll(in: part)
        XCTAssertEqual(found.count, 1)
        XCTAssertNotNil(found.first?.url)
    }
}

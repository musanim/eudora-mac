import XCTest
@testable import EudoraStore

/// `RecordedAttachment` reads Eudora's `X-Attachments:` header — the record of
/// what I attached to a message I sent. The header is nearly always present and
/// nearly always empty, so the tests that matter most are the ones about *not*
/// reporting an attachment, and about `isPresent` agreeing with `recordedPaths`
/// on every shape (they are separate implementations, and the message list and
/// the preview would disagree if they diverged).
final class RecordedAttachmentTests: XCTestCase {

    private func part(_ s: String) -> MIMEPart { MIMEParser.parse(Array(s.utf8)) }

    // MARK: parsing the header value

    func testEmptyAndAbsentHeaderNameNothing() {
        XCTAssertEqual(RecordedAttachment.recordedPaths(inHeaderValue: nil), [])
        XCTAssertEqual(RecordedAttachment.recordedPaths(inHeaderValue: ""), [])
        XCTAssertEqual(RecordedAttachment.recordedPaths(inHeaderValue: "   "), [])
        // Eudora writes a trailing semicolon, so a header holding only that is
        // still the empty case.
        XCTAssertEqual(RecordedAttachment.recordedPaths(inHeaderValue: ";"), [])
        XCTAssertEqual(RecordedAttachment.recordedPaths(inHeaderValue: " ; ; "), [])
    }

    func testSinglePath() {
        // The real header from the message that prompted this type: a macOS
        // per-user temp path, reached through Parallels' `\\Mac\AllFiles` share.
        let v = #"\\Mac\AllFiles\private\var\folders\r_\4j9\T\0FD8\StephenChatGPT_morality.pdf;"#
        XCTAssertEqual(RecordedAttachment.recordedPaths(inHeaderValue: v).count, 1)
        XCTAssertEqual(DetachedAttachment.filename(
            fromRecordedPath: RecordedAttachment.recordedPaths(inHeaderValue: v)[0]),
                       "StephenChatGPT_morality.pdf")
    }

    func testSeveralPaths() {
        let v = #"\\Mac\Home\Documents\a.jpg; \\Mac\Home\Documents\b.tiff; C:\DEV\TUNING.ZIP;"#
        let paths = RecordedAttachment.recordedPaths(inHeaderValue: v)
        XCTAssertEqual(paths.count, 3)
        XCTAssertEqual(paths.map { DetachedAttachment.filename(fromRecordedPath: $0) },
                       ["a.jpg", "b.tiff", "TUNING.ZIP"])
    }

    /// Spaces are ordinary in these paths and must not split or be trimmed out of
    /// the middle of a name.
    func testPathWithSpaces() {
        let v = #"\\Mac\Home\My Documents\Rite of Spring notes.doc;"#
        let paths = RecordedAttachment.recordedPaths(inHeaderValue: v)
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(DetachedAttachment.filename(fromRecordedPath: paths[0]),
                       "Rite of Spring notes.doc")
    }

    /// The drive-letter form from the pre-Parallels years, and the `\\psf\Host`
    /// share that replaced it — both are in `phaseX`, and neither is translated.
    func testOlderPathForms() {
        XCTAssertEqual(RecordedAttachment.recordedPaths(inHeaderValue: #"C:\DEV\C\TUNING\TUNING.ZIP;"#),
                       [#"C:\DEV\C\TUNING\TUNING.ZIP"#])
        let psf = #"\\psf\Host\Users\stephenmalinowski\Documents\report.pdf;"#
        XCTAssertEqual(RecordedAttachment.recordedPaths(inHeaderValue: psf), [String(psf.dropLast())])
    }

    // MARK: the pre-Windows shape

    /// Mac Eudora wrote a quoted name and an encoding, not a path. Eight of these
    /// survive in `phaseX`; without special handling the displayed "filename" is
    /// the whole string and the icon comes from an extension of
    /// `uuencode-datafork)`.
    func testMacEudoraNameAndTypeForm() {
        XCTAssertEqual(RecordedAttachment.displayName(
            fromRecordedPath: #""USA28XA1.ZIP" (type: uuencode-datafork)"#), "USA28XA1.ZIP")
        XCTAssertEqual(RecordedAttachment.displayName(
            fromRecordedPath: #""usa28.1.7.2b4.sit.hqx" (type: uuencode-datafork)"#),
                       "usa28.1.7.2b4.sit.hqx")
        // A name with spaces and no extension survives it too.
        XCTAssertEqual(RecordedAttachment.displayName(
            fromRecordedPath: #""EDTN's Top EDTN Network News- 0" (type: uuencode-datafork)"#),
                       "EDTN's Top EDTN Network News- 0")
    }

    /// The parenthetical is stripped only when it really is the trailing
    /// `(type: …)`. An ordinary path is untouched, including one that happens to
    /// end in a parenthesis.
    func testDisplayNameLeavesOrdinaryPathsAlone() {
        XCTAssertEqual(RecordedAttachment.displayName(
            fromRecordedPath: #"\\Mac\Home\Documents\report.pdf"#), "report.pdf")
        XCTAssertEqual(RecordedAttachment.displayName(
            fromRecordedPath: #"\\Mac\Home\Documents\scan (2).pdf"#), "scan (2).pdf")
        XCTAssertEqual(RecordedAttachment.displayName(
            fromRecordedPath: #"\\Mac\Home\Documents\draft (final)"#), "draft (final)")
    }

    /// The full recorded text is kept for the tooltip even when the displayed
    /// name is trimmed — that text is the only clue left about the file.
    func testRecordedPathKeepsTheOriginalText() {
        let raw = #""billsux.jpg" (type: uuencode-datafork)"#
        let p = part("From: me@x\r\nX-Attachments: \(raw)\r\n\r\nbody")
        let rows = RecordedAttachment.located(in: p)
        XCTAssertEqual(rows.map(\.filename), ["billsux.jpg"])
        XCTAssertEqual(rows.map(\.recordedPath), [raw])
    }

    // MARK: does the path record where the file came from?

    /// The shape that prompted this: a file dragged from the Mac Desktop into
    /// Windows Eudora. Parallels stages a copy under the Mac's `$TMPDIR` and
    /// gives Eudora *that* path, so the record says nothing about the Desktop.
    /// Every one of `phaseX`'s 653 `\\Mac\AllFiles` paths is of this shape.
    func testParallelsStagingPathDoesNotRecordOrigin() {
        let p = #"\\Mac\AllFiles\private\var\folders\r_\4j9ffv614gn599_fzq6v6glh0000gr\T\0FD83164-8A00-420E-896E-0B225000A941\StephenChatGPT_morality.pdf"#
        XCTAssertFalse(RecordedAttachment.pathRecordsOrigin(p))
        // The name is still exact, which is what a search will match.
        XCTAssertEqual(RecordedAttachment.displayName(fromRecordedPath: p),
                       "StephenChatGPT_morality.pdf")
    }

    func testWindowsTempPathsDoNotRecordOrigin() {
        XCTAssertFalse(RecordedAttachment.pathRecordsOrigin(
            #"C:\Users\steve\AppData\Local\Temp\eud1234\report.pdf"#))
        XCTAssertFalse(RecordedAttachment.pathRecordsOrigin(
            #"C:\WINDOWS\Local Settings\Temp\att.zip"#))
        XCTAssertFalse(RecordedAttachment.pathRecordsOrigin(#"D:\Temp\x.doc"#))
    }

    /// The 7,624 of 8,320 that do name a real place must keep saying so.
    func testOrdinaryPathsRecordOrigin() {
        XCTAssertTrue(RecordedAttachment.pathRecordsOrigin(
            #"\\Mac\Home\Documents\Active\HTMirror\StephenMalinowski_indoor_2011.jpg"#))
        XCTAssertTrue(RecordedAttachment.pathRecordsOrigin(
            #"\\psf\Host\Users\stephenmalinowski\Documents\report.pdf"#))
        XCTAssertTrue(RecordedAttachment.pathRecordsOrigin(#"C:\DEV\C\TUNING\TUNING.ZIP"#))
    }

    /// Matched with separators attached, so neither a file merely *named* like a
    /// temp file nor a folder whose name merely starts with "temp" is mistaken
    /// for staging.
    func testTempLookalikesStillRecordOrigin() {
        XCTAssertTrue(RecordedAttachment.pathRecordsOrigin(#"\\Mac\Home\Documents\temp.doc"#))
        XCTAssertTrue(RecordedAttachment.pathRecordsOrigin(#"\\Mac\Home\Templates\letter.doc"#))
        XCTAssertTrue(RecordedAttachment.pathRecordsOrigin(#"C:\Temperature\readings.xls"#))
    }

    /// Case-insensitive: Windows paths arrive in every capitalisation.
    func testStagingDetectionIsCaseInsensitive() {
        XCTAssertFalse(RecordedAttachment.pathRecordsOrigin(#"C:\USERS\S\APPDATA\LOCAL\TEMP\a.pdf"#))
        XCTAssertFalse(RecordedAttachment.pathRecordsOrigin(#"\\Mac\AllFiles\Private\Var\Folders\x\T\1\a.pdf"#))
    }

    // MARK: isPresent agrees with recordedPaths

    func testIsPresentMatchesRecordedPaths() {
        let cases: [String?] = [
            nil, "", "  ", ";", " ; ; ", "\t;\t",
            #"\\Mac\Home\a.jpg;"#,
            #"\\Mac\Home\a.jpg; \\Mac\Home\b.jpg;"#,
            #"C:\x.zip"#,                       // no trailing semicolon
            "  spaced.txt  ;",
        ]
        for v in cases {
            XCTAssertEqual(RecordedAttachment.isPresent(inHeaderValue: v),
                           !RecordedAttachment.recordedPaths(inHeaderValue: v).isEmpty,
                           "disagreement on \(v ?? "nil")")
        }
    }

    // MARK: reading from a message

    func testLocatedRowsFromMessage() {
        let p = part("From: me@x\r\n"
                     + #"X-Attachments: \\Mac\Home\Documents\photo.jpg; C:\DEV\TUNING.ZIP;"# + "\r\n"
                     + "\r\nbody")
        let rows = RecordedAttachment.located(in: p)
        XCTAssertEqual(rows.map(\.filename), ["photo.jpg", "TUNING.ZIP"])
        // Never resolved to a file: the Attachments folder holds received mail's
        // attachments, and a name match there would be someone else's file.
        XCTAssertTrue(rows.allSatisfy { $0.url == nil && !$0.isFound })
        XCTAssertTrue(rows.allSatisfy { $0.origin == .recordedOnSend })
        // The path survives intact for display — it is the only clue left.
        XCTAssertEqual(rows[0].recordedPath, #"\\Mac\Home\Documents\photo.jpg"#)
    }

    func testEmptyHeaderInMessageYieldsNoRows() {
        XCTAssertTrue(RecordedAttachment.located(in: part("From: me@x\r\nX-Attachments: \r\n\r\nbody")).isEmpty)
        XCTAssertTrue(RecordedAttachment.located(in: part("From: me@x\r\n\r\nbody")).isEmpty)
    }

    /// The header name is matched the way every other header is — case-insensitively
    /// — because nothing guarantees Eudora's capitalisation survived a round trip.
    func testHeaderNameIsCaseInsensitive() {
        let p = part("From: me@x\r\n" + #"x-attachments: \\Mac\Home\a.jpg;"# + "\r\n\r\nbody")
        XCTAssertEqual(RecordedAttachment.located(in: p).map(\.filename), ["a.jpg"])
    }

    /// A long header folded across lines is unfolded by the header parser, so a
    /// list of many files still reads as many files. Eudora itself writes these
    /// unfolded (the longest in `phaseX` is a single 1,506-character line), but a
    /// message that has been through another agent may not be.
    func testFoldedHeader() {
        let p = part("From: me@x\r\n"
                     + #"X-Attachments: \\Mac\Home\a.jpg;"# + "\r\n"
                     + #" \\Mac\Home\b.jpg;"# + "\r\n"
                     + "\r\nbody")
        XCTAssertEqual(RecordedAttachment.located(in: p).map(\.filename), ["a.jpg", "b.jpg"])
    }

    /// A message quoting the header inside its body is not a message with an
    /// attachment — only the real header counts, and the parser stops at the
    /// blank line.
    func testHeaderTextInBodyIsIgnored() {
        let p = part("From: me@x\r\n\r\n" + #"X-Attachments: \\Mac\Home\a.jpg;"# + "\r\nnot a header")
        XCTAssertTrue(RecordedAttachment.located(in: p).isEmpty)
    }
}

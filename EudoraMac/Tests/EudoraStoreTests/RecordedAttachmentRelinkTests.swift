import XCTest
import Foundation
@testable import EudoraStore

/// Tests for `RecordedAttachmentRelink`, which repoints an `X-Attachments:`
/// header at where the file actually is.
///
/// Three things can go wrong here and none of them throws.
///
/// The first is the one `MailboxReplaceTests` exists for: a header that changes
/// length shifts every later record, and a `.toc` still holding the old offsets
/// describes the wrong messages while the mailbox parses perfectly. So the
/// mailbox tests rewrite a record in the *middle* and check the neighbours.
///
/// The second is that the `.toc` carries far more than the seven fields `Toc`
/// models — measured over `phaseX`, 97% of entries have non-zero bytes outside
/// them — so an index that is *rebuilt* rather than patched silently blanks
/// timestamps, flags and window state for every message in the mailbox.
/// `testTocBytesOutsideTheModelledFieldsSurvive` is the guard for that, and it
/// pokes bytes a rebuild would lose.
///
/// The third is unique to this operation: it edits mail that is otherwise
/// finished, whose header bytes are CP1252 while our parser decodes UTF-8. A
/// decode/re-encode round trip would turn every non-ASCII byte in an *untouched*
/// entry into `EF BF BD`. So the record-level tests compare raw bytes rather
/// than re-parsing.
final class RecordedAttachmentRelinkTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-relink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var locations: RecordedAttachmentRelink.Locations {
        RecordedAttachmentRelink.Locations([
            (name: "photo.jpg", path: "/Users/s/Pictures/photo.jpg"),
            (name: "TUNING.ZIP", path: "/Users/s/Devel/TUNING.ZIP"),
            (name: "CarterCaténaires.png", path: "/Users/s/mam/CarterCaténaires.png"),
        ])
    }

    private let stagingPath =
        #"\\Mac\AllFiles\private\var\folders\r_\abc\T\A1B2\photo.jpg"#
    private let realPath = #"C:\DEV\TUNING.ZIP"#

    // MARK: - which entries get rewritten

    func testStagingEntryIsRepointed() throws {
        let after = try rewrite(headerValue: "\(stagingPath);")
        XCTAssertTrue(after.contains("X-Attachments: /Users/s/Pictures/photo.jpg;"))
        XCTAssertFalse(after.contains(#"\\Mac\AllFiles"#))
    }

    /// A path that already names a real place is not ours to change, even when
    /// the list happens to hold that filename. `pathRecordsOrigin` is the gate,
    /// and it is the same one the display uses.
    func testEntryWithARealPathIsLeftAlone() throws {
        XCTAssertNil(RecordedAttachmentRelink.rewrittenRecord(
            record(headerValue: "\(realPath);"), using: locations))
    }

    func testStagingEntryNotInTheListIsLeftAlone() throws {
        let unknown = #"\\Mac\AllFiles\private\var\folders\r_\abc\T\A1B2\mystery.pdf"#
        XCTAssertNil(RecordedAttachmentRelink.rewrittenRecord(
            record(headerValue: "\(unknown);"), using: locations))
    }

    /// The header reaches us mangled, not the list. `MIMEParser.parseHeaders`
    /// decodes header bytes as UTF-8 though Eudora wrote CP1252, so every
    /// non-ASCII byte in a filename arrives as U+FFFD.
    func testMangledNameStillMatches() throws {
        let mangled = #"\\Mac\AllFiles\private\var\folders\r_\x\T\Q\CarterCat\#u{FFFD}naires.png"#
        let after = try rewrite(headerValue: "\(mangled);")
        XCTAssertTrue(after.contains("X-Attachments: /Users/s/mam/CarterCaténaires.png;"))
    }

    /// Two candidates differing only where the wildcard sits is a guess, and a
    /// wrong guess writes the wrong file's location into the mail.
    func testAmbiguousMangledNameIsRefused() throws {
        let two = RecordedAttachmentRelink.Locations([
            (name: "sómething.pdf", path: "/a/sómething.pdf"),
            (name: "sàmething.pdf", path: "/b/sàmething.pdf"),
        ])
        let mangled = #"\\Mac\AllFiles\private\var\folders\r_\x\T\Q\s\#u{FFFD}mething.pdf"#
        XCTAssertNil(RecordedAttachmentRelink.rewrittenRecord(
            record(headerValue: "\(mangled);"), using: two))
    }

    /// U+FFFD can only have come from a byte ≥ 0x80, so it must not stand for an
    /// ASCII character — otherwise `photo1.jpg` in the list would claim a
    /// header's `photo<?>.jpg` and, being the only match, would pass the
    /// ambiguity check and write the wrong path.
    func testWildcardDoesNotMatchAnASCIICharacter() throws {
        let list = RecordedAttachmentRelink.Locations([
            (name: "photo1.jpg", path: "/a/photo1.jpg"),
        ])
        let mangled = #"\\Mac\AllFiles\private\var\folders\r_\x\T\Q\photo\#u{FFFD}.jpg"#
        XCTAssertNil(RecordedAttachmentRelink.rewrittenRecord(
            record(headerValue: "\(mangled);"), using: list))
    }

    /// The volume is case-insensitive and macOS hands back decomposed names, so
    /// neither difference may cost a match.
    func testLookupIgnoresCaseAndUnicodeComposition() throws {
        let list = RecordedAttachmentRelink.Locations([
            (name: "CarterCate\u{0301}naires.png", path: "/found/it.png"),   // NFD
        ])
        let path = #"\\Mac\AllFiles\private\var\folders\r_\x\T\Q\CARTERCATÉNAIRES.PNG"#
        let after = try rewrite(headerValue: "\(path);", using: list)
        XCTAssertTrue(after.contains("X-Attachments: /found/it.png;"))
    }

    // MARK: - the record comes back byte-identical apart from the entry

    /// Not "contains the right text" — the bytes either side of the replaced
    /// entry must be identical, or the promise the type makes is false.
    func testOnlyTheReplacedEntryBytesChange() throws {
        let before = record(headers: [
            "From: me@example.com",
            "Subject: with an attachment",
            "X-Attachments: \(stagingPath);",
            "Content-Type: text/plain; charset=us-ascii",
        ], body: "hello\r\n")

        let span = try XCTUnwrap(RecordedAttachmentRelink.headerValueSpan(
            before, name: RecordedAttachment.headerName))
        let after = try XCTUnwrap(RecordedAttachmentRelink.rewrittenRecord(
            before, using: locations)?.record)

        XCTAssertEqual(Array(after[0..<span.lowerBound]),
                       Array(before[0..<span.lowerBound]),
                       "everything up to the header's value must be untouched")
        let tailLength = before.count - span.upperBound
        XCTAssertEqual(Array(after.suffix(tailLength)), Array(before.suffix(tailLength)),
                       "everything after the header's value must be untouched")
    }

    /// The separator and spacing between entries belong to Eudora, not to us: a
    /// header written `a;b;` must not come back `a; b;`.
    func testSeparatorsAndSpacingArePreserved() throws {
        let after = try rewrite(headerValue: "\(realPath);\(stagingPath);")
        XCTAssertTrue(after.contains("X-Attachments: C:\\DEV\\TUNING.ZIP;/Users/s/Pictures/photo.jpg;"),
                      "got: \(after)")
    }

    /// The killer case for a decode/re-encode implementation: a CP1252 byte in
    /// an entry that is *not* being replaced. It must survive as the byte it is.
    func testCP1252BytesInAPreservedEntryAreNotTranscoded() throws {
        // `C:\DEV\Caf<0xE9>.zip; <staging>;` — the first entry is untouched.
        var value: [UInt8] = Array(#"C:\DEV\Caf"#.utf8)
        value.append(0xE9)
        value.append(contentsOf: Array(".zip; \(stagingPath);".utf8))

        var before: [UInt8] = Array("From ???@??? Thu Nov 19 17:23:56 2009\r\nSubject: s\r\nX-Attachments: ".utf8)
        before.append(contentsOf: value)
        before.append(contentsOf: Array("\r\n\r\nbody\r\n".utf8))

        let after = try XCTUnwrap(RecordedAttachmentRelink.rewrittenRecord(
            before, using: locations)?.record)
        XCTAssertTrue(after.contains(0xE9),
                      "the CP1252 byte in the preserved entry must survive as one byte")
        XCTAssertEqual(after.filter { $0 == 0xEF }.count, 0,
                       "a decode/re-encode round trip would have written EF BF BD here")
        let text = String(decoding: after, as: UTF8.self)
        XCTAssertTrue(text.contains("/Users/s/Pictures/photo.jpg;"),
                      "the staging entry should still have been replaced")
        XCTAssertFalse(text.contains(#"\\Mac\AllFiles"#))
    }

    /// A tree this old holds all three endings, and a record rewritten with the
    /// wrong one is not cosmetic: `findRecords` only accepts a separator that
    /// begins a line.
    func testBareLFRecordKeepsBareLF() throws {
        let before = Array(("From ???@??? Thu Nov 19 17:23:56 2009\n"
                            + "Subject: s\n"
                            + "X-Attachments: \(stagingPath);\n"
                            + "\n"
                            + "body\n").utf8)
        let after = String(decoding: try XCTUnwrap(
            RecordedAttachmentRelink.rewrittenRecord(before, using: locations)?.record),
                           as: UTF8.self)
        XCTAssertFalse(after.contains("\r"), "a bare-LF record must not acquire CRLF")
        XCTAssertTrue(after.contains("X-Attachments: /Users/s/Pictures/photo.jpg;\n"))
    }

    func testLoneCRRecordKeepsLoneCR() throws {
        let before = Array(("From ???@??? Thu Nov 19 17:23:56 2009\r"
                            + "Subject: s\r"
                            + "X-Attachments: \(stagingPath);\r"
                            + "\r"
                            + "body\r").utf8)
        let after = String(decoding: try XCTUnwrap(
            RecordedAttachmentRelink.rewrittenRecord(before, using: locations)?.record),
                           as: UTF8.self)
        XCTAssertFalse(after.contains("\n"), "a lone-CR record must not acquire LF")
        XCTAssertTrue(after.contains("X-Attachments: /Users/s/Pictures/photo.jpg;\r"))
    }

    /// A long list can be folded across lines. The value is read across the
    /// fold, and the fold itself survives because only the entry's bytes change.
    func testFoldedHeaderIsReadAcrossTheFoldAndKeepsItsFold() throws {
        let before = Array(("From ???@??? Thu Nov 19 17:23:56 2009\r\n"
                            + "Subject: s\r\n"
                            + "X-Attachments: \(realPath);\r\n"
                            + "\t\(stagingPath);\r\n"
                            + "Content-Type: text/plain\r\n"
                            + "\r\n"
                            + "body\r\n").utf8)
        let after = String(decoding: try XCTUnwrap(
            RecordedAttachmentRelink.rewrittenRecord(before, using: locations)?.record),
                           as: UTF8.self)
        XCTAssertTrue(after.contains("X-Attachments: C:\\DEV\\TUNING.ZIP;\r\n\t/Users/s/Pictures/photo.jpg;\r\n"),
                      "got: \(after)")
    }

    /// An `X-Attachments` in the *body* — a quoted reply carrying someone's
    /// headers — must not be touched.
    func testHeaderInTheBodyIsNotRewritten() throws {
        let before = record(headers: ["Subject: quoting an old message"],
                            body: "X-Attachments: \(stagingPath);\r\n")
        XCTAssertNil(RecordedAttachmentRelink.rewrittenRecord(before, using: locations))
    }

    /// Without a blank line there is no way to tell a header from a body line,
    /// and guessing wrong rewrites message text.
    func testRecordWithNoHeaderBodySeparatorIsRefused() throws {
        let before = Array(("From ???@??? Thu Nov 19 17:23:56 2009\r\n"
                            + "Subject: s\r\n"
                            + "X-Attachments: \(stagingPath);\r\n").utf8)
        XCTAssertNil(RecordedAttachmentRelink.rewrittenRecord(before, using: locations))
    }

    func testMessageWithNoHeaderIsUntouched() throws {
        XCTAssertNil(RecordedAttachmentRelink.rewrittenRecord(
            record(headers: ["Subject: nothing attached"], body: "text\r\n"),
            using: locations))
    }

    // MARK: - the list

    func testCRLFLocationsFileDoesNotLeaveATrailingCR() throws {
        let url = root.appendingPathComponent("map.tsv")
        try "photo.jpg\t/Users/s/Pictures/photo.jpg\r\n".write(to: url, atomically: true,
                                                               encoding: .utf8)
        let loaded = try RecordedAttachmentRelink.Locations.load(contentsOf: url)
        XCTAssertEqual(loaded.pairs.first?.path, "/Users/s/Pictures/photo.jpg")
    }

    /// Duplicate basenames are the likely case in a whole-disk scan, and the
    /// cost of picking one is writing one file's location into another file's
    /// message.
    func testDuplicateNameIsRefusedRatherThanGuessed() throws {
        let two = RecordedAttachmentRelink.Locations([
            (name: "photo.jpg", path: "/a/photo.jpg"),
            (name: "photo.jpg", path: "/b/photo.jpg"),
        ])
        XCTAssertNil(RecordedAttachmentRelink.rewrittenRecord(
            record(headerValue: "\(stagingPath);"), using: two))
    }

    /// A `;` in a path would be split into two entries on the next run,
    /// corrupting the header permanently. Newlines would break the record.
    func testUnwritablePathsAreRejectedByLoad() throws {
        let url = root.appendingPathComponent("bad.tsv")
        try ["a.pdf\t/Users/s/has;semicolon.pdf",
             "b.pdf\trelative/path.pdf",
             "c.pdf\t/Users/s/back\\slash.pdf",
             "d.pdf\t/Users/s/fine.pdf"].joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let loaded = try RecordedAttachmentRelink.Locations.load(contentsOf: url)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.rejected.count, 3)
        XCTAssertEqual(loaded.pairs.first?.path, "/Users/s/fine.pdf")
    }

    // MARK: - whole mailboxes

    /// A record that *grows* is the dangerous direction: a stale `.toc` offset
    /// then lands inside the following record rather than before it. The
    /// ordinary relink shortens a record — a POSIX path is shorter than a
    /// Parallels staging path — so this has to force the other case, and assert
    /// that it did.
    func testNeighboursSurviveALongerHeader() throws {
        let longer = RecordedAttachmentRelink.Locations([
            (name: "photo.jpg",
             path: "/Users/s/Pictures/2009/Family/Reunion/Scans/High Resolution/photo.jpg"),
        ])
        try buildMailbox(attachments: [nil, "\(stagingPath);", nil])
        let done = try RecordedAttachmentRelink.run(base: base, locations: longer, apply: true)
        XCTAssertEqual(done.disposition, .rewritten)
        XCTAssertEqual(done.changes.count, 1)
        XCTAssertGreaterThan(done.delta, 0,
                             "this test only means anything if the record grew")

        let listing = MailStore(root: root).list(at: base, name: "Out")!
        XCTAssertEqual(listing.rows.count, 3, "relinking must not add or drop a record")
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "S2", "S3"])
        XCTAssertTrue(bodyOfRecord(1).contains("body 1"))
        XCTAssertTrue(bodyOfRecord(3).contains("body 3"))
    }

    /// A POSIX path is usually shorter than a Parallels staging path, so
    /// shrinking is the common case, not the exotic one.
    func testNeighboursSurviveAShorterHeader() throws {
        try buildMailbox(attachments: [nil, "\(stagingPath); \(stagingPath);", nil])
        try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)

        let listing = MailStore(root: root).list(at: base, name: "Out")!
        XCTAssertEqual(listing.rows.map(\.subject), ["S1", "S2", "S3"])
        XCTAssertTrue(bodyOfRecord(1).contains("body 1"))
        XCTAssertTrue(bodyOfRecord(3).contains("body 3"))
    }

    func testTocStillDescribesTheMailbox() throws {
        try buildMailbox(attachments: ["\(stagingPath);", nil, "\(stagingPath);"])
        let done = try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)
        XCTAssertTrue(done.tocPatched)

        let listing = MailStore(root: root).list(at: base, name: "Out")!
        XCTAssertEqual(listing.source, .toc,
                       "a relink that invalidates the TOC would fall back to scanning")

        let entries = Toc.read(base.appendingPathExtension("toc"))!
        let recs = Mbox.findRecords([UInt8](try Data(contentsOf: base.appendingPathExtension("mbx"))))
        XCTAssertEqual(entries.map(\.offset), recs.map(\.offset),
                       "every cached offset must still name a real record")
        XCTAssertEqual(entries.map(\.length), recs.map(\.length))
    }

    /// The reason the `.toc` is patched and not rebuilt. `TocWriter` writes the
    /// seven fields `Toc` models and zeroes the other 210 bytes, plus the
    /// 104-byte folder header — and over `phaseX`, 97% of real entries carry
    /// data there. This pokes bytes at the positions that were measured to be
    /// populated and insists they come back.
    func testTocBytesOutsideTheModelledFieldsSurvive() throws {
        try buildMailbox(attachments: [nil, "\(stagingPath);", nil])
        let tocURL = base.appendingPathExtension("toc")

        var raw = [UInt8](try Data(contentsOf: tocURL))
        raw[8] = 0xAB                                       // folder header
        raw[41] = 0xCD
        let count = (raw.count - Toc.folderSize) / Toc.entrySize
        XCTAssertEqual(count, 3)
        for k in 0..<count {
            let e = Toc.folderSize + k * Toc.entrySize
            raw[e + 8] = 0xD2; raw[e + 9] = 0xC5             // timestamp
            raw[e + 14] = 0x11; raw[e + 15] = 0x20           // flags
            raw[e + 46] = 0xEF; raw[e + 49] = 0x55           // date-field tail
            raw[e + 182] = 0x7E; raw[e + 208] = 0x03         // the 178-212 region
        }
        try Data(raw).write(to: tocURL)

        try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)

        let after = [UInt8](try Data(contentsOf: tocURL))
        XCTAssertEqual(after.count, raw.count)
        XCTAssertEqual(after[8], 0xAB)
        XCTAssertEqual(after[41], 0xCD)
        for k in 0..<count {
            let e = Toc.folderSize + k * Toc.entrySize
            XCTAssertEqual(after[e + 8], 0xD2, "entry \(k): timestamp blanked")
            XCTAssertEqual(after[e + 14], 0x11, "entry \(k): flags blanked")
            XCTAssertEqual(after[e + 46], 0xEF, "entry \(k): date-field tail blanked")
            XCTAssertEqual(after[e + 182], 0x7E, "entry \(k): bytes 178-212 blanked")
            XCTAssertEqual(after[e + 208], 0x03)
        }
    }

    /// Status is cached only in the `.toc`, so carrying the wrong entry across
    /// would mark read mail unread — or a draft sent.
    func testCachedTocColumnsAreCarriedAcross() throws {
        try buildMailbox(attachments: [nil, "\(stagingPath);", nil])
        let before = Toc.read(base.appendingPathExtension("toc"))!
        try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)
        let after = Toc.read(base.appendingPathExtension("toc"))!

        XCTAssertEqual(after.map(\.status), before.map(\.status))
        XCTAssertEqual(after.map(\.subject), before.map(\.subject))
        XCTAssertEqual(after.map(\.to), before.map(\.to))
        XCTAssertEqual(after.map(\.date), before.map(\.date))
    }

    /// A `.toc` that doesn't line up cannot be patched — and must not be
    /// deleted either, because it holds every read/replied flag in the mailbox
    /// and the reader tolerates a far staler index than this check accepts.
    func testMailboxWithAnInconsistentTocIsSkippedNotDamaged() throws {
        try buildMailbox(attachments: [nil, "\(stagingPath);", nil])
        let mbxURL = base.appendingPathExtension("mbx")
        let tocURL = base.appendingPathExtension("toc")

        var raw = [UInt8](try Data(contentsOf: tocURL))
        TocWriter.writeU32LE(&raw, Toc.folderSize, 999_999)      // an offset naming nothing
        try Data(raw).write(to: tocURL)
        let mbxBefore = try Data(contentsOf: mbxURL)

        let done = try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)
        XCTAssertEqual(done.disposition, .skippedTocMismatch)
        XCTAssertEqual(try Data(contentsOf: mbxURL), mbxBefore, "the mailbox must be untouched")
        XCTAssertEqual([UInt8](try Data(contentsOf: tocURL)), raw, "the .toc must survive")
    }

    func testBacksUpBeforeWriting() throws {
        try buildMailbox(attachments: [nil, "\(stagingPath);"])
        let mbxURL = base.appendingPathExtension("mbx")
        let backup = mbxURL.appendingPathExtension(RecordedAttachmentRelink.backupSuffix)
        let before = try Data(contentsOf: mbxURL)

        let tocURL = base.appendingPathExtension("toc")
        let tocBefore = try Data(contentsOf: tocURL)

        try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)
        XCTAssertEqual(try Data(contentsOf: backup), before,
                       "the backup must be the mailbox as it was")
        XCTAssertNotEqual(try Data(contentsOf: mbxURL), before)
        // The .toc is backed up too: its offsets are useless without the old
        // mailbox, but its status flags exist nowhere else.
        XCTAssertEqual(try Data(contentsOf: tocURL.appendingPathExtension(
            RecordedAttachmentRelink.backupSuffix)), tocBefore)
    }

    /// A path with a line break in it would break the record itself, and could
    /// invent a record boundary. Both are legal in macOS filenames.
    func testPathWithALineBreakIsRejected() throws {
        let list = RecordedAttachmentRelink.Locations([
            (name: "photo.jpg", path: "/Users/s/two\nlines.jpg"),
        ])
        XCTAssertEqual(list.count, 0)
        XCTAssertEqual(list.rejected.count, 1)
        XCTAssertNil(RecordedAttachmentRelink.rewrittenRecord(
            record(headerValue: "\(stagingPath);"), using: list))
    }

    /// The ordinary state of real Eudora mail: messages deleted but not
    /// compacted, so the `.toc` has fewer entries than the `.mbx` has records.
    /// Every entry must still name a record, but not every record needs an
    /// entry.
    func testTocWithFewerEntriesThanRecordsIsStillPatched() throws {
        try buildMailbox(attachments: [nil, "\(stagingPath);", nil])
        let tocURL = base.appendingPathExtension("toc")

        // Drop the last entry, leaving two for three records.
        var raw = [UInt8](try Data(contentsOf: tocURL))
        raw.removeLast(Toc.entrySize)
        try Data(raw).write(to: tocURL)

        let done = try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)
        XCTAssertEqual(done.disposition, .rewritten)
        XCTAssertTrue(done.tocPatched)

        let entries = Toc.read(tocURL)!
        let recs = Mbox.findRecords([UInt8](try Data(contentsOf: base.appendingPathExtension("mbx"))))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.offset), Array(recs.prefix(2).map(\.offset)))
    }

    /// The backup is the only pristine copy. A second run must refuse rather
    /// than overwrite it — which is why this doesn't use `MailboxIO.backupOnce`,
    /// whose `.bak` already exists in the real tree from ordinary draft edits
    /// and which skips silently.
    func testRefusesWhenABackupAlreadyExists() throws {
        try buildMailbox(attachments: [nil, "\(stagingPath);"])
        let backup = base.appendingPathExtension("mbx")
            .appendingPathExtension(RecordedAttachmentRelink.backupSuffix)
        try Data("not the real backup".utf8).write(to: backup)

        let done = try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)
        guard case .skippedBackupExists = done.disposition else {
            return XCTFail("expected a refusal, got \(done.disposition)")
        }
        XCTAssertEqual(try Data(contentsOf: backup), Data("not the real backup".utf8))
    }

    /// A second run must be a no-op. It is, because a relinked entry holds a
    /// POSIX path, which `pathRecordsOrigin` does not call staging — so the
    /// property that makes the rewrite safe to repeat is the one that makes it
    /// correct.
    func testRunningTwiceChangesNothingTheSecondTime() throws {
        try buildMailbox(attachments: [nil, "\(stagingPath);", nil])
        try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)
        let afterFirst = try Data(contentsOf: base.appendingPathExtension("mbx"))

        let second = try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)
        XCTAssertEqual(second.disposition, .nothingToDo)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathExtension("mbx")), afterFirst)
    }

    func testDryRunReportsWithoutWriting() throws {
        try buildMailbox(attachments: [nil, "\(stagingPath);", nil])
        let before = try Data(contentsOf: base.appendingPathExtension("mbx"))

        let done = try RecordedAttachmentRelink.run(base: base, locations: locations, apply: false)
        XCTAssertEqual(done.disposition, .wouldRewrite)
        XCTAssertEqual(done.changes.count, 1)
        XCTAssertEqual(done.changes.first?.index, 2)
        XCTAssertEqual(done.changes.first?.relinked.first?.path, "/Users/s/Pictures/photo.jpg")
        XCTAssertEqual(try Data(contentsOf: base.appendingPathExtension("mbx")), before,
                       "a dry run must not touch the mailbox")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: base.appendingPathExtension("mbx")
                .appendingPathExtension(RecordedAttachmentRelink.backupSuffix).path),
            "a dry run must not leave a backup either")
    }

    /// A `.lck` means Eudora has the mailbox open. Rewriting records underneath
    /// it would corrupt whatever it later flushed.
    func testRefusesWhileLocked() throws {
        try buildMailbox(attachments: ["\(stagingPath);"])
        try Data().write(to: base.appendingPathExtension("lck"))
        XCTAssertThrowsError(try RecordedAttachmentRelink.run(base: base,
                                                              locations: locations, apply: true))
    }

    func testMailboxWithNothingToDoIsNotRewritten() throws {
        try buildMailbox(attachments: [nil, nil])
        let before = try Data(contentsOf: base.appendingPathExtension("mbx"))
        let done = try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)
        XCTAssertEqual(done.disposition, .nothingToDo)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathExtension("mbx")), before)
    }

    /// Every byte of every *unchanged* record must be identical afterwards —
    /// not just the subjects the listing shows.
    func testUnchangedRecordsAreByteIdentical() throws {
        try buildMailbox(attachments: [nil, "\(stagingPath);", nil])
        let before = [UInt8](try Data(contentsOf: base.appendingPathExtension("mbx")))
        let recsBefore = Mbox.findRecords(before)

        try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)

        let after = [UInt8](try Data(contentsOf: base.appendingPathExtension("mbx")))
        let recsAfter = Mbox.findRecords(after)
        XCTAssertEqual(recsAfter.count, recsBefore.count)
        for i in [0, 2] {
            XCTAssertEqual(Array(after[recsAfter[i].offset..<(recsAfter[i].offset + recsAfter[i].length)]),
                           Array(before[recsBefore[i].offset..<(recsBefore[i].offset + recsBefore[i].length)]),
                           "record \(i + 1) must be byte-identical")
        }
    }

    /// The relinked path has to survive the round trip back out through the
    /// reader, or the whole exercise buys nothing.
    func testRelinkedPathReadsBackThroughRecordedAttachment() throws {
        try buildMailbox(attachments: ["\(stagingPath);"])
        try RecordedAttachmentRelink.run(base: base, locations: locations, apply: true)

        let bytes = [UInt8](try Data(contentsOf: base.appendingPathExtension("mbx")))
        let recs = Mbox.findRecords(bytes)
        let part = MIMEParser.parse(Mbox.messageBytes(bytes, recs[0]))
        let paths = RecordedAttachment.recordedPaths(in: part)
        XCTAssertEqual(paths, ["/Users/s/Pictures/photo.jpg"])
        XCTAssertTrue(RecordedAttachment.pathRecordsOrigin(paths[0]),
                      "a relinked path must read as a real location, not staging")
        XCTAssertEqual(RecordedAttachment.located(in: part).first?.filename, "photo.jpg")
    }

    // MARK: - fixture

    private var base: URL { root.appendingPathComponent("Out") }

    private func record(headers: [String], body: String) -> [UInt8] {
        Array(("From ???@??? Thu Nov 19 17:23:56 2009\r\n"
               + headers.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    private func record(headerValue: String) -> [UInt8] {
        record(headers: ["Subject: s", "X-Attachments: \(headerValue)"], body: "body\r\n")
    }

    private func rewrite(headerValue: String,
                         using list: RecordedAttachmentRelink.Locations? = nil) throws -> String {
        let out = try XCTUnwrap(RecordedAttachmentRelink.rewrittenRecord(
            record(headerValue: headerValue), using: list ?? locations)?.record)
        return String(decoding: out, as: UTF8.self)
    }

    /// A mailbox with one message per entry, carrying that entry's
    /// `X-Attachments` value when it is non-nil. Built through `Outbox.append`
    /// so the records and the `.toc` come from the code the app uses.
    private func buildMailbox(attachments: [String?]) throws {
        for (i, value) in attachments.enumerated() {
            var lines = [
                "From: me@example.com",
                "To: you@example.com",
                "Subject: S\(i + 1)",
            ]
            if let value { lines.append("X-Attachments: \(value)") }
            lines.append("Content-Type: text/plain; charset=us-ascii")
            lines.append("")
            lines.append("body \(i + 1)")
            lines.append("")
            _ = try Outbox.append(messageData: Data(lines.joined(separator: "\r\n").utf8),
                                  to: base,
                                  status: MailboxMutator.statusSent,
                                  who: "you@example.com",
                                  subject: "S\(i + 1)")
        }
    }

    private func bodyOfRecord(_ index: Int) -> String {
        let data = (try? Data(contentsOf: base.appendingPathExtension("mbx"))) ?? Data()
        let bytes = [UInt8](data)
        let recs = Mbox.findRecords(bytes)
        guard index >= 1, index <= recs.count else { return "" }
        return String(decoding: Mbox.messageBytes(bytes, recs[index - 1]), as: UTF8.self)
    }
}

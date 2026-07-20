import XCTest
import Foundation
@testable import EudoraStore

/// These tests build their own tiny Eudora tree in a temp directory, so they
/// need no external fixture. They cover the paths most likely to hide bugs:
/// TOC parsing, scan fallback, stale-TOC detection, charset repair, multipart.
final class EudoraStoreTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try buildFixture()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: hierarchy

    func testTree() {
        let store = MailStore(root: root)
        let nodes = store.tree()
        XCTAssertEqual(nodes.count, 4)                 // In, Loose, Stale, MP
        let inNode = nodes.first { $0.entry.filename == "In" }
        XCTAssertNotNil(inNode)
        XCTAssertEqual(inNode?.messageCount, 2)
        XCTAssertEqual(inNode?.entry.hasUnread, true)
    }

    // MARK: TOC fast path

    func testListUsesToc() {
        let store = MailStore(root: root)
        let listing = store.list("In")!
        XCTAssertEqual(listing.source, .toc)
        XCTAssertEqual(listing.rows.count, 2)
        XCTAssertEqual(listing.rows[0].subject, "Hello")   // from TOC cache
        XCTAssertEqual(listing.rows[1].subject, "Cafe")
        XCTAssertEqual(listing.rows[0].statusGlyph, "R")   // status 2 = replied
    }

    // MARK: status glyphs (real Eudora summary.h codes)

    func testStatusGlyphsMatchEudoraCodes() throws {
        // 0 unread, 2 replied, 3 forwarded, 4 redirect, 8 sent.
        let subjects = ["u", "r", "f", "d", "s"]
        let (data, recs) = buildMbox(subjects.map {
            message(from: "a@x.com", subject: $0,
                    ctype: "text/plain; charset=us-ascii", body: "x")
        })
        try data.write(to: mbx("Glyphs"))
        try writeToc(url: toc("Glyphs"), entries: [
            tocEntry(recs[0], status: 0, priority: 4, subject: "u"),
            tocEntry(recs[1], status: 2, priority: 4, subject: "r"),
            tocEntry(recs[2], status: 3, priority: 4, subject: "f"),
            tocEntry(recs[3], status: 4, priority: 4, subject: "d"),
            tocEntry(recs[4], status: 8, priority: 4, subject: "s"),
        ])
        let store = MailStore(root: root)
        let rows = store.list(at: root.appendingPathComponent("Glyphs"), name: "Glyphs")!.rows
        XCTAssertEqual(rows.map(\.statusGlyph), ["•", "R", "F", "→", "S"])
    }

    // MARK: deleted-but-not-compacted (.toc lists a subset of the .mbx)

    func testStaleTocHidesDeletedGhosts() throws {
        // mbx has 3 messages; the .toc lists only #0 and #2 (message #1 deleted
        // but not compacted). Show those 2 with status; hide the ghost.
        let (data, recs) = buildMbox([
            message(from: "a@x.com", subject: "First",
                    ctype: "text/plain; charset=us-ascii", body: "1"),
            message(from: "b@x.com", subject: "GhostDeleted",
                    ctype: "text/plain; charset=us-ascii", body: "2"),
            message(from: "c@x.com", subject: "Third",
                    ctype: "text/plain; charset=us-ascii", body: "3"),
        ])
        try data.write(to: mbx("Ghosts"))
        try writeToc(url: toc("Ghosts"), entries: [
            tocEntry(recs[0], status: 1, priority: 4, subject: "First"),   // READ
            tocEntry(recs[2], status: 2, priority: 4, subject: "Third"),   // REPLIED
        ])
        let store = MailStore(root: root)
        let listing = store.list(at: root.appendingPathComponent("Ghosts"), name: "Ghosts")!
        XCTAssertEqual(listing.source, .tocCompacted)
        XCTAssertEqual(listing.rows.map(\.subject), ["First", "Third"])  // ghost hidden
        XCTAssertEqual(listing.rows[1].statusGlyph, "R")                 // status preserved
        XCTAssertEqual(listing.rows[1].index, 3)                         // maps to 3rd mbx msg
    }

    // MARK: message counts (from .toc size, not an .mbx read)

    func testMessageCountFromTocSize() throws {
        // Count should come from the .toc's size. Give an .mbx with NO Eudora
        // separators (a scan would find 0); the count must still be 3 (the .toc).
        let entries = (0..<3).map {
            tocEntry(MboxRecord(offset: $0 * 10, length: 10),
                     status: 1, priority: 4, subject: "s\($0)")
        }
        try writeToc(url: toc("Counted"), entries: entries)
        try Data("not a mailbox".utf8).write(to: mbx("Counted"))
        let store = MailStore(root: root)
        XCTAssertEqual(store.messageCount(base: root.appendingPathComponent("Counted")), 3)
    }

    func testMessageCountScanFallbackNoToc() throws {
        let (data, _) = buildMbox([
            message(from: "a@x.com", subject: "a", ctype: "text/plain; charset=us-ascii", body: "1"),
            message(from: "b@x.com", subject: "b", ctype: "text/plain; charset=us-ascii", body: "2"),
        ])
        try data.write(to: mbx("NoToc2"))
        let store = MailStore(root: root)
        XCTAssertEqual(store.messageCount(base: root.appendingPathComponent("NoToc2")), 2)
    }

    // MARK: scan fallback (no .toc)

    func testScanFallbackNoToc() {
        let store = MailStore(root: root)
        let listing = store.list("Loose")!
        XCTAssertEqual(listing.source, .scanNoToc)
        XCTAssertEqual(listing.rows.count, 1)
        XCTAssertEqual(listing.rows[0].subject, "Loose one")  // parsed from header
    }

    // MARK: stale .toc detection

    func testStaleTocDetected() {
        let store = MailStore(root: root)
        let listing = store.list("Stale")!
        XCTAssertEqual(listing.source, .scanStale)
        XCTAssertEqual(listing.rows.count, 2)
    }

    // MARK: charset repair (UTF-8 mislabeled as iso-8859-1)

    func testCharsetRepair() {
        let store = MailStore(root: root)
        let (_, part) = store.message("In", index: 2)!
        let textPart = part.walk().first { $0.mainType == "text" }!
        let decoded = CharsetDecoder.smartDecode(textPart.decodedPayload(), declared: textPart.charset)
        XCTAssertEqual(decoded.charsetUsed, "utf-8")
        XCTAssertTrue(decoded.text.contains("€"))
        XCTAssertTrue(decoded.text.contains("Café"))
    }

    // MARK: multipart splitting

    func testMultipart() {
        let store = MailStore(root: root)
        let (_, part) = store.message("MP", index: 1)!
        XCTAssertTrue(part.isMultipart)
        XCTAssertEqual(part.children.count, 2)
        let leaves = part.walk().filter { $0.mainType == "text" }
        XCTAssertEqual(leaves.count, 2)
        let plain = leaves.first { $0.subType == "plain" }!
        XCTAssertTrue(String(decoding: plain.body, as: UTF8.self).contains("plain part"))
        let html = leaves.first { $0.subType == "html" }!
        XCTAssertTrue(String(decoding: html.body, as: UTF8.self).contains("<b>html</b>"))
    }

    // MARK: Eudora flattened bodies (<x-html> / <x-flowed>)

    func testEudoraXHtmlBody() {
        // Eudora keeps a multipart Content-Type header but stores HTML in
        // <x-html>…</x-html> with no MIME parts. We recover it as a text/html leaf.
        let raw = [
            "From: a@b.com",
            "Subject: Hi",
            "Content-Type: multipart/alternative; boundary=\"XYZ\"",
            "",
            "<x-html>",
            "<div>Hello &amp; welcome</div>",
            "</x-html>",
        ].joined(separator: "\r\n")
        let part = MIMEParser.parse([UInt8](Data(raw.utf8)))
        XCTAssertFalse(part.isMultipart)          // recovered as a leaf, not multipart
        XCTAssertEqual(part.mainType, "text")
        XCTAssertEqual(part.subType, "html")
        XCTAssertTrue(String(decoding: part.decodedPayload(), as: UTF8.self)
            .contains("<div>Hello &amp; welcome</div>"))
    }

    // MARK: multipart headers describing a structure that isn't there

    // Eudora also strips the MIME structure WITHOUT wrapping what's left in
    // <x-html>/<x-flowed>: it keeps one alternative as a bare body and leaves the
    // multipart Content-Type header in place. The shape of the 1/1/04 eBay bid
    // confirmation in phaseX/EBAY.mbx, and ~6% of that tree.
    //
    // Such a part must not go on claiming multipart: it has no children, and
    // every consumer that hunts for a body skips multipart nodes — which is what
    // produced "(no text body)" in the reader and dropped these bodies from the
    // search index.
    func testMultipartWithNoBoundaryInBodyBecomesTextLeaf() {
        let raw = [
            "From: bidconfirm@ebay.com",
            "Subject: eBay Bid Confirmed",
            "Content-Type: multipart/alternative; boundary=1641688202.1072977771104.JavaMail",
            "",
            "YOU ARE THE CURRENT HIGH BIDDER",
            "Item name: SERIOUS GAMES",
        ].joined(separator: "\r\n")
        let part = MIMEParser.parse([UInt8](Data(raw.utf8)))

        XCTAssertFalse(part.isMultipart)
        XCTAssertEqual(part.contentType, "text/plain")
        XCTAssertTrue(part.children.isEmpty)
        XCTAssertTrue(String(decoding: part.decodedPayload(), as: UTF8.self)
            .contains("CURRENT HIGH BIDDER"))
        // And it is reachable the way the reader and the indexer look for a body.
        XCTAssertEqual(part.walk().filter { !$0.isMultipart && $0.mainType == "text" }.count, 1)
    }

    // Same salvage, but the leftover body is HTML — sniffed, since the declared
    // type is known to be wrong.
    func testMultipartWithNoBoundarySniffsHTML() {
        let raw = [
            "Content-Type: multipart/alternative; boundary=\"NOPE\"",
            "",
            "<html><body><b>hi</b></body></html>",
        ].joined(separator: "\r\n")
        let part = MIMEParser.parse([UInt8](Data(raw.utf8)))

        XCTAssertEqual(part.contentType, "text/html")
        XCTAssertFalse(part.isMultipart)
    }

    // A multipart header with no boundary parameter at all is the same problem.
    func testMultipartWithNoBoundaryParameterBecomesTextLeaf() {
        let raw = [
            "Content-Type: multipart/mixed",
            "",
            "just text",
        ].joined(separator: "\r\n")
        let part = MIMEParser.parse([UInt8](Data(raw.utf8)))

        XCTAssertFalse(part.isMultipart)
        XCTAssertEqual(part.contentType, "text/plain")
        XCTAssertTrue(String(decoding: part.body, as: UTF8.self).contains("just text"))
    }

    // A real multipart must be unaffected by the salvage path.
    func testWellFormedMultipartStillSplits() {
        let part = MIMEParser.parse([UInt8](multipartAlternative()))
        XCTAssertTrue(part.isMultipart)
        XCTAssertFalse(part.children.isEmpty)
    }

    // A salvaged body splits off its trailing "Attachment Converted:" notes, the
    // same as the <x-html> path, so they don't render as body text.
    func testSalvagedBodySplitsOffAttachmentNotes() {
        let raw = [
            "Content-Type: multipart/mixed; boundary=\"NOPE\"",
            "",
            "Here is the picture.",
            "",
            "Attachment Converted: \"Y:\\Eudora\\Attachments\\history.jpg\"",
        ].joined(separator: "\r\n")
        let part = MIMEParser.parse([UInt8](Data(raw.utf8)))

        let shown = String(decoding: part.body, as: UTF8.self)
        XCTAssertTrue(shown.contains("Here is the picture."))
        XCTAssertFalse(shown.contains(DetachedAttachment.marker))
        XCTAssertEqual(DetachedAttachment.filenames(in: part), ["history.jpg"])
    }

    // But a marker followed by more prose is NOT a trailing note run, and must
    // not truncate the body — losing real text is far worse than a stray line.
    func testMarkerMidBodyDoesNotTruncate() {
        let raw = [
            "Content-Type: multipart/mixed; boundary=\"NOPE\"",
            "",
            "Attachment Converted: \"Y:\\Eudora\\Attachments\\a.pdf\"",
            "",
            "...and here is some more of the message.",
        ].joined(separator: "\r\n")
        let part = MIMEParser.parse([UInt8](Data(raw.utf8)))

        let shown = String(decoding: part.body, as: UTF8.self)
        XCTAssertTrue(shown.contains("more of the message"))
        XCTAssertTrue(part.eudoraTrailer.isEmpty)
    }

    func testEudoraXFlowedBody() {
        let raw = [
            "Subject: p",
            "Content-Type: text/plain",
            "",
            "<x-flowed>",
            "plain flowed body",
            "</x-flowed>",
        ].joined(separator: "\r\n")
        let part = MIMEParser.parse([UInt8](Data(raw.utf8)))
        XCTAssertEqual(part.contentType, "text/plain")
        XCTAssertFalse(part.isMultipart)
        XCTAssertTrue(String(decoding: part.decodedPayload(), as: UTF8.self)
            .contains("plain flowed body"))
    }

    // MARK: real Windows-Eudora descmap format (extensions, S/M/F, .fol dirs)

    func testRealDescmapFormat() throws {
        // Real descmap: filenames carry the extension, system mailboxes use "S",
        // folders are ".fol" subdirectories with their own descmap, "Y" = unread.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Top-level In.mbx (system inbox), one message.
        let (inData, _) = buildMbox([
            message(from: "a@x.com", subject: "Hi",
                    ctype: "text/plain; charset=us-ascii", body: "hello"),
        ])
        try inData.write(to: base.appendingPathComponent("In.mbx"))

        // A ".fol" folder subdirectory with its own descmap + a mailbox.
        let fol = base.appendingPathComponent("Proj.fol", isDirectory: true)
        try FileManager.default.createDirectory(at: fol, withIntermediateDirectories: true)
        let (workData, _) = buildMbox([
            message(from: "b@x.com", subject: "Task",
                    ctype: "text/plain; charset=us-ascii", body: "world"),
        ])
        try workData.write(to: fol.appendingPathComponent("Work.mbx"))
        try Data("Work,Work.mbx,M,N\r\n".utf8).write(to: fol.appendingPathComponent("descmap.pce"))

        try Data("In,In.mbx,S,Y\r\nProj,Proj.fol,F,N\r\n".utf8)
            .write(to: base.appendingPathComponent("descmap.pce"))

        let store = MailStore(root: base)
        let nodes = store.tree()
        XCTAssertEqual(nodes.count, 2)

        let inNode = nodes.first { $0.entry.display == "In" }
        XCTAssertEqual(inNode?.entry.type, .inbox)     // "S" + name "In"
        XCTAssertEqual(inNode?.messageCount, 1)        // In.mbx was actually found
        XCTAssertEqual(inNode?.entry.hasUnread, true)  // "Y"

        let proj = nodes.first { $0.entry.display == "Proj" }
        XCTAssertEqual(proj?.isFolder, true)
        XCTAssertEqual(proj?.children.count, 1)        // recursed into Proj.fol
        XCTAssertEqual(proj?.children.first?.messageCount, 1)

        // Listing the inbox now returns the message (was "No messages").
        XCTAssertEqual(store.list(at: inNode!.base, name: "In")?.rows.count, 1)
        // System role resolves (Check Mail / delete-to-Trash rely on this).
        XCTAssertNotNil(store.mailboxBase(ofType: .inbox))
    }

    // MARK: charset — Windows-1252 preferred for Western single-byte

    func testCP1252Preferred() {
        // 0x93/0x94 are curly double-quotes in Windows-1252; Latin-1 would show
        // control chars. Declared iso-8859-1 → we render as cp1252.
        let raw = Data([0x93, 0x48, 0x69, 0x94])   // "Hi" in curly quotes
        let d = CharsetDecoder.smartDecode(raw, declared: "iso-8859-1")
        XCTAssertEqual(d.charsetUsed, "windows-1252")
        XCTAssertTrue(d.text.contains("\u{201C}"))  // “
        XCTAssertTrue(d.text.contains("\u{201D}"))  // ”
    }

    func testPureASCIIStaysClean() {
        let d = CharsetDecoder.smartDecode(Data("plain".utf8), declared: "us-ascii")
        XCTAssertEqual(d.text, "plain")
        XCTAssertEqual(d.note, "")
    }

    // MARK: charset — full IANA coverage (beyond the fast-path switch)

    func testIANACyrillic() {
        // Windows-1251 isn't in the fast-path switch; it must resolve via CF.
        let raw = Data([0xC0, 0xE0])               // А а in Windows-1251
        let d = CharsetDecoder.smartDecode(raw, declared: "windows-1251")
        XCTAssertEqual(d.charsetUsed, "windows-1251")
        XCTAssertTrue(d.text.contains("\u{0410}")) // А
        XCTAssertTrue(d.text.contains("\u{0430}")) // а
    }

    func testUnknownCharsetNeverFails() {
        let d = CharsetDecoder.smartDecode(Data([0x41, 0xE9]), declared: "totally-bogus-xyz")
        XCTAssertFalse(d.text.isEmpty)             // Latin-1 backstop
    }

    // MARK: RFC 2231 attachment filenames

    func testRFC2231ExtendedFilename() {
        let v = MIMEPart.paramValue("filename",
                                    in: "attachment; filename*=UTF-8''%E2%82%AC%20rate.txt")
        XCTAssertEqual(v, "€ rate.txt")
    }

    func testRFC2231Continuation() {
        let header = "attachment; filename*0*=UTF-8''%E2%82%AC; filename*1=rate.txt"
        XCTAssertEqual(MIMEPart.paramValue("filename", in: header), "€rate.txt")
    }

    func testPlainFilenameStillWorks() {
        XCTAssertEqual(MIMEPart.paramValue("filename", in: "attachment; filename=\"note.txt\""),
                       "note.txt")
    }

    // MARK: mutations (move / delete / mark-status) — one message, ghost-aware

    func testMoveAppendsToDestThenRemovesFromSource() throws {
        let (aData, aRecs) = buildMbox([
            message(from: "a@x.com", subject: "A1", ctype: "text/plain; charset=us-ascii", body: "1"),
            message(from: "b@x.com", subject: "A2", ctype: "text/plain; charset=us-ascii", body: "2"),
        ])
        try aData.write(to: mbx("A"))
        try writeToc(url: toc("A"), entries: [
            tocEntry(aRecs[0], status: 2, priority: 4, subject: "A1"),
            tocEntry(aRecs[1], status: 3, priority: 4, subject: "A2"),   // forwarded
        ])
        let (bData, bRecs) = buildMbox([
            message(from: "c@x.com", subject: "B1", ctype: "text/plain; charset=us-ascii", body: "3"),
        ])
        try bData.write(to: mbx("B"))
        try writeToc(url: toc("B"), entries: [
            tocEntry(bRecs[0], status: 1, priority: 4, subject: "B1"),
        ])

        let store = MailStore(root: root)
        let aBase = root.appendingPathComponent("A")
        let bBase = root.appendingPathComponent("B")
        try MailboxMutator.move(from: aBase, index: 2, to: bBase)

        XCTAssertEqual(store.list(at: aBase, name: "A")!.rows.map(\.subject), ["A1"])
        let bRows = store.list(at: bBase, name: "B")!.rows
        XCTAssertEqual(bRows.map(\.subject), ["B1", "A2"])
        XCTAssertEqual(bRows.last?.statusGlyph, "F")   // forwarded status carried across
    }

    func testSetStatusUpdatesOneEntry() throws {
        let (data, recs) = buildMbox([
            message(from: "a@x.com", subject: "m", ctype: "text/plain; charset=us-ascii", body: "x"),
            message(from: "b@x.com", subject: "n", ctype: "text/plain; charset=us-ascii", body: "y"),
        ])
        try data.write(to: mbx("S1"))
        try writeToc(url: toc("S1"), entries: [
            tocEntry(recs[0], status: 1, priority: 4, subject: "m"),   // read
            tocEntry(recs[1], status: 1, priority: 4, subject: "n"),
        ])
        let base = root.appendingPathComponent("S1")
        try MailboxMutator.setStatus(base: base, index: 1, status: 0)   // → unread
        let rows = MailStore(root: root).list(at: base, name: "S1")!.rows
        XCTAssertEqual(rows[0].statusGlyph, "•")   // now unread
        XCTAssertEqual(rows[1].statusGlyph, " ")   // untouched
    }

    func testRemoveKeepsTocForGhostyMailbox() throws {
        // mbx has 3 messages; the .toc lists only #1 and #3 (a ghost at #2).
        // Deleting the first listed message must keep the .toc (so the survivor
        // keeps its status) rather than dropping it to a status-less scan.
        let (data, recs) = buildMbox([
            message(from: "a@x.com", subject: "First", ctype: "text/plain; charset=us-ascii", body: "1"),
            message(from: "b@x.com", subject: "Ghost", ctype: "text/plain; charset=us-ascii", body: "2"),
            message(from: "c@x.com", subject: "Third", ctype: "text/plain; charset=us-ascii", body: "3"),
        ])
        try data.write(to: mbx("G2"))
        try writeToc(url: toc("G2"), entries: [
            tocEntry(recs[0], status: 1, priority: 4, subject: "First"),
            tocEntry(recs[2], status: 2, priority: 4, subject: "Third"),   // replied
        ])
        let base = root.appendingPathComponent("G2")
        let store = MailStore(root: root)
        XCTAssertEqual(store.list(at: base, name: "G2")!.rows.map(\.subject), ["First", "Third"])

        try MailboxMutator.remove(base: base, index: 1)   // delete "First" (mbx pos 1)

        let after = store.list(at: base, name: "G2")!
        XCTAssertEqual(after.rows.map(\.subject), ["Third"])
        XCTAssertEqual(after.rows[0].statusGlyph, "R")     // status preserved, not "?"
    }

    // MARK: - fixture construction

    private func buildFixture() throws {
        // In: two messages, second is UTF-8 mislabeled as iso-8859-1.
        let m1 = message(from: "a@example.com", subject: "Hello",
                         ctype: "text/plain; charset=us-ascii", body: "Plain body.")
        let m2 = message(from: "b@example.fr", subject: "Cafe",
                         ctype: "text/plain; charset=iso-8859-1", body: "Fee: 5€. Café résumé.")
        let (inData, inRecs) = buildMbox([m1, m2])
        try inData.write(to: mbx("In"))
        try writeToc(url: toc("In"), entries: [
            tocEntry(inRecs[0], status: 2, priority: 4, subject: "Hello"),
            tocEntry(inRecs[1], status: 1, priority: 4, subject: "Cafe"),
        ])

        // Loose: one message, NO .toc.
        let (looseData, _) = buildMbox([
            message(from: "c@example.com", subject: "Loose one",
                    ctype: "text/plain; charset=us-ascii", body: "no toc here"),
        ])
        try looseData.write(to: mbx("Loose"))

        // Stale: two messages, .toc with a deliberately wrong first offset.
        let (staleData, staleRecs) = buildMbox([
            message(from: "d@example.com", subject: "S1",
                    ctype: "text/plain; charset=us-ascii", body: "one"),
            message(from: "e@example.com", subject: "S2",
                    ctype: "text/plain; charset=us-ascii", body: "two"),
        ])
        try staleData.write(to: mbx("Stale"))
        var e0 = tocEntry(staleRecs[0], status: 2, priority: 4, subject: "S1")
        e0 = (offset: 99999, length: e0.length, status: e0.status,
              priority: e0.priority, date: e0.date, to: e0.to, subject: e0.subject)
        try writeToc(url: toc("Stale"), entries: [
            e0, tocEntry(staleRecs[1], status: 2, priority: 4, subject: "S2"),
        ])

        // MP: one multipart/alternative message (+ matching toc).
        let mp = multipartAlternative()
        let (mpData, mpRecs) = buildMbox([mp])
        try mpData.write(to: mbx("MP"))
        try writeToc(url: toc("MP"), entries: [tocEntry(mpRecs[0], status: 2, priority: 4, subject: "MP")])

        // descmap.pce
        let descmap = [
            "In,In,I,Y",          // Y = has unread
            "Loose,Loose,M,R",
            "Stale,Stale,M,R",
            "MP,MP,M,R",
        ].joined(separator: "\r\n") + "\r\n"
        try Data(descmap.utf8).write(to: root.appendingPathComponent("descmap.pce"))
    }

    // MARK: fixture helpers

    private func mbx(_ base: String) -> URL { root.appendingPathComponent("\(base).mbx") }
    private func toc(_ base: String) -> URL { root.appendingPathComponent("\(base).toc") }

    private func message(from: String, subject: String, ctype: String, body: String) -> Data {
        let head = [
            "From: \(from)",
            "To: me@example.com",
            "Subject: \(subject)",
            "Date: Mon, 01 Jan 2001 00:00:00 +0000",
            "Content-Type: \(ctype)",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        return Data((head + body + "\r\n").utf8)
    }

    private func multipartAlternative() -> Data {
        let s = [
            "From: x@example.com",
            "Subject: MP",
            "MIME-Version: 1.0",
            "Content-Type: multipart/alternative; boundary=\"BND\"",
            "",
            "preamble text",
            "--BND",
            "Content-Type: text/plain; charset=us-ascii",
            "",
            "the plain part",
            "--BND",
            "Content-Type: text/html; charset=us-ascii",
            "",
            "<b>html</b> part",
            "--BND--",
            "",
        ].joined(separator: "\r\n")
        return Data(s.utf8)
    }

    private func buildMbox(_ messages: [Data]) -> (Data, [MboxRecord]) {
        var data = Data()
        var recs: [MboxRecord] = []
        for m in messages {
            let sep = Data("From ???@??? Thu Jan 01 00:00:00 1970\r\n".utf8)
            let start = data.count
            data.append(sep)
            data.append(m)
            recs.append(MboxRecord(offset: start, length: data.count - start))
        }
        return (data, recs)
    }

    private typealias TocTuple = (offset: Int, length: Int, status: Int, priority: Int,
                                  date: String, to: String, subject: String)

    private func tocEntry(_ rec: MboxRecord, status: Int, priority: Int, subject: String) -> TocTuple {
        (offset: rec.offset, length: rec.length, status: status, priority: priority,
         date: "Mon Jan 01 2001", to: "me@example.com", subject: subject)
    }

    private func writeToc(url: URL, entries: [TocTuple]) throws {
        var data = Data(count: 104)          // folder header (zero-filled is fine for reading)
        for e in entries {
            var b = [UInt8](repeating: 0, count: 218)
            putU32LE(&b, 0, UInt32(e.offset))
            putU32LE(&b, 4, UInt32(e.length))
            b[12] = UInt8(e.status)
            b[16] = UInt8(e.priority)
            putCString(&b, 18, 32, e.date)
            putCString(&b, 50, 64, e.to)
            putCString(&b, 114, 64, e.subject)
            data.append(contentsOf: b)
        }
        try data.write(to: url)
    }

    private func putU32LE(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
        b[i] = UInt8(v & 0xff)
        b[i + 1] = UInt8((v >> 8) & 0xff)
        b[i + 2] = UInt8((v >> 16) & 0xff)
        b[i + 3] = UInt8((v >> 24) & 0xff)
    }

    private func putCString(_ b: inout [UInt8], _ start: Int, _ len: Int, _ s: String) {
        let bytes = Array(s.utf8).prefix(len - 1)
        for (k, byte) in bytes.enumerated() { b[start + k] = byte }
    }
}

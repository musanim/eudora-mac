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
            "In,In,I,N",
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

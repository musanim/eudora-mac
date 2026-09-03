import XCTest
import Foundation
import EudoraStore
@testable import EudoraSearch

/// Builds a tiny tree in a temp dir, indexes it into an in-memory FTS5 db, and
/// checks search behaviour: body match, diacritic folding, HTML indexing,
/// column filters, and no-match. The fixture writes no `.toc`, so the indexer's
/// cached-date fallback is inert here — `MailStoreCachedDatesTests` covers that
/// side, and the closure below only pins the parameter's shape.
final class EudoraSearchTests: XCTestCase {
    var root: URL!
    var index: SearchIndex!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try buildFixture()
        index = try SearchIndex(path: ":memory:")
        try index.rebuild(from: MailStore(root: root),
                          // Enough of Eudora's cached format for the fixture; the
                          // app hands down `EudoraDateFormat.tocDate`.
                          cachedDateEpoch: { cached in
                              let f = DateFormatter()
                              f.locale = Locale(identifier: "en_US_POSIX")
                              f.dateFormat = "hh:mm a M/d/yyyy"
                              return f.date(from: cached).map { Int($0.timeIntervalSince1970) } ?? 0
                          })
    }

    override func tearDownWithError() throws {
        index = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testIndexCount() throws {
        XCTAssertEqual(try index.count(), 3)
    }

    func testBodyMatch() throws {
        let hits = try index.search("paddle")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.mailbox, "In")
        XCTAssertTrue(hits.first?.subject.contains("Baidarka") ?? false)
    }

    func testDiacriticFold() throws {
        // Body is UTF-8 ("Café") mislabeled iso-8859-1; must still be searchable
        // as "cafe" thanks to charset repair + remove_diacritics tokenizer.
        let hits = try index.search("cafe")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.subject, "Cafe")
    }

    func testHTMLIndexed() throws {
        let hits = try index.search("fugue")   // inside <b>Fugue</b>
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.subject, "Newsletter")
    }

    func testColumnFilter() throws {
        XCTAssertEqual(try index.search("subject:baidarka").count, 1)
        XCTAssertEqual(try index.search("subject:paddle").count, 0)  // paddle is body, not subject
    }

    func testNoMatch() throws {
        XCTAssertEqual(try index.search("zzznotpresent").count, 0)
    }

    /// The case that motivated the Body target: every delivered message carries
    /// a `Received: … for <recipient>` trace line, so an Anywhere search for a
    /// phrase beginning "for " matches the whole tree. Body must not see it.
    func testBodyTargetIgnoresHeaders() throws {
        func hits(_ target: TextTarget, _ value: String) throws -> Int {
            try index.search(SearchQuery(criteria: [
                .text(target: target, op: .contains, value: value)
            ])).count
        }
        XCTAssertEqual(try hits(.anywhere, "for me"), 3)   // the Received: line
        XCTAssertEqual(try hits(.body, "for me"), 0)
        XCTAssertEqual(try hits(.body, "paddle"), 1)
        XCTAssertEqual(try hits(.body, "baidarka"), 0)     // subject only
        XCTAssertEqual(try hits(.body, "kayak"), 0)        // sender only
    }

    /// Attachment name covers all three records Eudora leaves: a detached
    /// attachment's `Attachment Converted:` note (m1), a sent copy's
    /// `X-Attachments:` header (m2), and a real MIME part (m3). Bare filenames,
    /// not the recorded paths.
    func testAttachmentTargetSeesAllThreeRecords() throws {
        func hits(_ target: TextTarget, _ value: String) throws -> Int {
            try index.search(SearchQuery(criteria: [
                .text(target: target, op: .contains, value: value)
            ])).count
        }
        XCTAssertEqual(try hits(.attachment, "boat plan.pdf"), 1) // detached
        XCTAssertEqual(try hits(.attachment, "tuning.zip"), 1)    // recorded on send
        XCTAssertEqual(try hits(.attachment, "score.png"), 1)     // MIME part
        XCTAssertEqual(try hits(.attachment, "Attach\\"), 0)      // directory dropped
        XCTAssertEqual(try hits(.attachment, "paddle"), 0)        // body text isn't a name
        XCTAssertEqual(try hits(.anywhere, "tuning.zip"), 1)
    }

    // MARK: fixture

    private func buildFixture() throws {
        // Each carries an attachment in a different one of Eudora's three
        // records; see `testAttachmentTargetSeesAllThreeRecords`.
        let m1 = message(from: "alice@kayak.org", subject: "Baidarka build night",
                         ctype: "text/plain; charset=us-ascii",
                         body: "Bring your Greenland paddle.\r\n"
                             + "Attachment Converted: \"C:\\Eudora\\Attach\\boat plan.pdf\"")
        let m2 = message(from: "euro@example.fr", subject: "Cafe",
                         ctype: "text/plain; charset=iso-8859-1",   // lie: body is UTF-8
                         extraHeaders: ["X-Attachments: C:\\DEV\\TUNING.ZIP;"],
                         body: "Fee: 5€. Café résumé.")
        let m3 = message(from: "news@example.com", subject: "Newsletter",
                         ctype: "multipart/mixed; boundary=\"BND\"",
                         body: [
                             "--BND",
                             "Content-Type: text/html; charset=us-ascii",
                             "",
                             "<html><body><b>Fugue</b> in G minor</body></html>",
                             "--BND",
                             "Content-Type: image/png; name=\"score.png\"",
                             "Content-Disposition: attachment; filename=\"score.png\"",
                             "Content-Transfer-Encoding: base64",
                             "",
                             "iVBORw0KGgo=",
                             "--BND--",
                         ].joined(separator: "\r\n"))
        try buildMbox([m1, m2, m3]).write(to: root.appendingPathComponent("In.mbx"))

        let descmap = "In,In,I,N\r\n"
        try Data(descmap.utf8).write(to: root.appendingPathComponent("descmap.pce"))
    }

    private func message(from: String, subject: String, ctype: String,
                         extraHeaders: [String] = [], body: String) -> Data {
        let head = ([
            "Received: from mx.example.com by mail.example.com",
            "\tfor me@example.com; Mon, 01 Jan 2001 00:00:00 +0000",
            "From: \(from)",
            "To: me@example.com",
            "Subject: \(subject)",
            "Date: Mon, 01 Jan 2001 00:00:00 +0000",
            "Content-Type: \(ctype)",
        ] + extraHeaders).joined(separator: "\r\n") + "\r\n\r\n"
        return Data((head + body + "\r\n").utf8)
    }

    private func buildMbox(_ messages: [Data]) -> Data {
        var data = Data()
        for m in messages {
            data.append(Data("From ???@??? Thu Jan 01 00:00:00 1970\r\n".utf8))
            data.append(m)
        }
        return data
    }
}

import XCTest
import Foundation
import EudoraStore
@testable import EudoraSearch

/// Builds a tiny tree in a temp dir, indexes it into an in-memory FTS5 db, and
/// checks search behaviour: body match, diacritic folding, HTML indexing,
/// column filters, and no-match. No `.toc` needed (indexing scans the `.mbx`).
final class EudoraSearchTests: XCTestCase {
    var root: URL!
    var index: SearchIndex!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try buildFixture()
        index = try SearchIndex(path: ":memory:")
        try index.rebuild(from: MailStore(root: root))
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

    // MARK: fixture

    private func buildFixture() throws {
        let m1 = message(from: "alice@kayak.org", subject: "Baidarka build night",
                         ctype: "text/plain; charset=us-ascii",
                         body: "Bring your Greenland paddle.")
        let m2 = message(from: "euro@example.fr", subject: "Cafe",
                         ctype: "text/plain; charset=iso-8859-1",   // lie: body is UTF-8
                         body: "Fee: 5€. Café résumé.")
        let m3 = message(from: "news@example.com", subject: "Newsletter",
                         ctype: "text/html; charset=us-ascii",
                         body: "<html><body><b>Fugue</b> in G minor</body></html>")
        try buildMbox([m1, m2, m3]).write(to: root.appendingPathComponent("In.mbx"))

        let descmap = "In,In,I,N\r\n"
        try Data(descmap.utf8).write(to: root.appendingPathComponent("descmap.pce"))
    }

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

    private func buildMbox(_ messages: [Data]) -> Data {
        var data = Data()
        for m in messages {
            data.append(Data("From ???@??? Thu Jan 01 00:00:00 1970\r\n".utf8))
            data.append(m)
        }
        return data
    }
}

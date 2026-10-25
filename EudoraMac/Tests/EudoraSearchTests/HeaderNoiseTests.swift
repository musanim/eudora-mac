import XCTest
import Foundation
import EudoraStore
@testable import EudoraSearch

/// A Headers search must find only what someone could see, and its result row
/// must show where. Prompted 2026oct25 by "zzyzx" matching a State Department
/// message through the `ZzYzx` inside its `IronPort-Data:` base64 blob.
final class HeaderNoiseTests: XCTestCase {

    private let blob = "E+vN5anmZgD6qe4QKa7X6ZWBihpfKMkSvqkAqm8A87ko0HOMfUURsqnaQpfAvm"
    private let blobWithZzyzx = "fpj67q3cz8EBqKZzYzxUzEAe81/FYB51ZrjDEjn6IqI0Avm"

    // MARK: what is stripped

    func testBase64BlobIsStripped() {
        let v = ContentExtractor.searchableHeaderValue(
            name: "IronPort-Data", value: "A9a23:\(blob) \(blobWithZzyzx)")
        XCTAssertEqual(v, "A9a23:\u{2026} \u{2026}")
    }

    func testDKIMKeepsItsTagsAndLosesItsSignature() {
        let v = ContentExtractor.searchableHeaderValue(
            name: "DKIM-Signature", value: "v=1; d=state.gov; bh=\(blob)==; b=\(blobWithZzyzx)")
        XCTAssertEqual(v, "v=1; d=state.gov; bh=\u{2026}; b=\u{2026}")
    }

    /// Long runs of letters alone are sometimes words. Real, from the tree.
    func testLongWordsSurvive() {
        let welsh = "Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch"
        XCTAssertEqual(ContentExtractor.searchableHeaderValue(name: "Subject", value: welsh), welsh)
        let path = "/Users/stephenmalinowski/Documents/Active/Correspondence"
        XCTAssertEqual(ContentExtractor.searchableHeaderValue(name: "X-Whatever", value: path), path)
    }

    func testShortRunsSurvive() {
        let v = "Zzyzx Saxophone Quartet <zzyzxquartet@gmail.com>"
        XCTAssertEqual(ContentExtractor.searchableHeaderValue(name: "From", value: v), v)
        // Hyphens and dots break a run, so slugs and hostnames are never one.
        let slug = "passport-application-status-update-2026-for-applicant"
        XCTAssertEqual(ContentExtractor.searchableHeaderValue(name: "List-Id", value: slug), slug)
    }

    /// Identifiers someone might paste into Find on purpose.
    func testExemptHeadersAreUntouched() {
        let id = "<CAH9\(blob)@mail.gmail.com>"
        XCTAssertEqual(ContentExtractor.searchableHeaderValue(name: "Message-ID", value: id), id)
        XCTAssertEqual(ContentExtractor.searchableHeaderValue(name: "references", value: id), id)
        let path = "/Users/s/mam/MAMFileRender/RESOURCES/Bach/bwv894/score2026final.pdf"
        XCTAssertEqual(ContentExtractor.searchableHeaderValue(name: "X-Attachments", value: path), path)
    }

    // MARK: the index, end to end

    private var root: URL!
    private var index: SearchIndex!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-noise-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let passport = message(subject: "Passport Application Status",
                               extra: ["IronPort-Data: A9a23:\(blob)\r\n \(blobWithZzyzx)"],
                               body: "Your application is in process.")
        let quartet = message(subject: "Concert",
                              extra: ["Cc: Zzyzx Saxophone Quartet <zzyzxquartet@gmail.com>"],
                              body: "See you there.")
        let trip = message(subject: "Trip",
                           extra: ["X-Destination: Zzyzx Road"],
                           body: "We drove past Zzyzx on the way to Vegas.")
        var mbox = Data()
        for m in [passport, quartet, trip] {
            mbox.append(Data("From ???@??? Thu Jan 01 00:00:00 1970\r\n".utf8))
            mbox.append(m)
        }
        try mbox.write(to: root.appendingPathComponent("In.mbx"))
        try Data("In,In,I,N\r\n".utf8).write(to: root.appendingPathComponent("descmap.pce"))

        index = try SearchIndex(path: ":memory:")
        try index.rebuild(from: MailStore(root: root), cachedDateEpoch: { _ in 0 })
    }

    override func tearDownWithError() throws {
        index = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func message(subject: String, extra: [String], body: String) -> Data {
        let head = ([
            "From: someone@example.com",
            "To: me@example.com",
            "Subject: \(subject)",
            "Date: Mon, 01 Jan 2001 00:00:00 +0000",
        ] + extra).joined(separator: "\r\n") + "\r\n\r\n"
        return Data((head + body + "\r\n").utf8)
    }

    private func find(_ target: TextTarget, _ value: String) throws -> [SearchHit] {
        try index.search(SearchQuery(criteria: [.text(target: target, op: .contains, value: value)]))
    }

    func testBlobHitIsGone() throws {
        let subjects = try find(.headers, "zzyzx").map(\.subject).sorted()
        XCTAssertEqual(subjects, ["Concert", "Trip"])
        XCTAssertEqual(try find(.anywhere, "zzyzx").map(\.subject).sorted(), ["Concert", "Trip"])
    }

    /// The match is shown, header name and all — not a body preview that
    /// doesn't contain it.
    func testHeaderHitShowsItsHeaderLine() throws {
        let hit = try XCTUnwrap(find(.headers, "zzyzx").first { $0.subject == "Concert" })
        XCTAssertTrue(hit.snippet.hasPrefix("Cc: "), hit.snippet)
        XCTAssertTrue(hit.snippet.localizedCaseInsensitiveContains("zzyzx"), hit.snippet)
    }

    /// A Headers search shows the header even when the body has the word too;
    /// a Body or Anywhere search prefers the body.
    func testTheSearchedColumnWins() throws {
        let headers = try XCTUnwrap(find(.headers, "zzyzx").first { $0.subject == "Trip" })
        XCTAssertTrue(headers.snippet.hasPrefix("X-Destination: "), headers.snippet)
        let anywhere = try XCTUnwrap(find(.anywhere, "zzyzx").first { $0.subject == "Trip" })
        XCTAssertTrue(anywhere.snippet.hasPrefix("We drove past"), anywhere.snippet)
    }

    /// A match far into a long header value keeps the header's name.
    func testLongHeaderValueKeepsItsName() {
        let stored = SearchIndex.StoredText(
            body: "", headers: "X-Long: " + String(repeating: "word ", count: 60) + "zzyzx end",
            sender: "", recipients: "", attachments: "")
        let s = SearchIndex.snippet(for: stored, focus: (target: .headers, term: "zzyzx"))
        XCTAssertTrue(s.hasPrefix("X-Long: \u{2026}"), s)
        XCTAssertTrue(s.contains("zzyzx"), s)
    }

    /// The subject has its own results column, so outside a Headers search a
    /// subject-only match gets the body preview rather than the subject again.
    func testSubjectOnlyMatchIsNotRepeated() {
        let stored = SearchIndex.StoredText(
            body: "hello there", headers: "From: a@b.c\nSubject: zzyzx news",
            sender: "a@b.c", recipients: "", attachments: "")
        XCTAssertEqual(SearchIndex.snippet(for: stored, focus: (target: .anywhere, term: "zzyzx")),
                       "hello there")
        XCTAssertEqual(SearchIndex.snippet(for: stored, focus: (target: .headers, term: "zzyzx")),
                       "Subject: zzyzx news")
    }

    /// A row found by "does not contain" has nothing to point at.
    func testNegativeCriterionGetsTheBodyPreview() {
        XCTAssertNil(SearchIndex.firstTextCriterion([.text(target: .headers, op: .doesNotContain, value: "x")]))
    }
}

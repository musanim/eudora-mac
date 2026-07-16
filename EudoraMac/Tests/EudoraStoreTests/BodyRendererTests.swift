import XCTest
import Foundation
@testable import EudoraStore

/// Covers the `<img>`-to-box rewriting and the embedded-image registry that the
/// view uses to resolve `eudora-image:` clicks. See design-decisions §1–§3.
final class BodyRendererTests: XCTestCase {

    /// Parse a raw message and return (top-level part, decoded first text/html body).
    private func parse(_ raw: String) -> (MIMEPart, String) {
        let part = MIMEParser.parse(Array(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        let html = part.walk().first { $0.mainType == "text" && $0.subType == "html" }
        let text = html.map { String(decoding: $0.decodedPayload(), as: UTF8.self) } ?? ""
        return (part, text)
    }

    // Remote images become an unviewable skull box; nothing is fetched, and the
    // real URL is preserved (in the href) for the copy affordance.
    func testRemoteImageBecomesBlockedBox() {
        let raw = """
        Content-Type: text/html; charset=us-ascii

        <p><img src="http://evil.example/pixel.gif"> hi</p>
        <a href="http://real.example/dest">click here</a>
        """
        let (msg, html) = parse(raw)
        let r = BodyRenderer.rewrite(html: html, in: msg)

        XCTAssertFalse(r.html.lowercased().contains("<img"), "no raw <img> should survive")
        XCTAssertTrue(r.html.contains("class=\"eu-remote\""))
        XCTAssertTrue(r.html.contains("http://evil.example/pixel.gif"))
        // Text links are left intact — the view enforces the link policy.
        XCTAssertTrue(r.html.contains("<a href=\"http://real.example/dest\">click here</a>"))
        XCTAssertTrue(r.images.isEmpty)
    }

    // A cid: reference resolves to the embedded part's bytes and yields a
    // viewable box pointing at the private scheme.
    func testCidImageBecomesViewBoxWithRegistry() {
        let raw = """
        MIME-Version: 1.0
        Content-Type: multipart/related; boundary="B"

        --B
        Content-Type: text/html; charset=us-ascii

        <p><img src="cid:img1@host"></p>
        --B
        Content-Type: image/png
        Content-Transfer-Encoding: base64
        Content-ID: <img1@host>

        iVBORw==
        --B--
        """
        let (msg, html) = parse(raw)
        let r = BodyRenderer.rewrite(html: html, in: msg)

        XCTAssertTrue(r.html.contains("class=\"eu-image\""))
        XCTAssertTrue(r.html.contains("eudora-image:eu-img-1"))
        XCTAssertEqual(r.images.count, 1)
        XCTAssertEqual(r.images["eu-img-1"]?.data, Data([0x89, 0x50, 0x4e, 0x47]))
        XCTAssertEqual(r.images["eu-img-1"]?.mimeType, "image/png")
    }

    // data: URIs carry their own bytes; they get pulled out of the HTML into
    // the registry and shown as a view box (kept out of the rendered markup).
    func testDataURIBecomesViewBox() {
        let raw = """
        Content-Type: text/html; charset=us-ascii

        <img src="data:image/png;base64,iVBORw==">
        """
        let (msg, html) = parse(raw)
        let r = BodyRenderer.rewrite(html: html, in: msg)

        XCTAssertTrue(r.html.contains("class=\"eu-image\""))
        XCTAssertFalse(r.html.contains("data:image"), "the data blob should not remain inline")
        XCTAssertEqual(r.images.count, 1)
        XCTAssertEqual(r.images.values.first?.data, Data([0x89, 0x50, 0x4e, 0x47]))
    }

    // A cid: that names no part, and an <img> with no src, both degrade to the
    // neutral unavailable box — never a fetch.
    func testUnresolvableImagesBecomeUnavailable() {
        let raw = """
        Content-Type: text/html; charset=us-ascii

        <img src="cid:missing@host"> <img width="10">
        """
        let (msg, html) = parse(raw)
        let r = BodyRenderer.rewrite(html: html, in: msg)

        XCTAssertFalse(r.html.lowercased().contains("<img"))
        let count = r.html.components(separatedBy: "eu-broken").count - 1
        XCTAssertEqual(count, 2)
        XCTAssertTrue(r.images.isEmpty)
    }

    // Attribute escaping: a URL with & and quotes stays safe in the href.
    func testAttributeEscaping() {
        let raw = """
        Content-Type: text/html; charset=us-ascii

        <img src="http://x.example/a?b=1&c=2">
        """
        let (msg, html) = parse(raw)
        let r = BodyRenderer.rewrite(html: html, in: msg)
        XCTAssertTrue(r.html.contains("a?b=1&amp;c=2"))
    }
}

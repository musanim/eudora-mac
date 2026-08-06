import XCTest
@testable import EudoraStore

/// Images pasted into a draft body: the model, the `cid:` HTML, the
/// `multipart/related` assembly, and — the part that matters most — that a
/// message survives being saved and reopened over and over unchanged.
///
/// The AppKit half (the paste itself, and `NSTextAttachment` conversion) can't
/// be reached from here; it lives in `EudoraRichText` and the app. Everything
/// below is what `swift test` can actually prove.
final class RichTextImageTests: XCTestCase {

    // A one-pixel PNG, and a different one, so identity has something to
    // distinguish. Only the leading magic bytes need to be real.
    private let pngA = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(0..<64))
    private let pngB = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(64..<128))

    private func image(_ data: Data, _ type: String = "image/png") -> RichTextImage {
        RichTextImage(mimeType: type, data: data)
    }

    // MARK: - the model

    /// Identity is the content hash, so the same bytes are the same image
    /// whether or not they arrived by the same route.
    func testIdentityIsTheContent() {
        XCTAssertEqual(image(pngA).id, image(pngA).id)
        XCTAssertNotEqual(image(pngA).id, image(pngB).id)
        XCTAssertEqual(image(pngA), image(pngA))
        XCTAssertNotEqual(image(pngA), image(pngB))
        XCTAssertEqual(image(pngA).id.count, 32)          // 128 bits, hex
    }

    /// `==` must not walk the bytes — it runs on every keystroke through
    /// `ComposeView.isDirty`. Two images with the same id compare equal even if
    /// one is handed different data, which is the observable consequence of
    /// comparing the hash rather than the content.
    func testEqualityDoesNotCompareBytes() {
        let real = image(pngA)
        let impostor = RichTextImage(id: real.id, mimeType: "image/png", data: pngB)
        XCTAssertEqual(real, impostor)
    }

    /// The placeholder is not text the user typed, so the plain alternative
    /// must not carry it — a reader showing only `text/plain` would otherwise
    /// see a stray glyph where the picture was.
    func testPlainTextDropsThePlaceholder() {
        let rich = RichText(runs: [RichTextRun("before "),
                                   RichTextRun(image: image(pngA)),
                                   RichTextRun(" after")])
        XCTAssertEqual(rich.plainText, "before  after")
        XCTAssertFalse(rich.plainText.contains("\u{FFFC}"))
    }

    /// An image forces HTML, whatever the styling. There is no way to put one
    /// in a `text/plain` body.
    func testAnImageMakesTheMessageStyled() {
        XCTAssertFalse(RichText(plain: "hello").isStyled)
        XCTAssertTrue(RichText(runs: [RichTextRun("hello"),
                                      RichTextRun(image: image(pngA))]).isStyled)
    }

    /// Two adjacent images share the plain style. Without the guard in
    /// `normalize` they would merge into one run holding two placeholders and a
    /// single image — losing a picture, and leaving a placeholder pointing at
    /// nothing.
    func testAdjacentImagesDoNotMerge() {
        let rich = RichText(runs: [RichTextRun(image: image(pngA)),
                                   RichTextRun(image: image(pngB))])
        XCTAssertEqual(rich.runs.count, 2)
        XCTAssertEqual(rich.images.count, 2)
    }

    /// The same picture pasted twice is one MIME part referred to twice.
    func testRepeatedImageIsCollectedOnce() {
        let rich = RichText(runs: [RichTextRun(image: image(pngA)),
                                   RichTextRun(" and again "),
                                   RichTextRun(image: image(pngA))])
        XCTAssertEqual(rich.runs.count, 3)
        XCTAssertEqual(rich.images.count, 1)
    }

    // MARK: - HTML

    func testHTMLEmitsACIDReference() {
        let img = image(pngA)
        let html = RichTextHTML.html(from: RichText(runs: [RichTextRun(image: img)]))
        XCTAssertTrue(html.contains("<img src=\"cid:\(img.id)\""), html)
    }

    /// The no-resolver overload drops images rather than inventing them — that
    /// is what every caller outside the composer wants, and it keeps the old
    /// signature working.
    func testParseWithoutAResolverDropsImages() {
        let img = image(pngA)
        let html = RichTextHTML.html(from: RichText(runs: [RichTextRun("hi "),
                                                           RichTextRun(image: img)]))
        let back = RichTextHTML.parse(html)
        XCTAssertTrue(back.images.isEmpty)
        XCTAssertTrue(back.plainText.contains("hi"))
        XCTAssertFalse(back.plainText.contains("\u{FFFC}"))
    }

    func testParseResolvesACIDReference() {
        let img = image(pngA)
        let html = RichTextHTML.html(from: RichText(runs: [RichTextRun("look: "),
                                                           RichTextRun(image: img)]))
        let back = RichTextHTML.parse(html) { src in
            src == "cid:\(img.id)" ? img : nil
        }
        XCTAssertEqual(back.images, [img])
        XCTAssertTrue(back.plainText.contains("look:"))
        XCTAssertFalse(back.plainText.contains("\u{FFFC}"))
        XCTAssertTrue(back.runs.last?.isImage == true)
    }

    // MARK: - assembly

    private let date = Date(timeIntervalSince1970: 1_784_000_000)
    private let messageID = "<fixed@example.com>"

    private func message(with rich: RichText) -> OutgoingMessage {
        OutgoingMessage(fromName: "Stephen", fromAddress: "stephen@example.com",
                        to: ["you@example.com"], subject: "Hello",
                        body: rich.plainText,
                        htmlBody: RichTextHTML.html(from: rich),
                        inlineImages: rich.images)
    }

    func testEmbeddedImageBecomesMultipartRelated() {
        let rich = RichText(runs: [RichTextRun("see: "), RichTextRun(image: image(pngA))])
        let part = MIMEParser.parse(Array(message(with: rich)
            .rfc822(date: date, messageID: messageID).data))

        XCTAssertEqual(part.contentType, "multipart/related")
        XCTAssertEqual(part.children.count, 2)
        XCTAssertEqual(part.children[0].contentType, "multipart/alternative")
        XCTAssertEqual(part.children[0].children.map(\.contentType),
                       ["text/plain", "text/html"])
        XCTAssertEqual(part.children[1].contentType, "image/png")
        XCTAssertEqual(Data(part.children[1].decodedPayload()), pngA)
    }

    /// The embedded part must not look like an attachment, or reopening the
    /// draft would move the picture onto the paperclip row and the next save
    /// would send it both ways.
    func testEmbeddedImageIsNotAnAttachment() {
        let rich = RichText(runs: [RichTextRun(image: image(pngA))])
        let part = MIMEParser.parse(Array(message(with: rich)
            .rfc822(date: date, messageID: messageID).data))
        let picture = part.children[1]
        XCTAssertFalse(picture.isAttachment)
        XCTAssertNil(picture.filename)
        XCTAssertEqual(picture.header("Content-ID"), "<\(image(pngA).id)>")
    }

    /// With attachments as well, the related group is one part of the mixed
    /// wrapper rather than a sibling of the files — otherwise a reader shows
    /// each picture twice, inline and as a paperclip.
    func testEmbeddedImageAlongsideAnAttachmentNestsInsideMixed() {
        var m = message(with: RichText(runs: [RichTextRun(image: image(pngA))]))
        m.attachments = [.init(filename: "notes.txt", mimeType: "text/plain",
                               data: Data("hi".utf8))]
        let part = MIMEParser.parse(Array(m.rfc822(date: date, messageID: messageID).data))

        XCTAssertEqual(part.contentType, "multipart/mixed")
        XCTAssertEqual(part.children.count, 2)
        XCTAssertEqual(part.children[0].contentType, "multipart/related")
        XCTAssertEqual(part.children[0].children[0].contentType, "multipart/alternative")
        XCTAssertEqual(part.children[1].filename, "notes.txt")
    }

    /// The guarantee: a message with no image assembles exactly as before.
    func testNoImageChangesNothing() {
        let styled = RichText(runs: [RichTextRun("hi", style: RichTextStyle(bold: true))])
        let part = MIMEParser.parse(Array(message(with: styled)
            .rfc822(date: date, messageID: messageID).data))
        XCTAssertEqual(part.contentType, "multipart/alternative")

        let plain = OutgoingMessage(fromName: "Stephen", fromAddress: "s@example.com",
                                    to: ["you@example.com"], subject: "Hello", body: "Hi there")
        let text = String(decoding: plain.rfc822(date: date, messageID: messageID).data,
                          as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Type: text/plain; charset=us-ascii"), text)
        XCTAssertFalse(text.contains("multipart"), text)
    }

    // MARK: - the round trip

    /// Save, reopen, save again — four times — and nothing drifts.
    ///
    /// This is the test the whole feature rests on, and the shape of failure it
    /// guards against is the one that has already bitten this codebase twice:
    /// something re-derived on each pass that doesn't come out the same.
    /// If the re-hashed id differed from the written `Content-ID`, the second
    /// reopen would find a `cid:` matching nothing and the picture would vanish.
    func testSaveAndReopenIsStable() throws {
        var rich = RichText(runs: [RichTextRun("look: "),
                                   RichTextRun(image: image(pngA)),
                                   RichTextRun(" and "),
                                   RichTextRun(image: image(pngB))])
        let firstHTML = RichTextHTML.html(from: rich)

        for pass in 1...4 {
            let part = MIMEParser.parse(Array(message(with: rich)
                .rfc822(date: date, messageID: messageID).data))

            // Reopen: collect the images, then parse the HTML against them —
            // the same two steps `AppModel.styledBody` performs.
            var byCID: [String: RichTextImage] = [:]
            for p in part.walk() where !p.isMultipart && p.mainType == "image" {
                let raw = try XCTUnwrap(p.header("Content-ID"))
                let id = String(raw.dropFirst().dropLast())     // strip <>
                byCID[id] = RichTextImage(mimeType: p.contentType, data: Data(p.decodedPayload()))
            }
            XCTAssertEqual(byCID.count, 2, "pass \(pass)")

            let htmlPart = try XCTUnwrap(part.walk().first {
                !$0.isMultipart && $0.mainType == "text" && $0.subType == "html"
            })
            let html = String(decoding: htmlPart.decodedPayload(), as: UTF8.self)
            rich = RichTextHTML.parse(html) { src in
                guard src.lowercased().hasPrefix("cid:") else { return nil }
                return byCID[String(src.dropFirst(4))]
            }

            XCTAssertEqual(rich.images.count, 2, "pass \(pass)")
            // The words survive and the placeholder never leaks into the plain
            // alternative. Exact spacing is deliberately not asserted: `encode`
            // holds runs of spaces open with `&nbsp;`, so the whitespace either
            // side of an image is settled by HTML's rules rather than by us.
            // What must hold is that it stops changing, which the next line pins.
            XCTAssertTrue(rich.plainText.contains("look:"), "pass \(pass)")
            XCTAssertTrue(rich.plainText.contains("and"), "pass \(pass)")
            XCTAssertFalse(rich.plainText.contains("\u{FFFC}"), "pass \(pass)")
            XCTAssertEqual(RichTextHTML.html(from: rich), firstHTML, "pass \(pass)")
        }

        // And the bytes really did come back, not just the references.
        XCTAssertEqual(Set(rich.images.map(\.data)), [pngA, pngB])
    }
}

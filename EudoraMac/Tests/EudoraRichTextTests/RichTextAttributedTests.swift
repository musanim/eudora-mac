import XCTest
import AppKit
@testable import EudoraRichText
import EudoraStore

/// The composer's `RichText` ⇄ `NSAttributedString` bridge.
///
/// The property that matters most is at the bottom: text edited in the default
/// face, size and colour must read back as `RichTextStyle.plain`, because that
/// is what keeps an unformatted message out of MIME. Everything above builds up
/// to being able to trust it.
final class RichTextAttributedTests: XCTestCase {

    private let defaults = RichTextDefaults(family: "Arial", size: 12)

    // MARK: - RichText → attributed

    func testPlainRunGetsTheDefaultFontAndNoColour() {
        let attr = RichTextAttributed.attributed(RichText(plain: "hello"), defaults: defaults)
        var range = NSRange()
        let font = attr.attribute(.font, at: 0, effectiveRange: &range) as? NSFont
        XCTAssertEqual(font?.familyName, "Arial")
        XCTAssertEqual(font?.pointSize, 12)
        XCTAssertNil(attr.attribute(.foregroundColor, at: 0, effectiveRange: &range))
        XCTAssertEqual(range.length, 5)
    }

    func testBoldRunResolvesToABoldFont() {
        let rich = RichText(runs: [RichTextRun("x", style: RichTextStyle(bold: true))])
        let attr = RichTextAttributed.attributed(rich, defaults: defaults)
        let font = attr.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testColouredRunCarriesThatColour() {
        let rich = RichText(runs: [
            RichTextRun("x", style: RichTextStyle(color: RichTextColor(r: 255, g: 0, b: 0)))])
        let attr = RichTextAttributed.attributed(rich, defaults: defaults)
        let color = (attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor)
            .usingColorSpace(.sRGB)!
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.001)
    }

    // MARK: - the relativity property

    func testDefaultFaceSizeAndColourReadBackAsPlain() {
        let attr = NSAttributedString(string: "just typing", attributes: [
            .font: NSFont(name: "Arial", size: 12)!,
            .foregroundColor: NSColor.textColor,
        ])
        let rich = RichTextAttributed.richText(attr, defaults: defaults)
        XCTAssertFalse(rich.isStyled, "default-styled text must not become MIME")
        XCTAssertEqual(rich.plainText, "just typing")
    }

    func testExplicitBlackIsTreatedAsTheDefault() {
        let attr = NSAttributedString(string: "x", attributes: [
            .font: NSFont(name: "Arial", size: 12)!,
            .foregroundColor: NSColor.black,
        ])
        XCTAssertFalse(RichTextAttributed.richText(attr, defaults: defaults).isStyled)
    }

    func testNoFontAttributeIsTreatedAsTheDefault() {
        let attr = NSAttributedString(string: "x")   // NSTextView leaves runs fontless sometimes
        XCTAssertFalse(RichTextAttributed.richText(attr, defaults: defaults).isStyled)
    }

    func testADifferentFaceIsRecorded() {
        let attr = NSAttributedString(string: "x", attributes: [
            .font: NSFont(name: "Courier New", size: 12) ?? NSFont(name: "Courier", size: 12)!])
        let style = RichTextAttributed.richText(attr, defaults: defaults).runs[0].style
        XCTAssertNotNil(style.face)
        XCTAssertNil(style.size, "the size matched the default and should be nil")
    }

    func testADifferentSizeIsRecordedButTheDefaultFaceIsNot() {
        let attr = NSAttributedString(string: "x", attributes: [
            .font: NSFont(name: "Arial", size: 18)!])
        let style = RichTextAttributed.richText(attr, defaults: defaults).runs[0].style
        XCTAssertNil(style.face)
        XCTAssertEqual(style.size, 18)
    }

    func testBoldIsReadFromTheFontTraits() {
        let bold = NSFontManager.shared.convert(NSFont(name: "Arial", size: 12)!, toHaveTrait: .boldFontMask)
        let attr = NSAttributedString(string: "x", attributes: [.font: bold])
        let style = RichTextAttributed.richText(attr, defaults: defaults).runs[0].style
        XCTAssertTrue(style.bold)
        XCTAssertNil(style.face, "a bold Arial is still the Arial family")
        XCTAssertNil(style.size)
    }

    // MARK: - round trips through AppKit

    func testStyledRoundTripThroughAttributed() {
        let rich = RichText(runs: [
            RichTextRun("plain "),
            RichTextRun("bold", style: RichTextStyle(bold: true)),
            RichTextRun(" big", style: RichTextStyle(size: 24)),
            RichTextRun(" red", style: RichTextStyle(color: RichTextColor(r: 255, g: 0, b: 0))),
        ])
        let back = RichTextAttributed.richText(
            RichTextAttributed.attributed(rich, defaults: defaults), defaults: defaults)
        XCTAssertEqual(back, rich)
    }

    /// Synthetic italic on a face that has real italic is not used; on one that
    /// doesn't, obliqueness stands in and still reads back as italic.
    func testItalicRoundTripsWhetherRealOrSynthetic() {
        for face in ["Arial", "Courier New"] {
            let rich = RichText(runs: [
                RichTextRun("x", style: RichTextStyle(italic: true, face: face == "Arial" ? nil : face))])
            let attr = RichTextAttributed.attributed(rich, defaults: defaults)
            let back = RichTextAttributed.richText(attr, defaults: defaults)
            XCTAssertTrue(back.runs[0].style.italic, "\(face) italic lost in the round trip")
        }
    }

    func testEmptyRichTextIsAnEmptyString() {
        XCTAssertEqual(RichTextAttributed.attributed(RichText(plain: ""), defaults: defaults).length, 0)
        XCTAssertFalse(RichTextAttributed.richText(NSAttributedString(string: ""), defaults: defaults).isStyled)
    }
}

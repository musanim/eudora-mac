import XCTest
@testable import EudoraStore

final class RecipientLineBreaksTests: XCTestCase {

    private func starts(_ s: String) -> [Int] {
        RecipientLineBreaks.entryStarts(in: s).sorted()
    }

    func testABreakIsAllowedOnlyAtEachRecipientsFirstCharacter() {
        // "Bob" starts at 9, "c@z.com" at 30.
        XCTAssertEqual(starts("a@x.com, Bob Smith <b@y.com>; c@z.com"), [9, 30])
    }

    func testCommasInsideQuotesAndAnglesAreNotSeparators() {
        XCTAssertEqual(starts("\"Andrews, Cody\" <c@a.com>, d@e.com"), [27])
        XCTAssertEqual(starts("<odd,addr@x.com>, d@e.com"), [18])
        XCTAssertEqual(starts("\"5\\\" nails, sharp\" <n@x.com>, d@e.com"), [30])
    }

    func testNoSpaceAfterTheCommaStillStartsARecipient() {
        XCTAssertEqual(starts("a@x.com,b@y.com"), [8])
    }

    func testATrailingSeparatorStartsNothing() {
        XCTAssertEqual(starts("a@x.com, "), [])
    }

    func testOffsetsAreUTF16() {
        // "🎹" is two UTF-16 units, so the second recipient starts at 14, not 13.
        XCTAssertEqual(starts("🎹 <p@x.com>, q@y.com"), [14])
    }

    /// The only ordinary spaces left are the gaps after separators, and inside
    /// each recipient no two visible characters are adjacent without a word
    /// joiner between them.
    func testDisplayStringKeepsOnlyTheGapsBetweenRecipientsBreakable() {
        let shown = RecipientLineBreaks.displayString("Bob Smith <bob-s@x.com>, 山田太郎 <t@x.jp>")
        let pieces = shown.split(separator: " ")
        XCTAssertEqual(pieces.count, 2)
        for piece in pieces {
            let scalars = Array(piece.unicodeScalars)
            for (a, b) in zip(scalars, scalars.dropFirst()) {
                XCTAssertTrue(a == "\u{2060}" || b == "\u{2060}",
                              "breakable pair \(a)\(b) inside a recipient")
            }
        }
    }

    func testDisplayStringOfASingleRecipientHasNoOrdinarySpace() {
        XCTAssertFalse(RecipientLineBreaks.displayString("\"Andrews, Cody\" <c@a.com>").contains(" "))
    }

    func testDisplayStringLooksTheSameWithTheInvisiblesRemoved() {
        let raw = "Bob Smith <bob-s@x.com>,  Ann <a@y.com>; \"Lee, K\" <k@z.com>"
        let shown = RecipientLineBreaks.displayString(raw)
            .replacingOccurrences(of: "\u{2060}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertEqual(shown, raw)
    }
}

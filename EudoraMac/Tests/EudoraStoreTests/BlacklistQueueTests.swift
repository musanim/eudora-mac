import XCTest
@testable import EudoraStore

/// `BlacklistQueue` — the list of addresses waiting to go to the ISP.
///
/// The behaviour worth pinning is what survives *editing*, because editing is
/// the point: Stephen generalises `someone@spam.example` to `spam.example`,
/// deletes lines, and leaves whatever whitespace a paste brought with it. The
/// queue has to keep counting and de-duplicating sensibly through all of that.
final class BlacklistQueueTests: XCTestCase {

    func testAddAppendsOnePerLine() {
        var q = BlacklistQueue()
        XCTAssertTrue(q.add("a@x.com"))
        XCTAssertTrue(q.add("b@y.com"))
        XCTAssertEqual(q.entries, ["a@x.com", "b@y.com"])
        XCTAssertEqual(q.count, 2)
    }

    func testAddRefusesADuplicateWhateverItsCase() {
        var q = BlacklistQueue()
        XCTAssertTrue(q.add("Spammer@Example.COM"))
        XCTAssertFalse(q.add("spammer@example.com"))
        XCTAssertEqual(q.count, 1)
    }

    /// A hand-edited list is the normal case, not the exception.
    func testCountsAndDeduplicatesThroughHandEditing() {
        var q = BlacklistQueue(text: "  spam.example  \n\n\nother@z.com\n")
        XCTAssertEqual(q.entries, ["spam.example", "other@z.com"])
        XCTAssertFalse(q.add(" OTHER@z.com "), "trimming and case should both be seen")
        XCTAssertTrue(q.add("new@spam.example"),
                      "a domain line must not silently swallow an address inside it — "
                      + "what the ISP does with each line isn't ours to guess")
    }

    /// Appending to a list whose last line lost its newline during editing must
    /// not join two addresses into one.
    func testAddAfterAnUnterminatedLastLine() {
        var q = BlacklistQueue(text: "first@x.com")
        XCTAssertTrue(q.add("second@x.com"))
        XCTAssertEqual(q.entries, ["first@x.com", "second@x.com"])
    }

    func testAddIgnoresBlank() {
        var q = BlacklistQueue()
        XCTAssertFalse(q.add("   "))
        XCTAssertTrue(q.isEmpty)
    }

    /// What goes to the pasteboard is the tidied list, not the buffer: no blank
    /// lines, no indentation, and a trailing newline so a paste into a textarea
    /// can't join the last address to what follows it.
    func testPasteboardTextIsTidied() {
        let q = BlacklistQueue(text: "\n  a@x.com \n\n b@y.com\n\n")
        XCTAssertEqual(q.pasteboardText, "a@x.com\nb@y.com\n")
        XCTAssertEqual(BlacklistQueue().pasteboardText, "")
    }

    func testClear() {
        var q = BlacklistQueue(text: "a@x.com\n")
        q.clear()
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(q.text, "")
    }

    func testRoundTripsThroughCodable() throws {
        let q = BlacklistQueue(text: "a@x.com\nspam.example\n")
        let back = try JSONDecoder().decode(BlacklistQueue.self,
                                            from: JSONEncoder().encode(q))
        XCTAssertEqual(back, q)
    }
}

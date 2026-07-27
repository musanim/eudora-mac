import XCTest
@testable import EudoraStore

final class TextCorrectionsTests: XCTestCase {

    func testSetAddsUpdatesAndKeepsOneRulePerTrigger() {
        var c = TextCorrections()
        XCTAssertTrue(c.set(trigger: "Bjork", replacement: "Björk"))
        XCTAssertTrue(c.set(trigger: "teh", replacement: "the"))
        // Same trigger updates in place, doesn't duplicate.
        XCTAssertTrue(c.set(trigger: "Bjork", replacement: "BJÖRK"))
        XCTAssertEqual(c.rules.count, 2)
        XCTAssertEqual(c.replacement(for: "Bjork"), "BJÖRK")
        // Insertion order preserved.
        XCTAssertEqual(c.rules.map(\.trigger), ["Bjork", "teh"])
    }

    func testSetIgnoresBlankAndSelfReplacement() {
        var c = TextCorrections()
        XCTAssertFalse(c.set(trigger: "   ", replacement: "x"))
        XCTAssertFalse(c.set(trigger: "x", replacement: "  "))
        XCTAssertFalse(c.set(trigger: "same", replacement: "same"))
        XCTAssertTrue(c.rules.isEmpty)
    }

    func testTriggerAndReplacementAreTrimmed() {
        var c = TextCorrections()
        c.set(trigger: "  Bjork ", replacement: "  Björk ")
        XCTAssertEqual(c.rules.first?.trigger, "Bjork")
        XCTAssertEqual(c.replacement(for: "Bjork"), "Björk")
    }

    func testMatchingIsCaseSensitive() {
        var c = TextCorrections()
        c.set(trigger: "Bjork", replacement: "Björk")
        XCTAssertEqual(c.replacement(for: "Bjork"), "Björk")
        XCTAssertNil(c.replacement(for: "bjork"))
        XCTAssertNil(c.replacement(for: "BJORK"))
        XCTAssertNil(c.replacement(for: "Bjor"))
    }

    func testRemoveByExactTrigger() {
        var c = TextCorrections()
        c.set(trigger: "Bjork", replacement: "Björk")
        c.set(trigger: "teh", replacement: "the")
        c.remove(trigger: "Bjork")
        XCTAssertEqual(c.rules.map(\.trigger), ["teh"])
    }

    func testCodableRoundTrip() throws {
        var c = TextCorrections()
        c.set(trigger: "Bjork", replacement: "Björk")
        c.set(trigger: "teh", replacement: "the")
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(TextCorrections.self, from: data)
        XCTAssertEqual(back, c)
    }
}

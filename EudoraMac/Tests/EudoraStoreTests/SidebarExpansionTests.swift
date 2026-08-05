import XCTest
@testable import EudoraStore

/// The sidebar's remembered disclosure state. Small enough to be obvious, and
/// pinned here because the app cannot test it: the two things that actually
/// bite are the stable encoding (a `Set` iterates in a different order every
/// launch) and `retain`, which is the one operation in the type that can throw
/// state away.
final class SidebarExpansionTests: XCTestCase {

    func testOpenAndClose() {
        var e = SidebarExpansion()
        XCTAssertFalse(e.isExpanded("PEOPLE"))

        e.setExpanded("PEOPLE", true)
        XCTAssertTrue(e.isExpanded("PEOPLE"))
        XCTAssertEqual(e.expandedIDs, ["PEOPLE"])

        e.setExpanded("PEOPLE", false)
        XCTAssertFalse(e.isExpanded("PEOPLE"))
        XCTAssertTrue(e.expandedIDs.isEmpty)
    }

    /// Closing something already closed, and opening something already open,
    /// both have to be no-ops — the binding's setter fires on every render pass
    /// SwiftUI feels like making, not only on a click.
    func testRepeatedSetsAreIdempotent() {
        var e = SidebarExpansion()
        e.setExpanded("A", true)
        e.setExpanded("A", true)
        XCTAssertEqual(e.expandedIDs, ["A"])
        e.setExpanded("A", false)
        e.setExpanded("A", false)
        XCTAssertTrue(e.expandedIDs.isEmpty)
    }

    func testEmptyIDIsIgnored() {
        var e = SidebarExpansion()
        e.setExpanded("", true)
        XCTAssertTrue(e.expandedIDs.isEmpty)
    }

    func testNestedIDsAreIndependent() {
        var e = SidebarExpansion()
        e.setExpanded("PEOPLE", true)
        e.setExpanded("PEOPLE/A-F", true)
        XCTAssertTrue(e.isExpanded("PEOPLE"))
        XCTAssertTrue(e.isExpanded("PEOPLE/A-F"))

        // Closing the parent must not forget the child's own state: reopening
        // PEOPLE should bring A-F back open, which is what the outline does.
        e.setExpanded("PEOPLE", false)
        XCTAssertTrue(e.isExpanded("PEOPLE/A-F"))
    }

    func testRetainDropsIDsNoLongerInTheTree() {
        var e = SidebarExpansion(expandedIDs: ["PEOPLE", "PEOPLE/A-F", "Gone"])
        e.retain(idsIn: ["PEOPLE", "PEOPLE/A-F", "Projects"])
        XCTAssertEqual(e.expandedIDs, ["PEOPLE", "PEOPLE/A-F"])
    }

    /// Documents the sharp edge rather than defending against it inside the
    /// type: `retain` with nothing present empties the set, so the app has to
    /// gate the call on a loaded tree. If that guard is ever removed, this test
    /// is the note explaining what goes wrong.
    func testRetainWithNothingPresentEmptiesTheSet() {
        var e = SidebarExpansion(expandedIDs: ["PEOPLE"])
        e.retain(idsIn: [])
        XCTAssertTrue(e.expandedIDs.isEmpty)
    }

    func testRoundTripsThroughJSON() throws {
        let e = SidebarExpansion(expandedIDs: ["PEOPLE", "PEOPLE/A-F", "Projects/Music"])
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(SidebarExpansion.self, from: data)
        XCTAssertEqual(back, e)
    }

    /// The encoding is a sorted array, so identical state encodes to identical
    /// bytes. Building the same state by two different insertion orders is the
    /// closest a single-process test can get to the cross-launch case this
    /// guards (`Set` hashing is seeded per process, not per instance).
    func testEncodingIsSortedAndStable() throws {
        var a = SidebarExpansion()
        for id in ["Projects", "PEOPLE", "PEOPLE/A-F"] { a.setExpanded(id, true) }
        var b = SidebarExpansion()
        for id in ["PEOPLE/A-F", "Projects", "PEOPLE"] { b.setExpanded(id, true) }

        let encoder = JSONEncoder()
        XCTAssertEqual(try encoder.encode(a), try encoder.encode(b))

        // Asserted by decoding back to an array rather than against a JSON
        // string: Foundation's escaping of "/" differs between Darwin and
        // swift-corelibs, so a literal-bytes assertion would pass wherever it
        // was written and fail on the other platform.
        let ids = try JSONDecoder().decode([String].self, from: encoder.encode(a))
        XCTAssertEqual(ids, ["PEOPLE", "PEOPLE/A-F", "Projects"])
    }

    func testDecodingAMissingBlobIsNotThisTypesJob() throws {
        // An empty array is the encoded form of "nothing open", and must decode
        // to exactly that rather than throwing.
        let e = try JSONDecoder().decode(SidebarExpansion.self, from: Data("[]".utf8))
        XCTAssertEqual(e, SidebarExpansion())
    }
}

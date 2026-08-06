import XCTest
@testable import EudoraStore

final class RecentMailboxesTests: XCTestCase {

    /// A fixed "now" so nothing here depends on the wall clock.
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func daysAgo(_ n: Int) -> Date {
        now.addingTimeInterval(-Double(n) * 24 * 60 * 60)
    }

    func testRecordMovesToFrontAndDedupes() {
        var r = RecentMailboxes()
        r.record("PEOPLE.fol/A.FOL/Andi Maerz.mbx", at: daysAgo(3))
        r.record("PEOPLE.fol/H.FOL/Holger Gehring.mbx", at: daysAgo(2))
        r.record("PEOPLE.fol/A.FOL/Andi Maerz.mbx", at: daysAgo(1))   // filed again
        XCTAssertEqual(r.ids(now: now),
                       ["PEOPLE.fol/A.FOL/Andi Maerz.mbx",
                        "PEOPLE.fol/H.FOL/Holger Gehring.mbx"])
        // Re-filing replaces rather than adds.
        XCTAssertEqual(r.entries.count, 2)
    }

    func testRecordIgnoresEmptyID() {
        var r = RecentMailboxes()
        r.record("", at: now)
        XCTAssertTrue(r.entries.isEmpty)
    }

    func testEntriesPastMaxAgeAreNotListed() {
        var r = RecentMailboxes(entries: [
            .init(id: "fresh", movedAt: daysAgo(RecentMailboxes.maxAgeDays - 1)),
            .init(id: "stale", movedAt: daysAgo(RecentMailboxes.maxAgeDays + 1)),
        ])
        XCTAssertEqual(r.ids(now: now), ["fresh"])
        // Still on disk until something prunes...
        XCTAssertEqual(r.entries.count, 2)
        r.prune(now: now)
        XCTAssertEqual(r.entries.map(\.id), ["fresh"])
    }

    /// The boundary itself: exactly `maxAgeDays` old is still in.
    func testExactlyMaxAgeIsNotExpired() {
        let r = RecentMailboxes(entries: [
            .init(id: "edge", movedAt: daysAgo(RecentMailboxes.maxAgeDays)),
        ])
        XCTAssertEqual(r.ids(now: now), ["edge"])
    }

    func testRecordPrunesTheRest() {
        var r = RecentMailboxes(entries: [
            .init(id: "stale", movedAt: daysAgo(RecentMailboxes.maxAgeDays + 5)),
        ])
        r.record("new", at: now)
        XCTAssertEqual(r.entries.map(\.id), ["new"])
    }

    /// A `movedAt` in the future — a clock change, a restore from backup — must
    /// not read as expired.
    func testFutureDateIsNotExpired() {
        let r = RecentMailboxes(entries: [
            .init(id: "ahead", movedAt: now.addingTimeInterval(60 * 60 * 24 * 400)),
        ])
        XCTAssertEqual(r.ids(now: now), ["ahead"])
    }

    /// The seed and a decoded blob both arrive from outside; order is imposed,
    /// not assumed.
    func testInitSortsNewestFirst() {
        let r = RecentMailboxes(entries: [
            .init(id: "old", movedAt: daysAgo(9)),
            .init(id: "new", movedAt: daysAgo(1)),
            .init(id: "mid", movedAt: daysAgo(5)),
        ])
        XCTAssertEqual(r.ids(now: now), ["new", "mid", "old"])
    }

    func testRoundTripsThroughJSON() throws {
        var r = RecentMailboxes()
        r.record("PEOPLE.fol/D.FOL/DavidTri.mbx", at: daysAgo(2))
        r.record("PEOPLE.fol/R.FOL/ralphlei.mbx", at: daysAgo(1))
        let blob = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(RecentMailboxes.self, from: blob)
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.ids(now: now),
                       ["PEOPLE.fol/R.FOL/ralphlei.mbx", "PEOPLE.fol/D.FOL/DavidTri.mbx"])
    }

    /// Ids carry the *filename* path, so a display-name rename is invisible here.
    /// Nothing to assert about renaming itself — the point is that the id a move
    /// records is the id the tree still offers afterwards.
    func testIDIsStableAcrossADisplayRename() {
        var r = RecentMailboxes()
        r.record("PEOPLE.fol/H.FOL/Holger Gehring.mbx", at: now)
        // A rename rewrites descmap's display field only; the id is unchanged,
        // so the entry recorded before it still names the same mailbox after.
        XCTAssertEqual(r.ids(now: now), ["PEOPLE.fol/H.FOL/Holger Gehring.mbx"])
    }
}

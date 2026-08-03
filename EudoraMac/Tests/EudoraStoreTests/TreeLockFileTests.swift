import XCTest
@testable import EudoraStore

/// The lock that says a Eudora is using this tree, and — the part that matters —
/// the rules for disbelieving it.
///
/// Eudora 7's lock could only be cleared by a human, because it carried no
/// evidence about its holder. Every test here is really about the same
/// requirement: the common case (the previous run died) must resolve itself
/// without asking anybody anything.
final class TreeLockFileTests: XCTestCase {
    private let ours = "com.stephen.eudora.app"

    // MARK: round trip

    func testSerializesAndParsesBack() throws {
        let lock = TreeLockFile(pid: 4242, bundleID: ours,
                                started: Date(timeIntervalSince1970: 1_785_000_000),
                                note: "Eudora 0.3.0")
        let back = try XCTUnwrap(TreeLockFile(parsing: lock.serialized()))
        XCTAssertEqual(back.pid, 4242)
        XCTAssertEqual(back.bundleID, ours)
        XCTAssertEqual(back.note, "Eudora 0.3.0")
        XCTAssertEqual(back.started.timeIntervalSince1970,
                       lock.started.timeIntervalSince1970, accuracy: 1)
    }

    /// A later version must be able to add fields without stranding this one.
    func testUnknownKeysAreIgnored() throws {
        let text = "pid=17\nbundle=\(ours)\nfuture=whatever\nnote=hi"
        let lock = try XCTUnwrap(TreeLockFile(parsing: text))
        XCTAssertEqual(lock.pid, 17)
        XCTAssertEqual(lock.note, "hi")
    }

    /// Everything degrades except the pid: without it there is nothing to check,
    /// and an uncheckable lock is precisely the thing being replaced.
    func testMissingPidIsUnparseable() {
        XCTAssertNil(TreeLockFile(parsing: "bundle=\(ours)\nnote=hi"))
        XCTAssertNil(TreeLockFile(parsing: "pid=notanumber"))
        XCTAssertNil(TreeLockFile(parsing: ""))
    }

    func testMissingOptionalFieldsDegradeRatherThanFail() throws {
        let lock = try XCTUnwrap(TreeLockFile(parsing: "pid=99"))
        XCTAssertEqual(lock.pid, 99)
        XCTAssertEqual(lock.bundleID, "")
        XCTAssertEqual(lock.started, .distantPast)
    }

    // MARK: the verdict

    func testNoLockIsTakenWithoutComment() {
        let v = TreeLockFile.verdict(for: nil, ourPID: 1, ourBundleID: ours,
                                     bundleIDOfRunningProcess: { _ in nil })
        XCTAssertEqual(v, .takeIt(wasStale: false))
    }

    /// Reopening a tree this same process already holds. Checked before
    /// liveness, so it can't depend on the caller having managed to delete the
    /// file first — that removal is best-effort, and without this a read-only
    /// volume would have the app raise a modal accusing itself of being a rival.
    func testOurOwnLockIsNotMistakenForARival() {
        let lock = TreeLockFile(pid: 1234, bundleID: ours)
        let v = TreeLockFile.verdict(for: lock, ourPID: 1234, ourBundleID: ours,
                                     bundleIDOfRunningProcess: { _ in self.ours })
        XCTAssertEqual(v, .takeIt(wasStale: false))
    }

    /// The case that made Eudora 7's lock a menace, and the one that must never
    /// ask a question: the holder is gone.
    func testALockWhoseProcessIsGoneIsTakenAsStale() {
        let lock = TreeLockFile(pid: 4242, bundleID: ours)
        let v = TreeLockFile.verdict(for: lock, ourPID: 1, ourBundleID: ours,
                                     bundleIDOfRunningProcess: { _ in nil })
        XCTAssertEqual(v, .takeIt(wasStale: true))
    }

    func testALockHeldByALiveEudoraIsRespected() {
        let lock = TreeLockFile(pid: 4242, bundleID: ours)
        let v = TreeLockFile.verdict(for: lock, ourPID: 1, ourBundleID: ours,
                                     bundleIDOfRunningProcess: { _ in self.ours })
        XCTAssertEqual(v, .heldByLiveEudora(lock))
    }

    /// A recycled pid: the holder died and something unrelated inherited its
    /// number. Live, but not us — the one genuinely ambiguous case, and the only
    /// one allowed to ask.
    func testALockHeldBySomeOtherLiveProcessIsAmbiguous() {
        let lock = TreeLockFile(pid: 4242, bundleID: ours)
        let v = TreeLockFile.verdict(for: lock, ourPID: 1, ourBundleID: ours,
                                     bundleIDOfRunningProcess: { _ in "com.apple.Safari" })
        XCTAssertEqual(v, .heldByUnknownProcess(lock))
    }

    /// A lock written by an older build, whose recorded bundle id we match even
    /// if our own has been renamed since, still counts as a Eudora.
    func testALockMatchingItsOwnRecordedBundleIDCountsAsEudora() {
        let lock = TreeLockFile(pid: 4242, bundleID: "com.stephen.eudora.old")
        let v = TreeLockFile.verdict(for: lock, ourPID: 1, ourBundleID: ours,
                                     bundleIDOfRunningProcess: { _ in "com.stephen.eudora.old" })
        XCTAssertEqual(v, .heldByLiveEudora(lock))
    }

    /// The pid actually asked about must be the one in the lock — a check
    /// against the wrong process proves nothing.
    func testTheProcessQueriedIsTheOneNamedInTheLock() {
        var asked: [Int32] = []
        _ = TreeLockFile.verdict(for: TreeLockFile(pid: 31337, bundleID: ours),
                                 ourPID: 1, ourBundleID: ours,
                                 bundleIDOfRunningProcess: { pid in asked.append(pid); return nil })
        XCTAssertEqual(asked, [31337])
    }

    func testFilenameIsNotEudora7s() {
        // Sharing OWNER.LOK would have the two versions clear each other's
        // locks, which is worse than neither seeing the other.
        XCTAssertNotEqual(TreeLockFile.filename.uppercased(), "OWNER.LOK")
        XCTAssertEqual(TreeLockFile.url(in: URL(fileURLWithPath: "/tmp/Eudora")).lastPathComponent,
                       TreeLockFile.filename)
    }
}

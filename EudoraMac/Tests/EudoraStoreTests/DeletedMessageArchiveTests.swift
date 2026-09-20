import XCTest
@testable import EudoraStore

/// `DeletedMessageArchive` — the rescue copy that Delete PERMANENTLY and
/// blacklisting leave in the Finder's Trash.
///
/// The file *name* is the part worth pinning, because it is the whole user
/// interface of this feature: if the name is wrong or unreadable the copy might
/// as well not exist. The writing itself needs a real Trash and is left to be
/// exercised by hand.
final class DeletedMessageArchiveTests: XCTestCase {

    private let when = Date(timeIntervalSince1970: 1_790_000_000)   // fixed
    private let utc = TimeZone(identifier: "UTC")!

    private func name(_ reason: DeletedMessageArchive.Reason,
                      _ from: String, _ subject: String) -> String {
        DeletedMessageArchive.fileName(reason: reason, when: when,
                                       from: from, subject: subject, timeZone: utc)
    }

    func testTheShapeIsFindableInATrashFullOfOtherThings() {
        let n = name(.deleted, "Fred Smith", "Cheap watches")
        XCTAssertTrue(n.hasPrefix("Eudora deleted "), n)
        XCTAssertTrue(n.hasSuffix(".txt"), n)
        XCTAssertTrue(n.contains("Fred Smith"), n)
        XCTAssertTrue(n.contains("Cheap watches"), n)
        // The timestamp sorts, so it must be year-first and fixed-width.
        XCTAssertTrue(n.contains("2026-"), n)
    }

    func testTheTwoCommandsAreToldApart() {
        XCTAssertTrue(name(.deleted, "A", "B").hasPrefix("Eudora deleted "))
        XCTAssertTrue(name(.blacklisted, "A", "B").hasPrefix("Eudora blacklisted "))
    }

    /// A colon in a POSIX path component is drawn by the Finder as a slash, and
    /// "Re: 50/50" is an ordinary enough subject to be worth a test.
    func testSlashesAndColonsCannotReachTheFileName() {
        let n = name(.deleted, "Accounts: Payable", "Re: 50/50 split")
        XCTAssertFalse(n.contains("/"), n)
        XCTAssertFalse(n.contains(":"), n)
        XCTAssertTrue(n.contains("Re- 50-50 split"), n)
    }

    func testEmptyHeadersGetSomethingToRead() {
        let n = name(.deleted, "", "   ")
        XCTAssertTrue(n.contains("unknown sender"), n)
        XCTAssertTrue(n.contains("no subject"), n)
    }

    func testNewlinesAndTabsInAHeaderDoNotBreakTheName() {
        let n = name(.deleted, "Fred\tSmith", "one\r\ntwo")
        XCTAssertFalse(n.contains("\n"), n)
        XCTAssertFalse(n.contains("\t"), n)
        XCTAssertTrue(n.contains("Fred Smith"), n)
        XCTAssertTrue(n.contains("one two"), n)
    }

    /// macOS allows 255 UTF-8 bytes in a path component, and a spam subject can
    /// be much longer than that.
    func testAVeryLongSubjectIsTrimmedToSomethingTheFilesystemAccepts() {
        let n = name(.deleted, String(repeating: "N", count: 300),
                              String(repeating: "S", count: 3000))
        XCTAssertLessThanOrEqual(n.utf8.count, 255, "\(n.utf8.count) bytes")
        XCTAssertTrue(n.hasSuffix(".txt"), n)
    }

    /// Multi-byte characters must not be cut in half by the byte cap.
    ///
    /// `capped` is asked directly as well, at a budget that lands mid-character,
    /// because `fileName`'s own limits are generous enough that the byte cap
    /// rarely bites and a test that never exercises it proves nothing.
    func testTrimmingDoesNotSplitACharacter() {
        let n = name(.deleted, String(repeating: "é", count: 200),
                              String(repeating: "漢", count: 400))
        XCTAssertLessThanOrEqual(n.utf8.count, 255, "\(n.utf8.count) bytes")

        // 漢 is three bytes, so every odd budget forces a decision.
        for budget in 10...20 {
            let cut = DeletedMessageArchive.capped(String(repeating: "漢", count: 10),
                                                   bytes: budget)
            XCTAssertLessThanOrEqual(cut.utf8.count, budget)
            XCTAssertEqual(cut.utf8.count % 3, 0, "split a character at \(budget)")
        }
    }

    /// An encoded-word subject in the Trash defeats the one job the name has,
    /// and encoded spam is exactly what gets blacklisted.
    func testEncodedWordsAreDecodedForTheName() {
        let d = DeletedMessageArchive.descriptor(
            for: record(from: "=?UTF-8?Q?Fr=C3=A9d=C3=A9ric?= <f@example.com>",
                        subject: "=?UTF-8?B?Q2hlYXAgd2F0Y2hlcw==?="))
        XCTAssertEqual(d.from, "Frédéric")
        XCTAssertEqual(d.subject, "Cheap watches")
    }

    // MARK: - the fallback folder's own uniquing

    func testAFallbackNameIsMadeUniqueRatherThanOverwritten() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try DeletedMessageArchive.uniqueURL(in: dir, name: "Eudora deleted x.txt")
        XCTAssertEqual(first.lastPathComponent, "Eudora deleted x.txt")
        try Data("one".utf8).write(to: first)

        let second = try DeletedMessageArchive.uniqueURL(in: dir, name: "Eudora deleted x.txt")
        XCTAssertEqual(second.lastPathComponent, "Eudora deleted x 2.txt")
        // The first copy is still there — the whole point.
        XCTAssertEqual(try String(contentsOf: first), "one")
    }

    /// A name beginning with a dot is invisible in the Finder, which would
    /// defeat the entire point.
    func testAHiddenNameCannotBeProduced() {
        let n = name(.deleted, ".hidden", ".also hidden")
        XCTAssertFalse(n.hasPrefix("."), n)
        XCTAssertTrue(n.contains("hidden"), n)
    }

    // MARK: - reading the headers back out

    private func record(from: String, subject: String) -> [UInt8] {
        Array(("From ???@??? Fri Sep 19 14:22:05 2026\r\n"
               + "From: \(from)\r\n"
               + "Subject: \(subject)\r\n"
               + "Date: Fri, 19 Sep 2026 14:22:05 -0700\r\n"
               + "\r\n"
               + "body\r\n").utf8)
    }

    func testTheDisplayNameIsPreferredToTheAddress() {
        let d = DeletedMessageArchive.descriptor(
            for: record(from: "Fred Smith <fred@example.com>", subject: "Hello"))
        XCTAssertEqual(d.from, "Fred Smith")
        XCTAssertEqual(d.subject, "Hello")
    }

    func testABareAddressIsUsedWhenThereIsNoDisplayName() {
        let d = DeletedMessageArchive.descriptor(
            for: record(from: "fred@example.com", subject: "Hello"))
        XCTAssertEqual(d.from, "fred@example.com")
    }

    func testAMissingSubjectComesBackEmptyRatherThanCrashing() {
        let bytes = Array(("From ???@??? Fri Sep 19 14:22:05 2026\r\n"
                           + "From: fred@example.com\r\n\r\nbody\r\n").utf8)
        let d = DeletedMessageArchive.descriptor(for: bytes)
        XCTAssertEqual(d.subject, "")
        XCTAssertEqual(DeletedMessageArchive.fileName(reason: .deleted, when: when,
                                                      from: d.from, subject: d.subject,
                                                      timeZone: utc).contains("no subject"),
                       true)
    }
}

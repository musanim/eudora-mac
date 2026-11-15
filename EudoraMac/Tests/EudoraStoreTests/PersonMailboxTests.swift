import XCTest
import Foundation
@testable import EudoraStore

/// Make Person Mailbox…: the name, the destination, the default ticks, and —
/// the part that moves real mail — which messages a mailbox scan picks.
final class PersonMailboxTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-person-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: name

    func testDisplayNameIsUsed() {
        XCTAssertEqual(PersonMailbox.suggestedName(fromHeader: "Jane Doe <jane@x.com>"), "Jane Doe")
    }

    func testQuotedLastFirstIsTurnedRound() {
        XCTAssertEqual(PersonMailbox.suggestedName(fromHeader: "\"Doe, Jane\" <jane@x.com>"), "Jane Doe")
    }

    func testEncodedWordIsDecoded() {
        XCTAssertEqual(PersonMailbox.suggestedName(fromHeader: "=?UTF-8?Q?=C3=89lodie_Martin?= <e@x.fr>"),
                       "Élodie Martin")
    }

    func testCommentFormIsUsed() {
        XCTAssertEqual(PersonMailbox.suggestedName(fromHeader: "jane@x.com (Jane Doe)"), "Jane Doe")
    }

    func testBareAddressFallsBackToLocalPart() {
        XCTAssertEqual(PersonMailbox.suggestedName(fromHeader: "jane.doe@x.com"), "Jane Doe")
        XCTAssertEqual(PersonMailbox.suggestedName(fromHeader: "<jdoe@x.com>"), "Jdoe")
    }

    func testDisplayNameThatIsAnAddressFallsBack() {
        XCTAssertEqual(PersonMailbox.suggestedName(fromHeader: "\"jane@x.com\" <jane@x.com>"), "Jane")
    }

    func testBannedCharactersAreDropped() {
        XCTAssertEqual(PersonMailbox.suggestedName(fromHeader: "Jane / Doe: <j@x.com>"), "Jane Doe")
    }

    func testUnquotedLastFirstIsRejoined() {
        XCTAssertEqual(PersonMailbox.suggestedName(fromHeader: "Doe, Jane <jane@x.com>"), "Jane Doe")
    }

    func testCharactersEudoraCannotStoreAreDropped() {
        XCTAssertEqual(PersonMailbox.suggestedName(fromHeader: "Jane \u{1F600} Ło <j@x.com>"), "Jane o")
        XCTAssertTrue(PersonMailbox.isStorableName("Élodie Martin"))
        XCTAssertFalse(PersonMailbox.isStorableName("Jiří"))
        XCTAssertFalse(PersonMailbox.isStorableName("a/b"))
        XCTAssertFalse(PersonMailbox.isStorableName("  "))
    }

    func testOnlyTheFirstSenderCounts() {
        XCTAssertEqual(PersonMailbox.suggestedName(fromHeader: "A B <a@x.com>, C D <c@x.com>"), "A B")
    }

    // MARK: destination

    private let people: [PersonMailbox.Group] = [
        .init(id: "PEOPLE.fol/A.FOL", display: "A"),
        .init(id: "PEOPLE.fol/E.FOL", display: "E"),
        .init(id: "PEOPLE.fol/J.FOL", display: "J", subgroups: [
            .init(id: "PEOPLE.fol/J.FOL/JA.fol", display: "JA"),
            .init(id: "PEOPLE.fol/J.FOL/JO.fol", display: "JO"),
        ]),
    ]

    func testTwoLetterSubgroupWhenOneFits() {
        XCTAssertEqual(PersonMailbox.destination(forName: "John Smith", in: people)?.map(\.id),
                       ["PEOPLE.fol/J.FOL", "PEOPLE.fol/J.FOL/JO.fol"])
    }

    func testLetterGroupWhenNoSubgroupFits() {
        XCTAssertEqual(PersonMailbox.destination(forName: "Jürgen Ott", in: people)?.map(\.id),
                       ["PEOPLE.fol/J.FOL"])
    }

    func testLetterGroupWithoutSubgroups() {
        XCTAssertEqual(PersonMailbox.destination(forName: "anna detrick", in: people)?.map(\.id),
                       ["PEOPLE.fol/A.FOL"])
    }

    func testDiacriticsFold() {
        XCTAssertEqual(PersonMailbox.destination(forName: "Élodie Martin", in: people)?.map(\.id),
                       ["PEOPLE.fol/E.FOL"])
    }

    func testNoMatchingLetterGroup() {
        XCTAssertNil(PersonMailbox.destination(forName: "Zoe", in: people))
        XCTAssertNil(PersonMailbox.destination(forName: "", in: people))
        XCTAssertNil(PersonMailbox.destination(forName: "42", in: people))
    }

    func testOneLetterNameGoesToTheLetter() {
        XCTAssertEqual(PersonMailbox.destination(forName: "J", in: people)?.map(\.id),
                       ["PEOPLE.fol/J.FOL"])
    }

    // MARK: default ticks

    func testDefaultTicks() {
        func ticked(_ t: MailboxType, _ display: String, top: Bool = false, people: Bool = false) -> Bool {
            PersonMailbox.tickedByDefault(type: t, isTopLevel: top,
                                          display: display, isUnderPeople: people)
        }
        XCTAssertFalse(ticked(.inbox, "In", top: true))
        XCTAssertFalse(ticked(.outbox, "Out", top: true))
        XCTAssertFalse(ticked(.trash, "Trash", top: true))
        XCTAssertFalse(ticked(.junk, "Junk", top: true))
        XCTAssertFalse(ticked(.mailbox, "SCAMS", top: true))
        XCTAssertFalse(ticked(.mailbox, "HOLDING", top: true))
        XCTAssertFalse(ticked(.mailbox, "James Carmichael", people: true))
        XCTAssertTrue(ticked(.mailbox, "MISCINQ"))
        XCTAssertTrue(ticked(.mailbox, "SCAMS"), "only the top-level SCAMS is excluded")
    }

    // MARK: scan

    private var base: URL { root.appendingPathComponent("Box") }

    private func message(from: String, to: String, cc: String? = nil, subject: String) -> Data {
        var lines = ["From: \(from)", "To: \(to)"]
        if let cc { lines.append("Cc: \(cc)") }
        lines += ["Subject: \(subject)", "Content-Type: text/plain; charset=us-ascii", "",
                  "Body mentions jane@x.com but that is not a header.", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func build(_ messages: [Data], statuses: [Int]? = nil) throws {
        for (i, m) in messages.enumerated() {
            _ = try Outbox.append(messageData: m, to: base,
                                  status: statuses?[i] ?? MailboxMutator.statusRead,
                                  who: "x", subject: "S\(i + 1)")
        }
    }

    private func message(from: String, id: String) -> Data {
        Data(["From: \(from)", "To: me@y.com", "Message-ID: \(id)", "Subject: s", "", "b", ""]
            .joined(separator: "\r\n").utf8)
    }

    func testScanMatchesFromToAndCcExactly() throws {
        try build([
            message(from: "Jane <JANE@x.com>", to: "me@y.com", subject: "S1"),
            message(from: "me@y.com", to: "other@z.com", subject: "S2"),
            message(from: "me@y.com", to: "other@z.com", cc: "jane@x.com", subject: "S3"),
            message(from: "j.jane@x.com", to: "me@y.com", subject: "S4"),     // near-miss
            message(from: "me@y.com", to: "\"Doe, Jane\" <jane@x.com>", subject: "S5"),
            message(from: "jane@x.com.au", to: "me@y.com", subject: "S6"),     // near-miss
        ])
        let scan = try XCTUnwrap(PersonMailbox.scan(base: base, address: "jane@x.com"))
        XCTAssertEqual(scan.matches, [1, 3, 5])
    }

    func testScanSkipsDeletedGhosts() throws {
        try build([
            message(from: "jane@x.com", to: "me@y.com", subject: "S1"),
            message(from: "jane@x.com", to: "me@y.com", subject: "S2"),
            message(from: "jane@x.com", to: "me@y.com", subject: "S3"),
        ])
        // Drop record 1 from the index: a deleted-but-not-compacted ghost.
        let toc = base.appendingPathExtension("toc")
        let loaded = try XCTUnwrap(Toc.load(toc))
        let kept = loaded.entries.enumerated().dropFirst()
            .map { (source: Optional($0.offset), entry: $0.element) }
        try TocWriter.patched(original: loaded.data, originalEntries: loaded.entries,
                              entries: kept).write(to: toc)

        let scan = try XCTUnwrap(PersonMailbox.scan(base: base, address: "jane@x.com"))
        XCTAssertEqual(scan.matches, [2, 3], "the ghost must not be moved back into view")
    }

    func testScanFindsTheRecordAtAnOffset() throws {
        try build([
            message(from: "a@b.com", to: "me@y.com", subject: "S1"),
            message(from: "jane@x.com", to: "me@y.com", subject: "S2"),
        ])
        let rows = try XCTUnwrap(MailStore(root: root).list(at: base)).rows
        let scan = try XCTUnwrap(PersonMailbox.scan(base: base, address: "jane@x.com",
                                                   offset: rows[1].offset))
        XCTAssertEqual(scan.indexAtOffset, 2)
        XCTAssertNil(PersonMailbox.scan(base: base, address: "jane@x.com", offset: 999_999)?.indexAtOffset)
    }

    /// The scan's indices are exactly what `moveMany` acts on: moving them
    /// moves the person's mail and leaves everyone else's.
    func testScanIndicesDriveMoveMany() throws {
        try build([
            message(from: "jane@x.com", to: "me@y.com", subject: "S1"),
            message(from: "a@b.com", to: "me@y.com", subject: "S2"),
            message(from: "me@y.com", to: "jane@x.com", subject: "S3"),
        ])
        let dest = root.appendingPathComponent("Jane")
        let scan = try XCTUnwrap(PersonMailbox.scan(base: base, address: "jane@x.com"))
        try MailboxMutator.moveMany(from: base, indices: scan.matches, to: dest)

        XCTAssertEqual(MailStore(root: root).list(at: base)?.rows.map(\.subject), ["S2"])
        XCTAssertEqual(MailStore(root: root).list(at: dest)?.rows.map(\.subject), ["S1", "S3"])
    }

    func testFingerprintChangesWhenTheMailboxDoes() throws {
        try build([message(from: "jane@x.com", to: "me@y.com", subject: "S1")])
        let before = try XCTUnwrap(PersonMailbox.Fingerprint.of(base: base))
        try build([message(from: "a@b.com", to: "me@y.com", subject: "S2")])
        XCTAssertNotEqual(PersonMailbox.Fingerprint.of(base: base), before)
    }

    /// Drafts and queued mail stay in Out; only sent copies go.
    func testUnsentAndQueuedAreNotMatched() throws {
        try build([
            message(from: "me@y.com", to: "jane@x.com", subject: "S1"),
            message(from: "me@y.com", to: "jane@x.com", subject: "S2"),
            message(from: "me@y.com", to: "jane@x.com", subject: "S3"),
        ], statuses: [MailboxMutator.statusSent, MailboxMutator.statusUnsent, 7])
        let scan = try XCTUnwrap(PersonMailbox.scan(base: base, address: "jane@x.com"))
        XCTAssertEqual(scan.matches, [1])
    }

    /// The offset alone isn't trusted when a Message-ID is given.
    func testOffsetIsConfirmedByMessageID() throws {
        try build([message(from: "jane@x.com", id: "<a@x>"), message(from: "jane@x.com", id: "<b@x>")])
        let rows = try XCTUnwrap(MailStore(root: root).list(at: base)).rows
        XCTAssertEqual(PersonMailbox.scan(base: base, address: "jane@x.com",
                                          offset: rows[1].offset, messageID: "<b@x>")?.indexAtOffset, 2)
        XCTAssertNil(PersonMailbox.scan(base: base, address: "jane@x.com",
                                        offset: rows[1].offset, messageID: "<a@x>")?.indexAtOffset)
    }

    func testStaleIndexIsReported() throws {
        try build([
            message(from: "jane@x.com", to: "me@y.com", subject: "S1"),
            message(from: "jane@x.com", to: "me@y.com", subject: "S2"),
            message(from: "jane@x.com", to: "me@y.com", subject: "S3"),
        ])
        XCTAssertEqual(PersonMailbox.scan(base: base, address: "jane@x.com")?.indexIsStale, false)

        // One extra entry pointing at nothing: still trusted by the listing
        // (a majority matches), but not consistent.
        let toc = base.appendingPathExtension("toc")
        let loaded = try XCTUnwrap(Toc.load(toc))
        var entries = loaded.entries.enumerated().map { (source: Optional($0.offset), entry: $0.element) }
        entries.append((source: nil, entry: TocEntry(offset: 999_999, length: 10, status: 1, priority: 4,
                                                     date: "", to: "", subject: "dead")))
        try TocWriter.patched(original: loaded.data, originalEntries: loaded.entries,
                              entries: entries).write(to: toc)

        let scan = try XCTUnwrap(PersonMailbox.scan(base: base, address: "jane@x.com"))
        XCTAssertEqual(scan.matches, [1, 2, 3])
        XCTAssertTrue(scan.indexIsStale)
    }

    func testMissingMailboxScansNil() {
        XCTAssertNil(PersonMailbox.scan(base: root.appendingPathComponent("Nope"), address: "jane@x.com"))
    }
}

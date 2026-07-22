import XCTest
import Foundation
@testable import EudoraStore

/// Tests for `MailboxTreeMutator.deleteEmptyMailbox` — the descmap.pce edit
/// behind right-click ▸ Delete on an empty mailbox.
///
/// The property that matters most is **byte-preservation of everything that
/// stays**: descmap.pce is a real Eudora file the app shares with real Eudora,
/// so removing one line must not re-encode, re-terminate, or "fix" any other
/// line. These tests therefore compare the surviving bytes exactly, not just
/// the parsed entries.
final class MailboxTreeMutatorTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-treemut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: the successful delete

    func testDeleteRemovesLineAndFilesAndNothingElse() throws {
        let lines = [
            "In,In.mbx,S,Y",
            "KEEP,KEEP.mbx,M,N",
            "GONE,GONE.mbx,M,N",
            "Trash,Trash.mbx,S,N",
        ]
        try writeDescmap(lines: lines, terminator: "\r\n")
        try makeEmptyMailbox("GONE")
        try seedMailbox("KEEP")

        try MailboxTreeMutator.deleteEmptyMailbox(directory: root, filename: "GONE.mbx")

        // The exact surviving bytes: original minus the one line.
        let expected = descmapData(lines: ["In,In.mbx,S,Y",
                                           "KEEP,KEEP.mbx,M,N",
                                           "Trash,Trash.mbx,S,N"], terminator: "\r\n")
        XCTAssertEqual(try Data(contentsOf: descURL), expected)

        // Its files are gone; its neighbour's are not.
        XCTAssertFalse(FileManager.default.fileExists(atPath: mbxPath("GONE")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tocPath("GONE")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mbxPath("KEEP")))

        // And the tree no longer lists it.
        let names = DescMap.read(directory: root).map(\.display)
        XCTAssertEqual(names, ["In", "KEEP", "Trash"])
    }

    /// A mailbox that has lived — messages appended, then all removed — is
    /// empty by the only measure that counts, the `.mbx`'s records.
    func testDeleteAcceptsAMailboxEmptiedThroughUse() throws {
        try writeDescmap(lines: ["GONE,GONE.mbx,M,N"], terminator: "\r\n")
        try seedMailbox("GONE")
        try MailboxMutator.removeMany(base: root.appendingPathComponent("GONE"), indices: [1])

        try MailboxTreeMutator.deleteEmptyMailbox(directory: root, filename: "GONE.mbx")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mbxPath("GONE")))
    }

    /// The `.mbx` is the truth for emptiness. A stale `.toc` claiming entries
    /// over an empty `.mbx` must not block the delete — the list itself would
    /// show the mailbox as empty (the reader distrusts an inconsistent .toc).
    func testStaleTocDoesNotBlockDeletion() throws {
        try writeDescmap(lines: ["GONE,GONE.mbx,M,N"], terminator: "\r\n")
        try makeEmptyMailbox("GONE")
        let ghost = TocEntry(offset: 0, length: 40, status: 1, priority: 4,
                             date: "", to: "x", subject: "ghost")
        try TocWriter.data(entries: [ghost, ghost])
            .write(to: root.appendingPathComponent("GONE.toc"))

        XCTAssertNoThrow(try MailboxTreeMutator.deleteEmptyMailbox(directory: root,
                                                                   filename: "GONE.mbx"))
    }

    /// A descmap line whose files never existed (or are already gone) is a dead
    /// entry, and deleting it must work — otherwise it is stuck forever.
    func testDeadEntryWithNoFilesIsDeletable() throws {
        try writeDescmap(lines: ["KEEP,KEEP.mbx,M,N", "GHOST,GHOST.mbx,M,N"],
                         terminator: "\r\n")
        try seedMailbox("KEEP")

        try MailboxTreeMutator.deleteEmptyMailbox(directory: root, filename: "GHOST.mbx")
        XCTAssertEqual(DescMap.read(directory: root).map(\.display), ["KEEP"])
    }

    func testDescmapIsBackedUpOnce() throws {
        try writeDescmap(lines: ["A,A.mbx,M,N", "B,B.mbx,M,N"], terminator: "\r\n")
        let original = try Data(contentsOf: descURL)
        try makeEmptyMailbox("A")
        try makeEmptyMailbox("B")

        try MailboxTreeMutator.deleteEmptyMailbox(directory: root, filename: "A.mbx")
        let bak = root.appendingPathComponent("descmap.pce.bak")
        XCTAssertEqual(try Data(contentsOf: bak), original)

        // The second delete must not overwrite the backup — it is the original
        // index, not the previous one.
        try MailboxTreeMutator.deleteEmptyMailbox(directory: root, filename: "B.mbx")
        XCTAssertEqual(try Data(contentsOf: bak), original)
    }

    func testBakFileIsLeftAlone() throws {
        try writeDescmap(lines: ["GONE,GONE.mbx,M,N"], terminator: "\r\n")
        try makeEmptyMailbox("GONE")
        let bak = root.appendingPathComponent("GONE.mbx.bak")
        try Data("old messages worth keeping".utf8).write(to: bak)

        try MailboxTreeMutator.deleteEmptyMailbox(directory: root, filename: "GONE.mbx")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bak.path),
                      "the backup of the mailbox's former contents must survive")
    }

    // MARK: byte preservation

    /// A descmap with bare-LF endings (fixtures, hand-edited files) must keep
    /// them: removing a line is not permission to re-terminate the others.
    func testLFOnlyDescmapKeepsItsLineEndings() throws {
        try writeDescmap(lines: ["A,A.mbx,M,N", "GONE,GONE.mbx,M,N", "C,C.mbx,M,N"],
                         terminator: "\n")
        try makeEmptyMailbox("GONE")

        try MailboxTreeMutator.deleteEmptyMailbox(directory: root, filename: "GONE.mbx")
        XCTAssertEqual(try Data(contentsOf: descURL),
                       descmapData(lines: ["A,A.mbx,M,N", "C,C.mbx,M,N"], terminator: "\n"))
    }

    /// Latin-1 display names (real Eudora is not UTF-8) must survive a
    /// neighbouring delete byte-for-byte.
    func testLatin1NeighbourSurvivesByteForByte() throws {
        // "CAFÉ" in ISO Latin-1: É is the single byte 0xC9.
        var data = Data("CAF".utf8); data.append(0xC9)
        data.append(Data(",CAFE.mbx,M,N\r\nGONE,GONE.mbx,M,N\r\n".utf8))
        try data.write(to: descURL)
        try makeEmptyMailbox("GONE")

        try MailboxTreeMutator.deleteEmptyMailbox(directory: root, filename: "GONE.mbx")

        var expected = Data("CAF".utf8); expected.append(0xC9)
        expected.append(Data(",CAFE.mbx,M,N\r\n".utf8))
        XCTAssertEqual(try Data(contentsOf: descURL), expected)
    }

    // MARK: refusals

    func testRefusesANonEmptyMailbox() throws {
        try writeDescmap(lines: ["FULL,FULL.mbx,M,N"], terminator: "\r\n")
        try seedMailbox("FULL")
        let before = try Data(contentsOf: descURL)

        XCTAssertThrowsError(try MailboxTreeMutator.deleteEmptyMailbox(
            directory: root, filename: "FULL.mbx")) { error in
            XCTAssertEqual(error as? MailboxTreeMutator.DeleteError, .notEmpty)
        }
        // Nothing moved: line still there, files still there.
        XCTAssertEqual(try Data(contentsOf: descURL), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mbxPath("FULL")))
    }

    func testRefusesSystemMailboxes() throws {
        try writeDescmap(lines: ["In,In.mbx,S,Y", "Trash,Trash.mbx,S,N"],
                         terminator: "\r\n")
        try makeEmptyMailbox("In")

        XCTAssertThrowsError(try MailboxTreeMutator.deleteEmptyMailbox(
            directory: root, filename: "In.mbx")) { error in
            XCTAssertEqual(error as? MailboxTreeMutator.DeleteError, .notAMailbox)
        }
    }

    func testRefusesAFolderLine() throws {
        try writeDescmap(lines: ["Stuff,Stuff.fol,F,N"], terminator: "\r\n")

        XCTAssertThrowsError(try MailboxTreeMutator.deleteEmptyMailbox(
            directory: root, filename: "Stuff.fol")) { error in
            XCTAssertEqual(error as? MailboxTreeMutator.DeleteError, .notAMailbox)
        }
    }

    func testRefusesAFilenameNotInTheIndex() throws {
        try writeDescmap(lines: ["A,A.mbx,M,N"], terminator: "\r\n")

        XCTAssertThrowsError(try MailboxTreeMutator.deleteEmptyMailbox(
            directory: root, filename: "MISSING.mbx")) { error in
            XCTAssertEqual(error as? MailboxTreeMutator.DeleteError, .notFound)
        }
    }

    func testRefusesWhenLocked() throws {
        try writeDescmap(lines: ["GONE,GONE.mbx,M,N"], terminator: "\r\n")
        try makeEmptyMailbox("GONE")
        try Data().write(to: root.appendingPathComponent("GONE.lck"))

        XCTAssertThrowsError(try MailboxTreeMutator.deleteEmptyMailbox(
            directory: root, filename: "GONE.mbx")) { error in
            XCTAssertEqual(error as? MailboxTreeMutator.DeleteError, .locked)
        }
    }

    // MARK: fixture

    private var descURL: URL { root.appendingPathComponent("descmap.pce") }
    private func mbxPath(_ name: String) -> String {
        root.appendingPathComponent("\(name).mbx").path
    }
    private func tocPath(_ name: String) -> String {
        root.appendingPathComponent("\(name).toc").path
    }

    private func descmapData(lines: [String], terminator: String) -> Data {
        Data(lines.map { $0 + terminator }.joined().utf8)
    }

    private func writeDescmap(lines: [String], terminator: String) throws {
        try descmapData(lines: lines, terminator: terminator).write(to: descURL)
    }

    /// An empty-but-real mailbox: zero-byte .mbx and a header-only .toc, the
    /// state a freshly created (or fully emptied and compacted) mailbox is in.
    private func makeEmptyMailbox(_ name: String) throws {
        try Data().write(to: root.appendingPathComponent("\(name).mbx"))
        try TocWriter.data(entries: []).write(to: root.appendingPathComponent("\(name).toc"))
    }

    /// A mailbox holding one real message, written by the same code the app uses.
    private func seedMailbox(_ name: String) throws {
        let msg = Data([
            "From: me@example.com",
            "To: you@example.com",
            "Subject: S",
            "",
            "body",
            "",
        ].joined(separator: "\r\n").utf8)
        _ = try Outbox.append(messageData: msg, to: root.appendingPathComponent(name),
                              status: MailboxMutator.statusRead,
                              who: "you@example.com", subject: "S")
    }
}

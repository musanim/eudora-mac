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

    // MARK: creating

    func testCreateMailboxAppendsLineAndFiles() throws {
        try writeDescmap(lines: ["In,In.mbx,S,Y", "KEEP,KEEP.mbx,M,N"], terminator: "\r\n")
        let before = try Data(contentsOf: descURL)

        let filename = try MailboxTreeMutator.createMailbox(directory: root, name: "New Box")
        XCTAssertEqual(filename, "New Box.mbx")

        // Byte-exact: the original bytes untouched, one CRLF line appended.
        var expected = before
        expected.append(Data("New Box,New Box.mbx,M,N\r\n".utf8))
        XCTAssertEqual(try Data(contentsOf: descURL), expected)

        // The files exist and read as a real, empty mailbox.
        XCTAssertTrue(FileManager.default.fileExists(atPath: mbxPath("New Box")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tocPath("New Box")))
        let store = MailStore(root: root)
        XCTAssertEqual(store.messageCount(base: root.appendingPathComponent("New Box")), 0)
        let entry = DescMap.read(directory: root).last!
        XCTAssertEqual(entry.display, "New Box")
        XCTAssertEqual(entry.type, .mailbox)
    }

    func testCreateMatchesAnLFOnlyFile() throws {
        try writeDescmap(lines: ["A,A.mbx,M,N"], terminator: "\n")
        try MailboxTreeMutator.createMailbox(directory: root, name: "B")
        XCTAssertEqual(try Data(contentsOf: descURL),
                       descmapData(lines: ["A,A.mbx,M,N", "B,B.mbx,M,N"], terminator: "\n"))
    }

    /// A final line missing its terminator must get one before the append, or
    /// the new line would merge into it and corrupt both.
    func testCreateTerminatesAnUnterminatedFinalLine() throws {
        try Data("A,A.mbx,M,N\r\nB,B.mbx,M,N".utf8).write(to: descURL)
        try MailboxTreeMutator.createMailbox(directory: root, name: "C")
        XCTAssertEqual(try Data(contentsOf: descURL),
                       Data("A,A.mbx,M,N\r\nB,B.mbx,M,N\r\nC,C.mbx,M,N\r\n".utf8))
    }

    func testCreatePreservesTypedCase() throws {
        try writeDescmap(lines: ["A,A.mbx,M,N"], terminator: "\r\n")
        try MailboxTreeMutator.createMailbox(directory: root, name: "MiXeD Case")
        let entry = DescMap.read(directory: root).last!
        XCTAssertEqual(entry.display, "MiXeD Case")
        XCTAssertEqual(entry.filename, "MiXeD Case.mbx")
    }

    func testCreateRefusesDuplicatesCaseInsensitively() throws {
        try writeDescmap(lines: ["KEEP,KEEP.mbx,M,N", "Stuff,Stuff.fol,F,N"],
                         terminator: "\r\n")
        let before = try Data(contentsOf: descURL)

        for name in ["KEEP", "keep", "Keep"] {
            XCTAssertThrowsError(try MailboxTreeMutator.createMailbox(
                directory: root, name: name)) { error in
                XCTAssertEqual(error as? MailboxTreeMutator.CreateError, .duplicate("KEEP"))
            }
        }
        // A mailbox may not shadow a folder's name either, nor vice versa.
        XCTAssertThrowsError(try MailboxTreeMutator.createMailbox(directory: root, name: "stuff"))
        XCTAssertThrowsError(try MailboxTreeMutator.createFolder(directory: root, name: "keep"))
        XCTAssertEqual(try Data(contentsOf: descURL), before, "a refusal must change nothing")
    }

    func testCreateRefusesAnOrphanFileCollision() throws {
        try writeDescmap(lines: ["A,A.mbx,M,N"], terminator: "\r\n")
        // On disk but not in the index — must not be adopted or clobbered.
        try Data("orphaned messages".utf8).write(to: root.appendingPathComponent("GHOST.mbx"))

        XCTAssertThrowsError(try MailboxTreeMutator.createMailbox(
            directory: root, name: "GHOST")) { error in
            XCTAssertEqual(error as? MailboxTreeMutator.CreateError, .duplicate("GHOST"))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("GHOST.mbx")),
                       Data("orphaned messages".utf8))
    }

    func testCreateRefusesBadNames() throws {
        try writeDescmap(lines: ["A,A.mbx,M,N"], terminator: "\r\n")
        for bad in ["", "   "] {
            XCTAssertThrowsError(try MailboxTreeMutator.createMailbox(
                directory: root, name: bad)) { error in
                XCTAssertEqual(error as? MailboxTreeMutator.CreateError, .emptyName)
            }
        }
        for bad in ["a,b", "a/b", "a\\b", "a:b", "a?b", "émoji 🎉"] {
            XCTAssertThrowsError(try MailboxTreeMutator.createMailbox(
                directory: root, name: bad)) { error in
                XCTAssertEqual(error as? MailboxTreeMutator.CreateError, .invalidName,
                               "\u{201C}\(bad)\u{201D} should be refused")
            }
        }
        // Latin-1 accents are fine — only characters *outside* Latin-1 are not.
        XCTAssertNoThrow(try MailboxTreeMutator.createMailbox(directory: root, name: "Café"))
    }

    func testCreateFolderThenMailboxInsideIt() throws {
        try writeDescmap(lines: ["In,In.mbx,S,Y"], terminator: "\r\n")

        let folderName = try MailboxTreeMutator.createFolder(directory: root, name: "Projects")
        XCTAssertEqual(folderName, "Projects.fol")
        let dir = root.appendingPathComponent("Projects.fol")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("descmap.pce").path))

        try MailboxTreeMutator.createMailbox(directory: dir, name: "Music")

        // The store sees the hierarchy exactly as built.
        let tree = MailStore(root: root).tree()
        XCTAssertEqual(tree.map(\.entry.display), ["In", "Projects"])
        XCTAssertTrue(tree[1].isFolder)
        XCTAssertEqual(tree[1].children.map(\.entry.display), ["Music"])
        XCTAssertEqual(tree[1].children[0].entry.type, .mailbox)
    }

    /// A freshly created mailbox must be a first-class move destination: the
    /// records land and their statuses travel, which needs the header-only
    /// `.toc` the create wrote (appendRecord only extends an *existing* .toc).
    func testMoveIntoAFreshlyCreatedMailboxKeepsStatuses() throws {
        try writeDescmap(lines: ["SRC,SRC.mbx,M,N"], terminator: "\r\n")
        try seedMailbox("SRC")

        try MailboxTreeMutator.createMailbox(directory: root, name: "FRESH")
        try MailboxMutator.moveMany(from: root.appendingPathComponent("SRC"),
                                    indices: [1],
                                    to: root.appendingPathComponent("FRESH"))

        let listing = MailStore(root: root).list(at: root.appendingPathComponent("FRESH"),
                                                 name: "FRESH")!
        XCTAssertEqual(listing.source, .toc)
        XCTAssertEqual(listing.rows.map(\.subject), ["S"])
    }

    /// Create then delete must round-trip the index to its original bytes.
    func testCreateThenDeleteRoundTripsTheIndex() throws {
        try writeDescmap(lines: ["A,A.mbx,M,N", "B,B.mbx,M,N"], terminator: "\r\n")
        let original = try Data(contentsOf: descURL)

        try MailboxTreeMutator.createMailbox(directory: root, name: "Temp")
        try MailboxTreeMutator.deleteEmptyMailbox(directory: root, filename: "Temp.mbx")

        XCTAssertEqual(try Data(contentsOf: descURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mbxPath("Temp")))
    }

    func testCreateBacksUpTheIndexOnce() throws {
        try writeDescmap(lines: ["A,A.mbx,M,N"], terminator: "\r\n")
        let original = try Data(contentsOf: descURL)

        try MailboxTreeMutator.createMailbox(directory: root, name: "One")
        let bak = root.appendingPathComponent("descmap.pce.bak")
        XCTAssertEqual(try Data(contentsOf: bak), original)

        try MailboxTreeMutator.createMailbox(directory: root, name: "Two")
        XCTAssertEqual(try Data(contentsOf: bak), original,
                       "the backup is the original index, not the previous one")
    }

    // MARK: system mailboxes

    func testFreshDirectoryGetsAllFourSystemMailboxes() throws {
        let created = try MailboxTreeMutator.ensureSystemMailboxes(root: root)
        XCTAssertEqual(created, ["In", "Out", "Junk", "Trash"])

        XCTAssertEqual(try Data(contentsOf: descURL),
                       descmapData(lines: ["In,In.mbx,S,N", "Out,Out.mbx,S,N",
                                           "Junk,Junk.mbx,S,N", "Trash,Trash.mbx,S,N"],
                                   terminator: "\r\n"))
        let tree = MailStore(root: root).tree()
        XCTAssertEqual(tree.map(\.entry.type), [.inbox, .outbox, .junk, .trash])
        XCTAssertEqual(tree.map(\.messageCount), [0, 0, 0, 0])
    }

    /// The common case — every open of a real tree — must be a pure read.
    func testCompleteTreeIsUntouched() throws {
        try writeDescmap(lines: ["In,In.mbx,S,Y", "Out,Out.mbx,S,N",
                                 "Junk,Junk.mbx,S,N", "Trash,Trash.mbx,S,N",
                                 "KEEP,KEEP.mbx,M,N"], terminator: "\r\n")
        let before = try Data(contentsOf: descURL)

        XCTAssertEqual(try MailboxTreeMutator.ensureSystemMailboxes(root: root), [])
        XCTAssertEqual(try Data(contentsOf: descURL), before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("descmap.pce.bak").path),
            "a no-op must not even back the file up")
    }

    func testOnlyTheMissingRoleIsAdded() throws {
        try writeDescmap(lines: ["In,In.mbx,S,Y", "Out,Out.mbx,S,N",
                                 "Junk,Junk.mbx,S,N"], terminator: "\r\n")
        let before = try Data(contentsOf: descURL)

        XCTAssertEqual(try MailboxTreeMutator.ensureSystemMailboxes(root: root), ["Trash"])

        var expected = before
        expected.append(Data("Trash,Trash.mbx,S,N\r\n".utf8))
        XCTAssertEqual(try Data(contentsOf: descURL), expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mbxPath("Trash")))
    }

    /// Legacy fixture type chars (I/O/T/J) count as present — resolveType
    /// already honours them, and doubling In because its line says "I" would
    /// be a regression against our own fixtures.
    func testLegacyTypeCharsCountAsPresent() throws {
        try writeDescmap(lines: ["In,In.mbx,I,Y", "Out,Out.mbx,O,N",
                                 "Junk,Junk.mbx,J,N", "Trash,Trash.mbx,T,N"],
                         terminator: "\r\n")
        XCTAssertEqual(try MailboxTreeMutator.ensureSystemMailboxes(root: root), [])
    }

    /// An orphaned system .mbx — real mail whose index line went missing — is
    /// adopted, never overwritten.
    func testOrphanedSystemMailboxIsAdoptedNotReplaced() throws {
        try writeDescmap(lines: ["Out,Out.mbx,S,N", "Junk,Junk.mbx,S,N",
                                 "Trash,Trash.mbx,S,N"], terminator: "\r\n")
        try seedMailbox("In")   // on disk, not in the index
        let mail = try Data(contentsOf: root.appendingPathComponent("In.mbx"))

        XCTAssertEqual(try MailboxTreeMutator.ensureSystemMailboxes(root: root), ["In"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("In.mbx")), mail,
                       "adoption must not touch the mailbox's bytes")
        // The adopted line is *appended*, and the tree keeps descmap order —
        // so In sits last here, resolved to its proper role.
        XCTAssertEqual(MailStore(root: root).tree().last?.entry.type, .inbox)
    }

    /// A role whose canonical name is already taken by an ordinary mailbox is
    /// skipped: a second "In" line naming the same file would be worse than a
    /// missing role.
    func testRoleNameTakenByOrdinaryMailboxIsSkipped() throws {
        try writeDescmap(lines: ["In,In.mbx,M,N", "Out,Out.mbx,S,N",
                                 "Junk,Junk.mbx,S,N", "Trash,Trash.mbx,S,N"],
                         terminator: "\r\n")
        let before = try Data(contentsOf: descURL)

        XCTAssertEqual(try MailboxTreeMutator.ensureSystemMailboxes(root: root), [])
        XCTAssertEqual(try Data(contentsOf: descURL), before)
    }

    func testEnsureIsIdempotent() throws {
        XCTAssertEqual(try MailboxTreeMutator.ensureSystemMailboxes(root: root).count, 4)
        XCTAssertEqual(try MailboxTreeMutator.ensureSystemMailboxes(root: root), [])
    }

    func testEnsureMatchesAnLFOnlyFile() throws {
        try writeDescmap(lines: ["In,In.mbx,S,Y", "Out,Out.mbx,S,N",
                                 "Junk,Junk.mbx,S,N"], terminator: "\n")
        try MailboxTreeMutator.ensureSystemMailboxes(root: root)
        XCTAssertEqual(try Data(contentsOf: descURL),
                       descmapData(lines: ["In,In.mbx,S,Y", "Out,Out.mbx,S,N",
                                           "Junk,Junk.mbx,S,N", "Trash,Trash.mbx,S,N"],
                                   terminator: "\n"))
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

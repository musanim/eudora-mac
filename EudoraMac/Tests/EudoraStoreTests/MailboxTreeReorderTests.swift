import XCTest
@testable import EudoraStore

/// Reordering and folder-deletion edits to `descmap.pce`. Both are raw-byte
/// edits of a file real Eudora also reads, so these pin the order results, the
/// group/boundary rules, byte/line-ending preservation, and that folder delete
/// never destroys mail it should have refused.
final class MailboxTreeReorderTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-reorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writeDescmap(_ s: String) throws {
        try Data(s.utf8).write(to: dir.appendingPathComponent("descmap.pce"))
    }
    private func order() -> [String] { DescMap.read(directory: dir).map(\.filename) }

    // In, Out (system) · Aaa, Bbb (mailboxes) · Proj (folder).
    private let sample =
        "In,In.mbx,S,N\r\nOut,Out.mbx,S,N\r\nAaa,Aaa.mbx,M,N\r\nBbb,Bbb.mbx,M,N\r\nProj,Proj.fol,F,N\r\n"

    // MARK: reorder

    func testMoveMailboxUpThenDownRoundTrips() throws {
        try writeDescmap(sample)
        try MailboxTreeMutator.moveEntry(directory: dir, filename: "Bbb.mbx", direction: .up)
        XCTAssertEqual(order(), ["In.mbx", "Out.mbx", "Bbb.mbx", "Aaa.mbx", "Proj.fol"])
        try MailboxTreeMutator.moveEntry(directory: dir, filename: "Bbb.mbx", direction: .down)
        XCTAssertEqual(order(), ["In.mbx", "Out.mbx", "Aaa.mbx", "Bbb.mbx", "Proj.fol"])
    }

    /// A mailbox stops at the system block above it, and at the end of the list
    /// below it — but nothing else stops it.
    func testMailboxStopsOnlyAtSystemAndAtTheEnd() throws {
        try writeDescmap(sample)
        // Aaa is the topmost non-system entry: up would collide with a system
        // mailbox, which is the one boundary that remains.
        XCTAssertThrowsError(try MailboxTreeMutator.moveEntry(
            directory: dir, filename: "Aaa.mbx", direction: .up)) {
            XCTAssertEqual($0 as? MailboxTreeMutator.MoveError, .atBoundary)
        }
        // Bbb sits above a folder, and may now swap with it.
        try MailboxTreeMutator.moveEntry(directory: dir, filename: "Bbb.mbx", direction: .down)
        XCTAssertEqual(order(), ["In.mbx", "Out.mbx", "Aaa.mbx", "Proj.fol", "Bbb.mbx"])
        // Now it is last: down has nowhere to go.
        XCTAssertThrowsError(try MailboxTreeMutator.moveEntry(
            directory: dir, filename: "Bbb.mbx", direction: .down)) {
            XCTAssertEqual($0 as? MailboxTreeMutator.MoveError, .atBoundary)
        }
    }

    /// The case that prompted the change: `create` appends, so a new top-level
    /// mailbox lands below every folder and used to be stranded there with Move
    /// Up greyed out. It must be able to walk all the way up to the system block.
    func testNewMailboxAppendedBelowFoldersCanWalkToTheTop() throws {
        try writeDescmap("In,In.mbx,I,N\r\nP,P.fol,F,N\r\nQ,Q.fol,F,N\r\nNew,New.mbx,M,N\r\n")
        try MailboxTreeMutator.moveEntry(directory: dir, filename: "New.mbx", direction: .up)
        XCTAssertEqual(order(), ["In.mbx", "P.fol", "New.mbx", "Q.fol"])
        try MailboxTreeMutator.moveEntry(directory: dir, filename: "New.mbx", direction: .up)
        XCTAssertEqual(order(), ["In.mbx", "New.mbx", "P.fol", "Q.fol"])
        // Stopped by In, and by nothing before it.
        XCTAssertThrowsError(try MailboxTreeMutator.moveEntry(
            directory: dir, filename: "New.mbx", direction: .up)) {
            XCTAssertEqual($0 as? MailboxTreeMutator.MoveError, .atBoundary)
        }
    }

    func testSystemMailboxIsPinned() throws {
        try writeDescmap(sample)
        XCTAssertThrowsError(try MailboxTreeMutator.moveEntry(
            directory: dir, filename: "Out.mbx", direction: .down)) {
            XCTAssertEqual($0 as? MailboxTreeMutator.MoveError, .notMovable)
        }
    }

    /// A system line in the MIDDLE of the file must be stepped over, not stopped
    /// at. `ensureSystemMailboxes` appends a missing role, so a tree that gained
    /// Junk late reads In, …user's entries…, Junk — and anything created after
    /// that lands below it. Stopping there would strand the new mailbox with both
    /// move commands dead, and the entry blocking it is invisible, since the
    /// sidebar hides Junk by default.
    func testStepsOverASystemLineInTheMiddle() throws {
        try writeDescmap("In,In.mbx,I,N\r\nAaa,Aaa.mbx,M,N\r\nJunk,Junk.mbx,S,N\r\nNew,New.mbx,M,N\r\n")
        try MailboxTreeMutator.moveEntry(directory: dir, filename: "New.mbx", direction: .up)
        // New and Aaa exchanged; Junk did not move.
        XCTAssertEqual(order(), ["In.mbx", "New.mbx", "Junk.mbx", "Aaa.mbx"])
        // Now nothing movable above it — In is system and there is nothing beyond.
        XCTAssertThrowsError(try MailboxTreeMutator.moveEntry(
            directory: dir, filename: "New.mbx", direction: .up)) {
            XCTAssertEqual($0 as? MailboxTreeMutator.MoveError, .atBoundary)
        }
        // And back down again, over Junk.
        try MailboxTreeMutator.moveEntry(directory: dir, filename: "New.mbx", direction: .down)
        XCTAssertEqual(order(), ["In.mbx", "Aaa.mbx", "Junk.mbx", "New.mbx"])
    }

    func testFoldersAndMailboxesIntermix() throws {
        try writeDescmap("Aaa,Aaa.mbx,M,N\r\nP,P.fol,F,N\r\nQ,Q.fol,F,N\r\n")
        try MailboxTreeMutator.moveEntry(directory: dir, filename: "Q.fol", direction: .up)
        XCTAssertEqual(order(), ["Aaa.mbx", "Q.fol", "P.fol"])
        // A folder may now rise past a mailbox — the restriction this replaced.
        try MailboxTreeMutator.moveEntry(directory: dir, filename: "Q.fol", direction: .up)
        XCTAssertEqual(order(), ["Q.fol", "Aaa.mbx", "P.fol"])
        // And nothing above it, so that is the boundary.
        XCTAssertThrowsError(try MailboxTreeMutator.moveEntry(
            directory: dir, filename: "Q.fol", direction: .up)) {
            XCTAssertEqual($0 as? MailboxTreeMutator.MoveError, .atBoundary)
        }
    }

    func testUnknownFilename() throws {
        try writeDescmap(sample)
        XCTAssertThrowsError(try MailboxTreeMutator.moveEntry(
            directory: dir, filename: "Nope.mbx", direction: .up)) {
            XCTAssertEqual($0 as? MailboxTreeMutator.MoveError, .notFound)
        }
    }

    /// LF-only file, last line unterminated: the swap must not merge lines and
    /// must leave every line terminated, in the file's own dialect.
    func testPreservesDialectAndDoesNotMerge() throws {
        try writeDescmap("Aaa,Aaa.mbx,M,N\nBbb,Bbb.mbx,M,N\nCcc,Ccc.mbx,M,N")
        try MailboxTreeMutator.moveEntry(directory: dir, filename: "Ccc.mbx", direction: .up)
        XCTAssertEqual(order(), ["Aaa.mbx", "Ccc.mbx", "Bbb.mbx"])
        let text = String(data: try Data(contentsOf: dir.appendingPathComponent("descmap.pce")),
                          encoding: .isoLatin1)
        XCTAssertEqual(text, "Aaa,Aaa.mbx,M,N\nCcc,Ccc.mbx,M,N\nBbb,Bbb.mbx,M,N\n")
    }

    /// A blank line sitting between the two swapped entries must survive — the
    /// file is preserved byte-for-byte but for the swap itself.
    func testPreservesInteriorBlankLine() throws {
        try writeDescmap("Aaa,Aaa.mbx,M,N\r\n\r\nBbb,Bbb.mbx,M,N\r\n")
        try MailboxTreeMutator.moveEntry(directory: dir, filename: "Bbb.mbx", direction: .up)
        XCTAssertEqual(order(), ["Bbb.mbx", "Aaa.mbx"])
        let text = String(data: try Data(contentsOf: dir.appendingPathComponent("descmap.pce")),
                          encoding: .isoLatin1)
        XCTAssertEqual(text, "Bbb,Bbb.mbx,M,N\r\n\r\nAaa,Aaa.mbx,M,N\r\n")
    }

    // MARK: rename

    private func displays() -> [String] { DescMap.read(directory: dir).map(\.display) }

    func testRenameChangesDisplayKeepsEverythingElse() throws {
        try writeDescmap(sample)
        try MailboxTreeMutator.rename(directory: dir, filename: "Aaa.mbx", to: "Alpha")
        // Display changes; filename, order, and the rest of the file do not.
        XCTAssertEqual(displays(), ["In", "Out", "Alpha", "Bbb", "Proj"])
        XCTAssertEqual(order(), ["In.mbx", "Out.mbx", "Aaa.mbx", "Bbb.mbx", "Proj.fol"])
        let text = String(data: try Data(contentsOf: dir.appendingPathComponent("descmap.pce")),
                          encoding: .isoLatin1)
        XCTAssertEqual(text,
            "In,In.mbx,S,N\r\nOut,Out.mbx,S,N\r\nAlpha,Aaa.mbx,M,N\r\nBbb,Bbb.mbx,M,N\r\nProj,Proj.fol,F,N\r\n")
    }

    func testRenameFolder() throws {
        try writeDescmap("Aaa,Aaa.mbx,M,N\r\nP,P.fol,F,N\r\n")
        try MailboxTreeMutator.rename(directory: dir, filename: "P.fol", to: "Projects")
        XCTAssertEqual(displays(), ["Aaa", "Projects"])
        XCTAssertEqual(order(), ["Aaa.mbx", "P.fol"])   // filename unchanged
    }

    func testRenameRefusesDuplicateDisplay() throws {
        try writeDescmap(sample)
        XCTAssertThrowsError(try MailboxTreeMutator.rename(
            directory: dir, filename: "Aaa.mbx", to: "Bbb")) {
            XCTAssertEqual($0 as? MailboxTreeMutator.RenameError, .duplicate("Bbb"))
        }
        XCTAssertEqual(displays(), ["In", "Out", "Aaa", "Bbb", "Proj"])
    }

    func testRenameRefusesDuplicateFilenameStem() throws {
        // New name collides with another entry's filename stem, even though no
        // display name matches — create guards this too.
        try writeDescmap("Aaa,Aaa.mbx,M,N\r\nShown,Bbb.mbx,M,N\r\n")
        XCTAssertThrowsError(try MailboxTreeMutator.rename(
            directory: dir, filename: "Aaa.mbx", to: "Bbb")) {
            XCTAssertEqual($0 as? MailboxTreeMutator.RenameError, .duplicate("Shown"))
        }
    }

    func testRenameToOwnCaseChangeAllowed() throws {
        try writeDescmap(sample)
        try MailboxTreeMutator.rename(directory: dir, filename: "Aaa.mbx", to: "AAA")
        XCTAssertEqual(displays(), ["In", "Out", "AAA", "Bbb", "Proj"])
    }

    func testRenameRejectsCommaAndEmpty() throws {
        try writeDescmap(sample)
        XCTAssertThrowsError(try MailboxTreeMutator.rename(
            directory: dir, filename: "Aaa.mbx", to: "A,B")) {
            XCTAssertEqual($0 as? MailboxTreeMutator.RenameError, .invalidName)
        }
        XCTAssertThrowsError(try MailboxTreeMutator.rename(
            directory: dir, filename: "Aaa.mbx", to: "   ")) {
            XCTAssertEqual($0 as? MailboxTreeMutator.RenameError, .emptyName)
        }
        XCTAssertEqual(displays(), ["In", "Out", "Aaa", "Bbb", "Proj"])
    }

    func testRenameUnknownFilename() throws {
        try writeDescmap(sample)
        XCTAssertThrowsError(try MailboxTreeMutator.rename(
            directory: dir, filename: "Nope.mbx", to: "X")) {
            XCTAssertEqual($0 as? MailboxTreeMutator.RenameError, .notFound)
        }
    }

    /// LF-only file, unterminated last line: renaming the last entry must not
    /// disturb the dialect or merge lines.
    func testRenamePreservesDialect() throws {
        try writeDescmap("Aaa,Aaa.mbx,M,N\nBbb,Bbb.mbx,M,N")
        try MailboxTreeMutator.rename(directory: dir, filename: "Bbb.mbx", to: "Beta")
        let text = String(data: try Data(contentsOf: dir.appendingPathComponent("descmap.pce")),
                          encoding: .isoLatin1)
        XCTAssertEqual(text, "Aaa,Aaa.mbx,M,N\nBeta,Bbb.mbx,M,N")
    }

    // MARK: folder delete

    private func makeFolder(_ filename: String, contents: [(String, Data)] = []) throws -> URL {
        let folder = dir.appendingPathComponent(filename, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("descmap.pce"))
        for (name, data) in contents { try data.write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    func testDeleteEmptyFolderRemovesLineAndDirectory() throws {
        try writeDescmap("Aaa,Aaa.mbx,M,N\r\nP,P.fol,F,N\r\n")
        let folder = try makeFolder("P.fol")
        try MailboxTreeMutator.deleteEmptyFolder(directory: dir, filename: "P.fol")
        XCTAssertEqual(order(), ["Aaa.mbx"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testDeleteFolderRefusedWhenItHoldsAMailbox() throws {
        try writeDescmap("P,P.fol,F,N\r\n")
        // descmap-empty, but a real .mbx sits inside — orphaned mail must survive.
        let folder = try makeFolder("P.fol", contents: [("Secret.mbx", Data("hi".utf8))])
        XCTAssertThrowsError(try MailboxTreeMutator.deleteEmptyFolder(
            directory: dir, filename: "P.fol")) {
            XCTAssertEqual($0 as? MailboxTreeMutator.DeleteError, .notEmpty)
        }
        XCTAssertEqual(order(), ["P.fol"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("Secret.mbx").path))
    }

    // MARK: sort alphabetically

    func testSortInterleavesMailboxesAndFolders() throws {
        try writeDescmap("In,In.mbx,I,N\r\nZed,Zed.mbx,M,N\r\nMid,Mid.fol,F,N\r\nAce,Ace.mbx,M,N\r\n")
        XCTAssertTrue(try MailboxTreeMutator.sortEntries(directory: dir))
        XCTAssertEqual(order(), ["In.mbx", "Ace.mbx", "Mid.fol", "Zed.mbx"])
    }

    /// System entries hold their slots wherever they sit — including in the
    /// middle, which `ensureSystemMailboxes` can produce by appending Junk.
    func testSortLeavesSystemEntriesWhereTheyAre() throws {
        try writeDescmap("In,In.mbx,I,N\r\nZed,Zed.mbx,M,N\r\nJunk,Junk.mbx,S,N\r\nAce,Ace.mbx,M,N\r\n")
        XCTAssertTrue(try MailboxTreeMutator.sortEntries(directory: dir))
        // Slots 0 and 2 were system and keep their occupants; 1 and 3 take the
        // movable entries in sorted order.
        XCTAssertEqual(order(), ["In.mbx", "Ace.mbx", "Junk.mbx", "Zed.mbx"])
    }

    /// The Finder's ordering: case-insensitive, and numbers compared as numbers.
    func testSortIsCaseInsensitiveAndNumberAware() throws {
        try writeDescmap("Item 10,i10.mbx,M,N\r\nitem 2,i2.mbx,M,N\r\nItem 1,i1.mbx,M,N\r\n")
        XCTAssertTrue(try MailboxTreeMutator.sortEntries(directory: dir))
        XCTAssertEqual(order(), ["i1.mbx", "i2.mbx", "i10.mbx"])
    }

    func testSortReportsWhenAlreadyInOrder() throws {
        try writeDescmap("In,In.mbx,I,N\r\nAce,Ace.mbx,M,N\r\nZed,Zed.mbx,M,N\r\n")
        XCTAssertFalse(try MailboxTreeMutator.sortEntries(directory: dir))
        XCTAssertEqual(order(), ["In.mbx", "Ace.mbx", "Zed.mbx"])
    }

    /// Same fidelity promise as `moveEntry`: an LF-only file stays LF-only, the
    /// last line gains its terminator, and each entry's own bytes are carried
    /// across rather than rebuilt.
    func testSortPreservesDialectAndEntryBytes() throws {
        try writeDescmap("Zed,Zed.mbx,M,N\nAce,Ace.mbx,M,Y")
        XCTAssertTrue(try MailboxTreeMutator.sortEntries(directory: dir))
        let text = try String(contentsOf: dir.appendingPathComponent("descmap.pce"),
                              encoding: .isoLatin1)
        XCTAssertEqual(text, "Ace,Ace.mbx,M,Y\nZed,Zed.mbx,M,N\n")
    }

    func testSortOfAnEmptyOrMissingDescmap() throws {
        try writeDescmap("")
        XCTAssertFalse(try MailboxTreeMutator.sortEntries(directory: dir))
        let missing = dir.appendingPathComponent("nowhere", isDirectory: true)
        XCTAssertThrowsError(try MailboxTreeMutator.sortEntries(directory: missing)) {
            XCTAssertEqual($0 as? MailboxTreeMutator.MoveError, .noIndex)
        }
    }
}

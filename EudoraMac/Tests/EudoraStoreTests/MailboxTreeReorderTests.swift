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

    func testMailboxWontCrossIntoSystemOrFolders() throws {
        try writeDescmap(sample)
        // Aaa is the top mailbox: up would collide with a system mailbox.
        XCTAssertThrowsError(try MailboxTreeMutator.moveEntry(
            directory: dir, filename: "Aaa.mbx", direction: .up)) {
            XCTAssertEqual($0 as? MailboxTreeMutator.MoveError, .atBoundary)
        }
        // Bbb is the bottom mailbox: down would collide with a folder.
        XCTAssertThrowsError(try MailboxTreeMutator.moveEntry(
            directory: dir, filename: "Bbb.mbx", direction: .down)) {
            XCTAssertEqual($0 as? MailboxTreeMutator.MoveError, .atBoundary)
        }
        XCTAssertEqual(order(), ["In.mbx", "Out.mbx", "Aaa.mbx", "Bbb.mbx", "Proj.fol"])
    }

    func testSystemMailboxIsPinned() throws {
        try writeDescmap(sample)
        XCTAssertThrowsError(try MailboxTreeMutator.moveEntry(
            directory: dir, filename: "Out.mbx", direction: .down)) {
            XCTAssertEqual($0 as? MailboxTreeMutator.MoveError, .notMovable)
        }
    }

    func testFoldersReorderAmongThemselves() throws {
        try writeDescmap("Aaa,Aaa.mbx,M,N\r\nP,P.fol,F,N\r\nQ,Q.fol,F,N\r\n")
        try MailboxTreeMutator.moveEntry(directory: dir, filename: "Q.fol", direction: .up)
        XCTAssertEqual(order(), ["Aaa.mbx", "Q.fol", "P.fol"])
        // Q is now the top folder — up would collide with the mailbox above.
        XCTAssertThrowsError(try MailboxTreeMutator.moveEntry(
            directory: dir, filename: "Q.fol", direction: .up))
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
}

import XCTest
import Foundation
@testable import EudoraStore

/// Tests for `MailboxTreeMutator.moveInto` — the descmap.pce + file work behind
/// "Move to group": relocating a mailbox or folder into another folder (or the
/// tree root). The moved line's bytes must survive verbatim, both descmaps must
/// end consistent, and the refusals (system mailboxes, cycles, name clashes)
/// must fire before anything is touched.
final class MailboxMoveIntoTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("eudora-moveinto-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    // MARK: helpers

    private func writeDescmap(_ dir: URL, _ lines: [String], terminator: String = "\r\n") throws {
        try Data(lines.map { $0 + terminator }.joined().utf8)
            .write(to: dir.appendingPathComponent("descmap.pce"))
    }
    private func makeMailbox(_ dir: URL, _ name: String) throws {
        try Data("mail".utf8).write(to: dir.appendingPathComponent("\(name).mbx"))
        try TocWriter.data(entries: []).write(to: dir.appendingPathComponent("\(name).toc"))
    }
    @discardableResult
    private func makeFolder(_ parent: URL, _ name: String, contents: [String] = []) throws -> URL {
        let dir = parent.appendingPathComponent("\(name).fol", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeDescmap(dir, contents)
        return dir
    }
    private func names(_ dir: URL) -> [String] { DescMap.read(directory: dir).map(\.display) }
    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    // MARK: mailbox

    func testMoveMailboxIntoFolderMovesFilesAndBothDescmaps() throws {
        try writeDescmap(root, ["In,In.mbx,S,Y", "Alpha,Alpha.mbx,M,N", "Trash,Trash.mbx,S,N"])
        try makeMailbox(root, "Alpha")
        let group = try makeFolder(root, "Group")

        try MailboxTreeMutator.moveInto(filename: "Alpha.mbx", from: root, to: group)

        XCTAssertEqual(names(root), ["In", "Trash"])
        XCTAssertEqual(names(group), ["Alpha"])
        XCTAssertFalse(exists(root.appendingPathComponent("Alpha.mbx")))
        XCTAssertTrue(exists(group.appendingPathComponent("Alpha.mbx")))
        XCTAssertTrue(exists(group.appendingPathComponent("Alpha.toc")))

        // The line's bytes are carried over verbatim.
        let destText = String(
            data: try Data(contentsOf: group.appendingPathComponent("descmap.pce")),
            encoding: .isoLatin1)!
        XCTAssertTrue(destText.contains("Alpha,Alpha.mbx,M,N"), destText)
    }

    func testMoveMailboxBackToTopLevel() throws {
        let group = try makeFolder(root, "Group", contents: ["Alpha,Alpha.mbx,M,N"])
        try makeMailbox(group, "Alpha")
        try writeDescmap(root, ["In,In.mbx,S,Y", "Group,Group.fol,F,N"])

        try MailboxTreeMutator.moveInto(filename: "Alpha.mbx", from: group, to: root)

        XCTAssertEqual(names(group), [])
        XCTAssertTrue(names(root).contains("Alpha"))
        XCTAssertTrue(exists(root.appendingPathComponent("Alpha.mbx")))
        XCTAssertFalse(exists(group.appendingPathComponent("Alpha.mbx")))
    }

    // MARK: folder

    func testMoveFolderIntoFolderCarriesItsContents() throws {
        let group = try makeFolder(root, "Group", contents: ["Mail,Mail.mbx,M,N"])
        try makeMailbox(group, "Mail")
        let other = try makeFolder(root, "Other")
        try writeDescmap(root, ["Group,Group.fol,F,N", "Other,Other.fol,F,N"])

        try MailboxTreeMutator.moveInto(filename: "Group.fol", from: root, to: other)

        XCTAssertEqual(names(root), ["Other"])
        XCTAssertEqual(names(other), ["Group"])
        XCTAssertTrue(exists(other.appendingPathComponent("Group.fol/Mail.mbx")))
        XCTAssertFalse(exists(root.appendingPathComponent("Group.fol")))
    }

    // MARK: refusals

    func testSystemMailboxRefused() throws {
        try writeDescmap(root, ["In,In.mbx,S,Y"])
        try makeMailbox(root, "In")
        let group = try makeFolder(root, "Group")
        XCTAssertThrowsError(
            try MailboxTreeMutator.moveInto(filename: "In.mbx", from: root, to: group)
        ) { XCTAssertEqual($0 as? MailboxTreeMutator.MoveIntoError, .notMovable) }
        // Untouched.
        XCTAssertTrue(exists(root.appendingPathComponent("In.mbx")))
    }

    func testFolderIntoOwnDescendantRefused() throws {
        let group = try makeFolder(root, "Group", contents: ["Sub,Sub.fol,F,N"])
        let sub = try makeFolder(group, "Sub")
        try writeDescmap(root, ["Group,Group.fol,F,N"])
        XCTAssertThrowsError(
            try MailboxTreeMutator.moveInto(filename: "Group.fol", from: root, to: sub)
        ) { XCTAssertEqual($0 as? MailboxTreeMutator.MoveIntoError, .intoDescendant) }
        XCTAssertTrue(exists(root.appendingPathComponent("Group.fol")))
    }

    func testDuplicateNameAtDestinationRefusedAndSourceIntact() throws {
        try writeDescmap(root, ["Alpha,Alpha.mbx,M,N"])
        try makeMailbox(root, "Alpha")
        let group = try makeFolder(root, "Group", contents: ["Alpha,Alpha.mbx,M,N"])
        try makeMailbox(group, "Alpha")

        XCTAssertThrowsError(
            try MailboxTreeMutator.moveInto(filename: "Alpha.mbx", from: root, to: group)
        ) {
            guard case .duplicate = ($0 as? MailboxTreeMutator.MoveIntoError) else {
                return XCTFail("expected .duplicate, got \(String(describing: $0))")
            }
        }
        // Refused before any change: the source still has its mailbox and line.
        XCTAssertTrue(exists(root.appendingPathComponent("Alpha.mbx")))
        XCTAssertEqual(names(root), ["Alpha"])
    }

    func testNoOpWhenSourceEqualsDestinationReturnsFalse() throws {
        try writeDescmap(root, ["Alpha,Alpha.mbx,M,N"])
        try makeMailbox(root, "Alpha")
        let moved = try MailboxTreeMutator.moveInto(filename: "Alpha.mbx", from: root, to: root)
        XCTAssertFalse(moved)
        XCTAssertTrue(exists(root.appendingPathComponent("Alpha.mbx")))
        XCTAssertEqual(names(root), ["Alpha"])
    }

    func testLockedMailboxRefused() throws {
        try writeDescmap(root, ["Alpha,Alpha.mbx,M,N"])
        try makeMailbox(root, "Alpha")
        try Data().write(to: root.appendingPathComponent("Alpha.lck"))
        let group = try makeFolder(root, "Group")
        XCTAssertThrowsError(
            try MailboxTreeMutator.moveInto(filename: "Alpha.mbx", from: root, to: group)
        ) { XCTAssertEqual($0 as? MailboxTreeMutator.MoveIntoError, .locked) }
        XCTAssertTrue(exists(root.appendingPathComponent("Alpha.mbx")))
    }

    func testMailboxBackupCompanionMovesToo() throws {
        try writeDescmap(root, ["Alpha,Alpha.mbx,M,N"])
        try makeMailbox(root, "Alpha")
        try Data("old".utf8).write(to: root.appendingPathComponent("Alpha.mbx.bak"))
        let group = try makeFolder(root, "Group")

        try MailboxTreeMutator.moveInto(filename: "Alpha.mbx", from: root, to: group)

        XCTAssertTrue(exists(group.appendingPathComponent("Alpha.mbx.bak")))
        XCTAssertFalse(exists(root.appendingPathComponent("Alpha.mbx.bak")))
    }

    /// The headline promise: a Latin-1 display name survives the move byte-for-byte.
    func testLatin1DisplayNamePreserved() throws {
        // "Café" — the é is 0xE9 in Latin-1.
        let display = "Caf\u{e9}"
        let lineBytes = Data((display + ",Cafe.mbx,M,N\r\n").utf8Latin1)
        try lineBytes.write(to: root.appendingPathComponent("descmap.pce"))
        try makeMailbox(root, "Cafe")
        let group = try makeFolder(root, "Group")

        try MailboxTreeMutator.moveInto(filename: "Cafe.mbx", from: root, to: group)

        let destData = try Data(contentsOf: group.appendingPathComponent("descmap.pce"))
        // The é byte (0xE9) is present verbatim in the destination.
        XCTAssertTrue(destData.contains(0xE9), "the Latin-1 é byte must survive")
        XCTAssertEqual(DescMap.read(directory: group).first?.display, display)
    }

    func testAppendsToDestWithNoTrailingNewline() throws {
        try writeDescmap(root, ["Alpha,Alpha.mbx,M,N"])
        try makeMailbox(root, "Alpha")
        // A destination descmap whose last line has no terminator.
        let group = root.appendingPathComponent("Group.fol", isDirectory: true)
        try fm.createDirectory(at: group, withIntermediateDirectories: true)
        try Data("Existing,Existing.mbx,M,N".utf8)      // no trailing \r\n
            .write(to: group.appendingPathComponent("descmap.pce"))
        try makeMailbox(group, "Existing")

        try MailboxTreeMutator.moveInto(filename: "Alpha.mbx", from: root, to: group)

        // Both lines are readable — the append didn't merge into the un-terminated one.
        XCTAssertEqual(Set(names(group)), ["Existing", "Alpha"])
    }
}

private extension String {
    /// Latin-1 bytes, for building a descmap with a non-ASCII display name.
    var utf8Latin1: Data { data(using: .isoLatin1) ?? Data() }
}

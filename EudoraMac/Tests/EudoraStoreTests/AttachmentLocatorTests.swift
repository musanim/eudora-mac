import XCTest
import Foundation
@testable import EudoraStore

/// Covers resolving Eudora's recorded Windows paths onto files in the tree's
/// Attachments folder.
final class AttachmentLocatorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EudoraLocator-\(UUID().uuidString)", isDirectory: true)
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: attachments.appendingPathComponent("invoice.pdf"))
        try Data("doc".utf8).write(to: attachments
            .appendingPathComponent("Christine & Stephen 5876 Park Ave.doc"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testResolvesRecordedWindowsPathToLocalFile() {
        let loc = AttachmentLocator(mailRoot: root)
        let found = loc.locate(recordedPath: "Y:\\Documents\\Active\\Eudora\\Attachments\\invoice.pdf")

        XCTAssertEqual(found.filename, "invoice.pdf")
        XCTAssertTrue(found.isFound)
        XCTAssertEqual(found.url?.lastPathComponent, "invoice.pdf")
    }

    // Spaces and ampersands are common in these names and must survive intact.
    func testResolvesNameWithSpacesAndAmpersand() {
        let loc = AttachmentLocator(mailRoot: root)
        let found = loc.locate(
            recordedPath: "\"Y:\\Eudora\\Attachments\\Christine & Stephen 5876 Park Ave.doc\"")

        XCTAssertTrue(found.isFound)
        XCTAssertEqual(found.filename, "Christine & Stephen 5876 Park Ave.doc")
        // The stored path is unquoted, so it reads cleanly in a tooltip.
        XCTAssertEqual(found.recordedPath,
                       "Y:\\Eudora\\Attachments\\Christine & Stephen 5876 Park Ave.doc")
    }

    // A recorded file that didn't come across is still reported, so the message
    // isn't silently misrepresented as having had no attachment.
    func testMissingFileIsReportedNotDropped() {
        let loc = AttachmentLocator(mailRoot: root)
        let found = loc.locate(recordedPath: "Y:\\Eudora\\Attachments\\gone.pdf")

        XCTAssertEqual(found.filename, "gone.pdf")
        XCTAssertFalse(found.isFound)
        XCTAssertNil(found.url)
        XCTAssertEqual(found.recordedPath, "Y:\\Eudora\\Attachments\\gone.pdf")
    }

    // Filenames come from message content, so they are untrusted: nothing may
    // escape the Attachments folder.
    func testRejectsPathEscapes() {
        let loc = AttachmentLocator(mailRoot: root)
        XCTAssertNil(loc.url(forFilename: "../secret.txt"))
        XCTAssertNil(loc.url(forFilename: "sub/dir.txt"))
        XCTAssertNil(loc.url(forFilename: "sub\\dir.txt"))
        XCTAssertNil(loc.url(forFilename: ".."))
        XCTAssertNil(loc.url(forFilename: ""))
    }

    // A directory that happens to share a name is not an attachment.
    func testDirectoryIsNotAFile() throws {
        let dir = root.appendingPathComponent("Attachments/folder.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertNil(AttachmentLocator(mailRoot: root).url(forFilename: "folder.pdf"))
    }

    func testLocateAllReadsMarkersInOrder() {
        let raw = [
            "Content-Type: text/plain",
            "",
            "body",
            "",
            "Attachment Converted: \"Y:\\Eudora\\Attachments\\invoice.pdf\"",
            "Attachment Converted: \"Y:\\Eudora\\Attachments\\gone.pdf\"",
        ].joined(separator: "\r\n")

        let msg = MIMEParser.parse(Array(raw.utf8))
        let found = AttachmentLocator(mailRoot: root).locateAll(in: msg)

        XCTAssertEqual(found.map(\.filename), ["invoice.pdf", "gone.pdf"])
        XCTAssertEqual(found.map(\.isFound), [true, false])
    }
}

import XCTest
import Foundation
@testable import EudoraStore

/// Every rewrite of an existing `.toc` must keep the bytes `TocEntry` doesn't
/// model.
///
/// `TocEntry` covers seven fields of a 218-byte entry, and over `phaseX` 97% of
/// real entries carry data outside them — Eudora 7's timestamps, flags, label
/// and window state — as do 116 of 120 folder headers. Eudora 8 never reads
/// them, so blanking them breaks nothing visible; which is why these tests
/// compare raw bytes rather than parsed entries. Nothing else would notice.
///
/// The fixture pokes a distinct value per entry into the positions `phaseX`
/// showed populated, so a test can tell not only that bytes survived but that
/// they stayed with the right message after the entries around them moved.
final class TocPatchTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-tocpatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - status

    func testSetStatusByOffsetChangesOnlyTheStatusByte() throws {
        let before = try buildPokedBox(count: 3)
        let target = Toc.read(tocURL)![1].offset

        try MailboxMutator.setStatus(base: base, offset: target, status: MailboxMutator.statusRead)

        let after = try tocBytes()
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(header(after), header(before), "folder header blanked")
        XCTAssertEqual(entry(after, 0), entry(before, 0))
        XCTAssertEqual(entry(after, 2), entry(before, 2))
        XCTAssertEqual(differingPositions(entry(before, 1), entry(after, 1)), [12])
        XCTAssertEqual(Toc.read(tocURL)![1].status, MailboxMutator.statusRead)
    }

    func testSetStatusByIndexChangesOnlyTheStatusByte() throws {
        let before = try buildPokedBox(count: 3)

        try MailboxMutator.setStatus(base: base, index: 3, status: MailboxMutator.statusReplied)

        let after = try tocBytes()
        XCTAssertEqual(header(after), header(before))
        XCTAssertEqual(entry(after, 0), entry(before, 0))
        XCTAssertEqual(entry(after, 1), entry(before, 1))
        XCTAssertEqual(differingPositions(entry(before, 2), entry(after, 2)), [12])
    }

    // MARK: - replace

    /// The record before is untouched, the one after differs only in its
    /// offset, and the replaced one only in the fields `replace` sets.
    func testReplaceKeepsUnmodelledBytesOfEveryEntry() throws {
        let before = try buildPokedBox(count: 3)

        try MailboxMutator.replace(base: base, index: 2,
                                   messageData: message(subject: "Two",
                                                        body: String(repeating: "x", count: 500)),
                                   status: MailboxMutator.statusUnsent,
                                   who: "someone.else@example.com", subject: "Two")

        let after = try tocBytes()
        XCTAssertEqual(header(after), header(before))
        XCTAssertEqual(entry(after, 0), entry(before, 0))
        XCTAssertEqual(Set(differingPositions(entry(before, 2), entry(after, 2))).subtracting(0..<4),
                       [], "the entry after the replacement may change only its offset")

        let allowed = Set(4..<8).union([12]).union(18..<178)
        let changed = Set(differingPositions(entry(before, 1), entry(after, 1)))
        XCTAssertTrue(changed.isSubset(of: allowed),
                      "replaced entry changed outside its fields: \(changed.subtracting(allowed).sorted())")
        XCTAssertEqual(entry(after, 1)[8], poke(1, 8), "replaced entry lost its timestamp bytes")
        XCTAssertEqual(entry(after, 1)[208], poke(1, 208))

        // And the index still describes the mailbox.
        let recs = Mbox.findRecords(try [UInt8](Data(contentsOf: base.appendingPathExtension("mbx"))))
        XCTAssertEqual(Toc.read(tocURL)!.map(\.offset), recs.map(\.offset))
        XCTAssertEqual(Toc.read(tocURL)!.map(\.subject), ["S1", "Two", "S3"])
    }

    // MARK: - remove and move

    /// The survivors keep their own bytes — the poked values follow the
    /// message, not the slot it used to occupy.
    func testRemoveKeepsTheSurvivorsBytesWithTheRightMessages() throws {
        let before = try buildPokedBox(count: 4)

        try MailboxMutator.removeMany(base: base, indices: [1, 3])

        let after = try tocBytes()
        XCTAssertEqual(after.count, Toc.folderSize + 2 * Toc.entrySize)
        XCTAssertEqual(header(after), header(before))
        // Old entries 1 and 3 (0-based) survive as new 0 and 1; each may differ
        // only in its offset.
        XCTAssertEqual(Set(differingPositions(entry(before, 1), entry(after, 0))).subtracting(0..<4), [])
        XCTAssertEqual(Set(differingPositions(entry(before, 3), entry(after, 1))).subtracting(0..<4), [])
        XCTAssertEqual(Toc.read(tocURL)!.map(\.subject), ["S2", "S4"])
    }

    func testMoveKeepsTheSourceSurvivorsBytes() throws {
        let before = try buildPokedBox(count: 3)
        let dest = root.appendingPathComponent("Dest")
        _ = try Outbox.append(messageData: message(subject: "D1", body: "dest"), to: dest,
                              who: "you@example.com", subject: "D1")

        try MailboxMutator.moveMany(from: base, indices: [2], to: dest)

        let after = try tocBytes()
        XCTAssertEqual(header(after), header(before))
        XCTAssertEqual(entry(after, 0), entry(before, 0))
        XCTAssertEqual(Set(differingPositions(entry(before, 2), entry(after, 1))).subtracting(0..<4), [])
        XCTAssertEqual(Toc.read(dest.appendingPathExtension("toc"))!.map(\.subject), ["D1", "S2"])
    }

    // MARK: - append

    func testAppendKeepsThePriorEntriesAndHeader() throws {
        let before = try buildPokedBox(count: 2)

        _ = try Outbox.append(messageData: message(subject: "S3", body: "three"), to: base,
                              who: "you@example.com", subject: "S3")

        let after = try tocBytes()
        XCTAssertEqual(after.count, Toc.folderSize + 3 * Toc.entrySize)
        XCTAssertEqual(header(after), header(before))
        XCTAssertEqual(entry(after, 0), entry(before, 0))
        XCTAssertEqual(entry(after, 1), entry(before, 1))
        XCTAssertEqual(Toc.read(tocURL)!.map(\.subject), ["S1", "S2", "S3"])
    }

    // MARK: - the patch itself

    /// An unchanged string is not rewritten, so bytes after its terminator
    /// survive; a changed one gets the new text and a NUL, and the bytes past
    /// that NUL are still left alone.
    func testChangedStringOverwritesOnlyUpToItsTerminator() {
        let e = TocEntry(offset: 0, length: 10, status: 1, priority: 4,
                         date: "D", to: "To", subject: "A long subject")
        var raw = [UInt8](TocWriter.data(entries: [e]))
        let start = Toc.folderSize
        raw[start + 18 + 30] = 0x99           // date-field tail, field unchanged
        raw[start + 114 + 60] = 0x77          // subject-field tail, field changed

        let changed = TocEntry(offset: 0, length: 10, status: 1, priority: 4,
                               date: "D", to: "To", subject: "Short")
        let out = [UInt8](TocWriter.patched(original: Data(raw),
                                            entries: [(source: 0, entry: changed)]))

        XCTAssertEqual(out[start + 18 + 30], 0x99)
        XCTAssertEqual(out[start + 114 + 60], 0x77)
        XCTAssertEqual(out[start + 114 + 5], 0, "new subject must be terminated")
        XCTAssertEqual(Toc.parse(out)![0].subject, "Short")
    }

    /// A new entry (no source) is a fresh one, and an index too short to have a
    /// header falls back to a plain build rather than trapping.
    func testNewEntriesAndHeaderlessOriginal() {
        let e = TocEntry(offset: 0, length: 10, status: 1, priority: 4,
                         date: "D", to: "To", subject: "S")
        let fresh = TocWriter.patched(original: Data([1, 2, 3]),
                                      entries: [(source: nil, entry: e)])
        XCTAssertEqual(fresh, TocWriter.data(entries: [e]))

        let outOfRange = TocWriter.patched(original: TocWriter.data(entries: []),
                                           entries: [(source: 5, entry: e)])
        XCTAssertEqual(outOfRange, TocWriter.data(entries: [e]))
    }

    // MARK: - fixture

    private var base: URL { root.appendingPathComponent("Box") }
    private var tocURL: URL { base.appendingPathExtension("toc") }

    /// Positions inside an entry that `phaseX` showed populated, all outside
    /// the modelled fields or past a string's terminator.
    private let pokedPositions = [8, 9, 14, 15, 46, 49, 182, 208]

    /// A distinct, non-zero value per entry and position.
    private func poke(_ entryIndex: Int, _ position: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: 0x40 + entryIndex * 16 + pokedPositions.firstIndex(of: position)!)
    }

    /// `count` messages S1…Sn written through `Outbox.append`, then the `.toc`
    /// poked as Eudora 7 would have left it. Returns the poked bytes.
    @discardableResult
    private func buildPokedBox(count: Int) throws -> [UInt8] {
        for i in 1...count {
            _ = try Outbox.append(messageData: message(subject: "S\(i)", body: "body \(i)"),
                                  to: base, status: MailboxMutator.statusSent,
                                  who: "you@example.com", subject: "S\(i)")
        }
        var raw = try tocBytes()
        XCTAssertEqual(raw.count, Toc.folderSize + count * Toc.entrySize)
        raw[8] = 0xAB
        raw[41] = 0xCD
        for k in 0..<count {
            let start = Toc.folderSize + k * Toc.entrySize
            for p in pokedPositions { raw[start + p] = poke(k, p) }
        }
        try Data(raw).write(to: tocURL)
        return raw
    }

    private func tocBytes() throws -> [UInt8] { [UInt8](try Data(contentsOf: tocURL)) }

    private func header(_ raw: [UInt8]) -> [UInt8] { Array(raw[0..<Toc.folderSize]) }

    private func entry(_ raw: [UInt8], _ k: Int) -> [UInt8] {
        let start = Toc.folderSize + k * Toc.entrySize
        return Array(raw[start..<(start + Toc.entrySize)])
    }

    private func differingPositions(_ a: [UInt8], _ b: [UInt8]) -> [Int] {
        zip(a, b).enumerated().compactMap { $0.element.0 == $0.element.1 ? nil : $0.offset }
    }

    private func message(subject: String, body: String) -> Data {
        Data([
            "From: me@example.com",
            "To: you@example.com",
            "Subject: \(subject)",
            "Content-Type: text/plain; charset=us-ascii",
            "",
            body,
            "",
        ].joined(separator: "\r\n").utf8)
    }
}

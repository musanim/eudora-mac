import XCTest
@testable import EudoraStore

/// `MailStore.cachedDates(at:)` — the dates Eudora kept in the `.toc`, keyed by
/// record offset.
///
/// This exists because **Eudora 7 never wrote a `Date:` header into a message it
/// composed**, only into the copy that went over the wire. Measured on the real
/// tree: of 694 such messages in one mailbox, not one has the header. So every
/// message Stephen ever sent was indexed and rendered as undated, while the
/// `.toc` had the date the whole time.
///
/// The contract these pin down is narrow and worth keeping narrow: a `.toc` read
/// and nothing else, keyed on the `.toc`'s own offsets, empty when there is no
/// `.toc` to read. Reaching for `list(at:)` instead would read and record-scan
/// the entire `.mbx` first — 1.59 GB across the real tree, for 54 MB of answers.
final class MailStoreCachedDatesTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-cacheddates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var base: URL { root.appendingPathComponent("Box") }

    /// A message with **no `Date:` header** — the shape this whole feature is
    /// about. `Outbox.append` writes the `.toc` entry, dated, either way.
    private func appendDateless(subject: String, at date: Date) throws -> Int {
        let raw = Data(("From: me@x.com\r\nTo: you@x.com\r\nSubject: \(subject)\r\n\r\nbody\r\n").utf8)
        return try Outbox.append(messageData: raw, to: base,
                                 status: MailboxMutator.statusSent,
                                 who: "you@x.com", subject: subject,
                                 date: date).messageOffset
    }

    func testReturnsATocDateForEveryRecordOffset() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try appendDateless(subject: "one", at: when)
        let second = try appendDateless(subject: "two", at: when.addingTimeInterval(3600))

        let dates = MailStore(root: root).cachedDates(at: base)
        XCTAssertEqual(dates.count, 2)
        XCTAssertNotNil(dates[first], "no cached date at the first record's offset")
        XCTAssertNotNil(dates[second], "no cached date at the second record's offset")
        XCTAssertFalse(dates[first]?.isEmpty ?? true)
        XCTAssertNotEqual(dates[first], dates[second], "an hour apart should not cache alike")
    }

    /// The keys must be the offsets `Mbox.findRecords` reports, since that is
    /// what every caller looks up. A mismatch would silently attach one
    /// message's date to another, or to none.
    func testKeysMatchTheRecordOffsetsCallersHave() throws {
        _ = try appendDateless(subject: "one", at: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try appendDateless(subject: "two", at: Date(timeIntervalSince1970: 1_700_003_600))

        let store = MailStore(root: root)
        let dates = store.cachedDates(at: base)
        let offsets = store.loadMessages(at: base).map(\.record.offset)
        XCTAssertEqual(offsets.count, 2)
        for offset in offsets {
            XCTAssertNotNil(dates[offset], "record at \(offset) has no cached date")
        }
    }

    /// No `.toc` means no answer — and, deliberately, no fallback. Without one a
    /// listing's date *is* the message's own `Date:` header, which every caller
    /// already has, so scanning to produce it would be pure cost.
    func testEmptyWhenThereIsNoToc() throws {
        _ = try appendDateless(subject: "one", at: Date(timeIntervalSince1970: 1_700_000_000))
        try FileManager.default.removeItem(at: base.appendingPathExtension("toc"))
        XCTAssertTrue(MailStore(root: root).cachedDates(at: base).isEmpty)
    }

    func testEmptyForAMailboxThatIsNotThere() {
        XCTAssertTrue(MailStore(root: root)
            .cachedDates(at: root.appendingPathComponent("Nope")).isEmpty)
    }
}

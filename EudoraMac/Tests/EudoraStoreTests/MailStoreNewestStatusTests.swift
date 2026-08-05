import XCTest
@testable import EudoraStore

/// `MailStore.newestStatus(base:)` / `newestIsUnread(base:)` — the one byte
/// behind the sidebar's green In badge.
///
/// The badge means "In's most recent message is unread", so the two things worth
/// pinning are the ones a careless implementation gets wrong: that "newest" is
/// the **last** entry in the `.toc` rather than the first, and that a mailbox
/// with nothing to read answers "don't know" instead of "unread".
///
/// Deliberately narrow, like `cachedDates`: this reads one 218-byte record and
/// must never grow into a listing. Reading the whole `.toc` to look at its end
/// would be megabytes of work per tree walk on a real In box, and this is called
/// on every one of them.
final class MailStoreNewestStatusTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eudora-newest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var base: URL { root.appendingPathComponent("In") }

    @discardableResult
    private func append(_ subject: String, status: Int) throws -> Int {
        let raw = Data(("From: them@x.com\r\nTo: me@x.com\r\nSubject: \(subject)\r\n\r\nbody\r\n").utf8)
        return try Outbox.append(messageData: raw, to: base, status: status,
                                 who: "them@x.com", subject: subject,
                                 date: Date(timeIntervalSince1970: 1_700_000_000)).messageOffset
    }

    func testNewestUnreadIsSeenThroughOlderReadMail() throws {
        try append("old and read", status: MailboxMutator.statusRead)
        try append("just arrived", status: MailboxMutator.statusUnread)

        let store = MailStore(root: root)
        XCTAssertEqual(store.newestStatus(base: base), MailboxMutator.statusUnread)
        XCTAssertTrue(store.newestIsUnread(base: base))
    }

    /// The case the whole rule turns on: a backlog of unread mail behind a newest
    /// message that *has* been read. The badge must be out — that is Stephen's
    /// "my perusal of the In box is complete", and it is where this differs from
    /// `DescMapEntry.hasUnread`, which would still be true here.
    func testNewestReadIsFalseEvenWithOlderUnreadMail() throws {
        try append("unread backlog", status: MailboxMutator.statusUnread)
        try append("second unread", status: MailboxMutator.statusUnread)
        try append("newest, and read", status: MailboxMutator.statusRead)

        let store = MailStore(root: root)
        XCTAssertEqual(store.newestStatus(base: base), MailboxMutator.statusRead)
        XCTAssertFalse(store.newestIsUnread(base: base))
    }

    /// Guards the ordering assumption explicitly. If "newest" were ever taken as
    /// the *first* entry, the test above would still pass by luck on a two-message
    /// mailbox; this one wouldn't.
    func testReadsTheLastEntryNotTheFirst() throws {
        // A third distinct value, so neither "first" nor "read" could produce a
        // passing answer by coincidence.
        try append("first", status: MailboxMutator.statusUnread)
        try append("middle", status: MailboxMutator.statusUnread)
        try append("last", status: MailboxMutator.statusSent)

        XCTAssertEqual(MailStore(root: root).newestStatus(base: base),
                       MailboxMutator.statusSent)
    }

    func testSingleMessageMailbox() throws {
        try append("only one", status: MailboxMutator.statusUnread)
        XCTAssertTrue(MailStore(root: root).newestIsUnread(base: base))
    }

    /// No `.toc` at all: nil, not a guess. The caller reads that as "no badge"
    /// rather than reading the `.mbx` to find out, which is the trade this whole
    /// function exists to make.
    func testNoTocIsNilRatherThanUnread() {
        let store = MailStore(root: root)
        XCTAssertNil(store.newestStatus(base: base))
        XCTAssertFalse(store.newestIsUnread(base: base))
    }

    /// A `.toc` holding only its 104-byte folder header — a mailbox that exists
    /// and is empty. Must not read a record out of the header, and must not
    /// return a byte from beyond the end of the file.
    func testHeaderOnlyTocIsNil() throws {
        try Data(count: Toc.folderSize).write(to: base.appendingPathExtension("toc"))
        XCTAssertNil(MailStore(root: root).newestStatus(base: base))
    }

    /// A trailing partial record — a `.toc` caught mid-write, or truncated. The
    /// entry count is derived from the file size by integer division, so the
    /// partial tail is not counted and the last *whole* record answers.
    func testTrailingPartialRecordIsIgnored() throws {
        try append("whole record", status: MailboxMutator.statusUnread)
        let toc = base.appendingPathExtension("toc")
        let existing = try Data(contentsOf: toc)
        try (existing + Data(count: Toc.entrySize / 2)).write(to: toc)

        XCTAssertEqual(MailStore(root: root).newestStatus(base: base),
                       MailboxMutator.statusUnread)
    }
}

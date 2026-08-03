import XCTest
@testable import EudoraSearch

/// "Where does this person's mail usually go?" — the query behind smart
/// move-to.
final class FilingHistoryTests: XCTestCase {

    // MARK: the phrase

    /// The index is tokenised with `unicode61`, which splits on punctuation, so
    /// an address is stored as several tokens and searching for it verbatim
    /// finds nothing. This is the whole reason the helper exists.
    func testAnAddressBecomesItsTokensAsAPhrase() {
        XCTAssertEqual(SearchIndex.addressPhrase("greg@gregsandow.com"),
                       "\"greg gregsandow com\"")
    }

    func testCaseIsNormalised() {
        XCTAssertEqual(SearchIndex.addressPhrase("Greg@GregSandow.COM"),
                       SearchIndex.addressPhrase("greg@gregsandow.com"))
    }

    /// Dots, plus-addressing and dashes are all token separators to the
    /// tokeniser, so they must be here too or the phrase won't line up with
    /// what was stored.
    func testEveryPunctuationFormSplitsTheSameWayTheIndexDid() {
        XCTAssertEqual(SearchIndex.addressPhrase("first.last+tag@sub-domain.example.com"),
                       "\"first last tag sub domain example com\"")
    }

    /// It is a phrase, not loose terms: loose terms would match any message
    /// merely *mentioning* the domain, which on a large archive is a flood of
    /// false positives.
    /// Quoting is the injection guard: an address carrying a `"` would
    /// otherwise close the phrase and let the rest be read as query syntax.
    func testItIsAQuotedPhrase() throws {
        let phrase = try XCTUnwrap(SearchIndex.addressPhrase("a@b.com"))
        XCTAssertTrue(phrase.hasPrefix("\""))
        XCTAssertTrue(phrase.hasSuffix("\""))
        XCTAssertEqual(phrase.filter { $0 == "\"" }.count, 2,
                       "quotes anywhere but the ends would escape the phrase")
    }

    /// A malformed header must contribute nothing rather than a query fragment
    /// that matches everything.
    func testAnAddressWithNoUsableTokensYieldsNil() {
        XCTAssertNil(SearchIndex.addressPhrase(""))
        XCTAssertNil(SearchIndex.addressPhrase("@"))
        XCTAssertNil(SearchIndex.addressPhrase("<>"))
        XCTAssertNil(SearchIndex.addressPhrase("...@..."))
    }

    /// The important nil case. `EmailAddress.bareAddress` accepts a malformed
    /// `someone@`, and a one-token phrase would match every message with that
    /// word anywhere in a sender or recipient.
    func testASingleTokenIsRefused() {
        XCTAssertNil(SearchIndex.addressPhrase("someone@"))
        XCTAssertNil(SearchIndex.addressPhrase("bob"))
        XCTAssertNotNil(SearchIndex.addressPhrase("bob@x"))
    }

    /// The query is bounded, however many mailboxes a thirty-year
    /// correspondent turns up in.
    func testTheResultIsLimited() throws {
        let index = try SearchIndex(path: ":memory:")
        for n in 0..<30 {
            try index.add(mailbox: "Box\(n).mbx",
                          sender: "x@y.com", recipients: "me@musanim.com")
        }
        XCTAssertEqual(try index.mailboxesFiledInto(addresses: ["x@y.com"], limit: 5).count, 5)
    }

    // MARK: against a real index

    func testCountsWhereACorrespondentHasBeenFiled() throws {
        let index = try SearchIndex(path: ":memory:")
        try index.add(mailbox: "PEOPLE.fol/G.FOL/GregSandow.mbx",
                      sender: "Greg Sandow <greg@gregsandow.com>", recipients: "me@musanim.com")
        try index.add(mailbox: "PEOPLE.fol/G.FOL/GregSandow.mbx",
                      sender: "me@musanim.com", recipients: "greg@gregsandow.com")
        try index.add(mailbox: "BUSINESS.fol/Licensing.mbx",
                      sender: "Greg Sandow <greg@gregsandow.com>", recipients: "me@musanim.com")
        try index.add(mailbox: "PEOPLE.fol/D.FOL/Douglas.mbx",
                      sender: "douglas@example.com", recipients: "me@musanim.com")

        let counts = try index.mailboxesFiledInto(addresses: ["greg@gregsandow.com"])
        XCTAssertEqual(counts.first?.mailbox, "PEOPLE.fol/G.FOL/GregSandow.mbx")
        XCTAssertEqual(counts.first?.count, 2)
        XCTAssertEqual(counts.map(\.mailbox).sorted(),
                       ["BUSINESS.fol/Licensing.mbx", "PEOPLE.fol/G.FOL/GregSandow.mbx"])
        XCTAssertFalse(counts.contains { $0.mailbox.contains("Douglas") },
                       "an unrelated correspondent's mailbox must not appear")
    }

    /// Matches whether the person was the sender or a recipient — filing a
    /// thread means both directions of it.
    func testMatchesSenderAndRecipientAlike() throws {
        let index = try SearchIndex(path: ":memory:")
        try index.add(mailbox: "A.mbx", sender: "x@y.com", recipients: "me@musanim.com")
        try index.add(mailbox: "A.mbx", sender: "me@musanim.com", recipients: "x@y.com")
        XCTAssertEqual(try index.mailboxesFiledInto(addresses: ["x@y.com"]).first?.count, 2)
    }

    /// A mixed selection merges into one ranking rather than several competing
    /// ones — the behaviour Stephen asked to try.
    func testSeveralAddressesAreMergedAndSummed() throws {
        let index = try SearchIndex(path: ":memory:")
        try index.add(mailbox: "Shared.mbx", sender: "a@x.com", recipients: "me@musanim.com")
        try index.add(mailbox: "Shared.mbx", sender: "b@x.com", recipients: "me@musanim.com")
        try index.add(mailbox: "OnlyA.mbx", sender: "a@x.com", recipients: "me@musanim.com")

        let counts = try index.mailboxesFiledInto(addresses: ["a@x.com", "b@x.com"])
        XCTAssertEqual(counts.first?.mailbox, "Shared.mbx", "the shared mailbox should rank first")
        XCTAssertEqual(counts.first?.count, 2)
    }

    func testAnUnknownCorrespondentSuggestsNothing() throws {
        let index = try SearchIndex(path: ":memory:")
        try index.add(mailbox: "A.mbx", sender: "x@y.com", recipients: "me@musanim.com")
        XCTAssertTrue(try index.mailboxesFiledInto(addresses: ["stranger@nowhere.com"]).isEmpty)
    }

    func testNoAddressesMeansNoQueryAndNoResults() throws {
        let index = try SearchIndex(path: ":memory:")
        try index.add(mailbox: "A.mbx", sender: "x@y.com", recipients: "me@musanim.com")
        XCTAssertTrue(try index.mailboxesFiledInto(addresses: []).isEmpty)
        XCTAssertTrue(try index.mailboxesFiledInto(addresses: ["@", ""]).isEmpty)
    }

    /// Two people at the same domain must not be confused with one another —
    /// the phrase requires the local part too.
    func testTwoPeopleAtOneDomainAreDistinguished() throws {
        let index = try SearchIndex(path: ":memory:")
        try index.add(mailbox: "Alice.mbx", sender: "alice@shared.com", recipients: "me@musanim.com")
        try index.add(mailbox: "Bob.mbx", sender: "bob@shared.com", recipients: "me@musanim.com")

        let counts = try index.mailboxesFiledInto(addresses: ["alice@shared.com"])
        XCTAssertEqual(counts.map(\.mailbox), ["Alice.mbx"])
    }
}

import XCTest
@testable import EudoraStore

/// `BlacklistRouting` — which of the two pending lists a blacklisted sender goes
/// on.
///
/// The cases worth pinning are the ones the real archive produces rather than
/// the tidy ones: mail Bcc'd so that `To` names nobody relevant, mailing-list
/// mail where `To` is the list, and the messages carrying no delivery header at
/// all. The tidy case — `Delivered-To: stephen@musanim.com` — has never been the
/// risk.
final class BlacklistRoutingTests: XCTestCase {

    private let isp: Set<String> = ["musanim.com"]
    private let gmail: Set<String> = ["gmail.com"]

    private func route(deliveredTo: [String?] = [], recipients: [String?] = [])
        -> Set<BlacklistBucket> {
        BlacklistRouting.buckets(deliveredTo: deliveredTo, recipients: recipients,
                                 ispDomains: isp, gmailDomains: gmail)
    }

    // MARK: the delivery header answers

    func testDeliveredToDecidesISP() {
        XCTAssertEqual(route(deliveredTo: ["stephen@musanim.com"]), [.isp])
    }

    func testDeliveredToDecidesGmail() {
        XCTAssertEqual(route(deliveredTo: ["stephen.malinowski@gmail.com"]), [.gmail])
    }

    /// The case the ordering exists for: it landed at Gmail, but the sender
    /// addressed it to a musanim.com list. Only Gmail can block it, so only
    /// Gmail's list should get it.
    func testDeliveryBeatsAContradictoryTo() {
        XCTAssertEqual(route(deliveredTo: ["stephen.malinowski@gmail.com"],
                             recipients: ["music-list@musanim.com"]),
                       [.gmail])
    }

    /// Header forms as they actually appear, not as bare addresses.
    func testParsesDisplayNameAndAngleBrackets() {
        XCTAssertEqual(route(deliveredTo: ["Stephen Malinowski <Stephen@Musanim.COM>"]),
                       [.isp])
    }

    // MARK: falling back to To/Cc

    func testFallsBackToRecipientsWhenNoDeliveryHeader() {
        XCTAssertEqual(route(deliveredTo: [nil, nil],
                             recipients: ["stephen@musanim.com"]),
                       [.isp])
    }

    /// Both addresses on one message is a real answer, not a tie to break.
    func testBothAddressesYieldBothLists() {
        XCTAssertEqual(route(recipients: ["stephen@musanim.com",
                                          "stephen.malinowski@gmail.com"]),
                       [.isp, .gmail])
    }

    // MARK: the last resort

    /// Bcc'd spam: no delivery header, and `To` names someone else entirely.
    /// Both lists, deliberately — a spurious line is deleted during the drain,
    /// a missing one is spam that keeps arriving.
    func testUnknowableGoesOnBothLists() {
        XCTAssertEqual(route(deliveredTo: [nil],
                             recipients: ["undisclosed-recipients:;"]),
                       Set(BlacklistBucket.allCases))
    }

    func testNoHeadersAtAllGoesOnBothLists() {
        XCTAssertEqual(route(), Set(BlacklistBucket.allCases))
    }

    /// A mailing list in `To` and no delivery header — the googlegroups.com and
    /// aol.com shape the archive is full of.
    func testMailingListInToGoesOnBothLists() {
        XCTAssertEqual(route(recipients: ["some-group@googlegroups.com"]),
                       Set(BlacklistBucket.allCases))
    }

    // MARK: domain rules

    func testDomainRuleMayBeWrittenWithOrWithoutAnAt() {
        let withAt = BlacklistRouting.buckets(deliveredTo: ["stephen@musanim.com"],
                                              recipients: [],
                                              ispDomains: ["@Musanim.com "],
                                              gmailDomains: ["@gmail.com"])
        XCTAssertEqual(withAt, [.isp])
    }

    /// A subdomain is not the domain. `mail.musanim.com` is a different mail
    /// destination, and guessing otherwise would file it under a blocklist that
    /// doesn't cover it.
    func testSubdomainDoesNotMatchTheDomainRule() {
        XCTAssertEqual(route(deliveredTo: ["stephen@mail.musanim.com"]),
                       Set(BlacklistBucket.allCases))
    }

    /// A quoted local part may legally contain an `@`; the domain is what
    /// follows the last one.
    func testDomainIsTakenFromTheLastAt() {
        XCTAssertEqual(BlacklistRouting.domain(of: "a@b@musanim.com"), "musanim.com")
    }
}

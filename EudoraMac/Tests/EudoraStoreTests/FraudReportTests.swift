import XCTest
@testable import EudoraStore

/// `FraudRecognizer` — recognizing USPTO impersonation, and building reports.
///
/// The addresses are invented, but each case has the shape of a real message in
/// the archive (2026nov03): a throwaway Gmail account named "USPTO", lookalike
/// domains (`usptoreview`, `gov-uspto`, `uspto.com`), a "legal" sender whose
/// name claims nothing, and the genuine USPTO's mail sent through third-party
/// services but signed for uspto.gov.
final class FraudReportTests: XCTestCase {

    private let me = MeIdentity(["stephen@musanim.com"])

    private func message(_ headers: [(String, String)]) -> MIMEPart {
        let text = headers.map { "\($0.0): \($0.1)\r\n" }.joined() + "\r\nBody.\r\n"
        return MIMEParser.parse([UInt8](text.utf8))
    }

    private func kinds(_ headers: [(String, String)]) -> Set<FraudKind> {
        FraudRecognizer.recognize(message(headers), me: me)
    }

    private let tigertechPass = "mx.tigertech.net; spf=pass smtp.mailfrom=x; dkim=pass header.d="

    // MARK: scams

    func testGmailAccountNamedUSPTO() {
        XCTAssertEqual(kinds([("From", "USPTO <jacksontmark@gmail.com>"),
                              ("Subject", "Trademark application MUSIC ANIMATION MACHINE serial number 74179002"),
                              ("Authentication-Results", tigertechPass + "gmail.com")]),
                       [.usptoImpersonation])
    }

    func testLookalikeDomainSignedForItself() {
        // A lookalike passes its own DKIM; what matters is *whose* signature it is.
        XCTAssertEqual(kinds([("From", "USPTO.GOV <examination@usptoreview.example>"),
                              ("Subject", "OFFICIAL NOTICE OF CANCELLATION"),
                              ("Authentication-Results", tigertechPass + "usptoreview.example")]),
                       [.usptoImpersonation])
    }

    func testDotComUSPTO() {
        XCTAssertEqual(kinds([("From", "USPTO <noreply@uspto.com>"),
                              ("Subject", "NOTICE OF EXAMINATION AND VERIFICATION APPOINTMENT")]),
                       [.usptoImpersonation])
    }

    func testFullNameClaim() {
        XCTAssertEqual(kinds([("From", "United States Patent and Trademark Office <abel@gov-uspto.example>"),
                              ("Subject", "Regarding your application")]),
                       [.usptoImpersonation])
    }

    func testSubjectAloneClaims() {
        XCTAssertEqual(kinds([("From", "allen@trademarkprotection.example"),
                              ("Subject", "Re: Trademark application MUSIC ANIMATION MACHINE serial number 74179002")]),
                       [.usptoImpersonation])
    }

    func testEncodedSubjectIsDecodedFirst() {
        // "Abandoned Tm Application – Serial No. 74179002", as RFC 2047.
        XCTAssertEqual(kinds([("From", "Filing Department <someone@gmail.com>"),
                              ("Subject", "=?utf-8?B?QWJhbmRvbmVkIFRtIEFwcGxpY2F0aW9uIOKAkyBTZXJpYWwgTm8uIDc0MTc5MDAy?=")]),
                       [.usptoImpersonation])
    }

    func testForgedUSPTOFromWithFailingSignature() {
        XCTAssertEqual(kinds([("From", "USPTO <no-reply@uspto.gov>"),
                              ("Subject", "Your trademark registration"),
                              ("Authentication-Results", "mx.tigertech.net; spf=fail; dkim=none")]),
                       [.usptoImpersonation])
    }

    func testPlantedPassBelowTheProvidersVerdictIsIgnored() {
        // The topmost header is the provider's; one beneath it came with the
        // message and proves nothing.
        XCTAssertEqual(kinds([("Authentication-Results", "mx.tigertech.net; dkim=fail header.d=uspto.gov"),
                              ("Authentication-Results", "fake.example; dkim=pass header.d=uspto.gov"),
                              ("From", "USPTO <no-reply@uspto.gov>"),
                              ("Subject", "Trademark cancellation")]),
                       [.usptoImpersonation])
    }

    // MARK: not scams

    func testGenuineSignedBySubdomainSender() {
        // Sent through Amazon SES, signed for uspto.gov.
        XCTAssertEqual(kinds([("From", "TMOfficialNotices@uspto.gov"),
                              ("Subject", "The USPTO has received your trademark application (serial number 50026733)"),
                              ("Authentication-Results", tigertechPass + "uspto.gov")]),
                       [])
    }

    func testGenuineSubdomainSignedForItself() {
        XCTAssertEqual(kinds([("From", "Trademark Center <noreply@feedback.uspto.gov>"),
                              ("Subject", "USPTO Survey: Trademark Center"),
                              ("Authentication-Results", tigertechPass + "feedback.uspto.gov")]),
                       [])
    }

    func testOldGenuineMailWithNoAuthenticationResults() {
        XCTAssertEqual(kinds([("From", "PrinTEAS@uspto.gov"),
                              ("Subject", "Trademark Application Serial No. 78336824 Received")]),
                       [])
    }

    func testStephensOwnReplyQuotingTheScamSubject() {
        XCTAssertEqual(kinds([("From", "Stephen Malinowski <stephen@musanim.com>"),
                              ("Subject", "Re: OFFICIAL NOTICE OF CANCELLATION — USPTO")]),
                       [])
    }

    func testOrdinaryMailClaimsNothing() {
        XCTAssertEqual(kinds([("From", "Friend <friend@example.com>"),
                              ("Subject", "Lunch on Friday?")]),
                       [])
    }

    func testLookalikeSigningDomainIsNotUSPTO() {
        XCTAssertEqual(kinds([("From", "USPTO <no-reply@uspto.gov>"),
                              ("Subject", "Trademark cancellation"),
                              ("Authentication-Results", tigertechPass + "uspto.gov-mail.example")]),
                       [.usptoImpersonation])
    }

    func testRealAddressHiddenInTheDisplayName() {
        XCTAssertEqual(kinds([("From", "\"USPTO <notice@uspto.gov>\" <scam@gmail.com>"),
                              ("Subject", "Notice")]),
                       [.usptoImpersonation])
    }

    func testCommentedVerdictWithSemicolonStillGenuine() {
        XCTAssertEqual(kinds([("From", "TMOfficialNotices@uspto.gov"),
                              ("Subject", "Your trademark application"),
                              ("Authentication-Results",
                               "mx.example; dkim=pass (2048-bit key; unprotected) header.d=uspto.gov")]),
                       [])
    }

    func testOldCommentFormFromIsGenuine() {
        XCTAssertEqual(kinds([("From", "PrinTEAS@uspto.gov (USPTO)"),
                              ("Subject", "Trademark Application Serial No. 78336824 Received")]),
                       [])
    }

    func testSerialNumberWithoutTrademarkContextIsNotAClaim() {
        XCTAssertEqual(kinds([("From", "Customer <c@example.com>"),
                              ("Subject", "Lost my serial number for the software")]),
                       [])
    }

    // MARK: the report

    func testHiddenSpoofCopiesTheRealSender() {
        let part = message([("From", "\"USPTO <notice@uspto.gov>\" <scam@gmail.com>")])
        XCTAssertEqual(FraudRecognizer.report(.usptoImpersonation, for: part, me: me).to,
                       ["Trademark Scams <TMScams@uspto.gov>", "scam@gmail.com"])
    }

    func testEncodedNameWithCommaStaysOneRecipient() {
        let part = message([("From", "=?utf-8?Q?Doe,_Jane?= <x@scam.example>")])
        let to = FraudRecognizer.report(.usptoImpersonation, for: part, me: me).to
        XCTAssertEqual(to, ["Trademark Scams <TMScams@uspto.gov>", "x@scam.example"])
    }

    /// Copies of the scammer are bare addresses; see `report`.
    func testUSPTOReportCopiesFromAndDifferingReplyTo() {
        let part = message([("From", "USPTO.GOV <examination@usptoreview.example>"),
                            ("Reply-To", "collector@gmail.com, examination@usptoreview.example"),
                            ("Subject", "OFFICIAL NOTICE OF CANCELLATION")])
        let r = FraudRecognizer.report(.usptoImpersonation, for: part, me: me)
        XCTAssertEqual(r.to, ["Trademark Scams <TMScams@uspto.gov>",
                              "examination@usptoreview.example",
                              "collector@gmail.com"])
        XCTAssertEqual(r.subject, "PTO scam (original email attached)")
        XCTAssertEqual(r.body, "The original message is attached.\n")
    }

    func testUSPTOReportNeverCopiesAUSPTOAddress() {
        let part = message([("From", "USPTO <no-reply@uspto.gov>"),
                            ("Reply-To", "help@mail.uspto.gov")])
        XCTAssertEqual(FraudRecognizer.report(.usptoImpersonation, for: part, me: me).to,
                       ["Trademark Scams <TMScams@uspto.gov>"])
    }

    func testReportNeverCopiesStephen() {
        let part = message([("From", "USPTO <x@gmail.com>"),
                            ("Reply-To", "stephen@musanim.com")])
        XCTAssertEqual(FraudRecognizer.report(.usptoImpersonation, for: part, me: me).to,
                       ["Trademark Scams <TMScams@uspto.gov>", "x@gmail.com"])
    }

    func testPhishingReportDoesNotCopyTheSender() {
        let part = message([("From", "Your Bank <alerts@bank.example>")])
        let r = FraudRecognizer.report(.phishing, for: part, me: me)
        XCTAssertEqual(r.to, ["reportphishing@apwg.org"])
        XCTAssertEqual(r.subject, "Phishing report (original email attached)")
    }
}

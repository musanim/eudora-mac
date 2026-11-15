import XCTest
@testable import EudoraStore

/// `BounceReport` — reading delivery-status reports — and `FailedAddresses`,
/// the list the composer warns from. Fixtures are invented; the shapes are
/// the ones measured in `phaseX` (2026nov14).
final class BounceReportTests: XCTestCase {

    /// A `multipart/report` with the given delivery-status body and a returned
    /// original after it.
    private func report(_ status: String,
                        type: String = "multipart/report; report-type=delivery-status") -> MIMEPart {
        let text = """
        From: Mail Delivery Subsystem <mailer-daemon@googlemail.com>
        To: stephen@example.org
        Subject: Delivery Status Notification (Failure)
        MIME-Version: 1.0
        Content-Type: \(type); boundary="BND"

        --BND
        Content-Type: text/plain; charset=UTF-8

        Address not found. Your message wasn't delivered.

        --BND
        Content-Type: message/delivery-status

        \(status)
        --BND
        Content-Type: message/rfc822

        From: stephen@example.org
        Message-ID: <orig.123@example.org>
        To: Final-Recipient <decoy@example.net>
        Subject: Music Animation Machine

        Action: failed
        Final-Recipient: rfc822; decoy@example.net
        Status: 5.1.1

        --BND--

        """
        return MIMEParser.parse(Array(text.utf8))
    }

    private let gmailStyle = """
        Reporting-MTA: dns; googlemail.com
        Arrival-Date: Sat, 14 Nov 2026 12:00:00 -0800

        Final-Recipient: rfc822; old.friend@example.com
        Action: failed
        Status: 5.1.1
        Remote-MTA: dns; mx.example.com
        Diagnostic-Code: smtp; 550-5.1.1 The email account that you tried to reach
         does not exist. Please try double-checking the recipient's email address.

        """

    // MARK: recognising a report

    func testGoneAddressIsFound() {
        let f = BounceReport.failures(in: report(gmailStyle))
        XCTAssertEqual(f.map(\.address), ["old.friend@example.com"])
        XCTAssertEqual(f.first?.status, "5.1.1")
        XCTAssertEqual(f.first?.addressIsGone, true)
        // Folded Diagnostic-Code is unfolded, and its type removed.
        XCTAssertTrue(f.first?.diagnostic.hasPrefix("550-5.1.1 The email account") ?? false)
        XCTAssertTrue(f.first?.diagnostic.contains("reach does not exist") ?? false)
    }

    func testReportCarriesArrivalDateAndOriginalID() {
        let r = BounceReport.report(in: report(gmailStyle))
        XCTAssertEqual(r?.arrivalDate, "Sat, 14 Nov 2026 12:00:00 -0800")
        XCTAssertEqual(r?.originalMessageID, "<orig.123@example.org>")
        XCTAssertNil(BounceReport.report(in: report(gmailStyle, type: "multipart/mixed")))
    }

    func testForwardedAddressIsNoted() {
        let f = BounceReport.failures(inStatusText: """
            Original-Recipient: rfc822; alumni@example.edu
            Final-Recipient: rfc822; someone@example.com
            Action: failed
            Status: 5.1.1

            Final-Recipient: rfc822; plain@example.com
            Action: failed
            Status: 5.1.1

            """)
        XCTAssertEqual(f.map(\.forwardedTo), ["someone@example.com", nil])
    }

    /// The returned original carries delivery-status-looking text; only the
    /// report's own status part may be read.
    func testReturnedOriginalIsNotRead() {
        let f = BounceReport.failures(in: report(gmailStyle))
        XCTAssertFalse(f.contains { $0.address == "decoy@example.net" })
    }

    func testOrdinaryMessageIsNotAReport() {
        let msg = MIMEParser.parse(Array("""
            From: a@example.com
            Subject: fwd: bounce
            Content-Type: text/plain

            Final-Recipient: rfc822; x@example.com
            Action: failed
            Status: 5.1.1

            """.utf8))
        XCTAssertEqual(BounceReport.failures(in: msg), [])
    }

    /// A report forwarded inside a mixed message is somebody's message, not a
    /// report to act on.
    func testReportNestedInMixedIsNotRead() {
        let text = """
            From: friend@example.com
            Content-Type: multipart/mixed; boundary=OUT

            --OUT
            Content-Type: text/plain

            Look what bounced.
            --OUT
            Content-Type: multipart/report; report-type=delivery-status; boundary=IN

            --IN
            Content-Type: message/delivery-status

            Final-Recipient: rfc822; a@example.com
            Action: failed
            Status: 5.1.1

            --IN--
            --OUT--

            """
        XCTAssertEqual(BounceReport.failures(in: MIMEParser.parse(Array(text.utf8))), [])
    }

    /// The same report, mislabelled: a root that isn't multipart/report.
    func testReportTypeIsRequiredOfTheRoot() {
        XCTAssertEqual(BounceReport.failures(in: report(gmailStyle, type: "multipart/mixed")), [])
    }

    func testGlobalDeliveryStatusIsRead() {
        let text = """
            Content-Type: multipart/report; report-type=global-delivery-status; boundary=B

            --B
            Content-Type: message/global-delivery-status

            Final-Recipient: rfc822; a@example.com
            Action: failed
            Status: 5.1.1

            --B--

            """
        XCTAssertEqual(BounceReport.failures(in: MIMEParser.parse(Array(text.utf8))).map(\.address),
                       ["a@example.com"])
    }

    // MARK: blocks

    func testSeveralRecipientsAndADelayedOne() {
        let f = BounceReport.failures(inStatusText: """
            Reporting-MTA: dns; mail.example.org

            Final-Recipient: rfc822;<one@example.com>
            Action: failed
            Status: 5.1.1

            Final-Recipient: RFC822; two@example.com
            Action: delayed
            Status: 4.4.1

            Final-Recipient: rfc822; three@example.com
            Action: failed
            Status: 5.2.2
            Diagnostic-Code: smtp; 552 mailbox full

            """)
        XCTAssertEqual(f.map(\.address), ["one@example.com", "three@example.com"])
        XCTAssertEqual(f.map(\.addressIsGone), [true, false])
    }

    /// The address as sent beats the one a forwarder rewrote it to.
    func testOriginalRecipientWins() {
        let f = BounceReport.failures(inStatusText: """
            Original-Recipient: rfc822; alumni@example.edu
            Final-Recipient: rfc822; someone@example.com
            Action: failed
            Status: 5.1.1

            """)
        XCTAssertEqual(f.map(\.address), ["alumni@example.edu"])
    }

    func testNonInternetAddressTypeIsSkipped() {
        let f = BounceReport.failures(inStatusText: """
            Final-Recipient: x-x500; CN=someone,OU=US
            Action: failed
            Status: 5.1.1

            """)
        XCTAssertEqual(f, [])
    }

    func testCRLFAndStatusComment() {
        let f = BounceReport.failures(
            inStatusText: "Final-Recipient: rfc822; a@example.com\r\nAction: failed\r\nStatus: 5.1.1 (bad mailbox)\r\n\r\n")
        XCTAssertEqual(f.first?.status, "5.1.1")
        XCTAssertEqual(f.first?.addressIsGone, true)
    }

    // MARK: the decision

    private func gone(_ status: String, _ diagnostic: String = "") -> Bool {
        BounceReport.addressIsGone(status: status, diagnostic: diagnostic)
    }

    /// EarthLink says only "Recipient rejected"; the code carries the meaning.
    /// The diagnostic is the real one from Gordon Green's bounce, 2026nov14.
    func testEarthLinkNoMailboxCodes() {
        XCTAssertTrue(gone("5.5.1", "smtp; 550 5.5.1 Recipient rejected - ELNK001_403 -\n"
            + "    https://postmaster-earthlink.vadesecure.com/inbound_error_codes/#_403"))
        XCTAssertTrue(gone("5.5.1", "550 5.5.1 Recipient rejected - ELNK002_402 - https://x/#_402"))
        // The temporary _402 and EarthLink's policy codes are not gone.
        XCTAssertFalse(gone("4.2.0", "450 4.2.0 Recipient temporarily unavailable - ELNK001_402"))
        XCTAssertFalse(gone("5.7.1", "550 5.7.1 Sender rejected - ELNK001_304"))
        XCTAssertFalse(gone("5.5.1", "550 5.5.1 Recipient rejected - ELNK001_4031"))
    }

    func testAddressCodesCountOnTheirOwn() {
        for code in ["5.1.1", "5.1.2", "5.1.3", "5.1.10", "5.2.1", "5.4.4"] {
            XCTAssertTrue(gone(code), code)
        }
        // A specific code isn't overturned by incidental wording.
        XCTAssertTrue(gone("5.1.1", "550 address couldn't be found; try to resend when fully checked"))
    }

    func testGenericCodesNeedTheText() {
        XCTAssertTrue(gone("5.0.0", "550 No Such User Here"))
        XCTAssertTrue(gone("5.0.0", "550 #5.1.0 Address rejected."))
        XCTAssertTrue(gone("5.5.0", "550 Requested action not taken: mailbox unavailable"))
        XCTAssertTrue(gone("5.4.1", "550 5.4.1 Recipient address rejected: Access denied."))
        XCTAssertTrue(gone("5.0.0", "554 delivery error: dd This user doesn't have a example.com account"))
        XCTAssertTrue(gone("5.0.0", "5.1.0 - Unknown address error 501-'#5.1.1 bad address' (delivery attempts: 0)"))
        XCTAssertTrue(gone("5.0.0", "550 user is unreachable (#5.1.1)."))
        XCTAssertFalse(gone("5.0.0", "550 message refused"))
        XCTAssertFalse(gone("5.0.0"))
    }

    func testRejectionsAboutTheMessageAreNotGone() {
        XCTAssertFalse(gone("5.7.1", "554 5.7.1 Content filter reject: From header address blacklisted"))
        XCTAssertFalse(gone("5.7.1", "554 5.7.1 <a@example.com>: Relay access denied"))
        XCTAssertFalse(gone("5.7.1", "550 rejected by policy: no such user check skipped, spam"))
        XCTAssertFalse(gone("5.2.2", "552 mailbox not found or over quota"))
        XCTAssertFalse(gone("5.1.7", "550 5.1.7 sender address does not exist"))
        XCTAssertFalse(gone("4.2.1", "450 mailbox temporarily disabled"))
        XCTAssertFalse(gone("4.0.0", "user unknown"))
        XCTAssertFalse(gone("5.0.0", "553 Sender address rejected: Domain not found"))
        // "relayed" and "successfully" are not overrides.
        XCTAssertTrue(gone("5.0.0", "relayed via smarthost; 550 no such user"))
        // An IP address is not a status code.
        XCTAssertFalse(gone("5.0.0", "550 connection from 195.1.1.4 refused"))
    }

    // MARK: FailedAddresses

    private func date(_ s: String) -> Date { FailedAddresses.dateFormatNoZone.date(from: s)! }

    func testRoundTrip() {
        var list = FailedAddresses()
        list.record(.init(address: "Old.Friend@Example.com", date: date("2026-11-14 12:00:00"),
                          status: "5.1.1", diagnostic: "550\tno such\nuser"))
        list.record(.init(address: "b@example.com", date: date("2010-01-02 03:04:05"),
                          status: "", diagnostic: ""))
        let reread = FailedAddresses(fileText: list.fileText)
        XCTAssertEqual(reread.entries.count, 2)
        XCTAssertEqual(reread.entries["old.friend@example.com"]?.diagnostic, "550 no such user")
        XCTAssertEqual(reread.entries["b@example.com"]?.date, date("2010-01-02 03:04:05"))
    }

    func testLaterFailureWinsWhicheverOrder() {
        var list = FailedAddresses()
        list.record(.init(address: "a@example.com", date: date("2026-11-14 00:00:00"),
                          status: "5.1.1", diagnostic: "new"))
        list.record(.init(address: "a@example.com", date: date("2005-01-01 00:00:00"),
                          status: "5.0.0", diagnostic: "old"))
        XCTAssertEqual(list.entries["a@example.com"]?.diagnostic, "new")
    }

    func testLookupTakesARecipientEntry() {
        var list = FailedAddresses()
        list.record(.init(address: "a@example.com", date: date("2026-11-14 00:00:00"),
                          status: "5.1.1", diagnostic: ""))
        XCTAssertNotNil(list.failure(for: "Somebody <A@example.com>"))
        XCTAssertNil(list.failure(for: "b@example.com"))
        list.remove("Somebody <A@EXAMPLE.COM>")
        XCTAssertNil(list.failure(for: "a@example.com"))
    }

    func testDateWithoutZoneIsLocal() {
        let list = FailedAddresses(fileText: "a@example.com\t2026-11-14 13:05:00\n")
        XCTAssertEqual(list.entries["a@example.com"]?.date,
                       FailedAddresses.dateFormatNoZone.date(from: "2026-11-14 13:05:00"))
    }

    func testFoldedEmptyFieldKeepsNoPrefix() {
        let f = BounceReport.failures(inStatusText: """
            Final-Recipient: rfc822; a@example.com
            Action: failed
            Status: 5.0.0
            Diagnostic-Code:
             smtp; 550 No such user

            """)
        XCTAssertEqual(f.first?.diagnostic, "550 No such user")
    }

    func testBadLinesAreKeptNotRead() {
        let list = FailedAddresses(fileText: """
            # comment
            not an address\t2026-11-14 00:00:00
            a@example.com\tyesterday
            b@example.com\t2026-11-14 00:00:00

            """)
        XCTAssertEqual(Array(list.entries.keys), ["b@example.com"])
        XCTAssertEqual(list.otherLines, ["# comment", "not an address\t2026-11-14 00:00:00",
                                         "a@example.com\tyesterday"])
    }

    /// A rewrite keeps what Stephen typed, and doesn't pile up its own header.
    func testHandEditsSurviveARewrite() {
        var list = FailedAddresses(fileText: """
            # people I know are gone
            typed@example.com
            day@example.com\t2019-03-04
            something odd

            """)
        XCTAssertNotNil(list.entries["typed@example.com"])
        XCTAssertNil(list.entries["typed@example.com"]?.date)
        XCTAssertEqual(list.entries["day@example.com"]?.date,
                       FailedAddresses.dayFormat.date(from: "2019-03-04"))
        list.record(.init(address: "new@example.com", date: date("2026-11-14 00:00:00"),
                          status: "5.1.1", diagnostic: ""))
        let twice = FailedAddresses(fileText: FailedAddresses(fileText: list.fileText).fileText)
        XCTAssertEqual(twice, list)
        XCTAssertEqual(twice.otherLines, ["# people I know are gone", "something odd"])
        XCTAssertEqual(list.fileText.components(separatedBy: "Written by Eudora").count, 2)
    }

    func testANoteContainingAnAddressIsNotAnEntry() {
        let list = FailedAddresses(fileText: "note: <bob@x.com> works again\nBob Smith <gone@x.com>\n")
        XCTAssertNil(list.entries["bob@x.com"])
        XCTAssertNotNil(list.entries["gone@x.com"])
        XCTAssertEqual(list.otherLines, ["note: <bob@x.com> works again"])
    }

    func testForwardingNoteRoundTrips() {
        let d = FailedAddresses.Entry.diagnostic("550 no such user", forwardedTo: "x@isp.example")
        let e = FailedAddresses.Entry(address: "a@alumni.example", date: nil, status: "5.1.1", diagnostic: d)
        XCTAssertEqual(e.forwardedTo, "x@isp.example")
        XCTAssertNil(FailedAddresses.Entry(address: "a@b.example", date: nil, status: "",
                                           diagnostic: "550 no such user").forwardedTo)
        XCTAssertEqual(FailedAddresses.Entry.diagnostic("t", forwardedTo: nil), "t")
    }

    func testDatedFailureBeatsUndated() {
        var list = FailedAddresses()
        list.record(.init(address: "a@example.com", date: date("2026-11-14 00:00:00"),
                          status: "5.1.1", diagnostic: "dated"))
        list.record(.init(address: "a@example.com", date: nil, status: "", diagnostic: "hand"))
        XCTAssertEqual(list.entries["a@example.com"]?.diagnostic, "dated")
    }
}

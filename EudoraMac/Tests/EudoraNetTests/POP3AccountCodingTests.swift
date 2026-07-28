import XCTest
import Foundation
@testable import EudoraNet

/// `POP3Account`'s decoder is the load-bearing piece of the single-account →
/// account-list migration: `AccountStore` reads the old `"POP3Account"`
/// UserDefaults blob through it and carries the result into the new list. If it
/// ever throws, or quietly returns defaults, a configured server and username
/// vanish and the app comes up looking freshly installed.
///
/// That blob was written by a build whose `POP3Account` also carried
/// `autoCheckEnabled` and `autoCheckMinutes`, which are now one app-wide
/// setting. So the decoder has to tolerate keys it no longer knows about, and a
/// future one has to tolerate keys that aren't there yet — which is why it is
/// written field-by-field with `decodeIfPresent` rather than synthesised.
final class POP3AccountCodingTests: XCTestCase {

    // MARK: forward from the single-account build

    /// The migration case. A blob with the two retired keys still in it must
    /// decode, and every field that matters must survive.
    func testLegacyBlobWithRetiredAutoCheckKeysStillDecodes() throws {
        let legacy = Data("""
        {"host":"mail.musanim.com","port":995,"username":"stephen",
         "deleteAfterDownload":false,"autoCheckEnabled":true,"autoCheckMinutes":5}
        """.utf8)

        let account = try JSONDecoder().decode(POP3Account.self, from: legacy)
        XCTAssertEqual(account.host, "mail.musanim.com")
        XCTAssertEqual(account.username, "stephen")
        XCTAssertEqual(account.port, 995)
        XCTAssertFalse(account.deleteAfterDownload)
    }

    /// `deleteAfterDownload` is the one field where a wrong default destroys
    /// mail rather than merely inconveniencing someone, so it is pinned
    /// separately in both directions.
    func testDeleteAfterDownloadRoundTripsAndDefaultsToFalse() throws {
        let on = try JSONDecoder().decode(
            POP3Account.self,
            from: Data(#"{"host":"h","port":995,"username":"u","deleteAfterDownload":true}"#.utf8))
        XCTAssertTrue(on.deleteAfterDownload)

        let absent = try JSONDecoder().decode(
            POP3Account.self,
            from: Data(#"{"host":"h","port":995,"username":"u"}"#.utf8))
        XCTAssertFalse(absent.deleteAfterDownload,
                       "a missing key must never turn server-side deletion on")
    }

    /// A blob missing everything must still produce a usable account rather than
    /// throwing — throwing is what would wipe the saved settings.
    func testEmptyObjectDecodesToDefaults() throws {
        let account = try JSONDecoder().decode(POP3Account.self, from: Data("{}".utf8))
        XCTAssertEqual(account.host, "")
        XCTAssertEqual(account.username, "")
        XCTAssertEqual(account.port, 995, "the default POP3S port, not zero")
        XCTAssertFalse(account.isConfigured)
    }

    // MARK: the list, which is what is written now

    func testAccountListRoundTrips() throws {
        let accounts = [
            POP3Account(host: "mail.musanim.com", port: 995, username: "stephen"),
            POP3Account(host: "pop.gmail.com", port: 995,
                        username: "someone@gmail.com", deleteAfterDownload: false),
        ]
        let data = try JSONEncoder().encode(accounts)
        let back = try JSONDecoder().decode([POP3Account].self, from: data)
        XCTAssertEqual(back, accounts)
    }

    /// The retired keys must not be written back out — a downgrade reads this
    /// through the old decoder, and stale auto-check values reappearing from a
    /// blob the new build wrote would be a surprise in both directions.
    func testEncodingDoesNotEmitRetiredKeys() throws {
        let data = try JSONEncoder().encode(POP3Account(host: "h", port: 995, username: "u"))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("autoCheck"), "got \(json)")
    }

    // MARK: the key everything else is filed under

    /// `keychainAccount` identifies the stored password *and* keys the
    /// downloaded-UID set. If it ever changes shape, every account silently
    /// loses its password and re-downloads everything still on the server —
    /// duplicating it into In. It is pinned here so that can't happen quietly.
    func testKeychainAccountFormatIsStable() {
        let account = POP3Account(host: "mail.musanim.com", port: 995, username: "stephen")
        XCTAssertEqual(account.keychainAccount, "pop:stephen@mail.musanim.com:995")
    }

    /// Two accounts differing only in a field that feeds the key must not
    /// collide — that would make one of them skip the other's mail.
    func testKeychainAccountDistinguishesAccounts() {
        let a = POP3Account(host: "pop.gmail.com", port: 995, username: "one@gmail.com")
        let b = POP3Account(host: "pop.gmail.com", port: 995, username: "two@gmail.com")
        let c = POP3Account(host: "pop.googlemail.com", port: 995, username: "one@gmail.com")
        XCTAssertNotEqual(a.keychainAccount, b.keychainAccount)
        XCTAssertNotEqual(a.keychainAccount, c.keychainAccount)
    }

    /// The corollary, and the reason `AccountStore.save()` trims: an untrimmed
    /// host is a *different* account as far as the UID tracking is concerned,
    /// so a pasted trailing space would re-download the whole server into In.
    func testUntrimmedHostProducesADifferentKey() {
        let clean = POP3Account(host: "pop.gmail.com", port: 995, username: "u")
        let spaced = POP3Account(host: "pop.gmail.com ", port: 995, username: "u")
        XCTAssertNotEqual(clean.keychainAccount, spaced.keychainAccount,
                          "if these ever compare equal, the trimming in save() is redundant")
    }

    // MARK: isConfigured

    func testIsConfiguredRequiresHostUsernameAndPort() {
        XCTAssertTrue(POP3Account(host: "h", port: 995, username: "u").isConfigured)
        XCTAssertFalse(POP3Account(host: "", port: 995, username: "u").isConfigured)
        XCTAssertFalse(POP3Account(host: "h", port: 995, username: "").isConfigured)
        XCTAssertFalse(POP3Account(host: "h", port: 0, username: "u").isConfigured)
    }
}

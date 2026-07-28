import Foundation
import SwiftUI
import EudoraNet

/// One incoming server as the app holds it: the persisted settings plus the
/// password, which is *not* persisted alongside them (it lives in the Keychain).
///
/// `id` exists only so SwiftUI can identify rows in the Settings list while they
/// are being edited. It is deliberately not persisted and not used for anything
/// else: a half-typed account has no stable host or username to be identified
/// by, and re-deriving identity from those fields mid-edit makes the row the
/// user is typing into disappear.
struct IncomingAccount: Identifiable {
    let id = UUID()
    var account: POP3Account
    var password: String

    init(account: POP3Account = POP3Account(), password: String = "") {
        self.account = account
        self.password = password
    }
}

/// Holds the mail account settings — SMTP (outgoing) and POP3 (incoming) —
/// persisted as JSON in UserDefaults, with every password in the Keychain.
/// Also tracks which POP3 UIDLs have already been downloaded, per account, so
/// Check Mail only pulls new messages.
///
/// **Incoming is a list; outgoing is not.** Mail is collected from every
/// configured POP account into the one In box, but everything is sent through a
/// single SMTP server — see design-decisions.md §7. Sending as an address whose
/// domain doesn't match the sending server is the SPF/DMARC failure case, and
/// Stephen doesn't need it.
@MainActor
final class AccountStore: ObservableObject {
    @Published var account: SMTPAccount
    @Published var password: String = ""

    /// Every incoming server, in the order they're listed in Settings. The order
    /// has no meaning beyond that; Check Mail walks them all.
    @Published var incoming: [IncomingAccount]

    /// Whether Check Mail runs on a timer, and how often. One setting for the
    /// app rather than one per account: Eudora 7 had a single interval, and
    /// nothing about the servers in use needs different ones. Gmail's documented
    /// limits are on simultaneous connections and daily bandwidth, neither of
    /// which one client polling sequentially approaches, so a one-minute
    /// interval is fine for it too. If a server ever does throttle, this is the
    /// setting that would have to become per-account.
    @Published var autoCheckEnabled: Bool
    /// The auto-check interval in minutes; forced to at least 1 wherever it is
    /// written or read.
    @Published var autoCheckMinutes: Int

    /// Set when the stored account list was present but wouldn't decode — the
    /// one case where settings really have been lost, as opposed to never
    /// having existed. Shown in Settings (see `SettingsView`) so a blank pane
    /// can't be mistaken for a fresh install. Nothing overwrites the bad data
    /// until the user saves, so a backup of the defaults plist is still worth
    /// something at that point.
    ///
    /// Not `@Published`: it is written once, in `init`, before any view exists.
    private(set) var incomingLoadFailed = false

    private static let smtpKey = "SMTPAccount"
    private static let incomingKey = "POP3Accounts"
    private static let autoCheckEnabledKey = "POP3AutoCheckEnabled"
    private static let autoCheckMinutesKey = "POP3AutoCheckMinutes"
    private static let uidKey = "POP3KnownUIDs"

    /// The single-account key written by builds before incoming mail became a
    /// list. Still read — never written, never deleted — so an existing setup
    /// migrates instead of coming back blank, and so a downgrade still finds its
    /// settings where it left them.
    private static let legacyPopKey = "POP3Account"

    /// The two fields that used to live on `POP3Account` and are now app-wide.
    /// Decoded out of the legacy blob only, to carry the old setting forward.
    private struct LegacyAutoCheck: Decodable {
        var autoCheckEnabled: Bool?
        var autoCheckMinutes: Int?
    }

    init() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: Self.smtpKey),
           let a = try? JSONDecoder().decode(SMTPAccount.self, from: data) {
            account = a
            password = Keychain.password(account: a.keychainAccount) ?? ""
        } else {
            account = SMTPAccount()
        }

        // Incoming: the list if it's there, otherwise the single legacy account,
        // otherwise one empty row to type into.
        //
        // The legacy key is only read. Migration deliberately doesn't delete it,
        // and nothing writes the new key until something is saved — so a first
        // launch of this build that goes wrong leaves the old settings exactly
        // where the old build expects them.
        //
        // The legacy key is consulted only when the new one is *absent*, not
        // whenever it fails to decode. Those are very different situations: a
        // present-but-corrupt list would otherwise silently resurrect the
        // pre-migration single account — dropping any account added since, and
        // reverting the first to its pre-migration host — with nothing to tell
        // the user it had happened. Better to come up empty and be obviously
        // wrong than to come up plausibly wrong.
        var loaded: [POP3Account] = []
        if let data = defaults.data(forKey: Self.incomingKey) {
            loaded = (try? JSONDecoder().decode([POP3Account].self, from: data)) ?? []
            incomingLoadFailed = loaded.isEmpty
        } else if let data = defaults.data(forKey: Self.legacyPopKey),
                  let one = try? JSONDecoder().decode(POP3Account.self, from: data) {
            loaded = [one]
        }
        // Assembled in a local and assigned once. Reading back a `@Published`
        // property mid-init is a whole-`self` access — the wrapper's static
        // subscript takes the enclosing instance — and `autoCheckEnabled` and
        // `autoCheckMinutes` below aren't initialized yet, so `if
        // incoming.isEmpty` on the property itself would not compile. Writing
        // is fine; only reading is.
        var entries = loaded.map {
            IncomingAccount(account: $0,
                            password: Keychain.password(account: $0.keychainAccount) ?? "")
        }
        if entries.isEmpty { entries = [IncomingAccount()] }
        incoming = entries

        // Auto-check: the app-wide keys if they exist, else whatever the legacy
        // single account carried, else off at one minute. `object(forKey:)`
        // rather than `bool(forKey:)` for the test, because `bool` can't tell
        // "saved as false" from "never saved".
        if defaults.object(forKey: Self.autoCheckEnabledKey) != nil {
            autoCheckEnabled = defaults.bool(forKey: Self.autoCheckEnabledKey)
            autoCheckMinutes = max(1, defaults.integer(forKey: Self.autoCheckMinutesKey))
        } else {
            let legacy = defaults.data(forKey: Self.legacyPopKey)
                .flatMap { try? JSONDecoder().decode(LegacyAutoCheck.self, from: $0) }
            autoCheckEnabled = legacy?.autoCheckEnabled ?? false
            autoCheckMinutes = max(1, legacy?.autoCheckMinutes ?? 1)
        }
    }

    var isReadyToSend: Bool { account.isConfigured && !password.isEmpty }

    /// The accounts Check Mail can actually collect from. An account that is
    /// half-typed, or has no password yet, is skipped rather than reported — a
    /// list with an empty row in it is the normal state of the Settings pane,
    /// not an error.
    var readyIncoming: [IncomingAccount] {
        incoming.filter { $0.account.isConfigured && !$0.password.isEmpty }
    }

    var isReadyToReceive: Bool { !readyIncoming.isEmpty }

    /// Accounts the user has begun filling in but not finished. Check Mail
    /// reports these rather than skipping them in silence — with one working
    /// account and one half-typed, a silent skip reads as "the new server
    /// doesn't work" when the truth is "you haven't finished typing it".
    var partiallyConfigured: [IncomingAccount] {
        incoming.filter { entry in
            let a = entry.account
            let started = !a.host.isEmpty || !a.username.isEmpty || !entry.password.isEmpty
            return started && !(a.isConfigured && !entry.password.isEmpty)
        }
    }

    var hasPartiallyConfiguredIncoming: Bool { !partiallyConfigured.isEmpty }

    func save() {
        let defaults = UserDefaults.standard

        if let data = try? JSONEncoder().encode(account) {
            defaults.set(data, forKey: Self.smtpKey)
        }
        if !password.isEmpty {
            Keychain.savePassword(password, account: account.keychainAccount)
        }

        // Trim before anything is keyed off these. `keychainAccount` — which is
        // also the key for the downloaded-UID set — is built from host and
        // username, so a pasted trailing space makes a *different* account as
        // far as the UID tracking is concerned, and every message still on the
        // server is downloaded again into In. Duplicates in the archive are the
        // expensive failure here, so this is trimmed at the one point where the
        // value becomes durable.
        for i in incoming.indices {
            let before = incoming[i].account
            incoming[i].account.host = before.host.trimmingCharacters(in: .whitespaces)
            incoming[i].account.username = before.username.trimmingCharacters(in: .whitespaces)
            // Trimming *changes the key*, which is the very thing that causes a
            // re-download. An account saved untrimmed by an earlier build has
            // its password and its downloaded-UID set filed under the old key,
            // so cleaning it up here would orphan both and pull the whole server
            // back into In — the exact harm this is meant to prevent. Carry them
            // across instead.
            let after = incoming[i].account
            guard after.keychainAccount != before.keychainAccount,
                  before.isConfigured else { continue }
            let carried = knownUIDs(for: before)
            if !carried.isEmpty { setKnownUIDs(carried, for: after) }
            if let secret = Keychain.password(account: before.keychainAccount) {
                Keychain.savePassword(secret, account: after.keychainAccount)
                Keychain.deletePassword(account: before.keychainAccount)
            }
        }

        persistIncomingAccounts()
        persistAutoCheck()
        for entry in incoming where entry.account.isConfigured && !entry.password.isEmpty {
            Keychain.savePassword(entry.password, account: entry.account.keychainAccount)
        }
    }

    /// Write the account list. Only `save()` and an explicit row removal do
    /// this — deliberately *not* the auto-check handlers, which would otherwise
    /// commit whatever half-finished edits happened to be in the other rows.
    /// Flipping a toggle is not consent to save a mistyped server.
    func persistIncomingAccounts() {
        if let data = try? JSONEncoder().encode(incoming.map(\.account)) {
            UserDefaults.standard.set(data, forKey: Self.incomingKey)
        }
    }

    /// Persist just the auto-check settings — no accounts, no Keychain — so the
    /// toggle and the interval stick the moment they change, without waiting for
    /// the Save button and without dragging unsaved account edits to disk with
    /// them.
    func persistAutoCheck() {
        let defaults = UserDefaults.standard
        defaults.set(autoCheckEnabled, forKey: Self.autoCheckEnabledKey)
        defaults.set(max(1, autoCheckMinutes), forKey: Self.autoCheckMinutesKey)
    }

    /// Forget a removed account's stored password, so deleting a row doesn't
    /// leave it in the Keychain and re-adding the same server later starts
    /// clean rather than silently picking up a stale one.
    ///
    /// Call this *after* the row has been taken out of `incoming`: it checks
    /// that no remaining row shares the login, so removing one of two rows
    /// pointing at the same server can't disarm the one being kept.
    func forgetPassword(for account: POP3Account) {
        guard account.isConfigured else { return }
        guard !incoming.contains(where: { $0.account.keychainAccount == account.keychainAccount })
        else { return }
        Keychain.deletePassword(account: account.keychainAccount)
    }

    // MARK: downloaded-UID tracking (per POP account)

    /// The UIDLs already downloaded for one account.
    ///
    /// Keyed by `keychainAccount` — user@host:port. Editing a configured
    /// account's server or username therefore starts it with an empty set,
    /// which is the safe direction to fail: mail may be fetched twice, never
    /// skipped. The dictionary was already keyed this way when there was only
    /// one account, so nothing has to migrate.
    func knownUIDs(for account: POP3Account) -> Set<String> {
        let all = UserDefaults.standard.dictionary(forKey: Self.uidKey) as? [String: [String]] ?? [:]
        return Set(all[account.keychainAccount] ?? [])
    }

    func setKnownUIDs(_ uids: Set<String>, for account: POP3Account) {
        var all = UserDefaults.standard.dictionary(forKey: Self.uidKey) as? [String: [String]] ?? [:]
        all[account.keychainAccount] = Array(uids)
        UserDefaults.standard.set(all, forKey: Self.uidKey)
    }
}

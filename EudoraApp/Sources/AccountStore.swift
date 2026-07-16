import Foundation
import SwiftUI
import EudoraNet

/// Holds the mail account settings — SMTP (outgoing) and POP3 (incoming) —
/// persisted as JSON in UserDefaults, with both passwords in the Keychain.
/// Also tracks which POP3 UIDLs have already been downloaded so Check Mail only
/// pulls new messages.
@MainActor
final class AccountStore: ObservableObject {
    @Published var account: SMTPAccount
    @Published var password: String = ""

    @Published var pop: POP3Account
    @Published var incomingPassword: String = ""

    private static let smtpKey = "SMTPAccount"
    private static let popKey = "POP3Account"
    private static let uidKey = "POP3KnownUIDs"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.smtpKey),
           let a = try? JSONDecoder().decode(SMTPAccount.self, from: data) {
            account = a
            password = Keychain.password(account: a.keychainAccount) ?? ""
        } else {
            account = SMTPAccount()
        }

        if let data = UserDefaults.standard.data(forKey: Self.popKey),
           let p = try? JSONDecoder().decode(POP3Account.self, from: data) {
            pop = p
            incomingPassword = Keychain.password(account: p.keychainAccount) ?? ""
        } else {
            pop = POP3Account()
        }
    }

    var isReadyToSend: Bool { account.isConfigured && !password.isEmpty }
    var isReadyToReceive: Bool { pop.isConfigured && !incomingPassword.isEmpty }

    func save() {
        if let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: Self.smtpKey)
        }
        if !password.isEmpty {
            Keychain.savePassword(password, account: account.keychainAccount)
        }
        if let data = try? JSONEncoder().encode(pop) {
            UserDefaults.standard.set(data, forKey: Self.popKey)
        }
        if !incomingPassword.isEmpty {
            Keychain.savePassword(incomingPassword, account: pop.keychainAccount)
        }
    }

    // MARK: downloaded-UID tracking (per POP account)

    func knownUIDs() -> Set<String> {
        let all = UserDefaults.standard.dictionary(forKey: Self.uidKey) as? [String: [String]] ?? [:]
        return Set(all[pop.keychainAccount] ?? [])
    }

    func setKnownUIDs(_ uids: Set<String>) {
        var all = UserDefaults.standard.dictionary(forKey: Self.uidKey) as? [String: [String]] ?? [:]
        all[pop.keychainAccount] = Array(uids)
        UserDefaults.standard.set(all, forKey: Self.uidKey)
    }
}

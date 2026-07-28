import Foundation

/// Non-secret POP3 (incoming mail) settings. Password lives in the Keychain.
/// Implicit TLS only (port 995), mirroring the SMTP client's transport.
public struct POP3Account: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    /// When true, downloaded messages are removed from the server — but only in
    /// a second pass, after they've been written to the local archive.
    ///
    /// Per account, deliberately. The two servers needn't agree: musanim is the
    /// permanent archive, while Gmail keeps its own copy under its "when
    /// messages are accessed with POP" setting.
    public var deleteAfterDownload: Bool

    public init(host: String = "", port: Int = 995, username: String = "",
                deleteAfterDownload: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.deleteAfterDownload = deleteAfterDownload
    }

    /// Decoded field-by-field with `decodeIfPresent` so a blob written by a
    /// different build still loads instead of throwing and wiping a saved
    /// server/username back to defaults. Unknown keys are ignored by `Codable`,
    /// so a blob from the single-account build — which carried `autoCheckEnabled`
    /// and `autoCheckMinutes` here before they became one app-wide setting —
    /// decodes cleanly. `AccountStore` reads those two out of the old blob
    /// separately when it migrates.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 995
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        deleteAfterDownload = try c.decodeIfPresent(Bool.self, forKey: .deleteAfterDownload) ?? false
    }

    public var keychainAccount: String { "pop:\(username)@\(host):\(port)" }
    public var isConfigured: Bool { !host.isEmpty && !username.isEmpty && port > 0 }
}

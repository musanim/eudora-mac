import Foundation

/// Non-secret POP3 (incoming mail) settings. Password lives in the Keychain.
/// Implicit TLS only (port 995), mirroring the SMTP client's transport.
public struct POP3Account: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    /// When true, downloaded messages are removed from the server — but only in
    /// a second pass, after they've been written to the local archive.
    public var deleteAfterDownload: Bool
    /// Whether the app checks for new mail on a timer (see
    /// `AppModel.configureAutoCheck`).
    public var autoCheckEnabled: Bool
    /// The auto-check interval in minutes. At least 1; clamped on decode and in
    /// the settings field.
    public var autoCheckMinutes: Int

    public init(host: String = "", port: Int = 995, username: String = "",
                deleteAfterDownload: Bool = false,
                autoCheckEnabled: Bool = false, autoCheckMinutes: Int = 1) {
        self.host = host
        self.port = port
        self.username = username
        self.deleteAfterDownload = deleteAfterDownload
        self.autoCheckEnabled = autoCheckEnabled
        self.autoCheckMinutes = max(1, autoCheckMinutes)
    }

    /// Decoded field-by-field with `decodeIfPresent` so a blob written by an
    /// older build — which had no auto-check keys — still loads instead of
    /// throwing and wiping the saved server/username back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 995
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        deleteAfterDownload = try c.decodeIfPresent(Bool.self, forKey: .deleteAfterDownload) ?? false
        autoCheckEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoCheckEnabled) ?? false
        autoCheckMinutes = max(1, try c.decodeIfPresent(Int.self, forKey: .autoCheckMinutes) ?? 1)
    }

    public var keychainAccount: String { "pop:\(username)@\(host):\(port)" }
    public var isConfigured: Bool { !host.isEmpty && !username.isEmpty && port > 0 }
}

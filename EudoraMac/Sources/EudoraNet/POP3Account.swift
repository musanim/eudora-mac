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

    public init(host: String = "", port: Int = 995, username: String = "",
                deleteAfterDownload: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.deleteAfterDownload = deleteAfterDownload
    }

    public var keychainAccount: String { "pop:\(username)@\(host):\(port)" }
    public var isConfigured: Bool { !host.isEmpty && !username.isEmpty && port > 0 }
}

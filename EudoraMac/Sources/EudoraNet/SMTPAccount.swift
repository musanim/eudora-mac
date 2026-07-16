import Foundation

/// Non-secret SMTP account settings (the password lives in the Keychain).
public struct SMTPAccount: Codable, Equatable, Sendable {
    public enum Security: String, Codable, CaseIterable, Identifiable {
        case tls        // implicit TLS (SMTPS), typically port 465 — supported now
        case startTLS   // STARTTLS, typically 587 — not yet implemented
        case plain      // no encryption (discouraged)
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .tls:      return "SSL/TLS (465)"
            case .startTLS: return "STARTTLS (587) — not yet"
            case .plain:    return "None (insecure)"
            }
        }
    }

    public var host: String
    public var port: Int
    public var security: Security
    public var username: String
    public var fromName: String
    public var fromAddress: String

    public init(host: String = "", port: Int = 465, security: Security = .tls,
                username: String = "", fromName: String = "", fromAddress: String = "") {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.fromName = fromName
        self.fromAddress = fromAddress
    }

    /// Keychain account key for this login.
    public var keychainAccount: String { "\(username)@\(host):\(port)" }

    public var isConfigured: Bool {
        !host.isEmpty && !username.isEmpty && !fromAddress.isEmpty && port > 0
    }
}

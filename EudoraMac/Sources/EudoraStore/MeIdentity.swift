import Foundation

/// The set of addresses that are *you* — the fact the Who column needs to decide
/// which end of a message is the correspondent and which way it went. Because
/// this archive spans decades, "me" is a set, not one address, and an incomplete
/// set shows old-you as the other party; so the app persists it and lets it be
/// grown (see `MeIdentityHarvest` for the free seed from the Out mailbox).
///
/// Two kinds of entry, both normalized and lowercased:
///   • **addresses** — exact `local@domain`, via `EmailAddress.bareAddress`;
///   • **domains** — a whole domain you own (`@musanim.com` or `*@musanim.com`),
///     where *every* local part is you. A domain rule is the honest way to say
///     "anything at musanim.com is me" without listing addresses you'll never
///     recall.
/// Both make membership a plain `Set` lookup, and collapse a person's varied
/// display names to one entry.
public struct MeIdentity: Codable, Equatable, Sendable {
    public private(set) var addresses: Set<String>
    public private(set) var domains: Set<String>

    /// Normalizes on the way in, so callers may pass raw address entries
    /// (`"Steve <s@x>"`), bare addresses, or domain rules (`"@musanim.com"`)
    /// alike; anything that is neither is dropped.
    public init<S: Sequence>(_ raw: S) where S.Element == String {
        addresses = []; domains = []
        for r in raw { insert(r) }
    }

    public init() { addresses = []; domains = [] }

    public var isEmpty: Bool { addresses.isEmpty && domains.isEmpty }

    @discardableResult
    public mutating func insert(_ raw: String) -> Bool {
        switch Self.classify(raw) {
        case .address(let a): return addresses.insert(a).inserted
        case .domain(let d):  return domains.insert(d).inserted
        case .invalid:        return false
        }
    }

    @discardableResult
    public mutating func remove(_ raw: String) -> Bool {
        switch Self.classify(raw) {
        case .address(let a): return addresses.remove(a) != nil
        case .domain(let d):  return domains.remove(d) != nil
        case .invalid:        return false
        }
    }

    /// Merge a set of already-normalized bare addresses (e.g. the Out-harvest).
    public mutating func formUnion(_ other: Set<String>) {
        for a in other { insert(a) }
    }

    /// Whether any address in this header value belongs to me — matched exactly
    /// or by its domain. `nil`/absent headers, and values holding no address at
    /// all, are not me.
    public func matches(headerValue: String?) -> Bool {
        guard let headerValue else { return false }
        return EmailAddress.addresses(in: headerValue).contains(where: isMine)
    }

    /// Whether *any* of several header values (From, To, Cc, Bcc…) is me.
    public func matches(anyOf headerValues: [String?]) -> Bool {
        headerValues.contains { matches(headerValue: $0) }
    }

    /// Whether a single, already-parsed bare address is me.
    public func contains(address: String) -> Bool {
        guard let a = EmailAddress.bareAddress(address) else { return false }
        return isMine(a)
    }

    /// The core test, on one normalized `local@domain`: an exact hit, or its
    /// domain is one I own.
    private func isMine(_ address: String) -> Bool {
        if addresses.contains(address) { return true }
        if let at = address.firstIndex(of: "@") {
            return domains.contains(String(address[address.index(after: at)...]))
        }
        return false
    }

    enum Entry: Equatable { case address(String); case domain(String); case invalid }

    /// Sort a raw entry into an exact address or a whole-domain rule. A rule is
    /// any entry whose local part is empty or a lone `*` (`@musanim.com`,
    /// `*@musanim.com`); everything else goes through the address parser.
    static func classify(_ raw: String) -> Entry {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if let at = t.firstIndex(of: "@") {
            let local = String(t[..<at]).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            if local.isEmpty || local == "*" {
                let domain = String(t[t.index(after: at)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'<>"))
                    .lowercased()
                return isValidDomain(domain) ? .domain(domain) : .invalid
            }
        }
        if let a = EmailAddress.bareAddress(raw) { return .address(a) }
        return .invalid
    }

    /// A plausible domain: has a dot, no whitespace, not empty. Deliberately
    /// loose — it only gates what the user typed into their own identity list.
    static func isValidDomain(_ d: String) -> Bool {
        d.contains(".") && !d.isEmpty && !d.contains(where: { $0 == " " || $0 == "\t" })
    }
}

/// Seeding the identity set from mail already on disk. Every `From` address in
/// the **Out** mailbox is, by definition, you — a high-precision, zero-typing
/// seed. The pure collector below takes the `From` header values so it can be
/// tested without files; `MailStore.senderAddresses(at:)` feeds it a real
/// mailbox.
public enum MeIdentityHarvest {
    /// The distinct normalized addresses appearing as `From` across a batch of
    /// messages. Intended for the Out mailbox, but agnostic to source.
    public static func senders<S: Sequence>(fromHeaders: S) -> Set<String>
    where S.Element == String? {
        var out: Set<String> = []
        for header in fromHeaders {
            guard let header else { continue }
            out.formUnion(EmailAddress.addresses(in: header))
        }
        return out
    }
}

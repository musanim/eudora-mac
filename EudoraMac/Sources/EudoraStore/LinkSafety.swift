import Foundation

/// What can be said about a link in a message *without asking anyone*.
///
/// The division of labour matters and is the reason this file is small. The
/// browser already checks reputation — Safari through Google Safe Browsing,
/// proxied by Apple so Google never sees your address, and Chrome directly — and
/// it does that the moment a URL is handed to it. Reimplementing that here would
/// mean worse privacy (our URLs, our IP, straight to a third party), a network
/// dependency in a client whose design decision 2 is "remote content is never
/// fetched", and a blocklist to keep current.
///
/// So this answers only the questions a browser structurally *cannot*, because
/// it never sees the message: is the URL itself constructed to deceive, and does
/// it resemble somewhere you already deal with? Reputation is the browser's job;
/// deception is ours.
///
/// Nothing here reaches the network, and nothing here decides for the user
/// except in the two cases that have no legitimate use in mail.
public enum LinkSafety {

    /// Something worth saying about a link before it is opened.
    public enum Warning: Equatable, Sendable {
        /// `https://apple.com@evil.example` — everything before the `@` is a
        /// username, not a host. Purely deceptive; no legitimate mail uses it.
        case credentialsInURL
        /// A punycode host: `xn--pple-43d.com` renders as `аpple.com` with a
        /// Cyrillic а.
        case punycodeHost
        /// Latin mixed with another script in one host — the same attack when
        /// it hasn't been encoded.
        case mixedScriptHost
        /// A bare IP address instead of a name.
        case ipAddressHost
        /// A familiar name appearing as a *label* rather than as the domain:
        /// `apple.com.security-check.ru` is `security-check.ru`.
        case familiarNameAsLabel(String)
        /// The host is a near-miss for a domain the user corresponds with:
        /// `paypa1.com` against a known `paypal.com`.
        case lookAlike(of: String)
    }

    /// A scheme that will not be opened at all.
    public enum Refusal: Equatable, Sendable {
        /// Anything but http, https and mailto. Only these can do nothing worse
        /// than show a page; the rest can hand the click to an application.
        case unsupportedScheme(String)
        /// Credentials in the URL. Deceptive by construction, so this is the one
        /// warning promoted to a refusal.
        case deceptiveCredentials
        case malformed
    }

    public struct Assessment: Sendable {
        public let host: String
        public let warnings: [Warning]
        public let refusal: Refusal?
        public var isSafeToOffer: Bool { refusal == nil }
    }

    /// Schemes a click may open. Everything else is refused: a link is allowed
    /// to show you a page, not to start an application.
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// Assess a link.
    ///
    /// - Parameter familiarDomains: domains the user demonstrably deals with,
    ///   used for the look-alike test. The value of this check is that it is
    ///   *personal* — a generic blocklist has no idea which brands would fool
    ///   this particular reader, and "one letter off a domain you have hundreds
    ///   of messages from" is a far stronger signal than any list can give.
    public static func assess(_ raw: String, familiarDomains: Set<String> = []) -> Assessment {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            return Assessment(host: raw, warnings: [], refusal: .malformed)
        }
        guard allowedSchemes.contains(scheme) else {
            return Assessment(host: url.host ?? raw, warnings: [],
                              refusal: .unsupportedScheme(scheme))
        }
        if scheme == "mailto" {
            return Assessment(host: url.path, warnings: [], refusal: nil)
        }
        // `user` is present for `https://apple.com@evil.example`, where
        // everything before the `@` is decoration.
        if url.user != nil {
            return Assessment(host: url.host ?? raw, warnings: [],
                              refusal: .deceptiveCredentials)
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return Assessment(host: raw, warnings: [], refusal: .malformed)
        }

        var warnings: [Warning] = []
        // Both name tests read the host **as the message wrote it**, not as
        // Foundation hands it back. `URL(string:)` IDNA-encodes on the way in:
        // the Cyrillic form of apple.com arrives as `xn--pple-43d.com`, so
        // `isMixedScript(url.host)` could never once return true and the
        // mixed-script warning was unreachable. (Measured, not assumed — that
        // exact string round-trips to that exact punycode.)
        //
        // A cascade, not three independent tests, so exactly one name warning
        // can fire and each is honest about what actually arrived: a link that
        // turned up already encoded is a punycode host; one written with a
        // Cyrillic а is a mixed-script host; and the last clause is the case
        // that made this a cascade rather than a straight swap — a
        // single-script non-Latin domain like `пример.рф` has no `xn--` as
        // written and no Latin letters to mix, so reading only the raw form
        // would have dropped its warning entirely. Falling back to the
        // normalised host keeps it.
        let written = rawAuthority(raw) ?? host
        if written.contains("xn--") { warnings.append(.punycodeHost) }
        else if isMixedScript(written) { warnings.append(.mixedScriptHost) }
        else if host.contains("xn--") { warnings.append(.punycodeHost) }
        if isIPAddress(host) { warnings.append(.ipAddressHost) }

        let labels = host.split(separator: ".").map(String.init)
        let registrable = registrableDomain(host)
        for familiar in familiarDomains where familiar != registrable {
            // The familiar name buried as a label: `apple.com.evil.ru`.
            if labels.dropLast(2).contains(where: { $0 == familiar.split(separator: ".").first.map(String.init) }) {
                warnings.append(.familiarNameAsLabel(familiar))
            } else if editDistance(registrable, familiar) <= 2,
                      abs(registrable.count - familiar.count) <= 2 {
                warnings.append(.lookAlike(of: familiar))
            }
        }
        return Assessment(host: host, warnings: warnings, refusal: nil)
    }

    /// The host a link's *visible text* claims to go to, if it claims one.
    ///
    /// The classic phishing move, and the one signal a browser can never
    /// provide: the text reads `paypal.com` and the `href` goes elsewhere. The
    /// browser only ever sees the destination.
    ///
    /// Only text that is *itself* an address counts. "Click here", "your
    /// account", a company's name in prose — none of those claim a destination,
    /// and treating them as claims would fire on ordinary mail until the warning
    /// meant nothing. What must be caught is text that looks like somewhere you
    /// could type into a browser.
    ///
    /// Returns nil when the text makes no claim.
    public static func claimedHost(inAnchorText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        // A URL, or a bare host. `URL(string:)` accepts far too much to use as
        // the test, so the shape is checked directly.
        var candidate = trimmed
        for prefix in ["https://", "http://"] where candidate.hasPrefix(prefix) {
            candidate = String(candidate.dropFirst(prefix.count))
        }
        candidate = String(candidate.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" }))
        // An address, not a hostname — a mailto's text is an address and its
        // href is that same address.
        guard !candidate.contains("@") else { return nil }
        let labels = candidate.split(separator: ".")
        guard labels.count >= 2,
              let tld = labels.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter }),
              labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return candidate
    }

    /// Whether a link's visible text claims a different destination from its
    /// `href`. Compared on the registrable domain, so `nytimes.com` in the text
    /// and `click.e.nytimes.com` in the href — a tracking redirect through the
    /// sender's own domain — is not a mismatch.
    public static func textMisleads(anchorText: String, href: String) -> String? {
        guard let claimed = claimedHost(inAnchorText: anchorText),
              let actual = URL(string: href)?.host?.lowercased() else { return nil }
        let claimedDomain = registrableDomain(claimed)
        return claimedDomain == registrableDomain(actual) ? nil : claimedDomain
    }

    /// The last two labels. Crude — it calls `bbc.co.uk` "co.uk" — and
    /// deliberately not a public-suffix list, which would be a data file to keep
    /// current for a check whose output is advisory text. The cost of the
    /// crudeness is a missed look-alike on a two-part TLD, not a false alarm.
    ///
    /// `public` because the app normalises its own list of familiar domains with
    /// it before passing them in — both sides of the comparison have to be
    /// reduced the same way, so this must be the one implementation.
    public static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return host }
        return labels.suffix(2).joined(separator: ".")
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }          // IPv6
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
    }

    /// The authority exactly as the link was written, before Foundation
    /// normalises it.
    ///
    /// Needed because `URL(string:)` IDNA-encodes a non-ASCII host, which erases
    /// the very difference `isMixedScript` looks for. Deliberately textual and
    /// deliberately not a parser: it is only ever fed to the two *name* tests,
    /// and both fall back to the parsed host when this returns nil, so the worst
    /// a malformed input can cost is the sharper of two warnings.
    ///
    /// Userinfo is dropped rather than trusted — `assess` has already refused
    /// anything with credentials by the time this is called, but a host taken
    /// from the wrong side of an `@` would be exactly the deception this file
    /// exists to catch.
    static func rawAuthority(_ raw: String) -> String? {
        guard let schemeEnd = raw.range(of: "://") else { return nil }
        var rest = raw[schemeEnd.upperBound...]
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = rest[..<end]
        }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        // A trailing `:port`, but not the colons inside an IPv6 literal — hence
        // the digits-only test and the bracket check. ASCII digits specifically:
        // `Character.isNumber` is true of `٣` and `½`, and this is the one place
        // the function discards characters, which is precisely the non-ASCII
        // evidence it exists to preserve.
        if !rest.hasSuffix("]"), let colon = rest.lastIndex(of: ":"),
           rest[rest.index(after: colon)...].allSatisfy({ $0.isASCII && $0.isNumber }) {
            rest = rest[..<colon]
        }
        return rest.isEmpty ? nil : String(rest).lowercased()
    }

    /// Latin letters mixed with another alphabet in one host — how `аpple.com`
    /// is spelled when it hasn't been punycoded.
    static func isMixedScript(_ host: String) -> Bool {
        var latin = false, other = false
        for scalar in host.unicodeScalars where CharacterSet.letters.contains(scalar) {
            if scalar.isASCII { latin = true } else { other = true }
        }
        return latin && other
    }

    /// Levenshtein distance, for the look-alike test. Small inputs — two domain
    /// names — so the simple two-row form is plenty.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}

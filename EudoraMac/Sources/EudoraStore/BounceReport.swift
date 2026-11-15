import Foundation

/// Reading a delivery-failure report: which addresses failed, and whether the
/// failure says the address itself is gone.
///
/// **Why** (2026nov14): the MAM4U announcement went to addresses collected
/// since 1997, and many of them no longer exist. A bounce is worth two things —
/// filed beside the person's other mail, it is a reminder; recorded in
/// `FailedAddresses`, it lets the composer warn before the same address is
/// tried again.
///
/// Only the standard machine-readable form is read: a `multipart/report;
/// report-type=delivery-status` message whose `message/delivery-status` part
/// holds per-recipient blocks (RFC 3464). That is what Gmail, Yahoo, Outlook,
/// Postfix and most other servers send. Older free-text bounces ("This is the
/// qmail-send program…") are not guessed at here; the app offers a command for
/// those.
public enum BounceReport {

    /// One per-recipient block that reported `Action: failed`.
    public struct Failure: Equatable, Sendable {
        /// Bare, lowercased. The address as it was *sent to* when the report
        /// gives `Original-Recipient`, else `Final-Recipient` (which a
        /// forwarding server may have rewritten).
        public let address: String
        /// `5.1.1` and the like; empty when the block carries none.
        public let status: String
        /// `Diagnostic-Code`, unfolded, with its `smtp;` type prefix removed.
        public let diagnostic: String
        /// Whether the failure says the address no longer works — as opposed to
        /// a full mailbox, a spam rejection or a relay refusal. See `addressIsGone`.
        public let addressIsGone: Bool
        /// `Final-Recipient`, when the report also gives an `Original-Recipient`
        /// that differs: the address was forwarded (an alumni forwarder, an old
        /// ISP account) or expanded (an alias), and this is where it failed.
        /// `address` stays the one Stephen sent to, which is what the composer
        /// must recognise; this is shown beside it so a working alias with one
        /// dead target can be told from a dead address.
        public let forwardedTo: String?

        public init(address: String, status: String, diagnostic: String, addressIsGone: Bool,
                    forwardedTo: String? = nil) {
            self.address = address
            self.status = status
            self.diagnostic = diagnostic
            self.addressIsGone = addressIsGone
            self.forwardedTo = forwardedTo
        }
    }

    /// What one report says.
    public struct Report: Equatable, Sendable {
        public let failures: [Failure]
        /// The per-message `Arrival-Date` field, raw: when the reporting server
        /// received the message it couldn't deliver. Nil if absent.
        public let arrivalDate: String?
        /// The `Message-ID` of the message that bounced, from the returned
        /// original (`message/rfc822`, or `text/rfc822-headers`) the report
        /// carries — what tells a bounce of Stephen's own mail from backscatter
        /// for spam forged in his name. Nil if the report returned none.
        public let originalMessageID: String?
    }

    /// The whole of a delivery-status report, or nil if `root` is not one.
    /// Strict in the way `failures(in:)` describes.
    public static func report(in root: MIMEPart) -> Report? {
        guard root.contentType == "multipart/report" else { return nil }
        guard let status = root.children.first(where: isStatusPart) else { return nil }
        let text = String(decoding: status.decodedPayload(), as: UTF8.self)
        let arrival = fieldBlocks(text).lazy.compactMap { $0["arrival-date"] }.first
        var originalID: String?
        for child in root.children
        where ["message/rfc822", "text/rfc822-headers", "message/global",
               "message/global-headers"].contains(child.contentType) {
            let original = MIMEParser.parse([UInt8](child.decodedPayload()))
            if let id = original.header("Message-ID")?.trimmingCharacters(in: .whitespaces),
               !id.isEmpty {
                originalID = id
                break
            }
        }
        return Report(failures: failures(inStatusText: text),
                      arrivalDate: arrival, originalMessageID: originalID)
    }

    /// The failed recipients of a delivery-status report, or `[]` if `root` is
    /// not one.
    ///
    /// **Strict on purpose**, because the app acts on it unasked: the message
    /// itself must be `multipart/report`, and only a `message/delivery-status`
    /// (or RFC 6533 `message/global-delivery-status`) part *directly* inside it
    /// is read. A bounce quoted or forwarded inside someone's ordinary message
    /// never counts, and neither does the returned original that a report
    /// carries.
    public static func failures(in root: MIMEPart) -> [Failure] {
        report(in: root)?.failures ?? []
    }

    /// The failures in delivery-status text, wherever it came from.
    ///
    /// Also used, leniently, by the app's by-hand command on a message whose
    /// structure Eudora 7 flattened: there the fields survive only as body
    /// text. Blocks are separated by blank lines; a block counts when it has a
    /// recipient field and `Action: failed`.
    public static func failures(inStatusText text: String) -> [Failure] {
        var out: [Failure] = []
        var seen: Set<String> = []
        for block in fieldBlocks(text) {
            guard let action = block["action"],
                  action.lowercased().hasPrefix("failed") else { continue }
            let original = recipient(block["original-recipient"])
            let finalRecipient = recipient(block["final-recipient"])
            guard let address = original ?? finalRecipient else { continue }
            guard seen.insert(address).inserted else { continue }
            let status = statusCode(block["status"] ?? "")
            let diagnostic = stripType(block["diagnostic-code"] ?? "")
            out.append(Failure(address: address, status: status, diagnostic: diagnostic,
                               addressIsGone: addressIsGone(status: status,
                                                            diagnostic: diagnostic),
                               forwardedTo: finalRecipient != nil && finalRecipient != address ? finalRecipient : nil))
        }
        return out
    }

    // MARK: - the decision

    /// Whether a permanent failure says the address itself no longer works.
    ///
    /// Measured on `phaseX`'s 913 reports (2026nov14). The status codes that
    /// mean "this address" are taken on their own (`addressStatusCodes`): bad
    /// mailbox, bad domain, bad syntax, moved, null MX, mailbox disabled,
    /// unroutable. Many servers send a generic 5.0.0 or 5.5.0 — and Microsoft
    /// a 5.4.1 or 5.7.x — with the meaning only in the diagnostic text ("No Such
    /// User Here", "Address rejected"), so any other 5.x.x counts when that text
    /// says the address is gone and says nothing of spam, policy or a passing
    /// condition.
    ///
    /// Deliberately not gone: 5.2.2 (mailbox full), 5.7.1 relay and content
    /// rejections, and every 4.x.x. The address may well work next time, and a
    /// false warning in the composer would teach Stephen to ignore it.
    static func addressIsGone(status: String, diagnostic: String) -> Bool {
        if addressStatusCodes.contains(status) { return true }
        guard status.isEmpty || status.hasPrefix("5.") else { return false }
        if status == "5.2.2" || status == "5.1.7" || status == "5.1.8" { return false }
        let d = diagnostic.lowercased()
        if notAboutTheAddress.contains(where: { d.contains($0) }) { return false }
        return addressGonePhrases.contains(where: { d.contains($0) })
            || providerSaysNoMailbox(d)
            || embeddedCodes(d).contains(where: { addressStatusCodes.contains($0) })
    }

    /// `d.d.d` tokens inside diagnostic text — a relaying server often wraps the
    /// final one's specific code ("501-'#5.1.1 bad address'") in its own generic
    /// 5.0.0. A token must stand alone, so a dotted IP address such as
    /// `195.1.1.4` never yields `5.1.1`.
    static func embeddedCodes(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var i = 0
        func isPart(_ c: Character) -> Bool { c.isNumber || c == "." }
        while i < chars.count {
            guard isPart(chars[i]), i == 0 || !isPart(chars[i - 1]) else { i += 1; continue }
            var j = i
            while j < chars.count, isPart(chars[j]) { j += 1 }
            let token = String(chars[i..<j])
            let trimmed = token.hasSuffix(".") ? String(token.dropLast()) : token
            if !statusCode(trimmed).isEmpty { out.append(trimmed) }
            i = j
        }
        return out
    }

    /// A provider's own code for "no such mailbox", where the words around it
    /// say only "Recipient rejected". EarthLink (Vade Secure) answers a dead
    /// address with `550 5.5.1 Recipient rejected - ELNK001_403 - <url>`; its
    /// postmaster page gives `_403` as "Mailbox does not exist on this
    /// platform" and the 5.x `_402` as "a non-existent customer/user"
    /// (2026nov14, Gordon Green). The 4.x `_402` is temporary and never gets
    /// here — `addressIsGone` stops at anything but 5.x.x first.
    static func providerSaysNoMailbox(_ diagnostic: String) -> Bool {
        diagnostic.range(of: #"elnk[0-9]*_40[23]\b"#, options: .regularExpression) != nil
    }

    /// Codes that name the recipient's address as the problem, taken without
    /// reading the text — which a code this specific never contradicts, while
    /// its wording can trip the overrides ("fully", "try to resend").
    ///
    /// Not every 5.1.x: 5.1.7 and 5.1.8 are about the *sender's* address, and
    /// 5.1.0 is generic.
    static let addressStatusCodes: Set<String> = [
        "5.1.1", "5.1.2", "5.1.3", "5.1.6", "5.1.10", "5.2.1", "5.4.4",
    ]

    /// Diagnostic wording that means the address does not, or no longer, exists.
    static let addressGonePhrases = [
        "user unknown", "unknown user", "no such user", "no such recipient",
        "unknown recipient", "recipient unknown", "invalid recipient",
        "recipient invalid", "address invalid", "invalid address",
        "address rejected", "does not exist", "doesn't exist", "not exist",
        "no mailbox", "mailbox not found", "mailbox unavailable",
        "mailbox does not", "account is unavailable", "account has been disabled",
        "account is disabled", "account that you tried to reach is disabled",
        "disableduser", "inactive", "unrouteable", "unroutable",
        "user not found", "recipient not found", "address not found",
        "no such domain", "domain not found", "host not found",
        "bad destination mailbox", "not a valid", "no longer",
        "doesn't have a", "does not have a", "bad address", "unknown address",
        "unknown local-part", "illegal alias", "invalid-email-address",
        "deactivated", "not a registered mail name", "may not exist",
    ]

    /// Wording that means the rejection was about the message or the sender,
    /// not the address — and overrides a status code that would otherwise
    /// count, since a spam filter can answer with almost any code.
    ///
    /// Phrases rather than bare words where a bare word would hit inside an
    /// innocent one: "relay" is in "relayed", "full" in "successfully". The
    /// sender phrases matter because "Sender address rejected: Domain not
    /// found" reads as gone to every phrase in `addressGonePhrases`.
    static let notAboutTheAddress = [
        "spam", "blacklist", "blocklist", "blocked", "policy", "content",
        "relay access", "relaying denied", "relay not permitted",
        "permitted to relay", "unable to relay", "relaying not allowed",
        "greylist", "temporar", "try again", "quota", "mailbox full",
        "mailbox is full", "authentication", "rate limit", "too many",
        "sender address", "sender domain", "sender verify", "sender's",
    ]

    // MARK: - parsing

    static func isStatusPart(_ part: MIMEPart) -> Bool {
        let t = part.contentType
        return t == "message/delivery-status" || t == "message/global-delivery-status"
    }

    /// The text split into blank-line-separated blocks of `name: value` fields,
    /// continuation lines unfolded, names lowercased. A repeated field keeps
    /// its first value.
    static func fieldBlocks(_ text: String) -> [[String: String]] {
        var blocks: [[String: String]] = []
        var current: [String: String] = [:]
        var lastName: String?
        func flush() {
            if !current.isEmpty { blocks.append(current) }
            current = [:]
            lastName = nil
        }
        // `\.isNewline`, not `"\n"`: Swift reads `\r\n` as one Character, so
        // splitting on "\n" alone leaves a CRLF report — most of them — as a
        // single line.
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                continue
            }
            if let first = line.first, first == " " || first == "\t" {
                if let name = lastName, let v = current[name] {
                    let more = line.trimmingCharacters(in: .whitespaces)
                    current[name] = v.isEmpty ? more : v + " " + more
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { lastName = nil; continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { lastName = nil; continue }
            if current[name] == nil {
                current[name] = value
                lastName = name
            } else {
                lastName = nil
            }
        }
        flush()
        return blocks
    }

    /// The bare address in a recipient field: `rfc822; a@b.com`, with or
    /// without `<>`. Nil for another address type (`x-x500;CN=…`) or for no
    /// address at all.
    static func recipient(_ value: String?) -> String? {
        guard let value else { return nil }
        var v = value
        if let semi = v.firstIndex(of: ";") {
            let type = v[..<semi].trimmingCharacters(in: .whitespaces).lowercased()
            guard type == "rfc822" || type == "utf-8" else { return nil }
            v = String(v[v.index(after: semi)...])
        }
        return EmailAddress.bareAddress(v)
    }

    /// The `d.d.d` code at the start of a Status value; empty when there is none.
    static func statusCode(_ value: String) -> String {
        let token = value.split(whereSeparator: { $0 == " " || $0 == "(" }).first.map(String.init) ?? ""
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return "" }
        return token
    }

    /// A Diagnostic-Code without its `smtp;` / `X-Postfix;` type.
    static func stripType(_ value: String) -> String {
        guard let semi = value.firstIndex(of: ";") else { return value }
        let type = value[..<semi]
        guard !type.isEmpty, !type.contains(" ") else { return value }
        return value[value.index(after: semi)...].trimmingCharacters(in: .whitespaces)
    }
}

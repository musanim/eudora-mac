import Foundation

/// Deciding whether an arriving message is held back from In.
///
/// **The problem it answers** (2026nov13): spam sent from a shared free-mail
/// domain, a fresh address every time. Blocking the address is useless — it is
/// never used twice — and blocking the domain would also block the people
/// Stephen does correspond with there. So, for a short list of *watched*
/// domains, mail from a sender he has never dealt with goes quietly to a
/// HOLDING mailbox, to be looked through as a batch, and mail from anyone he
/// knows arrives as usual.
///
/// Holding, never deleting: a genuinely new correspondent at a watched domain
/// waits there rather than being lost.
///
/// The pure parts live here so they can be tested; "has Stephen dealt with this
/// address" draws on the app's search index and recent recipients, and is
/// answered in `AppModel`.
public enum HoldingRule {

    /// The sender's bare address, if it is at one of `watchedDomains` (or a
    /// subdomain of one); nil otherwise.
    ///
    /// The address is taken from the *last* `<…>` in From, as
    /// `FraudRecognizer.senderAddress` does, so a real-looking address written
    /// into the display name can't steer the decision.
    public static func watchedSender(fromHeader: String, watchedDomains: Set<String>) -> String? {
        guard let address = FraudRecognizer.senderAddress(fromHeader),
              let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...].lowercased()
        let watched = watchedDomains.contains { base in
            let b = base.lowercased()
            return domain == b || domain.hasSuffix("." + b)
        }
        return watched ? address : nil
    }

    /// Every address named in From, To or Cc anywhere in the mailbox at
    /// `base`, lowercased — or nil if the mailbox can't be read.
    ///
    /// For In and Out, which the search index can't be trusted to know about:
    /// it is rebuilt wholesale rather than per delivery, so this morning's mail
    /// and this morning's replies are exactly what it is missing. Built once per
    /// check and reused for every watched-domain message in it.
    ///
    /// **Nil is "can't tell", not "nobody"**, and the caller must treat it so:
    /// an unreadable In is no evidence that a sender is a stranger.
    ///
    /// Headers only, and at most `headerWindow` bytes of each record, so a large
    /// attachment is never parsed. (The mailbox itself is read whole; In and
    /// Out are small.)
    public static func correspondents(inMailboxAt base: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: base.appendingPathExtension("mbx"),
                                   options: .mappedIfSafe) else { return nil }
        let bytes = [UInt8](data)
        var out: Set<String> = []
        for rec in Mbox.findRecords(bytes) {
            let end = min(rec.offset + min(rec.length, headerWindow), bytes.count)
            guard rec.offset < end else { continue }
            let record = Array(bytes[rec.offset..<end])
            let part = MIMEParser.parse(headerBlock(Mbox.messageBytes(fromRecord: record)))
            for h in part.headers where ["from", "to", "cc"].contains(h.name.lowercased()) {
                out.formUnion(EmailAddress.addresses(in: h.value))
            }
        }
        return out
    }

    /// How much of each record `correspondents` parses. Generous, because what
    /// a too-long header block loses is its *tail* — and servers prepend
    /// `Received:` and signatures, so the tail is where From, To and Cc usually
    /// sit. A block past this size loses them; the decision then falls to the
    /// index, never to "stranger" on this evidence alone.
    static let headerWindow = 256 * 1024

    /// Whether a filing count shows mail with this address kept somewhere —
    /// that is, in any mailbox but the ones that hold unwanted mail.
    ///
    /// SCAMS and HOLDING are excluded because mail there is precisely mail
    /// Stephen did *not* want; counting it would let a spammer's second message
    /// vouch for itself. Everywhere else counts, Trash included: a deleted
    /// message from a real person still means a real person, and the spam this
    /// is for never reuses an address, so it never has history to count.
    public static func keptAnywhere(_ mailboxes: [String], excluding unwanted: Set<String>) -> Bool {
        mailboxes.contains { !unwanted.contains($0) }
    }

    /// The header block of a message, through the blank line that ends it.
    /// The whole message if there is none.
    static func headerBlock(_ bytes: [UInt8]) -> [UInt8] {
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0x0A {
                if bytes[i + 1] == 0x0A { return Array(bytes[...(i + 1)]) }
                if bytes[i + 1] == 0x0D, i + 2 < bytes.count, bytes[i + 2] == 0x0A {
                    return Array(bytes[...(i + 2)])
                }
            }
            i += 1
        }
        return bytes
    }
}

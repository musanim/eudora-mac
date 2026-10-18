import Foundation

/// Who a reply goes to: the To and Cc lines for Reply, Reply to All, and Reply
/// to All as To.
///
/// Pure and AppKit-free so `swift test` can pin it down. `AppModel.reply`
/// supplies the original's raw headers and turns the entries returned here into
/// field text.
///
/// Entries come back as they appeared in the original's headers (encoded-words
/// and all) rather than decoded, because decoding is the caller's job:
/// `AppModel.recipientFieldText` splits *before* it decodes, which is what keeps
/// a comma hidden inside an encoded name from splitting one recipient in two.
public enum ReplyRecipients {

    public enum Mode: Sendable {
        /// The sender only.
        case sender
        /// The sender in To, everyone else on the original in Cc.
        case all
        /// Everyone in To.
        case allAsTo
    }

    /// The reply's recipients, as raw address entries.
    ///
    /// Rules, for the two reply-all modes:
    /// - **You are left out.** Any entry `me` matches is dropped from the
    ///   others, so you never Cc yourself.
    /// - **Nobody appears twice.** Compared by bare address, so `Bob <b@x>` in
    ///   To and `b@x` in Cc are one person; the first occurrence wins, with the
    ///   sender's line ahead of To ahead of Cc.
    /// - **Entries with no address are dropped** — `undisclosed-recipients:;`
    ///   and the like, which would only be an error in a To field.
    /// - **Replying to your own message** — every From address is yours, as on
    ///   something in Out or a sent-mail copy — means the people you wrote to
    ///   are the ones to answer: they become the primary recipients in place of
    ///   you. If that leaves nobody (a note to yourself), it falls back to the
    ///   From line, as a plain Reply does.
    ///
    /// `.sender` is exactly what Reply has always done — the From line, nothing
    /// removed — and is here so all three go through one place.
    public static func compute(from: String, to: String, cc: String,
                               me: MeIdentity, mode: Mode) -> (to: [String], cc: [String]) {
        let fromEntries = EmailAddress.splitList(from)
        guard mode != .sender else { return (fromEntries, []) }

        let toEntries = EmailAddress.splitList(to)
        let ccEntries = EmailAddress.splitList(cc)

        var seen = Set<String>()
        /// The entries of `list` not yet seen, not me, and holding an address,
        /// in order. Records what it keeps in `seen`.
        func fresh(_ list: [String], droppingMe: Bool) -> [String] {
            list.filter { entry in
                guard let address = EmailAddress.bareAddress(entry) else { return false }
                if droppingMe, me.contains(address: address) { return false }
                return seen.insert(address).inserted
            }
        }

        let fromIsMe = !fromEntries.isEmpty && fromEntries.allSatisfy { entry in
            EmailAddress.bareAddress(entry).map { me.contains(address: $0) } ?? false
        }

        var primary: [String]
        var others: [String]
        if fromIsMe {
            primary = fresh(toEntries, droppingMe: true)
            if primary.isEmpty {
                // A note to yourself: nobody else was on it, so answer the
                // From line, as Reply would. Kept even though it is you.
                primary = fresh(fromEntries, droppingMe: false)
            }
            others = fresh(ccEntries, droppingMe: true)
        } else {
            // The sender stays even if `me` happens to match them — an
            // over-broad domain rule must not empty the To line.
            primary = fresh(fromEntries, droppingMe: false)
            others = fresh(toEntries + ccEntries, droppingMe: true)
        }

        switch mode {
        case .allAsTo: return (primary + others, [])
        default:       return (primary, others)
        }
    }
}

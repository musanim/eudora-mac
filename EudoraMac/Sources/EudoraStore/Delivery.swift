import Foundation

/// Delivery of incoming mail into the Eudora tree. Parses the sender/subject
/// for the TOC cache and appends the raw message to the target mailbox as
/// **unread**, reusing the same envelope + backup + atomic + `.toc` path as
/// sent-mail write-back.
public enum Delivery {
    /// Append a received RFC-822 message to `base` (typically the In mailbox).
    @discardableResult
    public static func deliverIncoming(messageData: Data, to base: URL,
                                       date: Date = Date()) throws -> Int {
        let part = MIMEParser.parse([UInt8](messageData))
        let from = HeaderDecoder.decode(part.header("From") ?? "")
        let subject = HeaderDecoder.decode(part.header("Subject") ?? "")
        // `MailboxMutator.statusUnread`, not a literal. This read `status: 1`
        // with the comment "unread" beside it — but 1 is MS_READ; MS_UNREAD is
        // 0. Every delivered message was therefore marked read on arrival, so
        // the list drew no bullet and the mailbox never counted it as unread.
        // Every other caller in the app already used the named constants; this
        // was the one hand-written number, which is how the comment and the
        // value got to disagree.
        let result = try Outbox.append(messageData: messageData, to: base,
                                       status: MailboxMutator.statusUnread,
                                       priority: 4,    // normal
                                       who: from, subject: subject, date: date)
        return result.messageIndex
    }

    /// What one message's turn through `deliverIfNew` came to.
    ///
    /// An enum rather than a `Bool` or an optional index because the caller has
    /// three distinct pieces of bookkeeping and they don't agree: a duplicate
    /// must still have its UID recorded (or it is re-fetched on every check
    /// forever) and must still be deleted from the server if the account says
    /// to, but must **not** count towards "received", which drives the list
    /// refresh and the new-mail glyph. Lighting the glyph for mail that was
    /// discarded would send the user to an In box with nothing new in it.
    public enum Outcome: Equatable {
        /// Appended. `index` is the 1-based position in the target mailbox.
        case delivered(index: Int)
        /// Already present in the target mailbox; nothing was written.
        case duplicate(messageID: String)
    }

    /// Deliver `messageData` unless its `Message-ID` is already in `seen`.
    ///
    /// `seen` is `inout` and is updated on delivery, so a batch is guarded
    /// against itself as well as against the mailbox: the case this exists for —
    /// one message reaching two accounts — usually arrives inside a single
    /// check, before any rescan of the mailbox could see the first copy.
    ///
    /// A message with no usable `Message-ID` is always delivered. See
    /// `MessageIDIndex` for why every uncertain case resolves that way.
    ///
    /// - Precondition: `seen` describes **`base`** — either empty, or built by
    ///   `MessageIDIndex(scanning: base)` and since updated only by this
    ///   function. An index covering any other mailbox is a superset of this
    ///   one's contents and would discard mail that isn't here. That is the one
    ///   refactor which breaks this quietly: hoisting the scan out of a loop so
    ///   it is shared across differing destinations, or reusing an In-derived
    ///   index while delivering somewhere filtered.
    public static func deliverIfNew(messageData: Data, to base: URL,
                                    date: Date = Date(),
                                    seen: inout MessageIDIndex) throws -> Outcome {
        let id = MessageIDIndex.messageID(of: messageData)
        if let id = id, seen.contains(id) {
            if MessageIDIndex.diagnose {
                let part = MIMEParser.parse([UInt8](messageData))
                let subject = HeaderDecoder.decode(part.header("Subject") ?? "")
                print("MessageIDIndex diag: discarded duplicate \(id) — \"\(subject)\"")
            }
            return .duplicate(messageID: id)
        }
        let index = try deliverIncoming(messageData: messageData, to: base, date: date)
        // Recorded only *after* the append succeeds. Inserting first would, on a
        // throw, leave an id in the set for a message that never reached the
        // mailbox — and the retry would then be skipped as a duplicate of
        // something that isn't there, which is the one way this guard could
        // lose mail.
        if let id = id { seen.insert(id) }
        return .delivered(index: index)
    }
}

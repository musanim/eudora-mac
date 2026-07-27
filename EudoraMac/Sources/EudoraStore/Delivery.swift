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
}

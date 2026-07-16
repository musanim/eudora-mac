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
        let result = try Outbox.append(messageData: messageData, to: base,
                                       status: 1,      // unread
                                       priority: 4,    // normal
                                       who: from, subject: subject, date: date)
        return result.messageIndex
    }
}

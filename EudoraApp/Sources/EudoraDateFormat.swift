import Foundation

/// Date parsing and formatting for the message list.
///
/// Deliberately a free-standing type rather than statics on `AppModel`: that
/// class is `@MainActor`, so its static stored properties are main-actor
/// isolated and unreachable from the background parsing that builds the message
/// list. Nothing here touches the UI, so it has no business being isolated.
///
/// `DateFormatter` has been documented as safe to *use* from multiple threads
/// since macOS 10.5 — what isn't safe is mutating one after it's shared. These
/// three are configured once inside their initialisers and never touched again,
/// which is the shape that guarantee covers. Don't add a `var` here.
enum EudoraDateFormat {

    private static let rfc822In: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f
    }()

    private static let rfc822InNoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy HH:mm:ss Z"
        return f
    }()

    private static let eudoraOut: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d/yy h:mm a"
        return f
    }()

    /// Parse an RFC-822 Date header and render it Eudora-style
    /// ("12/17/02 9:04 AM"). Nil when the header is missing or unparseable, so
    /// callers can fall back to the date the TOC cached.
    static func eudoraDate(_ header: String?) -> String? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        let date = rfc822In.date(from: h) ?? rfc822InNoDay.date(from: h)
        return date.map { eudoraOut.string(from: $0) }
    }
}

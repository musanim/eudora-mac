import Foundation

/// Date parsing and formatting for the message list.
///
/// Deliberately a free-standing type rather than statics on `AppModel`: that
/// class is `@MainActor`, so its static stored properties are main-actor
/// isolated and unreachable from the background parsing that builds the message
/// list. Nothing here touches the UI, so it has no business being isolated.
///
/// `DateFormatter` has been documented as safe to *use* from multiple threads
/// since macOS 10.5 — what isn't safe is mutating one after it's shared. Every
/// one here is configured where it is created and never touched again, which is
/// the shape that guarantee covers. Don't add a `var` here.
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

    /// The shapes Eudora has written into the `.toc`'s 32-byte date field over
    /// the years, most common first.
    ///
    /// There is no one format. Reading all 245,671 TOC entries in the real tree
    /// found sixty-odd distinct shapes: the modern time-first pair covers 98.8%
    /// ("05:15 AM 9/29/2025", and "08:33 12/4/2015" for messages whose Date
    /// header carried no meridiem), but the older mail — 1996 through the early
    /// 2000s — is variously date-first, ISO, two-digit-year, year-first, with and
    /// without a numeric zone, and with lowercase meridiems. The ones below bring
    /// the miss rate to 0.03% (82 entries, all of them 1990s mail carrying an
    /// alphabetic zone like "EST"); those simply sort as undated.
    ///
    /// Order matters where two shapes could collide. `M/d/yy` is tried before
    /// `yy/MM/dd`, but either way the wrong one rejects itself: "00/01/10" as
    /// month-first is month zero, "96/11/23" is month 96, and a `DateFormatter`
    /// that isn't lenient refuses both.
    ///
    /// No time zone is set on the ones that don't parse an offset, so those are
    /// read in the machine's current zone — which is what Eudora meant, since it
    /// wrote local time and kept nothing else. See `tocDate(_:)`.
    private static let tocFormats = [
        "hh:mm a M/d/yyyy",     // 230,747
        "HH:mm M/d/yyyy",       //  12,003
        "M/d/yyyy hh:mm a",     //   1,845
        "M/d/yyyy HH:mm",
        "yyyy-MM-dd HH:mm",     //     151
        "hh:mm a M/d/yy Z",
        "hh:mm a M/d/yy",
        "hh:mm a yy/MM/dd Z",
        "hh:mm a yy/MM/dd",
        "M/d/yy hh:mm a",
    ]

    private static let tocIn: [DateFormatter] = tocFormats.map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        // A fixed two-digit-year window rather than the sliding default, which is
        // relative to *today* and would silently reinterpret this archive as the
        // years pass. Eudora predates 1988, so nothing here is older than 1970.
        f.twoDigitStartDate = Date(timeIntervalSince1970: 0)
        return f
    }

    /// Parse an RFC-822 Date header. Nil when the header is missing or
    /// unparseable, so callers can fall back to what the TOC cached.
    static func parse(_ header: String?) -> Date? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        return rfc822In.date(from: h) ?? rfc822InNoDay.date(from: h)
    }

    /// Render a date the way Eudora's message list did ("12/17/02 9:04 AM").
    static func display(_ date: Date) -> String { eudoraOut.string(from: date) }

    /// Parse an RFC-822 Date header and render it Eudora-style.
    static func eudoraDate(_ header: String?) -> String? { parse(header).map(display) }

    /// Parse the date string Eudora cached in the `.toc`, for sorting.
    ///
    /// This exists only to give the Date column a key that orders
    /// chronologically: the displayed string is "10:02 PM 12/5/2025" before the
    /// background parse lands and "12/5/25 10:02 PM" after, and neither sorts
    /// correctly as text (both put October before September).
    ///
    /// The zone mismatch against `parse(_:)` — local here, the sender's offset
    /// there — is deliberate and tolerated rather than avoided. The two kinds of
    /// key *are* mixed within a listing: TOC-derived while enrichment is still
    /// running, and permanently so for any message whose own `Date:` header
    /// didn't parse, since enrichment then leaves the cached value in place. The
    /// error is bounded by one zone offset, which can only reorder messages
    /// within a few hours of each other — invisible against a column showing
    /// dates to the minute over twenty-five years. Recovering the offset would
    /// mean reading the message, which is precisely the cost the TOC exists to
    /// avoid.
    static func tocDate(_ cached: String) -> Date? {
        // Uppercased for the handful of mailboxes that wrote "pm" rather than
        // "PM": `en_US_POSIX` matches the meridiem case-sensitively, and nothing
        // else in these formats is alphabetic, so this can't misread anything.
        let s = cached.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { return nil }
        for formatter in tocIn {
            if let date = formatter.date(from: s) { return date }
        }
        return nil
    }
}

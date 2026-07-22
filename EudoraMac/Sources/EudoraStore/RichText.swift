import Foundation

/// Styled composer text, as a flat list of runs.
///
/// **Why a model of our own rather than `NSAttributedString`.** The editor is an
/// `NSTextView` and its content *is* an attributed string, so this is one more
/// conversion. It buys two things worth more than the conversion costs:
///
/// - `EudoraStore` stays free of AppKit, so everything here is reachable from
///   `swift test` — which is the only place in this project where anything can
///   actually be verified before Stephen builds.
/// - It pins down what "styled" means. `NSAttributedString` always carries a
///   font on every character, so "did the user format anything?" is not a
///   question it can answer. Here a run's style is expressed *relative to the
///   composer's default*, so `isStyled` is exact — and that is what decides
///   between today's plain `text/plain` bytes and a `multipart/alternative`.
///
/// The app converts in both directions (see `RichTextAttributedString`); this
/// side owns the wire format (see `RichTextHTML`).

// MARK: - colour

/// An sRGB colour, as components in 0…1.
///
/// Not `NSColor`: see the note on `RichText`. Comparison is on the stored
/// components, so a colour that survives a round-trip through `#rrggbb` compares
/// equal to one that was quantised the same way — which is why `init` snaps to
/// 8-bit steps rather than keeping whatever float the colour panel produced.
/// Without that, reopening a draft would report it as edited.
public struct RichTextColor: Equatable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.quantise(red)
        self.green = Self.quantise(green)
        self.blue = Self.quantise(blue)
    }

    public init(r: Int, g: Int, b: Int) {
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// Clamp to 0…1 and snap to the nearest 1/255, the resolution the wire
    /// format has. A NaN component becomes 0 rather than propagating.
    private static func quantise(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return (min(max(v, 0), 1) * 255).rounded() / 255
    }

    public static let black = RichTextColor(r: 0, g: 0, b: 0)

    public var isBlack: Bool { self == .black }

    /// `#rrggbb`, lowercase.
    public var hex: String {
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }

    /// Parse the colour forms that turn up in mail HTML: `#rgb`, `#rrggbb`,
    /// `rgb(r, g, b)` (numbers or percentages), and the sixteen HTML 4 names
    /// plus a handful of others common in old mail.
    ///
    /// Anything unrecognised returns nil, and the caller leaves the run's colour
    /// unset — which renders as the reader's default rather than as black. That
    /// is the safer failure: guessing black would make a light-on-dark message
    /// unreadable.
    public static func parse(_ raw: String) -> RichTextColor? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return nil }

        if s.hasPrefix("#") {
            // `hexDigitValue` rather than testing `isHexDigit` and converting
            // separately: one call decides and yields the value, so there is no
            // pair of checks that could disagree and no force-unwrap to trip
            // over when they do.
            let digits = Array(s.dropFirst())
            let values = digits.compactMap { $0.hexDigitValue }
            guard values.count == digits.count else { return nil }
            if values.count == 3 {
                return RichTextColor(r: values[0] * 17, g: values[1] * 17, b: values[2] * 17)
            }
            if values.count == 6 {
                return RichTextColor(r: values[0] << 4 | values[1],
                                     g: values[2] << 4 | values[3],
                                     b: values[4] << 4 | values[5])
            }
            return nil
        }

        if s.hasPrefix("rgb(") || s.hasPrefix("rgba(") {
            guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
            let parts = s[s.index(after: open)..<close]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            var comps: [Double] = []
            for p in parts.prefix(3) {
                if p.hasSuffix("%") {
                    guard let v = Double(p.dropLast()) else { return nil }
                    comps.append(v / 100)
                } else {
                    guard let v = Double(p) else { return nil }
                    comps.append(v / 255)
                }
            }
            return RichTextColor(red: comps[0], green: comps[1], blue: comps[2])
        }

        return named[s]
    }

    /// The HTML 4 sixteen, plus the greys and oranges old mail composers offered.
    private static let named: [String: RichTextColor] = [
        "black": RichTextColor(r: 0, g: 0, b: 0),
        "silver": RichTextColor(r: 192, g: 192, b: 192),
        "gray": RichTextColor(r: 128, g: 128, b: 128),
        "grey": RichTextColor(r: 128, g: 128, b: 128),
        "white": RichTextColor(r: 255, g: 255, b: 255),
        "maroon": RichTextColor(r: 128, g: 0, b: 0),
        "red": RichTextColor(r: 255, g: 0, b: 0),
        "purple": RichTextColor(r: 128, g: 0, b: 128),
        "fuchsia": RichTextColor(r: 255, g: 0, b: 255),
        "magenta": RichTextColor(r: 255, g: 0, b: 255),
        "green": RichTextColor(r: 0, g: 128, b: 0),
        "lime": RichTextColor(r: 0, g: 255, b: 0),
        "olive": RichTextColor(r: 128, g: 128, b: 0),
        "yellow": RichTextColor(r: 255, g: 255, b: 0),
        "navy": RichTextColor(r: 0, g: 0, b: 128),
        "blue": RichTextColor(r: 0, g: 0, b: 255),
        "teal": RichTextColor(r: 0, g: 128, b: 128),
        "aqua": RichTextColor(r: 0, g: 255, b: 255),
        "cyan": RichTextColor(r: 0, g: 255, b: 255),
        "orange": RichTextColor(r: 255, g: 165, b: 0),
    ]
}

// MARK: - style

/// What one run of text carries *over and above* the composer's default.
///
/// Every field being nil/false means "exactly the default", which is what makes
/// `RichText.isStyled` trustworthy. The app must therefore convert an attributed
/// string **relative to** the default font it set on the text view: a run in the
/// default face at the default size records `face == nil, size == nil`, not the
/// literal values.
public struct RichTextStyle: Equatable, Hashable, Sendable {
    public var bold: Bool
    public var italic: Bool
    /// Family name, when the user chose one other than the default.
    public var face: String?
    /// Point size, when the user chose one other than the default.
    public var size: Double?
    /// Foreground colour, when the user chose one other than the default.
    public var color: RichTextColor?

    public init(bold: Bool = false, italic: Bool = false,
                face: String? = nil, size: Double? = nil,
                color: RichTextColor? = nil) {
        self.bold = bold
        self.italic = italic
        self.face = face
        self.size = size
        self.color = color
    }

    public static let plain = RichTextStyle()

    public var isPlain: Bool { self == .plain }
}

// MARK: - runs

public struct RichTextRun: Equatable, Sendable {
    public var text: String
    public var style: RichTextStyle

    public init(_ text: String, style: RichTextStyle = .plain) {
        self.text = text
        self.style = style
    }
}

/// A whole composed body: runs in order, no paragraph structure.
///
/// Line breaks live in the run text as `\n`, exactly as they do in the plain
/// `String` the composer used before this existed. There is no paragraph model
/// because there is no paragraph *formatting* — the scope here is font, size,
/// colour, bold and italic, and adding block structure that nothing can set
/// would be inventing a format to be wrong about later.
public struct RichText: Equatable, Sendable {
    public private(set) var runs: [RichTextRun]

    public init(runs: [RichTextRun]) {
        self.runs = runs
        normalize()
    }

    /// Unstyled text — the shape every message had before rich text existed.
    public init(plain text: String) {
        self.init(runs: text.isEmpty ? [] : [RichTextRun(text)])
    }

    /// The text with all styling dropped: the `text/plain` alternative, and the
    /// string the plain composer would have produced from the same typing.
    public var plainText: String { runs.map(\.text).joined() }

    /// Whether anything here needs HTML to express.
    ///
    /// The one question the whole wire-format decision turns on. False means the
    /// message must be assembled exactly as it was before rich text existed —
    /// see the guarantee documented on `OutgoingMessage.htmlBody`.
    public var isStyled: Bool { runs.contains { !$0.style.isPlain } }

    /// Drop empty runs and merge neighbours that share a style.
    ///
    /// Both matter for `isStyled` and for round-tripping. `NSAttributedString`
    /// enumeration readily produces adjacent runs with identical attributes
    /// (typing attributes change and change back, an undo coalesces), and an
    /// empty run can carry a style nothing displays — which would report a
    /// message as styled when the user can see no styling in it, and quietly
    /// turn it into MIME.
    private mutating func normalize() {
        var merged: [RichTextRun] = []
        for run in runs where !run.text.isEmpty {
            if var last = merged.last, last.style == run.style {
                last.text += run.text
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }
        runs = merged
    }
}

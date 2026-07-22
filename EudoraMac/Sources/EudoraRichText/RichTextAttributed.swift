import AppKit
import EudoraStore

/// The composer's default face and size: what a run with no override renders as,
/// and the baseline every attributed run is measured against when read back.
///
/// This is the pivot the whole "did the user format anything?" question turns
/// on. `RichText` records a run's style *relative* to this default (see the note
/// on `RichTextStyle`), and the two conversions here are what make that
/// relativity real: text typed in the default face at the default size, in the
/// default colour, must read back as `RichTextStyle.plain` — so the message
/// assembles to today's `text/plain` bytes rather than becoming MIME.
public struct RichTextDefaults: Equatable, Sendable {
    public var family: String
    public var size: Double

    public init(family: String, size: Double) {
        self.family = family
        self.size = size
    }

    /// Arial 12 — the seed until Stephen settles on a face. See `EudoraFont` for
    /// why the Windows-vs-Mac apparent size differs, and `design-decisions.md`.
    public static let arial12 = RichTextDefaults(family: "Arial", size: 12)
}

/// `RichText` ⇄ `NSAttributedString`, for the composer's `NSTextView`.
///
/// **AppKit lives here, not in `EudoraStore`.** The store target is deliberately
/// AppKit-free so the CLI and the search index don't drag in a UI framework;
/// this is the one place the styled-text model meets `NSFont`/`NSColor`, and it
/// is its own target so `swift test` can reach it without the app.
public enum RichTextAttributed {

    // MARK: - RichText → NSAttributedString

    /// Build the editable attributed string. Every character carries a resolved
    /// font (and a colour, when the run set one), because that is what an
    /// `NSTextView` edits — the relativity is reconstructed on the way back, not
    /// stored here.
    public static func attributed(_ rich: RichText, defaults: RichTextDefaults) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in rich.runs {
            out.append(NSAttributedString(string: run.text,
                                          attributes: attributes(for: run.style, defaults: defaults)))
        }
        return out
    }

    /// The attributes one run contributes: a font always, a foreground colour
    /// only when the run chose one.
    public static func attributes(for style: RichTextStyle,
                                  defaults: RichTextDefaults) -> [NSAttributedString.Key: Any] {
        let family = style.face ?? defaults.family
        let size = CGFloat(style.size ?? defaults.size)
        let (font, synthesizedItalic) = font(family: family, size: size,
                                             bold: style.bold, italic: style.italic)
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        // Synthetic slant for a face with no real italic — era-correct, and the
        // read-back path treats obliqueness as italic so it round-trips.
        if synthesizedItalic { attrs[.obliqueness] = 0.2 }
        if let color = style.color { attrs[.foregroundColor] = nsColor(color) }
        return attrs
    }

    /// Resolve a font, reporting whether italic had to be faked.
    ///
    /// `withSymbolicTraits` returns a descriptor even when the concrete variant
    /// is missing, and `NSFont(descriptor:size:)` then yields the upright face —
    /// so a plain check "did I get italic?" is needed rather than trusting the
    /// descriptor. When the real italic isn't there the caller adds obliqueness.
    static func font(family: String, size: CGFloat,
                     bold: Bool, italic: Bool) -> (font: NSFont, synthesizedItalic: Bool) {
        let base = NSFont(name: family, size: size)
            ?? NSFont(name: "Arial", size: size)
            ?? NSFont.systemFont(ofSize: size)

        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if traits.isEmpty { return (base, false) }

        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        let resolved = NSFont(descriptor: descriptor, size: size) ?? base
        let gotItalic = resolved.fontDescriptor.symbolicTraits.contains(.italic)
        return (resolved, italic && !gotItalic)
    }

    // MARK: - NSAttributedString → RichText

    /// Read the editor's content back as a relative `RichText`.
    ///
    /// Each attribute run becomes one `RichTextRun` whose style records only
    /// what differs from `defaults`: the default family → `face == nil`, the
    /// default size → `size == nil`, the default (black/`textColor`) foreground
    /// → `color == nil`. Bold and italic are absolute, because the composer's
    /// default is neither. `RichText.init` then merges and trims, so adjacent
    /// runs that came back identical collapse.
    public static func richText(_ attributed: NSAttributedString,
                                defaults: RichTextDefaults) -> RichText {
        let full = NSRange(location: 0, length: attributed.length)
        var runs: [RichTextRun] = []

        attributed.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            guard !text.isEmpty else { return }
            runs.append(RichTextRun(text, style: style(from: attrs, defaults: defaults)))
        }
        return RichText(runs: runs)
    }

    /// One attribute run's style, expressed relative to `defaults`.
    static func style(from attrs: [NSAttributedString.Key: Any],
                      defaults: RichTextDefaults) -> RichTextStyle {
        let font = (attrs[.font] as? NSFont) ?? NSFont(name: defaults.family,
                                                       size: CGFloat(defaults.size))
            ?? NSFont.systemFont(ofSize: CGFloat(defaults.size))
        let traits = font.fontDescriptor.symbolicTraits

        var style = RichTextStyle()
        style.bold = traits.contains(.bold)
        // Real italic, or the synthetic slant `attributes(for:)` applies to a
        // face that has none.
        let obliqueness = (attrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0
        style.italic = traits.contains(.italic) || obliqueness > 0

        // `familyName` is the base family ("Arial") even for the bold or italic
        // member, so comparing it to the default is trait-independent.
        if let family = font.familyName, !family.equalsIgnoringCase(defaults.family) {
            style.face = family
        }
        if abs(Double(font.pointSize) - defaults.size) > 0.01 {
            style.size = Double(font.pointSize)
        }
        if let color = attrs[.foregroundColor] as? NSColor,
           let resolved = richColorIfNotDefault(color) {
            style.color = resolved
        }
        return style
    }

    // MARK: - colour

    public static func nsColor(_ c: RichTextColor) -> NSColor {
        NSColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: 1)
    }

    /// A `RichTextColor` for a genuinely chosen colour, or nil for the default
    /// text colour.
    ///
    /// The composer's baseline is black text (`NSColor.textColor` in light
    /// appearance), and a run left at that must read back as `color == nil` or
    /// every plain paragraph would look styled and be sent as MIME. So a colour
    /// that resolves to black maps to nil: picking black is, in this composer,
    /// the same as not picking one, and renders identically either way.
    static func richColorIfNotDefault(_ color: NSColor) -> RichTextColor? {
        // Into a concrete RGB space first — `textColor` and friends are catalog
        // colours with no direct components until converted, and the conversion
        // can fail (pattern colours), in which case treat it as the default.
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let c = RichTextColor(red: Double(rgb.redComponent),
                              green: Double(rgb.greenComponent),
                              blue: Double(rgb.blueComponent))
        return c.isBlack ? nil : c
    }
}

private extension String {
    func equalsIgnoringCase(_ other: String) -> Bool {
        caseInsensitiveCompare(other) == .orderedSame
    }
}

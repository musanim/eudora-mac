import AppKit
import EudoraStore
// For `objc_getAssociatedObject` / `objc_setAssociatedObject`, which memoise the
// image derived from an attachment AppKit built.
import ObjectiveC

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

/// An embedded image inside the editor's attributed string.
///
/// A subclass rather than a plain `NSTextAttachment` so the image's identity
/// travels with it. Reading the editor back is not a rare event — it happens on
/// every keystroke, through `readBack` — and recomputing a content hash from the
/// bytes each time would put a SHA-256 of a multi-megabyte screenshot on the
/// typing path. Carrying the already-hashed `RichTextImage` makes the read a
/// pointer copy.
///
/// It also keeps the round trip exact. If the identity were re-derived, a
/// re-derivation that differed in any way would make `ComposeView.isDirty` true
/// forever and the composer would prompt to save a draft nobody had edited.
public final class RichTextImageAttachment: NSTextAttachment {
    /// Not named `image`: `NSTextAttachment` already has an `image` of its own,
    /// which is the `NSImage` it draws.
    public let source: RichTextImage

    public init(_ source: RichTextImage) {
        self.source = source
        // `ofType` wants a UTI, not a MIME type. It doesn't affect drawing —
        // `image` below settles that — but it is what gets written into any
        // RTFD this attachment is archived into, which is how an internal
        // copy-paste travels.
        super.init(data: source.data, ofType: Self.uti(forMIMEType: source.mimeType))
        // What the text view actually draws. `contents`/`fileType` alone are a
        // TextKit 2 route; the composer is a TextKit 1 `NSTextView`, which wants
        // this. A payload AppKit can't decode leaves the cell empty rather than
        // throwing, which is the right failure for a paste of something odd.
        self.image = NSImage(data: source.data)
    }

    /// Unarchiving produces a plain `NSTextAttachment`, not this. That is not a
    /// gap: `RichTextAttributed.richText` recovers an image from any attachment
    /// carrying bytes, re-hashing to recover the identity, so a selection copied
    /// and pasted within the draft — which round-trips through RTFD on the
    /// pasteboard and loses the subclass — still keeps its picture.
    required init?(coder: NSCoder) { return nil }

    /// The UTI for an image MIME type, for `NSTextAttachment`'s `ofType`.
    /// Unknown types fall back to `public.data`, which is honest rather than
    /// wrong — the bytes are still there and `source` still has the real type.
    static func uti(forMIMEType mime: String) -> String {
        switch mime.lowercased() {
        case "image/png":  return "public.png"
        case "image/jpeg": return "public.jpeg"
        case "image/gif":  return "com.compuserve.gif"
        case "image/tiff": return "public.tiff"
        case "image/heic": return "public.heic"
        case "image/webp": return "org.webmproject.webp"
        default:           return "public.data"
        }
    }
}

/// Associated-object storage for `embeddedImage(of:)`'s memo. A class box
/// because an associated object must be an object, and the value is optional —
/// "we looked and there was no image" is worth caching too.
private final class RichTextImageBox {
    let image: RichTextImage?
    init(_ image: RichTextImage?) { self.image = image }
}

/// Plain `var`, not `nonisolated(unsafe)`: that spelling is Swift 5.10 and this
/// target is 5.7. Only its address is ever used, and only from the main thread.
private var derivedImageKey: UInt8 = 0

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
            if let image = run.image {
                out.append(NSAttributedString(attachment: RichTextImageAttachment(image)))
            } else {
                out.append(NSAttributedString(string: run.text,
                                              attributes: attributes(for: run.style,
                                                                     defaults: defaults)))
            }
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
            // An attachment run is one object-replacement character carrying an
            // `.attachment`; it has no text to style, so it is taken whole and
            // the style pass is skipped.
            if let attachment = attrs[.attachment] as? NSTextAttachment,
               let image = embeddedImage(of: attachment) {
                runs.append(RichTextRun(image: image))
                return
            }
            runs.append(RichTextRun(text, style: style(from: attrs, defaults: defaults)))
        }
        return RichText(runs: runs)
    }

    /// The image an attachment carries, however it got there.
    ///
    /// The fast path is our own subclass, which already holds a hashed
    /// `RichTextImage`. The slow path re-derives one from the bytes, and exists
    /// for attachments AppKit made rather than us: an internal copy-paste goes
    /// through RTFD on the pasteboard and comes back as a plain
    /// `NSTextAttachment`. The content hash means the recovered image is *the
    /// same image*, so it merges with the original rather than travelling twice.
    ///
    /// **The slow path is memoised, and has to be.** A plain attachment doesn't
    /// go away after the paste — it stays in the text storage, and `readBack`
    /// converts the whole storage on every keystroke. Without the cache, every
    /// character typed after an internal image paste would re-run SHA-256 over a
    /// multi-megabyte screenshot and materialise its bytes again. The cache is
    /// keyed on the attachment object and held by it, so it dies with it.
    ///
    /// Returns nil for an attachment with no usable bytes, which drops it. A
    /// file attached by paperclip is not represented here at all; those live on
    /// `ComposeDraft.attachments` and never enter the text storage.
    static func embeddedImage(of attachment: NSTextAttachment) -> RichTextImage? {
        if let ours = attachment as? RichTextImageAttachment { return ours.source }
        if let cached = objc_getAssociatedObject(attachment, &derivedImageKey)
            as? RichTextImageBox { return cached.image }

        let derived = deriveImage(of: attachment)
        objc_setAssociatedObject(attachment, &derivedImageKey,
                                 RichTextImageBox(derived), .OBJC_ASSOCIATION_RETAIN)
        return derived
    }

    /// The uncached derivation. Split out so the memo above reads as one thing.
    private static func deriveImage(of attachment: NSTextAttachment) -> RichTextImage? {
        let wrapper = attachment.fileWrapper
        guard let data = attachment.contents ?? wrapper?.regularFileContents,
              !data.isEmpty
        else { return nil }

        // Prefer a declared type; fall back to sniffing the first bytes, since a
        // pasteboard-built attachment often names only a filename extension.
        let type = attachment.fileType.flatMap(mimeType(forUTIOrExtension:))
            ?? wrapper?.preferredFilename.flatMap { name in
                name.split(separator: ".").last.map { mimeType(forUTIOrExtension: String($0)) } ?? nil
            }
            ?? sniffedImageType(data)
        guard let type else { return nil }
        return RichTextImage(mimeType: type, data: data)
    }

    /// A UTI or a bare filename extension as an image MIME type, or nil when it
    /// isn't an image this should embed.
    public static func mimeType(forUTIOrExtension raw: String) -> String? {
        let s = raw.lowercased()
        switch s {
        case "public.png", "png":                     return "image/png"
        case "public.jpeg", "jpeg", "jpg":            return "image/jpeg"
        case "com.compuserve.gif", "gif":             return "image/gif"
        case "public.tiff", "tiff", "tif":            return "image/tiff"
        case "org.webmproject.webp", "webp":          return "image/webp"
        case "public.heic", "heic":                   return "image/heic"
        default:
            return s.hasPrefix("image/") ? s : nil
        }
    }

    /// The image type of a byte stream, from its magic number.
    ///
    /// Only the formats a Mac clipboard actually produces. Anything else returns
    /// nil and the attachment is dropped rather than sent with a type that would
    /// make a reader show a broken image.
    public static func sniffedImageType(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b.count >= 4, (b[0] == 0x49 && b[1] == 0x49) || (b[0] == 0x4D && b[1] == 0x4D) {
            return "image/tiff"
        }
        return nil
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

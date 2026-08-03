import Foundation

/// Windows code page 1252 — the encoding Eudora 7 actually used for the text
/// fields of its binary side-files.
///
/// This matters because Latin-1 and CP1252 agree everywhere *except* 0x80–0x9F,
/// which Latin-1 reserves for unused control codes and CP1252 fills with the
/// typographic characters mail is full of: curly quotes, en and em dashes, the
/// ellipsis, the bullet, the trademark sign, the euro. Reading a genuine Eudora
/// `.toc` as Latin-1 therefore turns `™` into an invisible control character —
/// and writing one as Latin-1 turns `’` into `?`, which is how this was found.
///
/// The mapping is spelled out rather than delegated to `String.Encoding
/// .windowsCP1252` for two reasons: five byte values (0x81, 0x8D, 0x8F, 0x90,
/// 0x9D) are undefined in CP1252 and appear in real legacy files — 130 times in
/// Stephen's tree — where Foundation's decoder may reject the whole string and
/// lose an entire subject line; and the encoder needs a fallback ladder
/// Foundation doesn't offer.
///
/// `Charset.swift` already prefers CP1252 over Latin-1 when decoding message
/// bodies. This puts the side-files on the same footing.
public enum CP1252 {

    /// What bytes 0x80...0x9F mean. `nil` marks the five undefined positions.
    static let c1: [UInt32?] = [
        0x20AC, nil,    0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,  // 80-87
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, nil,    0x017D, nil,     // 88-8F
        nil,    0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,  // 90-97
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, nil,    0x017E, 0x0178,  // 98-9F
    ]

    /// The reverse of `c1`, for encoding.
    static let c1Reverse: [UInt32: UInt8] = {
        var map: [UInt32: UInt8] = [:]
        for (i, scalar) in c1.enumerated() {
            if let scalar { map[scalar] = UInt8(0x80 + i) }
        }
        return map
    }()

    /// Decode a byte string. Undefined bytes are dropped rather than turned into
    /// replacement characters: they are corruption in files this old, and a
    /// subject reading `Amazon  Your order` is better than one reading
    /// `Amazon <?> Your order`, which invites the reader to wonder what it hid.
    public static func decode(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte < 0x80 || byte >= 0xA0 {
                scalars.append(Unicode.Scalar(byte))        // ASCII, and Latin-1 above 0x9F
            } else if let mapped = c1[Int(byte) - 0x80],
                      let scalar = Unicode.Scalar(mapped) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Encode, degrading gracefully rather than reaching for `?` at the first
    /// difficulty. The ladder, per scalar:
    ///
    /// 1. Representable in CP1252 — the byte, exactly.
    /// 2. A known typographic near-equivalent (`′` → `'`, `−` → `-`).
    /// 3. An accented letter outside CP1252 — its unaccented base (`ā` → `a`),
    ///    by canonical decomposition.
    /// 4. `?`.
    ///
    /// Step 3 deliberately does *not* transliterate between scripts, which is
    /// what `Any-Latin` would do. Turning a Cyrillic `а` into a Latin `a` would
    /// erase exactly the distinction `LinkSafety.isMixedScript` exists to
    /// preserve, and a homograph should look wrong here, not plausible.
    public static func encode(_ s: String) -> [UInt8] {
        // Precomposed first. macOS-originated mail routinely arrives decomposed,
        // and walking raw scalars would meet a bare combining acute with no byte
        // to give it — turning `café` into `cafe?`, which is the very failure
        // this file exists to stop.
        let normalised = s.precomposedStringWithCanonicalMapping
        var out: [UInt8] = []
        out.reserveCapacity(normalised.unicodeScalars.count)
        for scalar in normalised.unicodeScalars {
            if let byte = byteFor(scalar) {
                out.append(byte)
            } else if let substitute = substitutions[scalar.value] {
                out.append(contentsOf: substitute.unicodeScalars.map { UInt8($0.value) })
            } else if let folded = foldToBase(scalar) {
                out.append(contentsOf: folded)
            } else if !isDiscardable(scalar),
                      !CharacterSet.nonBaseCharacters.contains(scalar) {
                // A combining mark that survived precomposition has no base to
                // attach to; it drops rather than becoming a stray '?'.
                out.append(0x3F)
            }
        }
        return out
    }

    static func byteFor(_ scalar: Unicode.Scalar) -> UInt8? {
        // A C1 control in the *input* is mojibake rather than text, so it gets
        // no byte of its own here and falls through the ladder to '?'.
        if scalar.value < 0x80 || (scalar.value >= 0xA0 && scalar.value <= 0xFF) {
            return UInt8(scalar.value)
        }
        return c1Reverse[scalar.value]
    }

    /// Characters with no CP1252 spelling but an obvious plain-text stand-in.
    /// All replacements are ASCII, so their scalars are their bytes.
    static let substitutions: [UInt32: String] = [
        0x2010: "-", 0x2011: "-", 0x2012: "-", 0x2015: "-", 0x2212: "-",  // hyphens, minus
        0x2032: "'", 0x2035: "'",                                          // primes
        0x2033: "\"", 0x2036: "\"",
        0x2044: "/",                                                       // fraction slash
        0x2028: " ", 0x2029: " ",                                          // line/paragraph separators
        0x2192: "->", 0x2190: "<-",
    ]
    // Nothing below U+0100 belongs here: guillemets, the non-breaking space and
    // the accented letters are all CP1252 already, and `byteFor` takes them.

    /// Zero-width and byte-order marks: carry no meaning in a one-line summary,
    /// and a `?` in their place would be noise.
    static func isDiscardable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0xFEFF, 0x061C, 0x2060...0x2064: return true
        default: return false
        }
    }

    /// `ā` → `a`: decompose and keep the base characters, provided every one of
    /// them lands in CP1252. Returns nil when it doesn't, so the caller can fall
    /// through to `?`.
    static func foldToBase(_ scalar: Unicode.Scalar) -> [UInt8]? {
        let decomposed = String(scalar).decomposedStringWithCanonicalMapping
        guard decomposed.unicodeScalars.count > 1 else { return nil }
        var bytes: [UInt8] = []
        for piece in decomposed.unicodeScalars {
            if CharacterSet.nonBaseCharacters.contains(piece) { continue }   // drop the accent
            guard let byte = byteFor(piece) else { return nil }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : bytes
    }
}

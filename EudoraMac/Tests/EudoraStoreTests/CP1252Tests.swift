import XCTest
@testable import EudoraStore

/// The encoding of Eudora's binary side-files. Latin-1 and CP1252 agree on
/// everything except 0x80–0x9F, and that range is precisely where mail's
/// typography lives — which is why reading it wrong is invisible until a
/// subject line loses its apostrophe.
final class CP1252Tests: XCTestCase {

    // MARK: decoding what Eudora 7 wrote

    /// Bytes taken from Stephen's own `Amazon.toc`: 0x99 is the trademark sign
    /// in CP1252 and an unused control code in Latin-1.
    func testTheC1RangeDecodesAsTypography() {
        XCTAssertEqual(CP1252.decode([0x99]), "™")
        XCTAssertEqual(CP1252.decode([0x92]), "\u{2019}")   // right single quote
        XCTAssertEqual(CP1252.decode([0x96]), "–")          // en dash
        XCTAssertEqual(CP1252.decode([0x97]), "—")          // em dash
        XCTAssertEqual(CP1252.decode([0x85]), "…")
        XCTAssertEqual(CP1252.decode([0x80]), "€")
    }

    func testARealLegacySubject() {
        let bytes: [UInt8] = Array("Your Amazon.com order of \"U32 Shadow".utf8)
            + [0x99] + Array(" 1TB External\".".utf8)
        XCTAssertEqual(CP1252.decode(bytes),
                       "Your Amazon.com order of \"U32 Shadow™ 1TB External\".")
    }

    func testASCIIAndHighLatin1AreUnchanged() {
        XCTAssertEqual(CP1252.decode(Array("Re: plain".utf8)), "Re: plain")
        XCTAssertEqual(CP1252.decode([0xE9, 0xF1, 0xFF]), "éñÿ")
    }

    /// 0x81, 0x8D, 0x8F, 0x90 and 0x9D have no CP1252 meaning and do occur in
    /// the real tree. Dropping them must not cost the rest of the field.
    func testUndefinedBytesAreDroppedNotFatal() {
        XCTAssertEqual(CP1252.decode(Array("Notification".utf8) + [0x81] + Array(" from".utf8)),
                       "Notification from")
        XCTAssertEqual(CP1252.decode([0x8D, 0x8F, 0x90, 0x9D]), "")
    }

    // MARK: encoding

    func testTheApostropheThatStartedThis() {
        XCTAssertEqual(CP1252.encode("You\u{2019}ve received"),
                       Array("You".utf8) + [0x92] + Array("ve received".utf8))
    }

    func testRoundTrip() {
        for original in ["You\u{2019}ve got mail",
                         "Rite of Spring — licensing…",
                         "café, naïve, £5, €7, 100% ok",
                         "quote \u{201C}this\u{201D} and •bullet•"] {
            XCTAssertEqual(CP1252.decode(CP1252.encode(original)), original, original)
        }
    }

    /// Not everything has a CP1252 spelling. What matters is that the ladder
    /// degrades in steps rather than jumping to `?`.
    func testNearEquivalentsBeforeQuestionMark() {
        XCTAssertEqual(CP1252.decode(CP1252.encode("3\u{2032}5\u{2033}")), "3'5\"")
        XCTAssertEqual(CP1252.decode(CP1252.encode("a\u{2212}b")), "a-b")
    }

    /// Mail from a Mac often arrives decomposed: `e` followed by a combining
    /// acute. Encoding scalar by scalar would find no byte for the mark and
    /// write `cafe?`.
    func testDecomposedInputIsPrecomposedFirst() {
        let nfd = "cafe\u{0301}, nai\u{0308}ve"
        XCTAssertEqual(CP1252.encode(nfd), CP1252.encode("café, naïve"))
        XCTAssertEqual(CP1252.decode(CP1252.encode(nfd)), "café, naïve")
    }

    /// A combining mark with nothing to combine with survives precomposition.
    /// It should vanish rather than leave a `?` where no character was.
    func testAnOrphanedCombiningMarkIsDropped() {
        // The first mark precomposes onto the `a`; the second has no partner.
        XCTAssertEqual(CP1252.encode("a\u{0301}\u{0301}b"), [0xE1] + Array("b".utf8))
    }

    func testAccentsOutsideCP1252FoldToTheirBase() {
        XCTAssertEqual(CP1252.decode(CP1252.encode("Dvo\u{0159}\u{00E1}k")), "Dvor\u{00E1}k")
        XCTAssertEqual(CP1252.decode(CP1252.encode("\u{0101}")), "a")
    }

    /// Deliberate: `Any-Latin` transliteration would turn a Cyrillic а into a
    /// Latin a, quietly making a homograph look ordinary. A `?` is the honest
    /// answer.
    func testOtherScriptsAreNotTransliterated() {
        XCTAssertEqual(CP1252.encode("\u{0430}pple"), Array("?pple".utf8))
        XCTAssertEqual(CP1252.encode("東京"), Array("??".utf8))
    }

    func testZeroWidthCharactersVanishWithoutATrace() {
        XCTAssertEqual(CP1252.decode(CP1252.encode("a\u{200B}b\u{FEFF}c")), "abc")
    }

    // MARK: the field writer

    /// `putString` leaves the tail alone and relies on its caller's buffer being
    /// zeroed, which `entryBytes` guarantees — so the termination tests use a
    /// zeroed buffer, as production does.
    func testTocFieldIsCP1252AndNULTerminated() {
        var b = [UInt8](repeating: 0, count: 20)
        TocWriter.putString(&b, at: 0, len: 10, "You\u{2019}ve")
        XCTAssertEqual(Array(b[0..<6]), Array("You".utf8) + [0x92] + Array("ve".utf8))
        XCTAssertEqual(b[6], 0, "the field must be NUL-terminated")
    }

    func testOverlongFieldsTruncateAndStillTerminate() {
        var b = [UInt8](repeating: 0, count: 20)
        TocWriter.putString(&b, at: 0, len: 5, "abcdefghij")
        XCTAssertEqual(Array(b[0..<4]), Array("abcd".utf8))
        XCTAssertEqual(b[4], 0)
    }

    /// A separate buffer, poisoned, to catch a write past the field — the one
    /// failure that would corrupt the neighbouring column rather than this one.
    func testNothingIsWrittenBeyondTheField() {
        var b = [UInt8](repeating: 0xAA, count: 20)
        TocWriter.putString(&b, at: 4, len: 6, "a string far too long for six bytes")
        XCTAssertEqual(Array(b[0..<4]), [0xAA, 0xAA, 0xAA, 0xAA], "wrote before the field")
        // The field is b[4..<10]; b[9] is its last byte, reserved for the NUL and
        // never written, so an untouched 0xAA there is the contract holding.
        XCTAssertEqual(b[9], 0xAA, "wrote into the terminator byte")
        XCTAssertEqual(Array(b[10..<20]), [UInt8](repeating: 0xAA, count: 10),
                       "wrote past the field")
    }

    /// A subject whose 64th byte falls inside a multi-scalar substitution must
    /// still stop cleanly — CP1252 is single-byte, so truncation can never split
    /// a character, but `…` → `...` means the byte count is not the scalar count.
    func testTruncationCountsBytesNotCharacters() {
        var b = [UInt8](repeating: 0, count: 20)
        TocWriter.putString(&b, at: 0, len: 5, "ab\u{2032}\u{2032}\u{2032}\u{2032}")
        XCTAssertEqual(Array(b[0..<4]), Array("ab''".utf8))
        XCTAssertEqual(b[4], 0)
    }
}

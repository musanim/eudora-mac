import XCTest
@testable import EudoraStore

/// `Bytes.find` is the parser's innermost primitive — the record scan and every
/// MIME boundary and `<x-html>` marker go through it — so an off-by-one here
/// corrupts parsing wholesale. The `memchr`/pointer rewrite for speed has to
/// behave *exactly* like the naive loop it replaced; these pin that, and a
/// randomised sweep cross-checks it against a reference implementation.
final class BytesTests: XCTestCase {

    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testBasics() {
        XCTAssertEqual(Bytes.find(b("lo"), in: b("hello")), 3)
        XCTAssertEqual(Bytes.find(b("h"), in: b("hello")), 0)
        XCTAssertEqual(Bytes.find(b("o"), in: b("hello")), 4)          // last byte
        XCTAssertEqual(Bytes.find(b("hello"), in: b("hello")), 0)      // whole string
        XCTAssertNil(Bytes.find(b("z"), in: b("hello")))
        XCTAssertNil(Bytes.find(b("hello!"), in: b("hello")))          // needle longer
    }

    func testEmptyAndEdges() {
        XCTAssertNil(Bytes.find([], in: b("hello")))                   // empty needle
        XCTAssertNil(Bytes.find(b("x"), in: []))                       // empty hay
        XCTAssertNil(Bytes.find([], in: []))
    }

    func testFromOffset() {
        let hay = b("abcabc")
        XCTAssertEqual(Bytes.find(b("abc"), in: hay), 0)
        XCTAssertEqual(Bytes.find(b("abc"), in: hay, from: 1), 3)
        XCTAssertEqual(Bytes.find(b("abc"), in: hay, from: 3), 3)
        XCTAssertNil(Bytes.find(b("abc"), in: hay, from: 4))
        XCTAssertEqual(Bytes.find(b("a"), in: hay, from: -5), 0)       // negative clamps to 0
    }

    func testFirstByteRepeats() {
        // Where the first byte recurs before the full match — exercises the
        // memchr-skip-then-verify path, restarting after a partial hit.
        XCTAssertEqual(Bytes.find(b("aab"), in: b("aaab")), 1)
        XCTAssertEqual(Bytes.find(b("aaa"), in: b("aaaa")), 0)
        XCTAssertNil(Bytes.find(b("aab"), in: b("aaaa")))
    }

    func testFindAll() {
        XCTAssertEqual(Bytes.findAll(b("aa"), in: b("aaaa")), [0, 1, 2])   // +1 stepping
        XCTAssertEqual(Bytes.findAll(b("x"), in: b("axbxc")), [1, 3])
        XCTAssertEqual(Bytes.findAll(b("z"), in: b("abc")), [])
    }

    /// The CRLF-CRLF header/body split and the `From ` separator are the real
    /// needles the parser looks for; make sure they land where expected.
    func testRealisticNeedles() {
        let msg = b("From ???@??? x\r\nSubject: hi\r\n\r\nbody")
        XCTAssertEqual(Bytes.find([0x0d, 0x0a, 0x0d, 0x0a], in: msg),
                       ("From ???@??? x\r\nSubject: hi").utf8.count)
        XCTAssertEqual(Bytes.find(b("From ???@??? "), in: msg), 0)
    }

    /// Cross-check the fast path against a naive reference over a small alphabet
    /// (so matches are dense), across lengths and offsets.
    func testMatchesNaiveReference() {
        func naive(_ needle: [UInt8], _ hay: [UInt8], _ from: Int) -> Int? {
            let n = needle.count, h = hay.count
            if n == 0 || h < n { return nil }
            var i = max(0, from)
            let last = h - n
            while i <= last {
                var j = 0
                while j < n && hay[i + j] == needle[j] { j += 1 }
                if j == n { return i }
                i += 1
            }
            return nil
        }

        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let hay = (0..<Int.random(in: 0...14, using: &rng))
                .map { _ in UInt8.random(in: 0...3, using: &rng) }
            let needle = (0..<Int.random(in: 0...4, using: &rng))
                .map { _ in UInt8.random(in: 0...3, using: &rng) }
            let from = Int.random(in: -2...(hay.count + 2), using: &rng)
            XCTAssertEqual(Bytes.find(needle, in: hay, from: from),
                           naive(needle, hay, from),
                           "needle \(needle) hay \(hay) from \(from)")
        }
    }
}

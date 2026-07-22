import Foundation
import Network

public enum POP3Error: LocalizedError {
    case badPort
    case connectionFailed(String)
    case serverError(String, during: String)
    case closed(String)

    public var errorDescription: String? {
        switch self {
        case .badPort: return "Invalid POP3 port."
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .serverError(let m, let during): return "Server error during \(during): \(m)"
        case .closed(let during): return "Connection closed during \(during)."
        }
    }
}

public struct FetchedMessage: Sendable {
    public let uid: String
    public let raw: Data
}

/// A small hand-rolled POP3 client over Network.framework, implicit TLS only
/// (port 995). Fetches new messages (by UIDL, skipping ones already seen) and,
/// separately, deletes messages the caller has confirmed are stored locally.
///
/// `@unchecked Sendable`: `buffer` is only touched inside the sequential
/// `await` chain, never concurrently.
public final class POP3Client: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "pop3")
    private var buffer = Data()

    public init(account: POP3Account) throws {
        guard let p16 = UInt16(exactly: account.port),
              let port = NWEndpoint.Port(rawValue: p16) else { throw POP3Error.badPort }
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        connection = NWConnection(host: NWEndpoint.Host(account.host), port: port, using: params)
    }

    /// Diagnostic for the "message is on the server but nothing downloads" case.
    /// When on, `fetchNew` prints the full UIDL list the server returns and, for
    /// each entry, whether it is being fetched or skipped as already-known — which
    /// separates "the server isn't offering it" from "our known-set is eating it"
    /// without any more guessing.
    ///
    /// Off, but intact — the way this codebase keeps its diagnostics. It earned
    /// its keep once: the `UIDL body … (hex)` dump is what revealed the listing
    /// was CRLF-delimited, overturning a wrong line-ending theory and pointing at
    /// the grapheme-split bug in `parseUIDL`. Flip to `true` to see the UIDL
    /// exchange again.
    public static var diagnose = false

    // MARK: high-level operations

    /// Download messages whose UIDL is not in `knownUIDs`. Does NOT delete.
    public static func fetchNew(account: POP3Account, password: String,
                                knownUIDs: Set<String>) async throws -> [FetchedMessage] {
        let c = try POP3Client(account: account)
        try await c.start()
        defer { c.connection.cancel() }

        _ = try await c.readStatus(during: "greeting")
        try await c.login(account.username, password)

        let uidls = try await c.uidl()          // [(num, uid)]

        if Self.diagnose {
            print("POP3 diag [BUILD MARKER: line-ending-fix-v2]")
            print("POP3 diag: user=\(account.username) host=\(account.host):\(account.port)")
            print("POP3 diag: server listed \(uidls.count) message(s); knownUIDs holds \(knownUIDs.count)")
            for entry in uidls {
                let state = knownUIDs.contains(entry.uid) ? "SKIP (already known)" : "FETCH (new)"
                print("POP3 diag:   #\(entry.num)  uid=\(entry.uid)  \(state)")
            }
            let newCount = uidls.filter { !knownUIDs.contains($0.uid) }.count
            print("POP3 diag: \(newCount) new message(s) will be fetched")
        }

        var out: [FetchedMessage] = []
        for entry in uidls where !knownUIDs.contains(entry.uid) {
            try await c.sendLine("RETR \(entry.num)")
            _ = try await c.readStatus(during: "RETR")
            let raw = try await c.readMultiline()
            out.append(FetchedMessage(uid: entry.uid, raw: raw))
        }
        try await c.sendLine("QUIT")
        _ = try? await c.readStatus(during: "QUIT")
        return out
    }

    /// Delete the messages with these UIDLs from the server (a second pass, run
    /// only after local persistence succeeded). Deletions commit on QUIT.
    public static func delete(account: POP3Account, password: String,
                              uids: Set<String>) async throws {
        guard !uids.isEmpty else { return }
        let c = try POP3Client(account: account)
        try await c.start()
        defer { c.connection.cancel() }

        _ = try await c.readStatus(during: "greeting")
        try await c.login(account.username, password)

        for entry in try await c.uidl() where uids.contains(entry.uid) {
            try await c.sendLine("DELE \(entry.num)")
            _ = try await c.readStatus(during: "DELE")
        }
        try await c.sendLine("QUIT")
        _ = try? await c.readStatus(during: "QUIT")
    }

    // MARK: protocol steps

    private func login(_ user: String, _ password: String) async throws {
        try await sendLine("USER \(user)")
        _ = try await readStatus(during: "USER")
        try await sendLine("PASS \(password)")
        _ = try await readStatus(during: "PASS")
    }

    /// UIDL listing → [(num, uid)]. Numbers are per-session message indices.
    private func uidl() async throws -> [(num: Int, uid: String)] {
        try await sendLine("UIDL")
        _ = try await readStatus(during: "UIDL")
        let body = try await readMultiline()
        if Self.diagnose {
            // Show the actual bytes separating entries. If extractLine failed to
            // split the list, the original separator survives in `body`; the hex
            // reveals what it really is (we've assumed CR/LF and been wrong).
            let head = Array(body.prefix(96))
            let hex = head.map { String(format: "%02x", $0) }.joined(separator: " ")
            print("POP3 diag: UIDL body, first \(head.count) bytes (hex):")
            print("POP3 diag: \(hex)")
        }
        return Self.parseUIDL(body)
    }

    /// Parse a UIDL body — `num uid` per line — into pairs.
    ///
    /// **Splits on the LF *byte*, not on a `Character`.** The whole "message
    /// list collapses into one entry" bug lived here: the body is CRLF-delimited,
    /// and `String(decoding:).split { $0 == "\n" }` never matched, because a
    /// Swift `String` is a sequence of grapheme clusters and `"\r\n"` is a
    /// *single* `Character` equal to neither `"\n"` nor `"\r"`. So every line ran
    /// together and the 21-message listing parsed as one message with a nonsense
    /// concatenated UID — nothing ever downloaded. Working in bytes sidesteps
    /// grapheme clustering entirely. Static and `internal` so it can be tested
    /// directly on a `Data` — a test that would have caught this.
    static func parseUIDL(_ body: Data) -> [(num: Int, uid: String)] {
        var pairs: [(num: Int, uid: String)] = []
        for var lineBytes in body.split(separator: 0x0A) {   // LF
            if lineBytes.last == 0x0D { lineBytes = lineBytes.dropLast() }   // strip CR of CRLF
            let line = String(decoding: lineBytes, as: UTF8.self)
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, let n = Int(parts[0]) {
                pairs.append((n, String(parts[1])))
            }
        }
        return pairs
    }

    // MARK: line / response IO

    private func sendLine(_ line: String) async throws {
        try await write(Data((line + "\r\n").utf8))
    }

    /// Read a single-line status response and require it to be `+OK`.
    @discardableResult
    private func readStatus(during: String) async throws -> String {
        let line = try await readLine()
        let s = String(decoding: line, as: UTF8.self)
        if s.hasPrefix("+OK") { return s }
        throw POP3Error.serverError(s, during: during)
    }

    /// Read a dot-terminated multiline body (after its `+OK` status line),
    /// byte-safe and dot-unstuffed, with CRLF line endings preserved.
    private func readMultiline() async throws -> Data {
        var out = Data()
        while true {
            let line = try await readLine()
            if line.count == 1, line.first == 0x2E { break }   // "." terminator
            var l = line
            if l.first == 0x2E { l = l.dropFirst() }           // ".." → "."
            out.append(l)
            out.append(contentsOf: [0x0D, 0x0A])
        }
        return out
    }

    /// One line, its terminator stripped, buffering across reads.
    private func readLine() async throws -> Data {
        while true {
            if let line = extractLine() { return line }
            let chunk = try await receive()
            if chunk.isEmpty { throw POP3Error.closed("read") }
            buffer.append(chunk)
        }
    }

    private func extractLine() -> Data? {
        Self.extractLine(from: &buffer)
    }

    /// Split off the next line at the first CR or LF, tolerating CRLF, bare LF,
    /// and bare CR. Consumes the terminator; a CRLF counts as one break.
    /// Returns `nil` when no complete line is buffered yet.
    ///
    /// It was CRLF-only — `range(of: "\r\n")` — which is correct per RFC but
    /// brittle: a server that separated lines with a bare CR handed back one
    /// unbroken blob, and the UIDL parser then read a 21-message listing as a
    /// single message with a nonsense concatenated UID, so nothing ever
    /// downloaded. (Observed against Gmail POP reached via the wrong host.)
    /// Since `readMultiline` re-emits every line as CRLF, normalising here also
    /// repairs message bodies that arrive with odd endings.
    ///
    /// Static and `internal` (not `private`) so `EudoraNetTests` can drive it on
    /// a plain `Data` without a live connection — the regression it fixes is
    /// exactly the kind that hid for weeks, so it's worth a test that pins it.
    /// A trailing bare CR with nothing after it is held back deliberately: it may
    /// be the first half of a CRLF split across two reads. That can't be
    /// disambiguated until the next byte arrives, so a response whose final byte
    /// is a lone CR would stall — no RFC-compliant server ends that way.
    static func extractLine(from buffer: inout Data) -> Data? {
        guard let idx = buffer.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) else { return nil }
        let after = buffer.index(after: idx)
        if buffer[idx] == 0x0D, after == buffer.endIndex { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<idx)
        var consumeEnd = after
        if buffer[idx] == 0x0D, buffer[after] == 0x0A {
            consumeEnd = buffer.index(after: after)   // CRLF counts as one break
        }
        buffer.removeSubrange(buffer.startIndex..<consumeEnd)
        return line
    }

    // MARK: async NWConnection wrappers

    private func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume() }
                case .failed(let e):
                    if once.claim() { cont.resume(throwing: POP3Error.connectionFailed(e.localizedDescription)) }
                case .waiting(let e):
                    if once.claim() { cont.resume(throwing: POP3Error.connectionFailed(e.localizedDescription)) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: POP3Error.connectionFailed(err.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, err in
                if let err = err { cont.resume(throwing: POP3Error.connectionFailed(err.localizedDescription)); return }
                cont.resume(returning: data ?? Data())
            }
        }
    }
}

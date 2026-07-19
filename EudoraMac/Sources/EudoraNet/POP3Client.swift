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
        var pairs: [(Int, String)] = []
        for line in String(decoding: body, as: UTF8.self).split(whereSeparator: { $0 == "\n" }) {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ", maxSplits: 1)
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

    /// One CRLF-terminated line (CRLF stripped), buffering across reads.
    private func readLine() async throws -> Data {
        while true {
            if let line = extractLine() { return line }
            let chunk = try await receive()
            if chunk.isEmpty { throw POP3Error.closed("read") }
            buffer.append(chunk)
        }
    }

    private func extractLine() -> Data? {
        guard let r = buffer.range(of: Data([0x0D, 0x0A])) else { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<r.upperBound)
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

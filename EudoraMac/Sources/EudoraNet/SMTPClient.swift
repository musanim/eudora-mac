import Foundation
import Network
import EudoraStore

public enum SMTPError: LocalizedError {
    case startTLSUnsupported
    case badPort
    case connectionFailed(String)
    case unexpected(code: Int, message: String, during: String)
    case closed(String)

    public var errorDescription: String? {
        switch self {
        case .startTLSUnsupported:
            return "STARTTLS (port 587) isn't supported yet — use SSL/TLS on port 465."
        case .badPort:
            return "Invalid port number."
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .unexpected(let c, let m, let during):
            return "Server rejected \(during): \(c) \(m)"
        case .closed(let during):
            return "Connection closed during \(during)."
        }
    }
}

/// A small hand-rolled SMTP client over Network.framework, implicit TLS only
/// (SMTPS / port 465). STARTTLS needs a mid-stream TLS upgrade that
/// NWConnection can't do, so it's a separate follow-up.
///
/// `@unchecked Sendable`: the mutable `buffer` is only ever touched inside the
/// sequential `await` chain in `run`, never concurrently.
public final class SMTPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "smtp")
    private var buffer = Data()

    public init(account: SMTPAccount) throws {
        guard account.security == .tls else { throw SMTPError.startTLSUnsupported }
        guard let p16 = UInt16(exactly: account.port),
              let port = NWEndpoint.Port(rawValue: p16) else { throw SMTPError.badPort }
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        connection = NWConnection(host: NWEndpoint.Host(account.host), port: port, using: params)
    }

    /// Assemble-and-send convenience: build the message, send it, and hand back
    /// the raw RFC-822 bytes + Message-ID so the caller can write it to Out.
    public static func send(_ message: OutgoingMessage,
                            account: SMTPAccount,
                            password: String)
        async throws -> (raw: Data, messageID: String) {
        let assembled = message.rfc822()
        let client = try SMTPClient(account: account)
        try await client.run(raw: assembled.data, message: message,
                             account: account, password: password)
        return (assembled.data, assembled.messageID)
    }

    private func run(raw: Data, message: OutgoingMessage,
                     account: SMTPAccount, password: String) async throws {
        try await start()
        defer { connection.cancel() }

        let clientName = account.fromAddress.split(separator: "@").last.map(String.init) ?? "localhost"

        _ = try await expect(220, during: "greeting")
        let ehlo = try await command("EHLO \(clientName)", 250, during: "EHLO")
        try await authenticate(username: account.username, password: password, caps: ehlo.lines)
        _ = try await command("MAIL FROM:<\(message.envelopeSender)>", 250, during: "MAIL FROM")
        for rcpt in message.envelopeRecipients {
            _ = try await command("RCPT TO:<\(rcpt)>", 250, alt: 251, during: "RCPT TO")
        }
        _ = try await command("DATA", 354, during: "DATA")
        try await write(Self.dotStuff(raw))
        _ = try await expect(250, during: "message body")
        _ = try? await command("QUIT", 221, during: "QUIT")
    }

    private func authenticate(username: String, password: String, caps: [String]) async throws {
        let mechs = caps.joined(separator: " ").uppercased()
        if mechs.contains("PLAIN") {
            let token = Data("\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString()
            _ = try await command("AUTH PLAIN \(token)", 235, during: "AUTH PLAIN")
        } else {
            _ = try await command("AUTH LOGIN", 334, during: "AUTH LOGIN")
            _ = try await command(Data(username.utf8).base64EncodedString(), 334, during: "AUTH LOGIN (user)")
            _ = try await command(Data(password.utf8).base64EncodedString(), 235, during: "AUTH LOGIN (pass)")
        }
    }

    // MARK: protocol plumbing

    private func command(_ line: String, _ code: Int, alt: Int? = nil, during: String)
        async throws -> (code: Int, lines: [String]) {
        try await write(Data((line + "\r\n").utf8))
        return try await expect(code, alt: alt, during: during)
    }

    private func expect(_ code: Int, alt: Int? = nil, during: String)
        async throws -> (code: Int, lines: [String]) {
        while true {
            if let reply = parseReply() {
                if reply.code == code || reply.code == alt { return reply }
                throw SMTPError.unexpected(code: reply.code,
                                           message: reply.lines.last ?? "",
                                           during: during)
            }
            let chunk = try await receive()
            if chunk.isEmpty { throw SMTPError.closed(during) }
            buffer.append(chunk)
        }
    }

    /// Parse one complete SMTP reply out of `buffer` (final line has a space at
    /// position 3, continuations use '-'). Consumes the bytes it uses.
    private func parseReply() -> (code: Int, lines: [String])? {
        guard let text = String(data: buffer, encoding: .isoLatin1) else { return nil }
        var lines: [String] = []
        var consumed = 0
        var pieces = text.components(separatedBy: "\r\n")
        // Last piece is the (possibly partial) remainder after the final CRLF.
        pieces.removeLast()
        for line in pieces {
            consumed += line.unicodeScalars.count + 2   // latin1: 1 scalar == 1 byte
            lines.append(line)
            if line.count >= 4 {
                let chars = Array(line)
                if chars[0].isNumber, chars[1].isNumber, chars[2].isNumber, chars[3] == " " {
                    buffer.removeFirst(consumed)
                    return (Int(String(chars[0...2])) ?? -1, lines)
                }
            }
        }
        return nil
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
                    if once.claim() { cont.resume(throwing: SMTPError.connectionFailed(e.localizedDescription)) }
                case .waiting(let e):
                    if once.claim() { cont.resume(throwing: SMTPError.connectionFailed(e.localizedDescription)) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: SMTPError.connectionFailed(err.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
                if let err = err { cont.resume(throwing: SMTPError.connectionFailed(err.localizedDescription)); return }
                cont.resume(returning: data ?? Data())
            }
        }
    }

    /// Dot-stuff the message and append the terminating "\r\n.\r\n".
    static func dotStuff(_ raw: Data) -> Data {
        var out = Data()
        var atLineStart = true
        for b in raw {
            if atLineStart && b == 0x2E { out.append(0x2E) }   // double a leading '.'
            out.append(b)
            atLineStart = (b == 0x0A)
        }
        if out.suffix(2) != Data([0x0D, 0x0A]) { out.append(contentsOf: [0x0D, 0x0A]) }
        out.append(contentsOf: [0x2E, 0x0D, 0x0A])             // ".\r\n"
        return out
    }
}

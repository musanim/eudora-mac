import Foundation

/// The `Message-ID`s already present in a mailbox — the guard that keeps the
/// same message from being delivered into it twice.
///
/// **Why the UID set isn't enough.** A downloaded-UID set can only recognise a
/// message it has already seen *from the same account*, because it is keyed on
/// `keychainAccount` (`user@host:port`). Two situations defeat it, and both are
/// cut-over situations rather than hypotheticals:
///
/// - **Two accounts carrying the same mail.** Gmail forwarded into musanim and
///   Gmail also polled directly hand over two server-side messages, with
///   different UIDs on different servers and one identical `Message-ID`.
///   Nothing in either account's UID set can tell.
/// - **An edited account.** Changing an account's host, username or port
///   changes `keychainAccount`, so that account starts again with an empty UID
///   set and re-downloads everything still sitting on the server.
///
/// **Fail-open, deliberately, in every direction.** An unreadable mailbox, a
/// record whose headers run past the prefix we read, a message carrying no
/// `Message-ID` at all — every one of those means "not a duplicate", and the
/// message is delivered. Mail that arrives twice is a nuisance that takes a
/// keystroke to fix. Mail silently dropped on the floor cannot be recovered,
/// and the user would have no way to know it happened.
public struct MessageIDIndex {
    private var ids: Set<String>

    /// How much of each record is read looking for the header block. Headers
    /// beyond this are not examined, so a message with pathological headers is
    /// treated as having no `Message-ID` — it is delivered, never dropped. The
    /// bound is what keeps this off the message *bodies*: without it every
    /// record with a large attachment would be copied out in full just to read
    /// the dozen lines at its front.
    static let headerPrefix = 64 * 1024

    /// Print each discarded message's `Message-ID` and subject.
    ///
    /// Off, intact, and here for one specific accusation: "Eudora 8 is eating my
    /// mail from X." The false positive this guard can produce is a sender that
    /// reuses one `Message-ID` for every message it sends — scanners, cron jobs
    /// and some appliances do — in which case the first lands in In and the rest
    /// are discarded for as long as it stays there. The notice says only how
    /// many were ignored, which cannot distinguish that from a genuine
    /// double-delivery, so switch this on and the answer is in the console.
    /// (Following the project's pattern: diagnostics stay in the tree, switched
    /// off, with a note of what they found. See `POP3Client.diagnose`.)
    ///
    /// A length or checksum test would *not* be a better guard, incidentally:
    /// two servers stamp different `Received:` headers on the same message, so
    /// the bytes legitimately differ and any such test would defeat the guard
    /// entirely. `Message-ID` is the only thing that survives the trip.
    ///
    /// It was ON through the cut-over, when the transient Check Mail notice was
    /// too easy to miss and this guard firing was the thing worth not missing.
    /// **Off again 2026aug11**, the dust having settled: it reported nothing that
    /// needed acting on. Nothing depends on it either way.
    public static var diagnose = false

    /// Room for the `From ???@??? Thu Nov 19 17:23:56 2009` envelope line that
    /// precedes every record's real headers — 13 bytes of separator, 24 of
    /// asctime, 2 of CRLF, rounded up.
    static let envelopeAllowance = 64

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    /// An empty index: nothing is a duplicate. Used on the paths where no mail
    /// arrived, so no mailbox is read at all.
    public init() { ids = [] }

    /// Scan `<base>.mbx` and collect the `Message-ID` of every message in it.
    ///
    /// Cost is one read plus a memchr scan for the record separators, and a
    /// header parse bounded to `headerPrefix` bytes per record — never a full
    /// MIME parse, and never a message body. That is strictly less than
    /// `Outbox.append` already spends on **each** message it delivers, since it
    /// reads the whole destination mailbox into memory in order to append to
    /// it. So building this once for a batch of arriving mail costs nothing
    /// worth measuring against the delivery it guards.
    ///
    /// Build it only when mail has actually arrived. On an idle automatic check
    /// this would be a read of the In box for nothing, and a quiet check that
    /// touches no disk is a property worth keeping (see the `received > 0`
    /// guard in `receiveMail`).
    ///
    /// Never throws: a mailbox that cannot be read yields an empty index, which
    /// fails open.
    public init(scanning base: URL) {
        ids = []
        let mbx = base.appendingPathExtension("mbx")
        // `.mappedIfSafe` asks for the mapping; the `[UInt8]` conversion below
        // then copies, because `Mbox.findRecords` takes an array. Left as it is
        // for two reasons: it is what every other reader in EudoraStore does
        // (`MailStore.list`, `MailboxMutator.readRecord`), and the destination
        // of a delivery is the In box — a working mailbox, 16 messages and
        // 0.5 MB in the real tree, not one of the archives. Don't reach for
        // this on Trash (613 MB) without giving `findRecords` a `Data` form.
        guard let data = try? Data(contentsOf: mbx, options: .mappedIfSafe) else { return }
        let bytes = [UInt8](data)
        for rec in Mbox.findRecords(bytes) {
            let end = min(rec.offset + rec.length, bytes.count)
            guard rec.offset < end else { continue }
            // `+ envelopeAllowance` so the window measured here matches the one
            // `messageID(of:)` uses on an incoming message: this slice starts at
            // the record, which begins with the `From ???@??? <date>` envelope
            // line that `messageBytes(fromRecord:)` then strips, while the
            // incoming side counts from the first real header. Without the
            // allowance a `Message-ID` sitting in that sliver would be indexed as
            // absent but read as present, and the message would be delivered
            // twice. Fail-open either way; symmetric is easier to reason about.
            let stop = min(rec.offset + Self.headerPrefix + Self.envelopeAllowance, end)
            let head = Mbox.messageBytes(fromRecord: Array(bytes[rec.offset..<stop]))
            if let id = Self.messageID(inHeaderBytes: head) { ids.insert(id) }
        }
    }

    public func contains(_ messageID: String) -> Bool { ids.contains(messageID) }

    public mutating func insert(_ messageID: String) { ids.insert(messageID) }

    // MARK: locating

    /// The byte offset of the record in `<base>.mbx` carrying `wantedID`, or nil
    /// if no record does.
    ///
    /// The same scan as `init(scanning:)` — one read, `findRecords`, and a
    /// header parse bounded to `headerPrefix` per record — stopping at the first
    /// match instead of collecting every id.
    ///
    /// **Only ever a fallback.** A caller that has an offset should use it and
    /// verify, because that costs a few kilobytes; this costs a read of the
    /// whole mailbox, which on one of the archives is hundreds of megabytes.
    /// The one caller (`AppModel.markRepliedTo`) reaches it only when a reply is
    /// sent *and* the original's remembered offset no longer holds it.
    ///
    /// First match wins. Two records with one `Message-ID` means the mailbox has
    /// a duplicate, in which case either is as good an answer as the other.
    //
    // The internal parameter name is `wantedID`, not `messageID`, and must stay
    // that way: unqualified lookup stops at the innermost declaration of a name,
    // so a parameter called `messageID` shadows `messageID(inHeaderBytes:)`
    // below and the call inside the loop tries to invoke a `String`.
    public static func offset(of wantedID: String, in base: URL) -> Int? {
        guard let wanted = normalized(wantedID) else { return nil }
        var hit: Int?
        scanHeaders(in: base) { offset, head in
            guard messageID(inHeaderBytes: head) == wanted else { return true }
            hit = offset
            return false      // first match wins; stop reading
        }
        return hit
    }

    /// The byte offsets of every record in `<base>.mbx` whose `In-Reply-To`
    /// names `wantedID`, **in mailbox order**.
    ///
    /// This is the link from a message to the answers to it. Nothing stores that
    /// link — the R mark is one status byte and says only *that* a reply was
    /// sent — but every reply carries the original's id in its `In-Reply-To`, so
    /// the relation is derivable rather than remembered. Which is the better
    /// side to hold it on: it needs no new state, survives the reply being
    /// filed or the original being moved, and works for replies Eudora 7 sent
    /// years ago, none of which a side-car written today could know about.
    ///
    /// All of them rather than the first, because the caller wants the *last*
    /// one — "where did we leave this?" — and mailbox order is not send order
    /// once a reply has been filed. The caller compares dates.
    ///
    /// Same scan, same bound, same caveats as `offset(of:in:)`.
    public static func offsets(replyingTo wantedID: String, in base: URL) -> [Int] {
        guard let wanted = normalized(wantedID) else { return [] }
        var hits: [Int] = []
        scanHeaders(in: base) { offset, head in
            if normalizedHeader("In-Reply-To", inHeaderBytes: head) == wanted {
                hits.append(offset)
            }
            return true
        }
        return hits
    }

    /// Walk a mailbox's records, handing each one's offset and header bytes to
    /// `visit`. Returning false from `visit` stops the walk.
    ///
    /// The one implementation of the scan, shared so the two public readers
    /// above cannot drift apart about which bytes count as a record's headers —
    /// the window and its envelope allowance have to match `init(scanning:)`
    /// exactly, and that is the sort of agreement that decays silently when it
    /// is written out twice.
    private static func scanHeaders(in base: URL, visit: (Int, [UInt8]) -> Bool) {
        let mbx = base.appendingPathExtension("mbx")
        guard withinScanLimit(mbx),
              let data = try? Data(contentsOf: mbx, options: .mappedIfSafe) else { return }
        // Copies, because `findRecords` takes an array — the same compromise
        // `init(scanning:)` documents, and the reason for the size limit above.
        let bytes = [UInt8](data)
        for rec in Mbox.findRecords(bytes) {
            let end = min(rec.offset + rec.length, bytes.count)
            guard rec.offset < end else { continue }
            // Same window as `init(scanning:)`, allowance included, so the two
            // agree about which bytes count as a record's headers.
            let stop = min(rec.offset + headerPrefix + envelopeAllowance, end)
            let head = Mbox.messageBytes(fromRecord: Array(bytes[rec.offset..<stop]))
            if !visit(rec.offset, head) { return }
        }
    }

    /// How large a mailbox this scan will read.
    ///
    /// It runs on the main actor, immediately after a message has been sent, and
    /// it reads and copies the whole `.mbx`. On one of the archives — Trash is
    /// 613 MB — that is a visible stall at the worst possible moment, in pursuit
    /// of a message that by construction is no longer where it was. So it is
    /// bounded, and over the bound the answer is "not found", which the one
    /// caller already treats as "mark nothing".
    ///
    /// 64 MB comfortably covers the working mailboxes replies actually come
    /// from. To lift it, the scan has to move off the main actor and
    /// `findRecords` needs a `Data` form so the mapping isn't copied — do both
    /// or neither.
    static let scanSizeLimit = 64 * 1024 * 1024

    private static func withinScanLimit(_ mbx: URL) -> Bool {
        let size = (try? mbx.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        // An unreadable size is treated as within the limit: the read below
        // fails harmlessly if the file really isn't there, and refusing on a
        // missing attribute would silently disable the fallback.
        return (size ?? 0) <= scanSizeLimit
    }

    // MARK: extraction

    /// The normalised `Message-ID` of a complete RFC-822 message, or nil when it
    /// hasn't got one that can be compared.
    public static func messageID(of messageData: Data) -> String? {
        messageID(inHeaderBytes: [UInt8](messageData.prefix(headerPrefix)))
    }

    static func messageID(inHeaderBytes bytes: [UInt8]) -> String? {
        normalizedHeader("Message-ID", inHeaderBytes: bytes)
    }

    /// One header's value out of a record's header bytes, normalised as an id.
    ///
    /// Generalised from the `Message-ID` reader above so `In-Reply-To` — which
    /// carries an id in exactly the same syntax — is read by the same code and
    /// normalised the same way. A reply's `In-Reply-To` and its original's
    /// `Message-ID` must compare equal, and they only reliably do if one
    /// function decides what a bracketed, folded or bare id reduces to.
    static func normalizedHeader(_ name: String, inHeaderBytes bytes: [UInt8]) -> String? {
        let (head, _) = MIMEParser.splitHeaderBody(bytes)
        for entry in MIMEParser.parseHeaders(head)
        where entry.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name)
            == .orderedSame {
            // First match wins, matching `MIMEPart.header`. A message with two
            // Message-ID headers is malformed; agreeing with the rest of the
            // codebase about which one counts matters more than the choice.
            return normalized(entry.value)
        }
        return nil
    }

    /// `<abc@def>` from ` <abc@def> (comment) ` or from a bare `abc@def`.
    ///
    /// Three things are normalised, so that the same message re-sent through a
    /// different path still compares equal:
    ///
    /// - **Brackets are added if missing.** Some mailers emit `Message-ID:
    ///   abc@def`. Wrapping means the bracketed and bare forms of one id land on
    ///   the same key instead of counting as two different messages.
    /// - **Anything outside the first bracketed token is dropped** — trailing
    ///   comments are legal RFC-822 and carry no identity. The *first* `>` after
    ///   the opening `<` ends the token, not the last one in the line: a comment
    ///   may itself contain angle brackets (`<a@b> (see <c@d>)`), and taking the
    ///   last would fold the comment into the key.
    /// - **Whitespace inside the brackets is removed.** `parseHeaders` unfolds a
    ///   continuation line by joining it with a space, so a folded id arrives as
    ///   `<abc@ def>`. Real ids never contain spaces, so this cannot merge two
    ///   genuinely different messages.
    ///
    /// Case is **preserved**. RFC 5322 makes the id-left part case-sensitive, so
    /// two ids differing only in case are formally different messages, and
    /// lowercasing would risk discarding real mail. An empty or unusable value
    /// yields nil — never the empty token, which would collide with every other
    /// unusable value.
    /// Public so a caller comparing two ids from different sources — one read
    /// from a mailbox record, one remembered from earlier — puts both through
    /// the same normalisation rather than comparing raw header text.
    public static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if let open = trimmed.firstIndex(of: "<"),
           let close = trimmed[trimmed.index(after: open)...].firstIndex(of: ">") {
            body = String(trimmed[trimmed.index(after: open)..<close])
        } else {
            // Bare form: the first whitespace-delimited token, so a bare id
            // followed by a comment doesn't drag the comment into the key. Split
            // on any whitespace, not just a space — a tab is a legal separator.
            body = trimmed.split(whereSeparator: { $0.isWhitespace })
                .first.map(String.init) ?? ""
        }
        let compact = body.filter { !$0.isWhitespace }
        return compact.isEmpty ? nil : "<\(compact)>"
    }
}

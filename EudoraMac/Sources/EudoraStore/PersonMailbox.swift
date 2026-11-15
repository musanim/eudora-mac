import Foundation

/// Make Person Mailbox… — the parts that need no app: what to call the new
/// mailbox, where under PEOPLE it goes, which mailboxes start ticked, and which
/// messages in a mailbox involve the person.
///
/// The command is for a reply from someone whose earlier mail sits in MISCINQ or
/// another group mailbox rather than a PEOPLE mailbox of their own. Stephen's
/// design, 2026nov14: a right-click command rather than anything automatic, the
/// name editable, and a sheet listing every mailbox that holds their mail.
public enum PersonMailbox {

    // MARK: - Name

    /// The name to prefill, from the clicked message's raw `From` value:
    /// "First Last", the way PEOPLE mailboxes are named.
    ///
    /// The display name if there is one, turned round when it is written
    /// "Last, First"; otherwise the address's local part, split at dots and
    /// underscores. Characters a mailbox name may not contain are dropped
    /// rather than refused — the field is editable, and a prefill that the
    /// Create button then rejects is worse than one with a quote missing.
    ///
    /// Split before decoding, as everywhere else that reads address headers: a
    /// decoded encoded-word can carry a comma that was never a separator.
    public static func suggestedName(fromHeader raw: String) -> String {
        let entries = EmailAddress.splitList(raw)
        guard var entry = entries.first else { return "" }
        // An unquoted `Doe, Jane <j@x>` is split at its comma into a name with
        // no address and the rest; put it back together.
        if entries.count >= 2, EmailAddress.bareAddress(entry) == nil {
            entry = entry + "," + entries[1]
        }
        var display = ""
        if let lt = entry.firstIndex(of: "<") {
            display = String(entry[..<lt])
        } else if let open = entry.firstIndex(of: "("),
                  let close = entry[open...].firstIndex(of: ")") {
            display = String(entry[entry.index(after: open)..<close])
        }
        display = HeaderDecoder.decode(display)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))

        if display.isEmpty || display.contains("@") {
            let local = EmailAddress.bareAddress(entry)?.split(separator: "@").first.map(String.init) ?? ""
            display = local.split(whereSeparator: { $0 == "." || $0 == "_" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        } else {
            let parts = display.split(separator: ",", omittingEmptySubsequences: true)
            if parts.count == 2 {
                display = parts[1].trimmingCharacters(in: .whitespaces) + " "
                        + parts[0].trimmingCharacters(in: .whitespaces)
            }
        }

        // Above U+00FF too: `descmap.pce` is Latin-1, so `create` refuses
        // anything else (an emoji, Ł, CJK) — only after the second read.
        var cleaned = ""
        cleaned.unicodeScalars.append(contentsOf: display.unicodeScalars.filter {
            $0.value <= 0xFF && !MailboxTreeMutator.bannedNameCharacters.contains($0)
        })
        return cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// Whether `MailboxTreeMutator.createMailbox` would accept this name as far
    /// as its characters go (not duplicates, which depend on the folder): the
    /// sheet's Create & Move is disabled otherwise, so a refusal can't arrive
    /// only after the second read.
    public static func isStorableName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && trimmed.rangeOfCharacter(from: MailboxTreeMutator.bannedNameCharacters) == nil
            && trimmed.data(using: .isoLatin1) != nil
    }

    // MARK: - Destination

    /// A folder in the PEOPLE tree, as far as choosing a destination needs it.
    public struct Group: Equatable, Sendable {
        public let id: String
        public let display: String
        public let subgroups: [Group]
        public init(id: String, display: String, subgroups: [Group] = []) {
            self.id = id
            self.display = display
            self.subgroups = subgroups
        }
    }

    /// The group a new person's mailbox goes in, given PEOPLE's child folders:
    /// the two-letter subgroup when the letter group has one that fits (J holds
    /// JA, JO, …; "Jo…" goes to J ▸ JO), otherwise the letter group itself.
    /// Returned as the path below PEOPLE, letter first. Nil when no letter group
    /// matches — a name that starts with no letter, or a letter PEOPLE has no
    /// group for.
    ///
    /// By the **first** name, because PEOPLE mailboxes are named "First Last"
    /// and filed that way (`J ▸ JA ▸ James Carmichael`). Diacritics and case
    /// are folded, so "Élodie" goes to E.
    public static func destination(forName name: String, in people: [Group]) -> [Group]? {
        let letters = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .uppercased()
            .drop(while: { !$0.isLetter })
            .prefix(while: { $0.isLetter })
        guard let first = letters.first else { return nil }
        guard let letter = people.first(where: { folded($0.display) == String(first) }) else {
            return nil
        }
        if letters.count >= 2,
           let sub = letter.subgroups.first(where: { folded($0.display) == String(letters.prefix(2)) }) {
            return [letter, sub]
        }
        return [letter]
    }

    private static func folded(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .uppercased()
    }

    // MARK: - Default ticks

    /// Whether a mailbox holding this person's mail starts ticked in the sheet.
    ///
    /// Everything, except (Stephen's rule, 2026nov14): In, Out, Trash and Junk;
    /// the top-level SCAMS and HOLDING; and other people's PEOPLE mailboxes,
    /// where this person was most likely only copied. The message that was
    /// right-clicked moves whatever is ticked — that is the app's business, not
    /// this rule's.
    public static func tickedByDefault(type: MailboxType, isTopLevel: Bool,
                                       display: String, isUnderPeople: Bool) -> Bool {
        switch type {
        case .inbox, .outbox, .trash, .junk, .folder: return false
        case .mailbox: break
        }
        if isTopLevel, ["SCAMS", "HOLDING"].contains(display.uppercased()) { return false }
        return !isUnderPeople
    }

    // MARK: - Finding the person's messages

    /// What the scan saw of a mailbox's `.mbx`, to tell later whether it has
    /// changed. Size and modification time: every operation that renumbers
    /// records rewrites or appends to the `.mbx`, while a status change touches
    /// only the `.toc` and moves nothing.
    public struct Fingerprint: Equatable, Sendable {
        public let size: Int
        public let modified: Date

        public static func of(base: URL) -> Fingerprint? {
            let url = base.appendingPathExtension("mbx")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue,
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            return Fingerprint(size: size, modified: modified)
        }
    }

    /// The listed messages in one mailbox that involve an address.
    public struct Scan: Sendable {
        /// Row ids — 1-based record positions in the `.mbx`, what
        /// `MailboxMutator.moveMany` takes — of messages naming the address in
        /// From, To, Cc or Bcc, in mailbox order.
        public let matches: [Int]
        /// Each match's record offset, by row id — so a caller holding a
        /// listing can confirm its rows describe the same records.
        public let offsets: [Int: Int]
        /// The row id of the record starting at the offset asked about, if a
        /// listed record does — and carries the Message-ID asked about, when
        /// one was given. An offset alone can name another message once
        /// anything earlier in the mailbox has been removed.
        public let indexAtOffset: Int?
        /// Read by scanning the `.mbx`, with no usable `.toc`, so no status is
        /// known — a draft can't be told from a sent copy. Out read this way is
        /// never moved from.
        public let statusesUnknown: Bool
        /// The `.mbx` as it was throughout the scan.
        public let fingerprint: Fingerprint
    }

    /// Read a mailbox and find every listed message that involves `address`.
    ///
    /// **Listed** messages only — the rows `MailStore.list` shows. A `.mbx`
    /// keeps the bodies of messages deleted without compaction, which its `.toc`
    /// no longer names; matching those would carry deleted mail into the new
    /// mailbox and back into view.
    ///
    /// **Exact** address match on the parsed headers, not the search index's
    /// phrase match, which also takes `j.a@b.com` for `a@b.com`. Good enough for
    /// ranking where mail lives; not for deciding what gets moved.
    ///
    /// Nil when the mailbox can't be read, or changed while it was being read.
    ///
    /// Unsent, queued and failed outgoing messages are never matched: they
    /// belong in Out until they go, and an open draft window finds its draft
    /// there.
    public static func scan(base: URL, address: String, offset: Int? = nil,
                            messageID: String? = nil) -> Scan? {
        let wanted = address.lowercased()
        guard !wanted.isEmpty, let before = Fingerprint.of(base: base),
              let listing = MailStore(root: base.deletingLastPathComponent()).list(at: base),
              let data = try? Data(contentsOf: base.appendingPathExtension("mbx"),
                                   options: .mappedIfSafe) else { return nil }
        let needle = Array(wanted.utf8)
        var matches: [Int] = []
        var offsets: [Int: Int] = [:]
        var atOffset: Int?
        let wantedID = messageID.flatMap(MessageIDIndex.normalized)
        for row in listing.rows {
            let end = min(row.offset + min(row.size, headerWindow), data.count)
            guard row.offset >= 0, row.offset < end else { continue }
            let record = [UInt8](data[(data.startIndex + row.offset)..<(data.startIndex + end)])
            if row.offset == offset {
                if let wantedID {
                    let header = headerBlock(Mbox.messageBytes(fromRecord: record))
                    let found = MIMEParser.parse(header).header("Message-ID")
                        .flatMap(MessageIDIndex.normalized)
                    if found == wantedID { atOffset = row.index }
                } else {
                    atOffset = row.index
                }
            }
            if MailboxMutator.outgoingStatuses.contains(row.status),
               row.status != MailboxMutator.statusSent { continue }
            if involves(record: record, address: wanted, needle: needle) {
                matches.append(row.index)
                offsets[row.index] = row.offset
            }
        }
        guard Fingerprint.of(base: base) == before else { return nil }
        return Scan(matches: matches, offsets: offsets, indexAtOffset: atOffset,
                    statusesUnknown: listing.source == .scanNoToc || listing.source == .scanStale,
                    fingerprint: before)
    }

    /// How much of each record is read for its headers. Generous — DKIM and
    /// Received lines on list mail run to several kilobytes — and a header block
    /// longer than this simply doesn't match.
    static let headerWindow = 64 * 1024

    /// Whether one raw record (envelope line included) names `address` in an
    /// address header.
    static func involves(record: [UInt8], address: String, needle: [UInt8]) -> Bool {
        let header = headerBlock(Mbox.messageBytes(fromRecord: record))
        // Cheap test first: almost every record in a large mailbox doesn't
        // mention the address at all, and a byte search costs far less than a
        // MIME parse.
        guard containsIgnoringASCIICase(header, needle) else { return false }
        let part = MIMEParser.parse(header)
        for field in ["From", "To", "Cc", "Bcc"] {
            for value in part.headers where value.name.caseInsensitiveCompare(field) == .orderedSame {
                if EmailAddress.addresses(in: value.value).contains(address) { return true }
            }
        }
        return false
    }

    /// The header block, through the blank line that ends it; all of `bytes`
    /// when there is none (a window that cut the headers short).
    static func headerBlock(_ bytes: [UInt8]) -> [UInt8] {
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0x0A {
                if bytes[i + 1] == 0x0A { return Array(bytes[...(i + 1)]) }
                if bytes[i + 1] == 0x0D, i + 2 < bytes.count, bytes[i + 2] == 0x0A {
                    return Array(bytes[...(i + 2)])
                }
            }
            i += 1
        }
        return bytes
    }

    /// `needle` is already lowercase ASCII-or-UTF-8; only ASCII letters in the
    /// haystack are folded, which is all an address needs.
    static func containsIgnoringASCIICase(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let first = needle[0]
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if lower(haystack[i]) == first {
                var j = 1
                while j < needle.count, lower(haystack[i + j]) == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    private static func lower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
    }
}

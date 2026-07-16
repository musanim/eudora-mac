# A macOS Eudora 7 Successor — Architecture & Build Plan

*Working design doc. Goal: a native macOS email client that reads existing Eudora 7 (Windows) data files in place, mirrors Eudora's mailbox layout, and matches or beats its search — without migrating to a new storage format until (and unless) you choose to.*

---

## 1. Guiding decisions

**Reference, don't fork.** The Computer History Museum released Eudora under BSD in 2018, but neither released tree is a viable *build base* on modern macOS:

- The **Mac source is Eudora 6.2.4** — Carbon-era C. Carbon is 32-bit and was removed in macOS Catalina (10.15). It will not build on a current Mac without a ground-up port.
- The **Windows source (7.1)** is the one the active "Eudoramail 8.0 / HERMES" revival patches — but only *because it stays on Windows*. It is welded to MFC, Perforce's proprietary **Stingray** GUI toolkit (which the revival team tried and failed to remove, and now licenses for ~$2,800–3,600), and **Trident** (the old IE engine) for HTML rendering. None of that helps on macOS; porting it means replacing the entire UI + rendering layer anyway.

So the released source is **documentation of behavior and file formats**, and we write the guts fresh. This also matches where the one prior Cocoa attempt (HERMES Mail/X) pointed before it stalled.

**Read in place; don't migrate.** The app treats the Eudora directory tree as the system of record. It reads `.mbx`/`.toc`/`descmap.pce` directly and writes changes back in Eudora's own format. Anything the app needs that Eudora didn't store (a full-text index, UI state) lives in **sidecar files** the app owns, alongside — never inside — the Eudora data. That keeps the door open to running Eudora (or reverting) in parallel for a year or two, and makes "migrate later" a choice rather than a prerequisite.

---

## 2. The Eudora 7.1 (Windows) on-disk format

*All of the below is verified against the actual `Eudora71` source and the `eudora2unix` TOC parser — not assumed. File/line references are to the `evilneuro/eudora-win` tree.*

### 2.1 Folder hierarchy — `descmap.pce`

Each directory in the mail tree contains a plain-text **`descmap.pce`**. Each line describes one child, in the format (from `QCMailboxDirector.cpp:393` / format string at `:938`):

```
DisplayName,Filename,TypeChar,UnreadStatusChar
```

- `DisplayName` — what the user sees (can differ from the on-disk filename; this is how Eudora shows friendly names).
- `Filename` — the actual `.mbx` (mailbox) or subdirectory (folder) on disk.
- `TypeChar` — parsed via a `toupper` switch (`:410–442`): distinguishes the system mailboxes **In / Out / Junk / Trash** from a regular user mailbox, and from a **folder** (nested directory; folders carry a `.fol` companion, `IDS_FOLDER_EXTENSION`).
- `UnreadStatusChar` — cached unread indicator.

Reconstructing this recursively gives you Eudora's exact tree, display names and all. **This file is the key to the "same mailbox/folder layout" requirement** — you render from `descmap.pce`, not from a directory listing.

### 2.2 Mailbox contents — `<name>.mbx`

A **modified mbox** file: RFC-822 messages concatenated, each preceded by a pseudo-envelope line of the form:

```
From ???@??? Fri Mar 10 09:04:22 1995\r\n
```

(confirmed at `pop.cpp:687` and in the importers). Note **CRLF** line endings and the literal `???@???` sender placeholder — Eudora never puts a real address there, so you cannot rely on the `From ` line for anything but record-splitting. Real sender/recipient come from the headers and the TOC cache.

### 2.3 Index — `<name>.toc` (binary)

A binary index so a mailbox can be listed without parsing the `.mbx`. Layout (Windows variant, from `eudora2unix`'s `win_entry`/`win_folder`):

- **Header:** 2-byte version (`0x3000` for Pro 5.x, `0x2a00` for Lite 1.x — upper byte non-zero ⇒ Windows), the mailbox name (32 bytes), type, and per-column widths / window geometry.
- **Then N fixed-size entries**, one per message. Each entry (little-endian on Windows) holds:
  - 4-byte **offset** into the `.mbx`
  - 4-byte **length**
  - **status** byte (unread/replied/forwarded/redirected/queued/sent/…)
  - **priority** byte (Hi…Lo)
  - 32-byte **date** string
  - 64-byte **To** (cached, truncated)
  - 64-byte **Subject** (cached, truncated)
  - window size + padding

Practical consequence: **the `.toc` is a cache you can always rebuild** from the `.mbx`. Treat the `.mbx` as truth and the `.toc` as a derived index you keep in sync (Eudora itself has a "rebuild TOC" path). This de-risks write-back enormously — a bug in TOC writing is recoverable, not data loss.

### 2.4 Everything else

- **Attachments:** stored as loose files in a separate attachments directory, *referenced* by messages, not embedded. (Watch for Eudora-on-Mac's historical long-filename mangling; Windows 7.1 is less affected.)
- **Settings:** `eudora.ini` (huge; many settings are INI-only, exposed via `x-eudora-setting` URIs).
- **Filters:** `filters.pce`.
- **Address book / nicknames:** `nndbase.txt` + nickname files.

### 2.5 Two traps to avoid

1. **The `E2 Mailbox.pdf` / `E2 Mailstore.pdf` XML design is NOT your format.** Those describe the unshipped next-gen "Eudora 2" mailstore (one-message-per-file, XML, cross-platform). It was never the on-disk reality of Eudora 7. Build to the `.mbx`/`.toc`/`descmap.pce` format above; keep the E2 docs only as inspiration for your *own* future format if you ever migrate.
2. **Character encoding.** Eudora for Windows never really implemented encodings — it hardcoded outgoing mail as `iso-8859-1` and displayed incoming mail using the system codepage. Real-world `.mbx` files therefore contain a mix of declared-Latin-1, actual-Latin-1, and undeclared UTF-8/other. Your reader needs a tolerant decode step (respect MIME charset when present; heuristically detect otherwise) rather than trusting headers. This is exactly the wall the Windows revival hit, and where you can immediately be *better*.

---

## 3. Application architecture

Four layers, cleanly separated so the Eudora-format coupling stays quarantined in one place.

```
┌──────────────────────────────────────────────────────────┐
│  UI  (AppKit/SwiftUI) — Eudora-faithful 3-pane + search   │
├──────────────────────────────────────────────────────────┤
│  Domain model — Mailbox tree, Message, Account            │
│  (format-agnostic; knows nothing about .mbx/.toc)         │
├───────────────┬───────────────────────┬──────────────────┤
│ Store/Interop │  Search index         │  Network         │
│ layer         │  (SQLite FTS5 sidecar)│  IMAP/POP/SMTP   │
│ .mbx/.toc/    │  app-owned, rebuildable│                 │
│ descmap.pce   │                       │                  │
└───────────────┴───────────────────────┴──────────────────┘
        │
   Eudora data directory (read in place, written back in Eudora format)
```

### 3.1 Store / interop layer (the heart of the "in-place" requirement)

A single module owning all Eudora-format knowledge:

- **Tree reader:** walk directories, parse `descmap.pce`, build the mailbox tree with display names, system-mailbox roles, and folder nesting.
- **Mailbox reader:** memory-map the `.mbx`; use `.toc` offsets for O(1) message access; fall back to scanning `From ???@???` separators if the `.toc` is missing/stale, and rebuild the `.toc`.
- **Message parser:** RFC-822/MIME parse on demand, tolerant charset decoding (§2.5), attachment resolution to the attachments dir.
- **Writer:** append/flag/move/delete implemented as `.mbx` edits + `.toc` regeneration. Start by **rebuilding the whole `.toc`** for a touched mailbox (simple, safe) before optimizing to incremental updates.
- **Safety:** file-presence + lock detection so you never write while Eudora is open on the same tree; write-to-temp-then-rename; optional automatic `.mbx` backup before first write.

Expose a clean protocol (`MailStore`) to the layers above so nothing else ever touches a byte of Eudora format.

### 3.2 Domain model

Format-agnostic `Mailbox`, `Message`, `Account` types. The tree is the Eudora tree; messages are lazily loaded via the store. This layer is what the UI and search bind to, so a future format migration is invisible above this line.

### 3.3 Search — SQLite FTS5 sidecar

Eudora 7's "Ultra-Fast Search" was the proprietary **X1** engine (`Windows Eudora Indexed Search.pdf`; schema in `Search.xml`, index in a `Search` dir). X1 was never open-sourced — the Eudoramail revival had to ship *without* it. So reuse isn't an option, which is fine, because **SQLite FTS5 cleanly beats it**:

- One app-owned index database (e.g. `~/Library/Application Support/<App>/index.sqlite`) — **never written into the Eudora tree**.
- Index headers + body text + attachment filenames; store `(mailbox-id, toc-offset)` as the locator.
- Incremental updates on receive/move/delete/flag, mirroring Eudora's "index update actions" model but on a background queue (no main-thread constraint like X1 had).
- FTS5 gives prefix, phrase, boolean AND/OR, and negation out of the box — a superset of what X1 offered — plus ranking. Full reindex is a bounded background scan you can always fall back to.

This is the requirement you'll satisfy *first and most convincingly*.

### 3.4 Network

Standard **IMAP + POP3 + SMTP** with modern TLS and a current root-cert store (another thing classic Eudora couldn't do post-Heartbleed). Received mail lands in the store layer, which writes it into the Eudora tree in native format so the two worlds stay coherent. Consider building this against Apple's frameworks or a maintained Swift IMAP library rather than hand-rolling.

### 3.5 UI

AppKit (or SwiftUI with AppKit escape hatches) reproducing Eudora's three-pane feel: mailbox tree on the left rendered from `descmap.pce`, message list (columns straight from the TOC cache: status, priority, who, date, size), preview pane. Keep the interaction model familiar; modernize rendering (a WebKit view replaces Trident for HTML mail).

---

## 4. Recommended stack

- **Language/UI:** Swift + AppKit (SwiftUI where it doesn't fight you). Native, long-lived, best fit for a Mac-faithful client.
- **Storage/interop:** Swift, with `mmap` for `.mbx`; a small hand-written `.toc` codec (the format is tiny and fixed — `eudora2unix` is your reference implementation).
- **Search:** SQLite + FTS5 (built into macOS).
- **HTML mail:** WKWebView, with a strict content policy (no remote-content-by-default).
- **MIME/RFC-822:** a vetted Swift MIME parser, or port the parsing rules from the Eudora source for bug-for-bug familiarity where it matters.

---

## 5. Phased plan

**Phase 0 — Format spike (de-risk first).** Command-line tool: point it at a real Eudora tree, reconstruct and print the mailbox hierarchy from `descmap.pce`, list one mailbox's messages via `.toc`, and dump a chosen message (headers + decoded body + attachments). No UI. This proves the interop layer against *your actual data* before any app scaffolding.

**Phase 1 — Read-only viewer.** The three-pane UI over the store layer. Browse the whole tree, read messages, open attachments. Fully usable as a parallel reader while Eudora remains your live client. Zero write risk.

**Phase 2 — Search.** FTS5 sidecar + background indexer + a search UI that matches Eudora's criteria and beats its speed. Still read-only against the Eudora tree.

**Phase 3 — Receive & send.** IMAP/POP/SMTP with modern TLS. New mail written into the Eudora tree in native format; TOC rebuilt on write. This is the first time you write to the tree — gate it behind backups and lock detection.

**Phase 4 — Full mutation & parity.** Compose/reply/forward, move/delete/flag, filters (`filters.pce`), address book (`nndbase.txt`), incremental TOC updates, settings. At this point it can replace Eudora day-to-day.

**Phase 5 (optional, someday).** Only if you ever want to: introduce a native store and a migration path. The layer boundaries mean nothing above §3.1 has to change.

---

## 6. Known hard problems (worth respecting up front)

1. **Charset soup** (§2.5) — the single biggest correctness risk in *reading* old mail.
2. **TOC write-back fidelity** — mitigated by treating `.mbx` as truth and rebuilding TOC; still needs careful field-by-field matching so Eudora (if run in parallel) accepts your files.
3. **Concurrent access** — must not write while Eudora is open on the same tree; detect and refuse.
4. **Attachment linkage** — resolving message → attachment file, including any mangled filenames.
5. **`eudora.ini` breadth** — hundreds of settings; implement the ones that affect behavior/layout, ignore the rest initially.

---

## 7. Reference assets pulled (local, for the build)

From `evilneuro/eudora-win` (BSD-3-Clause-Clear) and `jonabbey/eudora2unix` (GPL — reference/study only, don't copy code into a BSD project):

- **`eudora2unix/EudoraTOC.py`** — working `.toc` parser (Mac + Windows structs). Your reference spec for the TOC codec.
- **`Documents/Pachyderm/Windows Eudora Indexed Search.pdf`** — how X1 search worked (what to reimplement on FTS5).
- **`Documents/Pachyderm/Windows Eudora IMAP Architecture.pdf`**, **`IMAP Action Queue.pdf`**, **`Offline IMAP.pdf`** — protocol behavior to mirror.
- **`Documents/Pachyderm/E2 Mailbox.pdf` / `E2 Mailstore.pdf`** — the *unshipped* next-gen design (Phase 5 inspiration only; not the on-disk format).
- **`Documents/Pachyderm/Windows Eudora SSL Architecture.pdf`**, **`Junk Mail Architecture.pdf`**, **`Bringing Eudora 6 for Mac to Mach-O.pdf`** — supporting context.
- **`Eudora71/Eudora/QCMailboxDirector.*`** — authoritative `descmap.pce` handling.
- **`Eudora71/Eudora/pop.cpp`** — the `From ???@???` separator and delivery path.

---

*Bottom line: your instinct was right on both counts — write the guts fresh, and don't migrate the data. The format is small, well-documented, and now verified; the risky-sounding "read Eudora files in place" is the tractable part, and "better search" is nearly free with FTS5. Recommended first move: Phase 0, the format spike against your real mailbox tree.*

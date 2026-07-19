# Handoff: Eudora (macOS successor) — 2026jul18

Continues `handoffs/Eudora_handoff_2026jul16.md`. That session built image/link
handling and fixed code-signing; the plan was to wire Search into the app. This
session **built the whole Search feature**, then spent most of its time on the
**first real-data testing** against Stephen's actual archive — which surfaced and
fixed a cascade of interop bugs. Everything below is written but **compiles/tests
only on Stephen's Mac** (Claude can't compile Swift in its sandbox).

## Goal
Native macOS email client to replace Windows Eudora 7: reads the existing Eudora
tree in place, mirrors the mailbox layout, matches/beats its search. Security
stance: a **"dumb" client** — no active behavior a message can trigger. Guts
written fresh in Swift. `EudoraMac/` is a SwiftPM package (EudoraStore /
EudoraSearch / EudoraNet); `EudoraApp/` is the SwiftUI app built via XcodeGen.

## Big change this session: now testing against REAL mail
- Stephen copied his real Eudora folder to **`~/ClaudeProjects/Eudora/phaseX/`**
  (a **624-mailbox+, multi-GB** tree; Trash alone is **625 MB / 22.5k msgs**). It
  is **gitignored** (along with `Eudora_*.zip` and `EudoraTestPassword.txt`) — the
  repo is **public** at `github.com/musanim/eudora-mac`, so real mail must never
  be committed. Open it in-app via File ▸ Open Eudora Folder… (⌘O); the app
  remembers it.
- Claude can read `phaseX/` directly (it's under the mounted folder) — this was
  invaluable for diagnosing format bugs. Use it.

## Completed this session
- **Search feature (the headline "beat Eudora" work).** Eudora-style **Find
  Messages** window (⌘F / Edit▸Find… / Tools▸Search…), `FindView.swift`. Scope
  pruned with Stephen to exactly what he uses: **where** = Anywhere/Headers/
  Subject/Date; **text ops** = contains/does-not-contain/is/is-not/starts-with;
  **date ops** = is/is-not/after/before; Match All/Any; More/Fewer; Results +
  Mailboxes(checkbox scope tree) tabs. Engine = LIKE/comparison over the FTS5
  columns (substring-faithful), not MATCH — MATCH acceleration is a deferred
  optimisation. Index gained `headers` + sortable `epoch` columns. Selecting a
  result opens it in the main window (`AppModel.openHit`). See design-decisions §6.
- **Background indexing + progress bar.** Index build runs off-main
  (`Task.detached`) with an "Indexing… X of N mailboxes" bar; window stays
  responsive; generation token + `indexingPath` guard + SQLite `busy_timeout`.
  **Reuse-on-open**: a completed index is reused (schema-checked via
  `hasCurrentSchema()`), so only the first open pays the cost.
- **Charset §5 (mostly done).** Full IANA coverage via
  `CFStringConvertIANACharSetNameToEncoding`; Windows-1252-preferred single-byte
  fallback; RFC 2231 attachment filenames. Only the per-message Text-Encoding
  override **menu** remains [planned].
- **Attachments.** Chips in the preview header; **Save As…** only (no
  open-in-app, per the dumb-client stance); image attachments get **View** in the
  existing native viewer. Bytes ride in `MessagePreview.attachments`.
- **Real-data interop fixes (all found by testing phaseX):**
  - **descmap format**: real filenames include the extension (`In.mbx`,
    `Foo.fol`); folders are `.fol` subdirectories; type codes are **S**(system,
    resolved to In/Out/Junk/Trash by name)/**M**/**F**; status **Y**=unread.
    (`DescMap.resolveType`, `MailStore.build` strips the ext for the base.)
  - **Status glyphs** corrected to Eudora's real `summary.h` codes (0 unread•,
    1 read, 2 replied R, 3 forwarded F, 4 redirect →, 8 sent S). Old map was
    inverted.
  - **Stale-TOC reconciliation**: when the `.toc` lists a subset of the `.mbx`
    (deleted-but-not-compacted "ghosts"), trust the `.toc` (show its messages
    with status, hide ghosts) instead of a status-less scan.
    (`MailStore.list`, `IndexSource.tocCompacted`.)
  - **Fast launch**: message-count badges now come from the `.toc` file *size*
    (a stat), not by reading every `.mbx` — launch dropped ~60s → ~6s.
  - **Eudora `<x-html>` bodies**: Eudora rewrites received mail into
    `<x-html>…</x-html>` (or `<x-flowed>`) with MIME parts flattened but a stale
    `multipart` Content-Type header, so messages showed "(no text body)". Now
    detected and rendered as the right text leaf. (`EudoraBody` in `MIME.swift`,
    `MIMEPart.eudoraContentType`.)
  - **Delete hang FIXED**: move-to-Trash read+parsed the entire 625 MB Trash on
    the main thread. Rewrote `MailboxMutator` so append is **O(one message)**
    (streaming `FileHandle` append + one 218-byte `.toc` entry); `remove` /
    `setStatus` / `readRecord` now touch a single message (never parse the whole
    mailbox) and are **ghost-aware** (don't drop the `.toc`). `move` now appends
    to dest **before** removing from source (no data-loss). Also fixed
    mark-read/unread writing the wrong status byte (constants were 1/2, should be
    0/1).
- **Swift 6 cleanup**: `ResumeOnce` latch replaces the `var resumed` capture in
  POP3Client/SMTPClient; `SMTPAccount.Security` made `Sendable`.
- **Git**: repo initialized this session and pushed to
  **`git@github.com:musanim/eudora-mac.git`** (public, branch `main`). Uncommitted
  work from today's later edits is still pending — see Next steps.

## Current state
Nothing half-edited. All of today's code is written and passed review agents, but
**not yet built by Stephen after the last several changes** (charset, indexing,
descmap, glyphs/TOC, launch speed, x-html, delete-fix, Swift6). Stephen confirmed
the earlier ones (search, attachments, launch, x-html render, delete) work; the
Swift 6 cleanup is the most recent and is unbuilt/unconfirmed. The **git working
tree has uncommitted changes** (everything after the initial commit).

## Next steps
1. **Commit the session's work.** `cd ~/ClaudeProjects/Eudora && git status` then
   commit the many EudoraMac/EudoraApp changes + design-decisions.md. (reference/,
   phaseX/, Eudora_*.zip, EudoraTestPassword.txt are gitignored — verify none are
   staged.) Then `git push`.
2. **Stephen keeps testing against `phaseX`** — expect more real-data quirks.
   Read the actual bytes in `phaseX/` to diagnose (works great).
3. Offered but not chosen next features: the **Text-Encoding override menu**
   (§5's last piece), **address book** (`nndbase.txt`), **filters**
   (`filters.pce`). Also **incremental indexing** (per-mailbox reindex on
   delete/Check Mail — Stephen asked about this; the FTS5 schema's `mailbox`
   column already supports it) and **compaction** (physically remove ghosts).

## Key context / gotchas
- **Build loop**: Claude can't compile (no Swift toolchain; Network-framework is
  macOS-only). Write carefully → Stephen builds & pastes errors → fix. Use
  **review agents** (general-purpose) for big/critical changes — they've caught
  real compile + logic bugs every time (Swift 5 `try?` flattening, wrong status
  constants, an `openHit` selection bug, etc.).
- **XcodeGen**: run `xcodegen generate` after adding a new file **to
  `EudoraApp/Sources/`** (the app target), then ⌘R. New files in **`EudoraMac/`**
  (the SwiftPM package) are auto-discovered — **no** xcodegen needed. This tripped
  Stephen up repeatedly; mention it in the same breath as any new-file change.
- **Verify library changes with `cd EudoraMac && swift test`** — the store/search
  tests are the safety net and Stephen runs them.
- **Index correctness note**: search still indexes not-yet-compacted deleted
  (ghost) messages, so a search can surface a "deleted" message. Minor; align when
  compaction lands.
- **Deferred perf**: permanently deleting from a *huge* Trash still rewrites that
  file (~1s, not a hang); send/receive append (Outbox/Delivery) still read+rewrite
  the whole mailbox. Both could get the streaming treatment later.
- macOS 13 / Swift 5.7 target; watch 14+ API traps. Read `design-decisions.md`
  (esp. §5 charset, §6 search) and `eudora-mac-architecture.md` first; don't
  re-debate settled decisions.

The user will likely ask you to **commit today's work and push**, then continue
real-data testing against `phaseX` (or pick up one of the deferred features:
Text-Encoding override menu, address book, filters, or incremental indexing).

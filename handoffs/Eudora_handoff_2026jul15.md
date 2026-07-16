# Handoff: Eudora (macOS successor) — 2026jul15

## Goal
Build a native **macOS email client to replace Windows Eudora 7** for Stephen. Three hard requirements: (1) works with existing Eudora data files **in place** (no migration), (2) mirrors Eudora's mailbox/folder layout exactly, (3) search that matches or beats Eudora's. Deliberately **not** migrating decades of real mail into the new app until it's been trusted for a year or two — so everything is being built and tested against a **synthetic fixture**, not real data.

## Completed (Phases 0–2, all verified)

**Research / design**
- Confirmed there's no finished macOS project to duplicate. The only live effort (HERMES/Eudoramail 8.0) is Windows-only and welded to proprietary Windows tech (MFC, Perforce Stingray, IE/Trident); the Cocoa "HERMES Mail/X" Kickstarter stalled in 2019. The released Eudora source (CHM, BSD, 2018) is only usable as **reference**, not a build base (Mac 6.2.4 is Carbon; Windows 7.1 is Windows-bound).
- Decision: **write the guts fresh in Swift, use the released source only as format/behavior reference.** Verified the on-disk format against the actual 7.1 source.

**Eudora format (verified, not assumed)**
- Folder tree = `descmap.pce` per directory, lines `DisplayName,Filename,TypeChar,UnreadStatus` (TypeChar I/O/T/J = In/Out/Trash/Junk, folders are subdirs).
- Mailbox = `.mbx`, modified mbox, CRLF, records split on `From ???@??? <date>` pseudo-envelope lines.
- `.toc` = binary index (rebuildable cache): 104-byte header + 218-byte entries, LE offset/length into the mbx, plus cached status/priority/date/to/subject.
- Eudora 7's fast search was proprietary **X1** — never open-sourced, unshippable. So search is reimplemented on SQLite FTS5 (and beats it).

**Phase 0 — Python spike** (`phase0/`): fixture generator + reader, fully tested. Proves hierarchy reconstruction, `.toc` listing with scan fallback, tolerant charset decoding (repairs UTF-8 mislabeled as iso-8859-1), multipart + attachment extraction.

**Phase 1 — Swift interop layer** (`EudoraMac/`, SwiftPM package): `EudoraStore` library behind a `MailStore` facade — `DescMap`, `Mbox`, `Toc`, minimal `MIME` parser, `Charset` (tolerant decode), QP/RFC-2047 decoders. Plus `eudora-spike` CLI (tree/list/dump). **Compiles and all XCTests pass on Stephen's Mac.**

**Phase 2 — FTS5 search** (`EudoraMac/Sources/EudoraSearch/`): indexes MailStore content into SQLite FTS5 (system sqlite3, no deps) as an **app-owned sidecar**, never inside the Eudora tree. bm25 ranking, snippets, prefix/phrase/boolean, `subject:` column filters, diacritic folding. CLI `search` command + XCTests. **Compiles and all tests pass.**

## Current state
Phases 0–2 are done, compiling, and green on Stephen's Mac (`swift test` passes both `EudoraStoreTests` and `EudoraSearchTests`). Note: I (Claude) have **no Swift toolchain in my sandbox** and can't compile — the loop is: I write Swift carefully, Stephen runs `swift build`/`swift test` and pastes results, I fix. One bug found this way and fixed: `descmap.pce` splitting must use `Character.isNewline` (a CRLF is a single grapheme cluster in Swift, so `== "\r" || == "\n"` never matched).

**Folder move: done.** The project was moved from `~/Eudora` to **`~/ClaudeProjects/Eudora`** (and `~/ClaudeStuff` renamed to `~/ClaudeProjects`, with Eudora/DeleteFileApp/Harmonizer2026/Harmonizer2010 consolidated inside it). Path references in the other projects were already rewritten to match. The Eudora package uses only relative paths, so it was unaffected.

## Next steps
1. **Phase 3 — the GUI.** Add an AppKit/SwiftUI app target to the `EudoraMac` package: Eudora-style three-pane window (mailbox tree from `MailStore.tree()`, message list from `list()`, preview via `message()`), with search wired to `SearchIndex`. This is the first thing Stephen can't test via XCTest, so expect keyboard-in-the-loop iteration.
2. Persist the search index as an app-owned sidecar (e.g. Application Support) with incremental updates on receive/move/delete, instead of the CLI's rebuild-each-run.
3. Later: IMAP/POP/SMTP with modern TLS; loose-file attachments (separate attach dir); and — only if ever desired — write-back to the Eudora format.

## Key context
- **Project lives at `~/ClaudeProjects/Eudora`.** Build with `cd EudoraMac && swift build && swift test`. Run CLI: `swift run eudora-spike ../phase0/sample-tree tree|list|dump|search`. (The `.build` cache was cleared during the move; the first `swift build` regenerates it.)
- **`.mbx` is the source of truth; `.toc` is a rebuildable cache.** The reader verifies `.toc` offsets against the mbx and falls back to scanning. This is what makes eventual write-back safe. Preserve this stance.
- **Reference material** is in `Eudora/reference/`: `eudora-win/` (full BSD Windows 7.1 source + design PDFs incl. `Documents/Pachyderm/Windows Eudora Indexed Search.pdf`) and `eudora2unix/` (the `.toc` parser we ported from). Architecture writeup: `Eudora/eudora-mac-architecture.md`.
- **Unvalidated-against-real-data caveats** (check the day real mail is available, before any write-back): the `.toc` 104/218-byte struct layout is the eudora2unix reverse-engineering (self-consistent with the fixture, not field-checked against a genuine `.toc`); the descmap TypeChar letters are approximated; only inline-MIME attachments handled so far (real Eudora also keeps loose files in a separate attach dir).
- **Two testing frameworks:** `swift test` runs both XCTest (our suite) and Swift Testing (empty) — the trailing "0 tests in 0 suites passed" is the empty Swift Testing runner, harmless.
- **Language choice:** Phase 0 spike is Python (so it could be run/verified in the sandbox and serves as a reference oracle); everything real is Swift.

The user will likely ask you to **start Phase 3 (the AppKit/SwiftUI GUI)** hung off the existing `EudoraMac` package. Read `eudora-mac-architecture.md` and `EudoraMac/README.md` first; don't re-debate the settled decisions above.

# EudoraMac — Phase 1 seed (Swift)

The Phase 0 format spike, ported to the target language as a **Swift Package**.
This is the real interop layer the macOS app will grow from: a reusable
`EudoraStore` library plus a small `eudora-spike` CLI and an XCTest suite.

> **Heads up:** this package was authored in an environment with **no Swift
> toolchain**, so it has not been compiled here. It's written carefully and
> idiomatically, and the logic is a line-for-line port of the Python spike that
> *was* fully tested — but expect the possibility of a minor fixup on first
> build. The XCTest suite is the fastest way to shake anything out.

## Open / build / test

It's a SwiftPM package, not an `.xcodeproj`. Both of these work:

- **Xcode:** double-click `Package.swift` (or File ▸ Open this folder). Build
  and test with ⌘B / ⌘U.
- **Command line:**
  ```sh
  cd EudoraMac
  swift build
  swift test
  swift run eudora-spike ../phase0/sample-tree tree
  swift run eudora-spike ../phase0/sample-tree list In
  swift run eudora-spike ../phase0/sample-tree dump In 3
  swift run eudora-spike ../phase0/sample-tree dump In 6 --save ./out
  ```
  The `../phase0/sample-tree` fixture is the one the Python spike generated, so
  the CLI here is a direct cross-check: same tree, same expected output.

## Layout

```
Sources/
  EudoraStore/          the reusable interop layer (import this from the app)
    Bytes.swift         byte-search helpers
    DescMap.swift       descmap.pce -> MailboxType / entries
    Mbox.swift          .mbx record splitting (From ???@??? separators)
    Toc.swift           binary .toc index parser
    MIME.swift          minimal MIME parser (multipart, params)
    Charset.swift       tolerant decode (repairs UTF-8-mislabeled-as-latin1)
    QuotedPrintable.swift  QP + RFC 2047 "Q" decoder
    HeaderDecoder.swift    RFC 2047 encoded-word decoder
    MailStore.swift     the facade: tree / locate / list / message
  EudoraSearch/         Phase 2: full-text search (SQLite FTS5)
    SQLite.swift        tiny wrapper over the system sqlite3 (no deps)
    Content.swift       message -> indexable text (incl. stripped HTML)
    SearchIndex.swift   FTS5 schema, rebuild, bm25-ranked search + snippets
  eudora-spike/
    main.swift          tree / list / dump / search commands
Tests/
  EudoraStoreTests/     self-contained: builds its own temp fixture
  EudoraSearchTests/    indexes a temp fixture and checks queries
```

## Search (Phase 2)

`EudoraSearch` indexes what `MailStore` exposes into a SQLite **FTS5** database —
an **app-owned sidecar**, never written into the Eudora tree. It gives
prefix/phrase/boolean/negation search, column filters, bm25 ranking, and
snippets — a superset of Eudora 7's old (proprietary, unshippable) X1 engine,
and diacritic-insensitive to boot.

```sh
swift run eudora-spike ../phase0/sample-tree search paddle
swift run eudora-spike ../phase0/sample-tree search "subject:baidarka"
swift run eudora-spike ../phase0/sample-tree search cafe        # matches "Café"
```

The CLI builds a fresh in-memory index each run to stay self-contained; a real
app persists the index (e.g. in Application Support) and updates it
incrementally on receive/move/delete.

## What the tests assert

- tree reconstruction and message counts from `descmap.pce`
- `.toc` fast-path listing (cached subject/status/priority)
- scan fallback when the `.toc` is missing
- **stale-`.toc` detection** (offsets disagree → fall back to scan)
- **charset repair** (UTF-8 body mislabeled `iso-8859-1` decodes correctly)
- multipart/alternative splitting into text + html parts

## Design stance (unchanged from Phase 0)

`.mbx` is the source of truth; `.toc` is a rebuildable cache that we verify and
fall back from. All Eudora-format knowledge lives in `EudoraStore` behind the
`MailStore` facade, so the eventual UI, search index, and network layers bind to
format-agnostic types (`MailboxNode`, `MIMEPart`, `Listing`).

## Same caveats as Phase 0 (validate against real data before write-back)

1. `.toc` struct layout (104-byte header, 218-byte entries) is the eudora2unix
   reverse-engineering — self-consistent with the fixture, not yet field-checked
   against a genuine `.toc`.
2. `descmap.pce` TypeChar letters (I/O/T/J/F/M) are approximated.
3. Real Eudora also stores loose attachment files in a separate directory; only
   inline-MIME attachments are handled so far.

## Next steps

- Build & run the tests on your Mac (`swift test`); report any fixups.
- Phase 3: an AppKit/SwiftUI GUI target hung off this package — the Eudora-style
  three-pane window over `MailStore` + `SearchIndex`.
- Later: incremental index updates, loose-file attachments, and (only if ever
  desired) write-back to the Eudora format.

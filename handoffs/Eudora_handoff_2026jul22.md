# Handoff: Eudora (macOS successor) — 2026jul22

Continues `handoffs/Eudora_handoff_2026jul21.md`. **Read `CLAUDE.md` first** —
how to work here, above all: **ask Stephen questions in plain prose, never the
multiple-choice widget.**

## Goal
Native macOS email client replacing Windows Eudora 7: reads the existing
Eudora tree in place, native format both ways, "dumb client" security stance.
`EudoraMac/` is the SwiftPM library (testable: `cd EudoraMac && swift test`);
`EudoraApp/` is the SwiftUI app (not compilable by Claude — no toolchain).

## The next task: rich text in the composer (font, color, bold, italic)
Scoped and decided with Stephen this session — **don't re-ask these**:

- **Editor**: replace `ComposeView`'s `TextEditor` (plain `String` binding,
  `ComposeView.swift` ~line 79) with an `NSTextView`-backed representable —
  rich text on, so ⌘B/⌘I and the standard font/color panels come along.
- **Controls**: a **compact strip** above the body — font popup, size, color
  well, B and I toggles. No Format menu needed.
- **Wire format**: styled body → `multipart/alternative` (generated
  plain-text fallback + HTML). **An unstyled message must produce exactly
  today's bytes** (`OutgoingMessage.rfc822`, `MessageBuilder.swift` — pure
  text/plain). Emit HTML only when styling is actually present.
- **Drafts round-trip**: saved styled drafts become multipart records in Out
  (via the existing `MailboxMutator.replace` path); `reopenDraft` must
  rebuild the attributed string (HTML → NSAttributedString). Note real
  Eudora 7 reading the same Out sees a MIME draft — Stephen knows.
- **Replies/forwards keep plain-text quoting**; styling goes on top.
- **Default font is a Stephen-personal choice**: he wants Windows Eudora's
  crisp small "Arial" (GDI-hinted, single-pixel stems). Plan: make face +
  size a **setting**, plus an **antialiasing on/off toggle** for the body
  (his display is non-Retina — scale 1, verified). He's downloading **Pixel
  Arial 11** from dafont (regular + bold TTFs; crisp only at design sizes —
  try 8 and 11; synthetic italic is fine/era-correct). Seed the setting with
  Arial 12 until his verdict. **Outgoing HTML declares `Arial, sans-serif`
  regardless of the local display face.**
- `EudoraFont.swift` already resolves list-font Arial 13 with fallback —
  the pattern (and the Windows-vs-Mac apparent-size note) to follow.
- Put the HTML generation/parsing logic in `EudoraMac/` where `swift test`
  reaches it (e.g. alongside `MessageBuilder`); the app-side editor is
  write-carefully territory.

## Current state
Working tree clean except `apps.txt` deleted by Stephen (may show as
untracked-removed noise; ignore). All commits pushed through `40ef4b0`
(`4f50302` mailbox-create + removal veil, `41c39d4` handoffs, `40ef4b0`
CLAUDE.md rule). Nothing half-done. `Scrolling.diagnoseRestore` is back to
`false`.

## Completed this session (all committed + pushed)
- **Multi-select in the message list** (`c19daba`): `selectedMessageIDs:
  Set` + `primaryMessageID` on AppModel; Delete/Transfer act on the whole
  selection (`canActOnSelection`), Reply/Forward/Mark-read need exactly one
  (`canActOnMessage`, nil-for-many computed `selectedMessageID`). Batch
  primitives `MailboxMutator.removeMany/moveMany` — one snapshot, one
  rewrite, toc offsets shifted via prefix sums; single remove/move delegate
  to them. `MailboxBatchTests`.
- **Sidebar right-click Delete for empty mailboxes** (`e353055`):
  `MailboxTreeMutator.deleteEmptyMailbox` edits descmap.pce as raw bytes
  (byte-preserving, LF or CRLF), .mbx is sole truth for emptiness, .bak
  left on disk. SwiftUI `.contextMenu` justified vs the AppKit-menus rule
  (one flat item; comment on `MailboxTree` records reasoning).
- **Move to ▸ New… creates mailboxes/folders** (`4f50302`): every level of
  both Move menus; NSAlert prompt with "make it a folder" (folder loops
  inside itself Eudora-style); create+move is one gesture.
  `MailboxTreeMutator.createMailbox/createFolder` append descmap lines in
  the file's own line-ending dialect; case preserved, duplicates refused
  case-insensitively. `ensureSystemMailboxes` on open recreates missing
  In/Out/Junk/Trash (fresh dir → minimal tree; orphans adopted, never
  overwritten).
- **The removal veil** (also `4f50302`): delete/move freezes the list as a
  *photograph* (window-server capture cropped to the bridge's anchor view),
  washed half-white, "Deleting…"/"Moving…" capsule; drops only after the
  scroll restore is applied, verified, and **confirmed 150 ms later**;
  survivors **carry enrichment across the re-list** (index-shift map in
  `afterRemoval`) so nothing resettles after the cut; completion notice
  ("Moved to Trash.") appears in the capsule's exact spot, never the
  banner. Backstop 15 s; mailbox switch drops the veil silently.

## Key context / gotchas
- **Build loop**: write carefully → Stephen builds → pastes errors. **Run a
  general-purpose review agent before every handover** — they caught real
  bugs at every step this session (test asserting `.first` where the entry
  appends last, a swallowed backup failure, stale itemsByID across a modal).
- **Instrument, don't theorize.** The veil took FIVE guesses until a
  frame-stepped screen recording + dumping the actual bitmap to
  /tmp/eudora-veil.png found both real causes. Diagnostics now in the tree:
  `Scrolling.diagnoseRestore` (restore/veil pipeline, prints SNAPSHOT lines,
  writes the png), plus the old ones. Turn them on before guessing.
- **Two capture dead-ends are documented in `installCamera`**
  (ContentView.swift): `cacheDisplay` on the layer-backed hierarchy, and
  capturing `table.enclosingScrollView` — it's **wider than the visible
  pane** (NavigationSplitView extends detail under the sidebar; measured
  1238 pt vs ~920 pt pane). The bridge's anchor NSView is the only correct
  capture region, and the camera reinstalls on every `attach` pass.
- **SwiftUI Table resets scroll to top when rows are replaced** (sometimes;
  clip.y −28 in the diagnostics). The bridge corrects it; anything that
  swaps `rows` non-trivially should think about `pendingScrollTopRow`.
- **`applyMessageSelection` is the single owner of selection+primary**;
  it ignores non-empty sets while the veil is up. Programmatic selection
  goes through `selectMessage(_:)`.
- Sandbox git: can commit; `rm -f .git/*.lock` before/after every git op
  (Claude CAN delete them now — file-deletion permission was granted).
  Cannot push (no SSH key) — Stephen pushes.
- Committing Stephen's handoff→archive moves needs no permission (now in
  CLAUDE.md).
- macOS 13 / Swift 5.7. `xcodegen generate` only for new files under
  `EudoraApp/Sources/`. Xcode may need DerivedData removed when a library
  change "isn't taking"; a build-marker print settles which binary runs.
- Enrichment reshuffle after re-list is now invisible for removals (carry-
  over), but sorting a mailbox on Date still reorders when enrichment
  *first* lands — pre-existing, known to Stephen, separate discussion.

The user will likely ask you to **build the rich-text composer** per the
scope above — start with the `EudoraMac` HTML half (testable), then the
editor + strip, and put the design questions already answered here to use
rather than re-asking them.

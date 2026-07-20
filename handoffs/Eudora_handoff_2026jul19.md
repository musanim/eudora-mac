# Handoff: Eudora (macOS successor) — 2026jul19

Continues `handoffs/archive/Eudora_handoff_2026jul18.md`. That session built Search
and fixed a cascade of real-data interop bugs. **This session was almost entirely
UI polish on the message list, plus remembered view state and a launch splash** —
Stephen is preparing to use the app for real mail, one item at a time.

## Goal
Native macOS email client to replace Windows Eudora 7: reads the existing Eudora
tree in place, mirrors the mailbox layout, matches/beats its search. Security
stance: a **"dumb" client** — no active behavior a message can trigger. `EudoraMac/`
is a SwiftPM package (EudoraStore / EudoraSearch / EudoraNet); `EudoraApp/` is the
SwiftUI app built via XcodeGen.

## Completed this session
All built and confirmed working by Stephen, and committed (`c799400`).

- **Message list columns.** Dropped priority, color-label and size (**K**) columns.
  Status + attachment now share **one** leading column headed by Eudora 7's own
  icon art (`EudoraApp/Resources/Assets.xcassets`, sources kept in `assets/`).
- **Column geometry closed up** — see `MessageTableMetrics` in `ContentView.swift`.
- **Row-stepped scrolling**, direction reversed from the system setting; wheel
  magnitude and trackpad momentum ignored so one notch = one row.
- **Remembered view state** (`ViewState.swift`, per Eudora folder): selected
  mailbox, selected message, scroll position; restored selection takes keyboard
  focus. Message stored as a **byte offset**, not a row index.
- **Launch splash** (`SplashWindow.swift`): Eudora 7 about-box art covers the ~6–7 s
  open, main window hidden until the listing is built.
- **Fixed** "Publishing changes from within view updates is not allowed" — List/Table
  selection now goes through deferring bindings (`mailboxSelection` /
  `messageSelection` on AppModel). `loadListing` made idempotent.

## Current state
Nothing half-edited; working tree clean except untracked `SharingFromEudoraMac.txt`
(Stephen's own SMB notes, deliberately not committed). **Two commits are unpushed**
— `451f460` and `c799400`. Claude can't push (no SSH key in its sandbox); Stephen
runs `git push`.

## Next steps
1. **FIRST: removing the K column broke the text columns' horizontal positions.**
   The columns were tuned when the table had 5 columns; K was column 3 and Subject
   was renumbered 3. The `.tableCell(column:)` indices in `MessageListView` were
   updated, but the result is visibly off. Everything lives in `MessageTableMetrics`
   (`ContentView.swift`): `swiftUISpacing` (17), `leadingGlyphInset` (8, column 0
   only), `textHeaderInset` (2, text columns). Diagnostic rule established this
   session: **a constant error across all text columns is an inset; an error that
   grows left-to-right is `swiftUISpacing`.** Ask Stephen for a screenshot — he'll
   give one and the offsets can be measured off it directly (that worked well).
2. Keep testing against `phaseX` with real mail; expect more quirks.
3. Deferred features, none chosen yet: **address book** (`nndbase.txt`), **filters**
   (`filters.pce`), **incremental indexing** (per-mailbox reindex; the FTS5 schema's
   `mailbox` column already supports it), **Text-Encoding override menu** (§5's last
   piece), **compaction** (physically remove ghosts).
4. Small loose ends: splash art is 1x only (needs a 990×544 2x entry to be sharp —
   currently nearest-neighbour filtered); the debounced scroll-position save loses
   the last position if the app quits within 0.4 s; **File ▸ Open** on a running app
   still blocks 6–7 s with no splash.

## Key context / gotchas
- **Build loop**: Claude cannot compile (no Swift toolchain). Write carefully →
  Stephen builds → pastes errors. **Use review agents (general-purpose) for anything
  non-trivial** — they caught, this session alone: two actor-isolation errors that
  wouldn't compile, a retain cycle leaking notification observers, a scroll feature
  that silently overwrote the value it was about to restore, and a restored message
  index that would have selected the *wrong* message after a delete.
- **XcodeGen**: run `xcodegen generate` after adding a file to `EudoraApp/Sources/`,
  then ⌘R. Files in `EudoraMac/` are auto-discovered. **This bit us twice** — once
  when xcodegen ran before the file was written, so mention the ordering explicitly.
- **The SwiftUI/AppKit boundary in `ContentView.swift` is hard-won; don't re-derive
  it.** SwiftUI's `Table` is backed by `SwiftUIOutlineTableView` (an `NSOutlineView`
  subclass — so is the sidebar `List`, which is why `MessageTableFinder`
  discriminates by *column count*, not by type). Headers must be painted via
  `NSTableHeaderCell`; a SwiftUI header is a `Text` and is inset with no opt-out.
  `intercellSpacing` moves headers but *not* SwiftUI's content grid.
- **Splash timing is fragile and was expensive to get right.** Creating an `NSWindow`
  in `App.init` **or** in `applicationDidFinishLaunching` stops SwiftUI from ever
  building its scene — the app runs with no main window and **no console output at
  all**. `App.init` calls `SplashWindow.arm()`, which only registers an observer.
  `SplashWindow.enabled = false` is a one-line kill switch; that's how the bug was
  bisected. Don't reintroduce `CATransaction.flush()` during launch.
- Console noise from `WebContent[…]` (pasteboard/LaunchServices/sandbox) is WKWebView's
  helper process and is **not actionable** — don't chase it.
- `phaseX/` (real mail, multi-GB), `Eudora_*.zip`, `EudoraTestPassword.txt` are
  gitignored; **the repo is public** (`github.com/musanim/eudora-mac`). Claude can
  read `phaseX/` directly to diagnose format bugs — do it, it works well.
- Verify library changes with `cd EudoraMac && swift test`.
- macOS 13 / Swift 5.7 target. Read `design-decisions.md` (esp. §5 charset, §6 search)
  and `eudora-mac-architecture.md`; don't re-debate settled decisions.

The user will likely ask you to **fix the text-column positions broken by removing the
K column** (step 1), after pushing the two pending commits.

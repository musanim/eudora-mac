# Working on Eudora with Claude

Project conventions and hard-won context. `design-decisions.md` and
`eudora-mac-architecture.md` hold the design; this file holds how to work here.

## Asking Stephen questions

**Ask in plain prose, in the normal message flow. Do not use the multiple-choice
question widget** — it doesn't render reliably for him. This applies to every
question, including the ones that would otherwise be a natural fit for it:
clarifying scope, choosing between approaches, confirming a design decision.
Write the options out as ordinary text and let him answer however he likes.

Housekeeping Claude may do without asking: commit Stephen's moves of old
handoffs into `handoffs/archive/`.

## Building

Claude cannot compile: there is no Swift toolchain in the sandbox. The loop is
**write carefully → Stephen builds → he pastes the errors**. Consequences:

- Use review agents (`general-purpose`) for anything non-trivial *before*
  handing it over. They have repeatedly caught real bugs — a listing task with
  no settle delay that would have stacked overlapping 613 MB reads,
  `NSMenu.autoenablesItems` silently overriding a hand-set `isEnabled`, a
  `row(at:)` probe point outside the table's bounds.
- Library changes can be verified for real: `cd EudoraMac && swift test`. Prefer
  putting logic in `EudoraMac/` where it can be tested over `EudoraApp/` where
  it can't.
- After adding a file to `EudoraApp/Sources/`, run `xcodegen generate` — and run
  it *after* writing the file, not before. Files in `EudoraMac/` and new
  imagesets inside `Assets.xcassets` are picked up automatically.

## Diagnosing

Guessing has cost several build round-trips. When behaviour is wrong and the
cause isn't provable from the code, **instrument rather than theorise** — the
codebase keeps its diagnostics (`TableHeaderIconStyler.diagnoseGeometry`,
`TableScrollStateSyncer.Scrolling.diagnose`, `PerfLog`) switched off but intact,
with a comment recording what each one found. Add to that pattern.

For performance specifically: use `sample $(pgrep -x Eudora) 10 -file out.txt`,
not homemade counters. The binary is `Eudora`, not `EudoraApp`. A
`CFRunLoopObserver` at order 0 fires *before* CoreAnimation's commit, so in-app
instrumentation reports an idle main thread while the app is visibly stalling.

## Things that will bite

- **SwiftUI ignores `.keyboardShortcut` inside an in-window `Menu`.** Real
  shortcuts live in `EudoraApp.eudoraCommands`; the ones in `MenuBarView` are
  decorative glyphs. See the comments in both files.
- **SwiftUI builds menus eagerly**, including nested ones, and rebuilds
  context-menu content on every right-click. Any menu over the mailbox tree must
  be AppKit with a `menuNeedsUpdate:` delegate.
- **Anything observing `AppModel` re-renders on every published change.** New
  expensive views should take plain values and be `Equatable`.
- **The SwiftUI/AppKit boundary in `ContentView.swift` is hard-won.** Don't
  re-derive the column geometry, and read `MessageTableMetrics` /
  `MessageColumnWidths` before touching widths or `intercellSpacing`.
- **`phaseX/` is real mail (12 GB) and gitignored; the repo is public.** Claude
  can read it directly to diagnose format bugs, and modelling the parser in
  Python against it has settled several questions outright — the TOC date
  formats, detached-attachment detection, the 6% multipart figure.
- macOS 13 / Swift 5.7 target.

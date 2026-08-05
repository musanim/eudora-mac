# Working on Eudora with Claude

Project conventions and hard-won context. `design-decisions.md` and
`eudora-mac-architecture.md` hold the design; this file holds how to work here.

## Asking Stephen questions

**Ask in plain prose, in the normal message flow. Do not use the multiple-choice
question widget** — it doesn't render reliably for him. This applies to every
question, including the ones that would otherwise be a natural fit for it:
clarifying scope, choosing between approaches, confirming a design decision.
Write the options out as ordinary text and let him answer however he likes.

**Anything he needs to know before running a command goes before the command.**
He reads and acts in order, so a caveat, a question, or an offer placed after a
block of shell arrives too late — he has already run it. Put the question first
and the commands last, or don't ask.

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

## Releasing

`scripts/release.sh` builds, signs, notarizes, staples and packages a
distributable app. Stephen runs it; Claude cannot (no toolchain, and it talks to
Apple). It fails loudly at each gate rather than producing a half-signed app.

Signing lives in `project.yml` and its comments are load-bearing — the
Developer ID fingerprint, the deliberately empty `DEVELOPMENT_TEAM`, and two
**Release-only** settings that exist because notarization rejected the build
without them. Don't move those into `base`.

`EudoraDevelopmentNotes.txt` has the full account, including three separate
Apple certificate types that are easy to confuse and four failures that each
looked like something else.

## Git

**Claude must not run git.** The sandbox cannot unlink files in `.git`, so every
git command — even `git status` — strands a lock file that then blocks Stephen's
own git. Write the commit message to a file and let him run the commit.

Recovery when one has already been stranded, and it is safe once no git process
is running: `rm -f .git/index.lock` (or whichever `.lock` the error names).

`reference/` is gitignored, so it is the place to leave a commit message for him
to pass to `git commit -F` without it turning up in the commit.

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
- **A SwiftUI `List`'s row height answers to exactly two things**, and reaching
  for anything else costs a build: `.listStyle(.plain)` (the sidebar style pins a
  fixed 32 pt row) *and* `defaultMinListRowHeight` applied **inside** the `List`,
  since `List` overwrites that key in its content environment. The AppKit
  `rowHeight`, `usesAutomaticRowHeights`, `intercellSpacing`, `rowSizeStyle` and
  `.listRowInsets` were each measured inert on the sidebar — SwiftUI answers
  `heightOfRowByItem` there — and KVO-pinning the height the way the *message
  table* legitimately does will stack-overflow. See `SidebarRowMetrics`.
- **Passing `self` into a child view is fine for `@ViewBuilder` methods and not
  fine for `@State`.** A write through a view struct a child is holding updates the
  value but doesn't invalidate anything, so the state is correct and the screen
  isn't — a bug no assertion about the model can catch. It cost a sidebar
  disclosure that would open but not close. Resolve state in the owning view's
  `body` and pass plain values down, with a closure made in `body` for writes. See
  `MailboxTree.setExpanded`.
- **Prefer deriving a badge to remembering one.** The In new-mail flag was
  session state cleared by "user engagement" and produced two bugs — cleared by a
  delivery's own selection echo, and lost on quit. Recomputing it from the mail on
  disk during the tree walk deleted both, plus seven other things. See
  `AppModel.inboxNewestIsUnread`.
- **The SwiftUI/AppKit boundary in `ContentView.swift` is hard-won.** Don't
  re-derive the column geometry, and read `MessageTableMetrics` /
  `MessageColumnWidths` before touching widths or `intercellSpacing`.
- **`phaseX/` is real mail (12 GB) and gitignored; the repo is public.** Claude
  can read it directly to diagnose format bugs, and modelling the parser in
  Python against it has settled several questions outright — the TOC date
  formats, detached-attachment detection, the 6% multipart figure.
- macOS 13 / Swift 5.7 target.

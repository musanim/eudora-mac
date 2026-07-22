# Handoff: Eudora (macOS successor) — 2026jul21

Continues `handoffs/Eudora_handoff_2026jul20.md`. **Read `CLAUDE.md` first** — how
to work here, and the one rule above all: **ask Stephen questions in plain prose,
never the multiple-choice widget.**

## Goal
Native macOS email client to replace Windows Eudora 7: reads the existing Eudora
tree in place, mirrors the mailbox layout, matches/beats its search. Security
stance: a **"dumb" client** — no active behaviour a message can trigger.
`EudoraMac/` is a SwiftPM package (EudoraStore / EudoraSearch / EudoraNet);
`EudoraApp/` is the SwiftUI app built via XcodeGen.

## The next task: multi-item selection in the message list
Stephen wants to select several messages at once and act on them together
(delete, move, mark read). **This session decided it deserves its own fresh
context, and here's the scope analysis — don't re-derive it.**

**The Table plumbing is nearly a one-liner.** The list is
`Table(model.rows, selection: model.messageSelection)` in `ContentView.swift`
(~line 1632). `messageSelection` is a `Binding<MessageRow.ID?>` (`AppModel.swift`
~387). SwiftUI's `Table` accepts a `Binding<Set<MessageRow.ID>>` for multi-select
— that part really is just a type change plus a new binding.

**The real work is everything hanging off the single ID:**

1. **`selectedMessageID: MessageRow.ID?` is threaded through ~20 sites** across
   `AppModel.swift`, `ContentView.swift`, `MessageContextMenu.swift` (grep it). It
   becomes a `Set`, and you'll want a notion of a **primary** (last-clicked) for
   the preview pane. Suggest keeping a computed single-ID accessor for the many
   call sites that still act on "the one selected".

2. **Batch delete/move is the hard part — it's the offset-shift bug class this
   codebase keeps fighting.** `MailboxMutator` works by index/offset (see
   `deleteSelected`/`moveSelected` → `currentSelection()` returning a single
   `(item, index)`). Removing one message shifts every later index. A naïve loop
   over the selection corrupts the offsets of the not-yet-processed ones. Delete
   **high-index-to-low**, or resolve to Message-IDs/offsets up front, and re-list
   **once** at the end (not per item). `MailboxReplaceTests` in `EudoraMac` is the
   place to add coverage — it deliberately asserts on the *neighbours* of a
   mutated record, which is exactly what a wrong shift breaks.

3. **`afterRemoval`'s scroll-retention (just written this session) assumes a
   single removed row.** With N removed it needs the min/adjust over the batch.

4. **Preview pane shows one message.** Decide what N-selected shows — Mail shows
   "N messages selected". `PreviewView` / `model.preview` / `loadMessage`.

5. **Right-click + double-click** (`MessageContextMenu.swift`) key off a single
   clicked row. macOS convention: right-clicking inside a multi-selection acts on
   the whole selection; right-clicking outside it selects that one row first.
   `MessageContextMenuController.resolveClickedID` → resolve to a set.

6. **`ViewState` persists one `selectedMessageOffsetByMailbox` per mailbox.**
   Decide what persists — probably just the primary.

**Decisions to put to Stephen (plain prose):** preview with N selected; whether
Reply/Forward apply to a multi-selection or disable; right-click-on-selection
semantics; what persists across relaunch.

## Current state
Working tree **clean**. Four commits made this session, **all unpushed** (origin
is at `f6fb44c`):

- `7f12f09` Fix POP3 UIDL parsing that dropped every incoming message
- `bac6995` Keep the list position when a message is deleted or moved
- `9129f55` Settings dialog: resize to fit, and close on Save
- `9de35b7` Toolbar: settings gear, trim to New/Settings/Delete, Check Mail status

Nothing half-done. `POP3Client.diagnose` is back to `false`. Multi-select is not
started.

## Before you push — sandbox leaves stale git locks
Claude's sandbox can commit but can't delete git's temp lock files afterward, so
`.git/*.lock` files pile up and will block the next `git` command with "Unable to
create '.git/index.lock': File exists." **Run this on the Mac before pushing (or
before any git op):**

```
rm -f .git/HEAD.lock .git/index.lock .git/objects/maintenance.lock
git push
```

## Completed earlier this session (all shipped + committed)
- **POP3 incoming mail finally works.** Root cause was subtle: `uidl()` decoded
  the server reply to a `String` and split on the `Character` `"\n"`, but Swift
  strings are grapheme-cluster sequences and `"\r\n"` is a *single* Character, so
  the split never matched Gmail's CRLF listing — 21 messages collapsed into one
  bogus concatenated UID that got marked "known", so nothing downloaded. Fixed by
  parsing in bytes (`POP3Client.parseUIDL`). A hex dump behind
  `POP3Client.diagnose` is what found it after three wrong theories — **instrument,
  don't theorise** (it's in CLAUDE.md for a reason). New `EudoraNetTests` target;
  `cd EudoraMac && swift test` is green.
  - Along the way: Gmail POP needs the incoming host `pop.gmail.com` (not
    `smtp.gmail.com`), and `recent:stephen.malinowski@gmail.com` as the username
    avoids Gmail's serve-once POP flag. `keychainAccount` folds the username in,
    so changing it rekeys the stored password *and* the `knownUIDs` set — a known
    footgun, noted for later cleanup.
- **⌘M checks mail** (was ⌘⇧M); `MinimizeKeyStripper` clears the duplicate glyph
  from Window ▸ Minimize. (`429f96d`, already pushed.)
- **Splash rebranded to Eudora 8** — stylized gold 8 replacing the 7, "Version
  8…" in the fine print. Original kept as `assets/EudoraSplash7.png` +
  `EudoraSplash.imageset`; new art wired via a new `EudoraSplash8.imageset` and
  `SplashWindow` loads `"EudoraSplash8"`. (`f6fb44c`, already pushed.)
- **Lazy AppKit Move menus + hand-built list/preview divider.** (Prior session's
  commit `f6053f1`.) The divider is a `VStack` with `PaneDividerHandle`, not a
  `VSplitView` — the latter is `NSSplitViewController`-managed and won't give up
  its delegate, so its grab area can't be widened. Divider position persists in
  `@AppStorage`.
- **Settings gear** on the toolbar (template-rendered from `assets/settings.png`;
  its centre "hole" was opaque white, so alpha is derived from darkness).
  **Toolbar trimmed** to New, Settings, Delete — Reply/Forward/Move-to live on the
  menus + right-click; Check Mail is ⌘M now. **Check Mail status** in the centered
  `.principal` toolbar slot.
- **Delete/move keeps the list scroll position** (`afterRemoval` now restores it).

## Key context / gotchas (still current)
- **Build loop**: Claude cannot compile (no Swift toolchain in sandbox). Write
  carefully → Stephen builds → pastes errors. **Use review agents (general-purpose)
  for anything non-trivial before handover** — they caught real bugs every time
  this session.
- **Library changes ARE verifiable**: `cd EudoraMac && swift test`. Put logic in
  `EudoraMac/` (testable) over `EudoraApp/` (not). The multi-select batch-mutation
  logic belongs in / tested against `EudoraStore`.
- **`xcodegen generate`** only after adding a *new source file* to
  `EudoraApp/Sources/`. New imagesets in `Assets.xcassets` and files in
  `EudoraMac/` are picked up automatically.
- **Xcode caches the local package build.** This session, a fixed `EudoraNet`
  wouldn't take until `rm -rf ~/Library/Developer/Xcode/DerivedData` + rebuild.
  If a library fix "isn't taking", that's the cure. A `print` build-marker is a
  cheap way to confirm which binary is actually running.
- **Anything observing `AppModel` re-renders on every published change.** New
  expensive views should take plain values and be `Equatable`.
- **SwiftUI ignores `.keyboardShortcut` inside an in-window `Menu`.** Real
  shortcuts live in `EudoraApp.eudoraCommands`; `MenuBarView`'s are decorative.
- **SwiftUI builds menus eagerly.** Any menu over the mailbox tree must be AppKit
  with a `menuNeedsUpdate:` delegate (see `MoveToMenu.swift` / `MessageContextMenu`).
- **`phaseX/` is real mail (12 GB), gitignored; repo is public.** Claude can read
  it to diagnose format bugs.
- macOS 13 / Swift 5.7. Read `design-decisions.md` and `eudora-mac-architecture.md`;
  don't re-debate settled decisions.

The user will likely ask you to **push the four commits** (after the `rm` above),
then start **multi-item selection in the message list** — begin by putting the
four open design questions (preview, Reply/Forward, right-click, persistence) to
Stephen in plain prose.

# Handoff: Eudora — 2026aug02

## Goal

Eudora 8: a native macOS replacement for Eudora 7 (Windows, under Parallels).
The cutover is **done** — Stephen's real 12 GB tree is live at
`/Users/stephenmalinowski/Eudora` and both POP accounts (gmail, musanim) are
collecting into it. The Aug 14 Parallels deadline is therefore no longer a
threat; work is now ordinary improvement, driven by Stephen using the app daily.

## Completed this session

All of the following are **built and confirmed working by Stephen** unless
marked otherwise:

- **TOC text encoding: CP1252, not Latin-1.** Found because an apostrophe showed
  as `?` in the message list while the reader was correct. Two separate bugs:
  the `.toc` cache was read/written as Latin-1 when Eudora 7 wrote CP1252
  (2,985 fields across the tree display differently now — `™`, `–`, `—`, `…`
  were rendering as invisible C1 controls); and RFC 2047 §6.2 whitespace between
  adjacent encoded-words wasn't being dropped, so a folded subject read
  "developer respo nse". New `CP1252.swift`, edits to `Toc`, `TocWriter`,
  `HeaderDecoder`.
- **mailto: links open a Eudora composer.** `CFBundleURLTypes` in Info.plist,
  new `MailtoLink.swift` (RFC 6068), `AppDelegate.application(_:open:)`,
  `AppModel.handleMailto` / `drainPendingMailtos`.
- **"Make Eudora the default" button** in Settings ▸ Default email app, so the
  handler can be set without opening Mail.app. New `DefaultMailClient.swift`.
  Stephen confirmed it works. Button now *hides* once Eudora is the default
  (his call — a greyed-out button implies a blocked action, and there is none).
- **Message preview pane in the Find window** — NOT YET TESTED. Results table
  above, `PreviewView` below in a `VSplitView`. Selection previews only;
  right-click gives **View in Mailbox**.
- **View in Mailbox centres the message in the list** — NOT YET TESTED.

## Current state

Everything compiles as far as anyone knows — Stephen last built and ran before
the Find-pane work. `swift test` passed at the CP1252 stage. The last two items
above (**Find preview pane** and **centred reveal**) are written, reviewed, and
**not built or run by Stephen yet**. He said he'll be using the feature and will
report back if it's wrong.

Uncommitted work has accumulated since commit `29100f4` — a large pile. Stephen
runs the commits himself; a suggested message is at the bottom of this file.

## Next steps

1. **Ask whether the Find preview pane and centred reveal work.** If not, the
   most likely failure points, in order: the centred scroll geometry (see Key
   context), `.contextMenu(forSelectionType:)` not firing, and
   `MailStore.message(at:offset:)` truncating a long message at a chunk
   boundary.
2. **`swift test`** — `MailStore.message(at:offset:)` is new library code with
   no tests yet. Worth adding some against `phaseX/` or a fixture: a message at
   a 64K/320K boundary is the case that matters.
3. Nothing else is queued. Stephen drives.

## Key context

**How to work here.** Read `CLAUDE.md` first — it is short and every line was
paid for. The essentials: **ask questions in plain prose, never the
multiple-choice widget**; Claude cannot compile (no Swift toolchain), so the
loop is write carefully → Stephen builds → he pastes errors; **use
`general-purpose` review agents before handing anything over** — they caught
real bugs in every single feature this session, including two that would have
shipped broken today.

**`swift test` works** for anything in `EudoraMac/`. Prefer putting logic there.

**`xcodegen generate`** is needed after adding a file to `EudoraApp/Sources/`.
Two new files this session (`DefaultMailClient.swift`, and earlier
`TreeLock.swift`) — Stephen has run it since, but confirm if a build fails with
"cannot find X in scope".

**Do not run git.** The sandbox cannot unlink files in `.git`, so every git
command strands a lock file — even `git status`. Write the commit message and
let Stephen run it.

**The scroll geometry in `ContentView.swift` is the most dangerous code in the
app.** `Scrolling.originY(forTopRow:)` **clamps** its result; the new
`originY(forCenteredRow:)` therefore uses the *unclamped* helper and clamps
once at the end. Getting that wrong scrolls the row off the bottom for anything
in the last screenful. The clip view has a **28 pt top content inset** (the
column header floats over it) and a read/write pair of this geometry has
already drifted apart once — hence one implementation of the clamp.

**`pendingMessageID` has two callers with opposite needs**: `openHit` (an
explicit jump, wants centring) and the launch-time restore (wants the remembered
scroll position, and must not be recorded over). `pendingMessageIsExplicitJump`
distinguishes them. If a mailbox stops coming back at the bottom after a
relaunch, that flag is why.

**Known and deliberate, don't "fix" without asking:**

- If Eudora is launched **from Xcode**, a mailto: click starts a second copy
  that the single-instance guard kills before the URL event is delivered — the
  link does nothing. Launching from Dock/Finder is fine. Stephen has an open
  question here: whether pointing Mail's default-reader at the *DerivedData*
  bundle makes the Xcode-run copy receive the event. Untested; the Settings
  pane now shows the registered handler's full path, which is the diagnostic.
- `splitAddresses` is not quote-aware, so a display name with a comma coming in
  from a mailto: link is reduced to its bare address.
- Some legacy TOC entries hold mojibake Eudora 7 itself stored (`Lionâ€™s`).
  Not repairable; not this bug.

**`EudoraDevelopmentNotes.txt`** (gitignored) is the running to-test record and
is long. Every feature this session has a section with a "To test" list.
Stephen reads it; keep appending in the same style.

The user will likely ask you whether the Find window's preview pane and the
centred "View in Mailbox" behave — and if they don't, to diagnose rather than
guess. This codebase's rule is to **instrument rather than theorise**; there are
dormant diagnostics (`Scrolling.diagnose`, `TableHeaderIconStyler
.diagnoseGeometry`, `PerfLog`) kept switched off but intact for exactly that.

---

## Suggested commit message

```
CP1252 side-files, mailto: handling, and a Find-window preview pane

Read and write the .toc's cached who/subject columns as CP1252 rather
than Latin-1. The two encodings differ exactly where mail's typography
lives (0x80-0x9F: curly quotes, dashes, ellipsis, trademark), so Eudora 7
subjects were rendering their punctuation as invisible C1 controls, and
newly delivered mail had its curly apostrophes written out as '?'. 2,985
fields across the real tree display differently. Also drop the whitespace
between adjacent RFC 2047 encoded-words, which was turning a folded
subject into "developer respo nse".

Register as the system mailto: handler and open a composer for incoming
links, parsing them per RFC 6068 — honouring only to/cc/subject/body,
naming what was refused, and folding CR/LF to a space so a link cannot
inject a header. Add a Settings button that sets the handler directly,
so this doesn't require opening Mail.app and letting it adopt live POP
accounts mid-cutover.

Add a message preview pane to the Find window, reusing PreviewView via a
new Source enum so there is one renderer rather than two. Selecting a
result now only previews it; "View in Mailbox" moved to a right-click,
and centres the message in the list instead of letting the mailbox's
remembered scroll position land the selection off screen.

New MailStore.message(at:offset:) reads a message by byte offset instead
of scanning the whole .mbx, which is what made previewing search hits
affordable on a 612 MB mailbox.
```

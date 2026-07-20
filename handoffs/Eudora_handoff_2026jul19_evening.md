# Handoff: Eudora (macOS successor) — 2026jul19 evening

Continues `handoffs/archive/Eudora_handoff_2026jul19.md` (same day, earlier). That
session's step 1 — fixing the text-column positions — was done first; the rest of
this session was **detached attachments, row icons, hierarchical Move menus, and
a long performance investigation**. Stephen is using the app against his real
12 GB tree, so everything now has to survive Trash: 613 MB, 22,515 messages.

## Goal
Native macOS email client to replace Windows Eudora 7: reads the existing Eudora
tree in place, mirrors the mailbox layout, matches/beats its search. Security
stance: a **"dumb" client** — no active behavior a message can trigger.
`EudoraMac/` is a SwiftPM package (EudoraStore / EudoraSearch / EudoraNet);
`EudoraApp/` is the SwiftUI app built via XcodeGen.

## Completed this session
All built and confirmed by Stephen. Five commits, **all unpushed** (`git push`).

- **`895f0ee` Column alignment.** The two-states bug from the last handoff. Cause:
  `intercellSpacing` was set to 0 from an async callback, *after* SwiftUI had laid
  out. AppKit's headers collapsed, SwiftUI's content didn't, and −17×i offsets
  were added to compensate — which then became pure error the moment a resize made
  SwiftUI re-read the spacing. Fixed by **not touching `intercellSpacing` at all**;
  both sides stay on the 17 pt grid and the residue is a flat inset (6 pt glyph
  column, 8 pt text). Column widths are now fixed (`MessageColumnWidths`) and
  pinned on both sides, because each side otherwise negotiated flexible widths
  independently and disagreed.
- **`6334457` Bodies from lying multipart headers.** Messages showed "(no text
  body)" — Eudora often strips the MIME structure, keeps one alternative as a bare
  body, and leaves the `multipart/…` header in place. The part reported multipart
  with no children, and *every* consumer skips multipart nodes. Fixed in
  `MIMEParser`, so it repaired the reader **and** the search index, which had been
  indexing no body text for those. **6% of the tree** (2,226 of 37,030 messages).
- **`875ffe6` Detached attachments.** Eudora writes received attachments to its
  `Attachments` folder and leaves `Attachment Converted: "…"` in the body, so
  nothing had a MIME attachment to find. Worse, the parser was *discarding* those
  bytes (they follow `</x-html>`, and `EudoraBody.between` returned only what was
  between the tags) — now kept in `MIMEPart.eudoraTrailer`. Shown after the body
  with Reveal in Finder / Save a Copy / View.
- **`7411573` Hierarchical Move menus**, mirroring the sidebar.
- **`53b00de` Responsiveness** — the big one, see below.

Also: row icons (Stephen's `Unread.png` / `attachment.png`, alpha added by
`assets/make-row-icons.py`), and Arial in the lists (`EudoraFont`).

## Performance: what was actually wrong
Stephen's list was (1) make the UI fast even when updates are slow, (2) make
"in progress" obvious, (3) speed things up. **Only (1) is done.**

Three separate causes, none of them the one we assumed:

1. **Everything ran on the main thread.** `MailStore.message(at:index:)` reads the
   whole `.mbx`, copies it to `[UInt8]` and re-scans it — *per selection*. Now:
   listing is TOC-first with a background enrichment pass; preview renders off the
   main actor after a 150 ms settle. Both cancellable, guarded by
   `listingGeneration`.
2. **The toolbar's Move menu.** 39% of wall time in `NSToolbarItemViewer` layout,
   building 2,657 items on every mailbox click — because the menu's content
   depended on `selectedMailboxID`. Fixed by removing that dependency + an
   `Equatable` wrapper on `treeVersion`. The sidebar `OutlineGroup` got the same
   treatment (it rebuilt all 2,723 nodes on *any* published change).
3. **The right-click menu, ~4 seconds.** Same eager-menu problem, but `Equatable`
   can't help — context-menu content is built fresh each time. Now a native
   `NSMenu` with lazy submenus (`MessageContextMenu.swift`).

## Next steps
1. **Performance part 2: make "in progress" obvious.** `isListing`,
   `isEnriching`, `isLoadingPreview` are published on AppModel and **nothing reads
   them** — so a slow mailbox currently looks like nothing happening, which is
   arguably worse than the old freeze. Stephen asked for: the preview pane blank
   (with a busy indicator) until the new message renders, and the spinning-wait
   cursor for anything past the system delay.
2. **Performance part 3: actually speed it up.** The known big one:
   `buildListing` on Trash was still running after 10 s with a **3.0 GB** process
   footprint — `Data(contentsOf:)` plus a `[UInt8]` copy is ~1.2 GB per pass.
   Memory-map instead, and cache the record offsets per mailbox; that removes the
   O(file) cost from listing, preview, reply/forward and `openHit` at once.
   `Bytes.find` is also a naive byte-at-a-time scan over 613 MB.
   Still on the main thread: `selectedPart()` (reply/forward) and
   `indexOfRecord` in `openHit`.
3. **Column sorting** — click a header to sort, click again to reverse. Not
   started. Note the `Table` currently has no `sortOrder` binding, which is what
   lets `clickedRow` map straight into `model.rows`; adding sorting means the
   context menu's row→id mapping must follow the *displayed* order.
4. Deferred, none chosen: address book (`nndbase.txt`), filters (`filters.pce`),
   incremental indexing, Text-Encoding override menu, compaction.
5. Small: splash art is 1x only; **File ▸ Open** on a running app still blocks;
   the search index needs a manual **Tools ▸ Rebuild Search Index** to pick up the
   bodies recovered by `6334457` (`hasCurrentSchema()` only checks columns exist —
   stamping an indexer version would make that automatic).

## Key context / gotchas
- **Build loop**: Claude cannot compile (no Swift toolchain). Write carefully →
  Stephen builds → pastes errors. **Use review agents (general-purpose) for
  anything non-trivial** — this session they caught, among others: a listing task
  with no settle delay that would have stacked overlapping 613 MB reads;
  `markSelected` re-listing and discarding all enrichment; `open()` not cancelling
  in-flight work, letting a previous tree's rows install themselves; and
  `NSMenu.autoenablesItems` silently overriding a hand-set `isEnabled`.
- **XcodeGen**: run `xcodegen generate` after adding a file to `EudoraApp/Sources/`
  — *after writing it*. This bit us twice more this session, once because
  xcodegen ran seven minutes before the file was created. Files in `EudoraMac/`
  and new imagesets inside `Assets.xcassets` are picked up automatically.
- **Profiling: use `sample`, not homemade counters.** In-app instrumentation kept
  reporting "main thread idle, 0 ms turns" while the app plainly stalled, because
  a `CFRunLoopObserver` at order 0 fires *before* CoreAnimation's commit (order
  2000000) — which is where AppKit and SwiftUI lay out and draw. Two rounds were
  lost to that. `sample $(pgrep -x Eudora) 10 -file out.txt` (app must already be
  running; the binary is `Eudora`, not `EudoraApp`) found each real cause in one
  shot. `PerfLog` survives in `AppModel.swift`, `enabled = false`.
- **SwiftUI builds menus eagerly**, including nested ones, and rebuilds
  context-menu content on every right-click. Any menu over the mailbox tree must
  be AppKit with a `menuNeedsUpdate:` delegate. Also: **assigning
  `NSTableView.menu` does nothing** — SwiftUI's table subclass owns that
  machinery; `MessageContextMenu.swift` intercepts the event instead.
- **Anything that observes `AppModel` re-renders on *every* published change.**
  That is what made the sidebar and toolbar expensive. New expensive views should
  take plain values and be `Equatable`.
- **The SwiftUI/AppKit boundary in `ContentView.swift` is hard-won; don't
  re-derive it.** `Table` is backed by `SwiftUIOutlineTableView` (an
  `NSOutlineView` subclass — so is the sidebar `List`, hence `MessageTableFinder`
  discriminates by *column count*). Headers must be painted via
  `NSTableHeaderCell`.
- **Splash timing is fragile.** Creating an `NSWindow` in `App.init` or
  `applicationDidFinishLaunching` stops SwiftUI building its scene entirely.
  `SplashWindow.enabled = false` is the kill switch. It now hides from
  `loadListing`'s completion (rows are no longer built synchronously), with a 10 s
  backstop.
- **git**: Claude's sandbox could not delete files under the mount, so every git
  command left an `index.lock` behind. Fixed mid-session by granting delete
  permission for the folder; if `Operation not permitted` reappears in a new
  session, that's why — one approval clears it.
- Console noise from `WebContent[…]` is WKWebView's helper and **not actionable**.
- `phaseX/` (real mail, 12 GB), `Eudora_*.zip`, `EudoraTestPassword.txt` are
  gitignored; **the repo is public** (`github.com/musanim/eudora-mac`). Claude can
  read `phaseX/` directly to diagnose format bugs — it worked well repeatedly this
  session (verifying detached-attachment detection at 18/18, and the 6% multipart
  figure, by modelling the parser in Python).
- Verify library changes with `cd EudoraMac && swift test`.
- macOS 13 / Swift 5.7 target. Read `design-decisions.md` (esp. §5 charset, §6
  search) and `eudora-mac-architecture.md`; don't re-debate settled decisions.
- Untracked and deliberately so: `SharingFromEudoraMac.txt`,
  `EudoraDevelopmentNotes.txt` (Stephen's own notes).

The user will likely ask you to **finish the performance work — part 2 (progress
indication) then part 3 (memory-map and cache the record offsets)** — and then to
**make the message-list columns sort on a header click**.

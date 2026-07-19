# Handoff: Eudora (macOS successor) — 2026jul16

Continues `handoffs/Eudora_handoff_2026jul15_evening.md`. That session's plan was
image/link handling **or** keep designing; this session **implemented image/link
handling** (design-decisions §1–§3) and fixed a long code-signing problem. Next
up, by Stephen's choice: **wire Search into the app** — the headline "beat
Eudora" feature, whose index is already built & tested but not yet in the UI.

## Goal
Native macOS email client to replace Windows Eudora 7 for Stephen: reads existing
Eudora data files in place, mirrors the mailbox layout, matches/beats its search.
Built & tested against a **synthetic fixture** (`phase0/sample-tree`), not real
mail, until trusted. Guts written fresh in Swift. Security stance: a **"dumb"
client** — no active behavior a message can trigger (no remote fetch, no scripts,
no auto-nav, no auto-open).

## Completed this session
- **Image/link handling (design-decisions §1–§3) — built, reviewed, not yet
  Stephen-tested against real HTML mail.** New `EudoraStore/BodyRenderer.swift`
  rewrites every `<img>` in HTML mail into a text box:
  - remote `http(s)` → skull box `☠ blocked remote image` (an `<a href>` to the
    real URL; **never fetched**),
  - `cid:` / `data:` / embedded (bytes present) → `IMAGE [view]` box linked on a
    private `eudora-image:<id>` scheme,
  - unresolvable → `image unavailable`.
  Bytes ride in `MessagePreview.images: [String: EmbeddedImage]`.
- **`WebView.swift` reworked** — nav delegate now allows **only** the initial
  in-memory load and cancels everything else (a review caught that the old
  fall-through `.allow` let a crafted `<meta refresh>` reach a CSP-less document
  and fire a tracking pixel). A deliberate link click copies the **true** URL
  (not anchor text) + shows a banner; `eudora-image:` clicks open a native
  viewer; right-click menu trimmed to Copy Link; CSP tightened to `img-src 'none'`.
- **`ImageViewerWindow.swift`** (new) — native NSWindow sized to the image
  (capped to screen, scroll + magnify), **Save As…** on right-click.
- **Tests** — `EudoraStoreTests/BodyRendererTests.swift` (6 cases): remote→skull,
  cid→view+bytes, data→view, unresolvable, attribute escaping.
- **Two review agents** run per the usual loop; both findings fixed (the
  nav-delegate hole above, and a `@MainActor` call from the delegate now wrapped
  in `Task { @MainActor }`).
- **Type rename** — my `ImageResource` collided with the SDK's auto-generated
  `DeveloperToolsSupport.ImageResource` on Stephen's Xcode → renamed to
  **`EmbeddedImage`** everywhere.
- **Code signing fixed** (`project.yml`) — ad-hoc `"-"` gave a new signature every
  build, so the Keychain "Always Allow" for the SMTP password never stuck and
  re-prompted each launch. Now signs by **SHA-1 fingerprint** of the existing
  "Apple Development: stephen@musanim.com" cert
  (`D493F1004F5E3E7A3C1A3912E00D9922C411A402`), `DEVELOPMENT_TEAM: ""`,
  `PROVISIONING_PROFILE_SPECIFIER: ""`. This sidesteps team/account validation
  (that Apple ID isn't signed into Xcode ▸ Accounts, which broke both automatic
  and name+team manual signing). **Confirmed working by Stephen.** If the cert is
  renewed, re-run `security find-identity -v -p codesigning` and paste the new
  hash.

## Current state
Everything above compiles and runs on Stephen's Mac; the app builds green and he
just confirmed the signing fix. Nothing is half-edited. Search is **not started**.

## Next steps — wire Search into the app
1. Read `EudoraMac/Sources/EudoraSearch/SearchIndex.swift` and `Content.swift`
   first. The API is ready:
   - `SearchIndex(path:)` — opens/creates the FTS5 DB.
   - `rebuild(from: MailStore)` — (re)indexes a whole tree.
   - `search(_ query:, limit:) -> [SearchHit]` — FTS5 MATCH, ranked by bm25,
     returns `snippet(...)`.
   - `SearchHit` = `mailbox, offset, date, subject, snippet`.
2. Decide the UX with Stephen (this is a "you talk, I listen" area — confirm
   before building): where the search field lives (toolbar? the in-window
   `MenuBarView`?), whether results replace the message-list pane or open a
   dedicated results view, live-as-you-type vs. return-to-search, and where the
   index file lives (per-tree, e.g. under the Eudora root or app support).
3. Add an `AppModel` path: build/open the index for the opened tree, run queries,
   publish `[SearchHit]`, and **open a hit** on selection.

## Key context / gotchas
- **`SearchHit` gives `mailbox` + byte `offset`, but `MailStore.message(...)`
  takes a 1-based `index` within a mailbox, not an offset.** Opening a hit needs a
  mapping. Options: add a `MailStore.message(mailbox:, offset:)` that finds the
  record whose `MboxRecord.offset == offset`, or index the 1-based position into
  the FTS row instead of/alongside offset. Check `MailStore.list(...)` /
  `MboxRecord` for the offset↔index relationship before choosing.
- **When to (re)build the index?** `rebuild(from:)` is a full pass. For now a
  build-on-open or an explicit "Rebuild index" command is fine; incremental
  update on Check Mail / delivery is a later refinement.
- **Same build loop as always: Claude can't compile in the sandbox** (no `swift`
  on Linux; the Network-framework targets are macOS-only). Write Swift carefully →
  Stephen builds & pastes errors → fix. Use **two `general-purpose` review
  agents** per big feature before he builds; it keeps catching real bugs.
- **XcodeGen:** run `xcodegen generate` after adding ANY new source file (it
  writes an explicit file list — no auto-sync), then ⌘R on the **EudoraApp**
  scheme. Source-only edits just need ⌘R.
- **macOS 13 / Swift 5.7 target.** Watch newer-API traps (already hit:
  `.textContentType(.emailAddress)` and `SettingsLink` are 14+; the SDK's
  `ImageResource` symbol forced this session's rename).
- Project at `~/ClaudeProjects/Eudora`. Read `eudora-mac-architecture.md`,
  `EudoraApp/README.md`, and `design-decisions.md` (image/link §1–§3 now marked
  **[done]**) first. Don't re-debate settled decisions.

The user will likely ask you to **wire the EudoraSearch FTS5 index into the app**
— confirm the search UX with him before building, and remember he tests every
change himself against the fixture / his gmail.

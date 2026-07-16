# Handoff: Eudora (macOS successor) — 2026jul15 (evening)

Continues the morning handoff (`handoffs/Eudora_handoff_2026jul15.md`, Phases 0–2).
A lot shipped this session: the app now sends and receives real mail.

## Goal
Native macOS email client to replace Windows Eudora 7 for Stephen: reads existing
Eudora data files in place, mirrors the mailbox layout, matches/beats its search.
Everything is built and tested against a **synthetic fixture** (`phase0/sample-tree`),
not real mail, until it's trusted for a year or two. Guts written fresh in Swift.

## Completed this session (Phase 3 + compose/send + management + receive)
All of the below compiles and runs on Stephen's Mac. **SMTP send and POP3 receive
were both verified live against his gmail.com account** (isolated from the real
musanim.com addresses).

- **Phase 3 GUI** — SwiftUI app target `EudoraApp`, delivered as an Xcode project via
  an **XcodeGen** spec (`project.yml`). Classic Eudora layout: mailbox tree (left) +
  `VSplitView` with message list (top) over preview (bottom). Full Eudora column set
  (status glyph, priority chevrons, attachment paperclip, label placeholder, Who,
  Date, Size K, Subject); "Who" and attachment come from parsing since the fixture's
  `.toc` caches the recipient on every incoming msg. HTML mail in a locked-down
  WKWebView (JS off, strict CSP, remote blocked). Folder choice persists (UserDefaults).
- **Compose & send** — `EudoraNet` target: hand-rolled SMTP over NWConnection,
  **implicit TLS 465 only**. RFC-822 assembly (`MessageBuilder`), QP encode, RFC-2047
  headers. New/Reply/Reply-All/Forward. Sent mail written back to `Out.mbx`
  (`Outbox.append`) with backup + atomic + `.toc` rails. Account settings + Keychain.
- **Message management** — delete (= move to Trash; permanent if already in Trash),
  move to any mailbox, mark read/unread. `MailboxMutator` + `MailboxIO` + `TocWriter`.
  Toolbar, in-window menu, and right-click context menu.
- **In-window menu bar** (`MenuBarView`) — Windows-Eudora style, all nine menus
  (File/Edit/Mailbox/Message/Transfer/Special/Tools/Window/Help) rendered *inside* the
  window (Stephen works on a huge display, hates reaching the top menu bar). Unbuilt
  features are greyed placeholders. System menu bar stripped to near-minimum.
- **POP3 receiving** — `POP3Client` over NWConnection implicit TLS 995. Check Mail
  (toolbar / File ▸ Check Mail / ⇧⌘M) fetches new mail by UIDL into In as unread
  (`Delivery.deliverIncoming`). Per-account seen-UID tracking; optional delete pass
  runs **only after** local write, defaults **off** (leave-on-server).
- **Design decisions recorded** (`design-decisions.md`) — see Next steps.

## Current state
Everything builds green and both mail directions work live. We spent the back half of
the session on **security/rendering design** (Stephen "you talk, I listen"), and
recorded the decisions in `design-decisions.md` — NOT yet implemented. Stephen got
tired and wants to stop; nothing is half-edited. Last file created:
`design-decisions.md`.

## Next steps
Two directions; let Stephen choose.

1. **Implement the recorded design decisions** (`design-decisions.md`), roughly in
   order of his enthusiasm:
   - **Image handling**: every body image → compact box. Embedded/`cid:`/`data:`/
     attachment images (bytes present) → `IMAGE [view]` box → click opens a native
     window sized to the image → right-click **Save As…**. **Remote** images → an
     unviewable **skull/blocked** box, never fetched, but with a **Copy URL** action
     (same affordance as links). Implement the box as a link on a private
     `eudora-image:<part-id>` scheme caught by the existing nav delegate — no JS.
   - **Links**: no navigation ever; right-click trimmed to **Copy Link**, left-click
     copies with confirmation; always surface the **true** URL, not anchor text.
   - **Plain-text-by-default** toggle (candidate).
   - **Charset**: full IANA coverage via `CFStringConvertIANACharSetNameToEncoding`;
     prefer Windows-1252 for ambiguous single-byte (keep Latin-1 as never-fail);
     per-message Text-Encoding override menu; RFC 2231 filenames.
2. **Keep designing** other subsystems (attachments proper, filters `filters.pce`,
   address book `nndbase.txt`) — each has "how should it behave" questions.

Also deferred (not urgent): **Search** UI (the `EudoraSearch` FTS5 index is built &
tested, just not wired into the app — this is the headline "beat Eudora" feature);
**STARTTLS / port 587** for SMTP (NWConnection can't upgrade a plaintext socket, so
it's a real chunk — only needed if a server lacks 465; check musanim's SMTP);
Empty Trash; attachment open/save; prune the seen-UID list.

## Key context
- **Project at `~/ClaudeProjects/Eudora`.** Package `EudoraMac/` (targets: EudoraStore,
  EudoraSearch, EudoraNet, eudora-spike CLI). App target `EudoraApp/` built from
  `project.yml`.
- **Build:** `xcodegen generate` (needed after ANY new source file — XcodeGen writes an
  explicit file list, no auto-sync), then open `EudoraApp.xcodeproj`, select the
  **EudoraApp** scheme (a shared scheme is pinned in project.yml), ⌘R. Source-only
  edits just need ⌘R, no regenerate.
- **I (Claude) can't compile in the sandbox.** The loop: write Swift carefully →
  Stephen builds and pastes errors → fix. Two independent `general-purpose` review
  agents were used per big feature to catch compile/logic bugs before he builds; keep
  doing that — it caught real issues (e.g. the toc-less status-clobber, the UID
  re-download bug).
- **Deployment target macOS 13**, Swift 5.7. Watch for newer-API traps (already hit:
  `.textContentType(.emailAddress)` is 14+, and `SettingsLink` is 14+ — there's a
  `SettingsButton` wrapper that uses SettingsLink on 14+ and a selector fallback on 13).
- **Gmail test setup** (Stephen's, works): SMTP `smtp.gmail.com:465` SSL; POP
  `pop.gmail.com:995` SSL; username = full gmail address; password = a 16-char Google
  **App Password** (requires 2-Step Verification; NOT the normal password — "less
  secure apps" ended May 2025). POP must be enabled in Gmail settings.
- **Write-back safety stance (preserve it):** `.mbx` is truth, `.toc` is a rebuildable
  cache. Every mailbox write = one-time `<name>.mbx.bak` backup + temp-write + atomic
  rename. The `.toc` is only rewritten when it was a *valid* cache; if not (e.g. the
  toc-less `Projects/Music` fixture), it's dropped so the reader rescans — never
  fabricate status for other messages.
- **Unvalidated-against-real-data caveats** (from morning handoff, still true): the
  `.toc` 104/218-byte struct layout and descmap TypeChars are reverse-engineered /
  approximated, self-consistent with the fixture but not field-checked against a real
  Eudora file. Fine for the fixture (regenerate with `phase0/make_fixture.py`); revisit
  before pointing write-back at real mail.
- **Security philosophy Stephen cares about:** a "dumb" client — no active behavior a
  message can trigger. No remote fetches, no scripts, no auto-open. He explicitly wants
  remote images unviewable (skull) with no "load anyway" path. See `design-decisions.md`.
- Read `eudora-mac-architecture.md`, `EudoraApp/README.md`, and `design-decisions.md`
  first. Don't re-debate settled decisions.

The user will likely ask you to **implement the image/link handling from
`design-decisions.md`** (or continue design). Confirm which, and remember he tests
every change himself against the fixture / his gmail.

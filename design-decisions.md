# Eudora (macOS successor) — Design Decisions

Recorded design decisions that aren't yet (fully) built. These capture intent
agreed with Stephen so the implementation, when it happens, matches the plan.
Companion to `eudora-mac-architecture.md`.

Status legend: **[done]** implemented · **[partial]** partly implemented ·
**[planned]** agreed, not yet built.

---

## Guiding principle: a "dumb" client

Email is attacker-controlled input that we render and act on. The safest client
has **no active behavior that a message can trigger**: no scripting, no
auto-loaded remote content, no auto-navigation, no auto-open. *You* act; the
mail doesn't. Old Eudora was safe partly by age/obscurity; we rebuild the
*principled* version of that — small, dependency-free, no active content — which
doesn't rely on nobody bothering to attack it.

---

## 1. Links in HTML mail — display, never navigate

A URL in an `<a href>` renders normally (blue, underlined) but **clicking never
navigates the client anywhere**. Instead:

- **Right-click** shows a trimmed context menu whose main action is **Copy
  Link** — WebKit's default "Open Link / Open in New Window" items are removed.
- **Left-click** copies the URL (with a brief "Link copied" confirmation)
  rather than opening it.
- The **true destination URL** is always what's surfaced/copied — never the
  anchor text — because deceptive link text (text says one thing, `href` goes
  elsewhere) is the classic phishing move.

The user then pastes into a browser (or wherever) deliberately, having seen
where it really goes.

Status: **[done]** — the render view refuses navigation (JS off, strict CSP,
and the nav delegate now allows *only* the initial in-memory load, cancelling
everything else so no message can auto-navigate). A deliberate left-click on a
link copies its **true destination URL** (`navigationAction.request.url`, not
the anchor text) and shows a "Link copied: …" banner; the right-click menu is
trimmed to **Copy Link** (Open/Open-in-New-Window/Download/Reload/Back/Forward/
Share removed). See `WebView.swift`.

---

## 2. Remote content & remote images — never fetched

No remote resource is ever loaded from a message: no remote images, CSS, fonts,
or scripts. This kills **tracking pixels** (the remote 1×1 image whose loading
silently tells a sender the mail was opened, when, and from what IP) and removes
a large class of "smarts that can be appropriated."

Specifically for **remote images**:

- They are **replaced with an unviewable placeholder** — a skull-and-crossbones
  / "blocked remote image" box. There is deliberately **no "load anyway"**
  path: removing the mechanism removes the attack surface entirely.
- A remote image **cannot be "viewed"**, because its bytes are not in the
  message — viewing would require the very fetch we refuse.
- **But** the client provides a way to **copy the image's URL** (the same
  copy affordance as `<a href>` links in §1), so the user can do something with
  it by choice — inspect it, open it in a dedicated tool — on their own terms,
  never automatically.

Status: **[done]** — `BodyRenderer` rewrites every remote `<img>` into a styled
skull box (`☠ blocked remote image`), and the CSP is tightened to
`default-src 'none'; img-src 'none'; style-src 'unsafe-inline'; font-src 'none'`
(no `img-src data:` anymore — data-URI images become view boxes too, §3). The box
is an `<a href>` to the real remote URL, so left-click copies that URL (same
affordance as §1 links) with **no fetch** — there is deliberately no "load
anyway" path.

---

## 3. Embedded / attached images — compact box, view on demand

Images the sender actually included (embedded `cid:` parts inside
`multipart/related`, `data:` URIs, or image attachments) have their bytes in the
message, so they can be shown with **zero network** and no tracking. The user
doesn't want them rendered inline (email should stay compact, and images are
better studied in a real viewer). So:

- Each such image appears in the body as a small box labeled **`IMAGE [view]`**.
- Clicking **view** opens a **native window sized to the image** (capped to the
  screen, with scroll/zoom for very large images).
- **Right-clicking** that window offers **Save As…** (writes the image bytes via
  a save panel).
- Images that arrived as real attachments also appear in the attachment area;
  both point at the same bytes.

Implementation note: the box is a link on a private URL scheme (e.g.
`eudora-image:<part-id>`) that the existing navigation-catcher intercepts — **no
JavaScript required**. It resolves the `cid:`/part reference to the local MIME
part and opens the native viewer.

Rationale it fits the user: legit "please study this" images travel embedded or
attached (→ viewable), while junk-mail imagery is remote (→ skull, §2). The box
just labels which is which.

Status: **[done]** — `BodyRenderer` resolves `cid:` parts (by Content-ID) and
`data:` URIs to their bytes, replacing each with an `IMAGE [view]` box linked on
the private `eudora-image:<id>` scheme (no JS). The nav delegate intercepts a
click on that scheme and opens `ImageViewerController` — a native window sized to
the image (capped to screen, scroll + magnify), with **Save As…** on right-click.
Image bytes ride along in `MessagePreview.images`.

**Attachment subsystem — [done, pending Stephen's build/test].** Every attachment
now rides through `MessagePreview.attachments` as a `MessageAttachment` (bytes +
sanitized name + MIME), shown in the preview header as chips (name + size). Per
the dumb-client stance the only action is **Save As…** (`NSSavePanel` → write
bytes) — deliberately **no open-in-default-app**, so a message can never launch
or execute anything. Image attachments additionally offer **View** into the same
safe native viewer (`ImageViewerController`) used for embedded images. Filenames
are RFC-2047-decoded then stripped of path separators/control chars before use as
a Save default. See `AttachmentActions.swift`, `AttachmentChip` in
`ContentView.swift`, and `AppModel.attachment(from:index:)`.

---

## 4. Plain text by default (candidate)

When a message is `multipart/alternative` with both `text/plain` and
`text/html`, prefer showing the **plain-text** part, with "Show HTML" as an
explicit per-message choice. For the common case this means **no rendering
engine runs at all**, and no images (remote or embedded) render until HTML is
chosen — the safest resting state. Closest to classic Eudora's feel.

Status: **[planned / candidate]** — not yet decided as the hard default.

---

## 5. Character encoding — tolerant, complete, overridable

Old mail is "charset soup": bodies honestly-labeled Latin-1, bodies labeled
Latin-1 that are really Windows-1252, undeclared UTF-8, and international
encodings — with labels that often lie. The plan:

- **Full coverage:** map the IANA charset name via CoreFoundation
  (`CFStringConvertIANACharSetNameToEncoding`) instead of a hand-written switch,
  so every labeled encoding the OS knows (all ISO-8859-*, the Windows-125x
  family, Shift-JIS/EUC-JP/ISO-2022-JP, GB2312/Big5, KOI8-R, Mac Roman, …)
  decodes correctly. *(Today only a handful are handled.)*
- **Smarter single-byte guess:** when something is labeled `iso-8859-1` or is
  unlabeled, prefer **Windows-1252** (it renders the smart quotes / em-dashes /
  ellipses that real Western mail put in the 0x80–0x9F range), while keeping
  true Latin-1 as the **never-fail** backstop (Latin-1 maps every byte; 1252 has
  a few undefined slots).
- **Repair obvious lies:** keep detecting "declared single-byte but actually
  valid UTF-8" and decoding as UTF-8, recording a note.
- **Never fail:** decoding always yields *something* readable, with a note —
  never a crash or a throw.
- **Transparency + override:** show which decoding was chosen and offer a
  per-message **Text Encoding** menu to re-decode when a message comes out
  wrong (essential for a decades-old archive with genuinely ambiguous cases).
- **Header/filename hardening:** RFC 2047 encoded-word edge cases (adjacent
  words, exotic charsets) and **RFC 2231** for non-ASCII attachment filenames.
- **Outgoing stays UTF-8** (or ASCII when possible) — the one place we choose
  rather than guess, and already better than Eudora's hardcoded Latin-1.

Status: **[partial → mostly done, pending Stephen's build/test]** — the tolerant
decoder, UTF-8-mislabel repair, never-fail Latin-1 fallback, RFC 2047 B/Q header
decoding, and UTF-8 outgoing already existed. Now added (this session):
**full IANA coverage** (`encoding(for:)` falls through to
`CFStringConvertIANACharSetNameToEncoding`, so every OS-known charset —
ISO-8859-*, Windows-125x, Shift-JIS/EUC-JP/ISO-2022-JP, GB2312/GBK/GB18030, Big5,
KOI8-R, Mac Roman — decodes), **cp1252-preferred single-byte fallback** (Western
single-byte/undeclared bodies render via Windows-1252 with Latin-1 as backstop),
and **RFC 2231 attachment filenames** (`filename*=charset'lang'pct` and
`filename*0*/filename*1` continuations, via `MIMEPart.paramValue`). New unit
tests cover each. The only remaining **[planned]** piece is the **per-message
Text Encoding override menu** (curated common list + Auto, transient per-message,
surfacing the auto-chosen encoding via `DecodedText.charsetUsed`).

---

## 6. Search — Eudora's "Find Messages", pruned to what Stephen uses

Replicates Eudora 7's Find window as a dedicated window (⌘F, or Edit ▸ Find… /
Tools ▸ Search…), sharing the one `AppModel` so a chosen result opens in the main
window. Criteria rows (`[where] [match] [value]`), More/Fewer, Match All/Any,
Search button (Return), and Results / Mailboxes tabs — the Mailboxes tab is a
checkbox tree (all selected by default) that scopes the search.

Scope pruned with Stephen from Eudora's full menu to exactly what he uses:

- **Where fields** (dropdown order): **Anywhere, Headers, Subject, Date**.
- **Text operators** (Anywhere/Headers/Subject): **contains, does not contain,
  is, is not, starts with**.
- **Date operators**: **is, is not, is after, is before**.

Everything else in Eudora's menus (From/To/CC/BCC/Any Recipient/Body/Attachment
Name/Status/Priority/Label/Size/Age/Junk Score/Personality/Mailbox Name; the
regexp and "contains whole word" operators) is deliberately **out** — not built
until asked for.

Implementation:

- The FTS5 index gained two columns: **`headers`** (the full raw header block,
  so "Headers contains X" matches any header line) and **`epoch`** (the `Date:`
  header parsed to seconds-since-1970, for date comparisons). `RFC822Date`
  parses the common on-the-wire forms and strips trailing `(GMT)`/`(PST)`
  comments; unparseable dates store 0 and are excluded from date predicates.
- The engine (`SearchIndex.search(_ SearchQuery)`) builds **LIKE / comparison
  predicates over the stored columns** — Eudora-faithful *substring* semantics —
  rather than FTS5 `MATCH`, and generates its own snippet. This is the correct,
  simple v1; **FTS5-MATCH acceleration for the common "contains" case is a
  deferred optimisation** (the index is already shaped for it). Relevant at
  Stephen's ~6600-mailbox real store; a non-issue on the fixture.
- Index is an **app-owned sidecar** in `Application Support/Eudora/Indexes/`,
  keyed per-tree by a stable hash of the root path — never inside the Eudora
  folder (consistent with the store's existing stance). Built on open; a manual
  **Tools ▸ Rebuild Search Index** forces a rebuild.
- **Background indexing [done].** The build runs off the main thread
  (`Task.detached`) with a live **"Indexing… X of N mailboxes"** progress bar
  under the menu strip; the window stays responsive and search is disabled until
  it finishes. A generation token discards a superseded build's result if a
  different tree is opened mid-index, an `indexingPath` guard + SQLite
  `busy_timeout` prevent two writers on one index file, and all `@Published`
  updates are deferred to main-actor hops (which also cleared the "Publishing
  changes from within view updates" warning). `SearchIndex.rebuild(from:progress:)`
  reports throttled per-mailbox progress.
- **Reuse on open [done].** Opening a tree *reuses* a previously completed index
  if one is on disk (file present, current schema via
  `SearchIndex.hasCurrentSchema()`, count > 0), so only the first open pays the
  build cost and later launches are instant. A build is all-or-nothing (single
  transaction), so an interrupted first build leaves nothing to reuse and
  restarts — there is no partial-progress resume (deliberately deferred). New
  mail isn't searchable until a manual **Tools ▸ Rebuild Search Index**. Still a
  later refinement: **incremental** update on Check Mail / delivery (today any
  change is a full rebuild) and the FTS5-MATCH query acceleration noted above.

Status: **[done — pending Stephen's build & real-mail testing]** — code written
and passed two review agents (one compile/API-availability pass, one SQL/logic
pass; a real `openHit` selection bug and a date-parsing gap were found and
fixed). Not yet compiled on Stephen's Mac or tested against real HTML mail.

---

## 7. Incoming mail from more than one account

**Decided 2026-07. Not yet built.**

### The situation this replaces

Stephen has two addresses. `stephen@musanim.com` is the main one and the home of
a 30-year permanent archive, reached until now through Windows Eudora 7 in
emulation on a dedicated MacBook, viewed remotely from the main MacBook Pro and
an iPad — a 12.9-inch iPad Pro (5th generation), 2732x2048 pixels, 1366x1024
points at 2x, so exactly 4:3. A remote display sized to that ratio fills it
without letterboxing, which is the target for the BetterDisplay virtual-display
experiment. `stephen.malinowski@gmail.com` is secondary and readable natively
everywhere. Gmail is currently configured to **forward a copy of everything to
musanim**, purely so the archive sees it.

Eudora 8 running natively on the main MacBook Pro retires the Windows machine.
The forwarding then has no reason to exist — *if* Eudora 8 can collect Gmail
directly.

### The decisions

- **Two (eventually N) incoming POP accounts; one outgoing.** Receiving becomes
  a list. Sending stays single. Stephen doesn't need to send as Gmail; on the
  rare occasion he wants a reply to go there he'll ask the correspondent, or
  send that message from Gmail. This deliberately avoids the SPF/DMARC problem
  of emitting `From: …@gmail.com` through musanim's SMTP server.
- **Both accounts deliver into the same In mailbox.** No per-account inboxes, no
  visible distinction. `stephen.malinowski@gmail.com` is already in the "me"
  identity set, so the Who column resolves Gmail messages correctly.
- **Nothing is deleted from either server.** `deleteAfterDownload` stays false.
  It remains a per-account setting because the two accounts needn't agree
  forever — musanim is Stephen's archive, Gmail's copy is Google's.
- **Direct POP replaces the forwarding, and the two must never overlap.** With
  one In box there is nothing to separate a forwarded copy from a directly
  fetched one, so running both would duplicate every Gmail message. Forwarding
  goes off at the moment direct POP goes on.

### Gmail is not an ordinary POP server

This is the part that governs the design, and none of it is in our code.

A normal POP server offers every message and lets the client decide what to take
and what to delete; our `deleteAfterDownload = false` plus UIDL tracking is
exactly that contract. Gmail instead keeps its **own** server-side record of what
it has handed out over POP and won't offer it again, whatever the client's UIDL
set says. So the behaviour Stephen wants is bought with Gmail's settings, not
ours:

- **"When messages are accessed with POP" → keep Gmail's copy in the Inbox.**
  This, not anything in Eudora 8, is what leaves the mail readable in Gmail on
  the phone. It is also therefore the safety net for the whole transition:
  Gmail retains everything regardless of what Eudora 8 does, so the cut-over
  risks nothing. (An earlier draft of this plan proposed keeping the forwarding
  on as a net — wrong, and it would have caused the duplication above.)
- **Enable POP "for mail that arrives from now on"**, not "for all mail" —
  which would drag the entire Gmail history into In on the first check. The
  history is already in the archive by way of the forwarding.
- **Recent mode** (`recent:` prefixed to the username) re-offers the last 30
  days regardless of prior download. Not needed while Eudora 8 is the only POP
  client, but it is the recovery route if Gmail and Eudora 8 ever disagree about
  what has been delivered.
- **An App Password is required** — 2-Step Verification on, then a 16-character
  password. Google's plain-password access is long gone. No OAuth work is
  implied: `POP3Client.login` sends `USER`/`PASS` and an App Password satisfies
  it as-is.
- **Gmail rate-limits POP polling.** `autoCheckMinutes` clamps at 1, which is
  fine against musanim and a bad idea against Gmail; 15 minutes is the usual
  recommended floor.

### What the code change involves

`AccountStore` holds one `pop: POP3Account` and one `incomingPassword`. The
storage beneath is already per-account and needs no rework: `knownUIDs()` reads
`all[pop.keychainAccount]` out of a dictionary, and the Keychain key is derived
the same way. The work is:

- `pop` becomes a list; `incomingPassword` becomes per-account.
- `knownUIDs()` / `setKnownUIDs()` take an account rather than reading `pop`.
- `receiveMail`'s fetch-and-deliver body becomes a loop, with `reloadTree`, the
  sort/scroll arrangement, the new-mail badge and the notice hoisted out and run
  once at the end.
- **Per-account failure isolation.** Today a single `catch` wraps everything, so
  with two accounts one server's failure would silently abandon the other's
  fetch. Each account must succeed or fail independently, with results
  aggregated into one notice.
- **Migration must not be able to lose the musanim settings.** They live in
  UserDefaults under `"POP3Account"` as a single object. The list is written
  under a *new* key with the old one kept readable as a fallback, so a mistake
  or a downgrade cannot wipe a configured server back to defaults. (This is why
  `POP3Account.init(from:)` already decodes field-by-field with
  `decodeIfPresent`.)
- Settings grows from one fixed incoming section to an add/remove list — the
  bulk of the work.

### Rollout

Stephen is not yet using musanim with Eudora 8, so the order is: build the
multi-account support, leave the first slot empty, configure **Gmail** in the
second and run it alone for a while. musanim moves over at the real cut-over,
and the Gmail forwarding is switched off then.

Status: **[built — pending Stephen's build and real testing]**. What differed
from the plan above:

- **Auto-check is one app-wide setting, not per account.** The 15-minute floor
  quoted earlier was third-party convention, not a Google rule; the documented
  limits are 15 simultaneous connections and daily bandwidth, neither of which
  one client polling sequentially approaches. So a single one-minute interval
  serves both accounts and `autoCheckEnabled`/`autoCheckMinutes` moved off
  `POP3Account` onto `AccountStore`. If a server ever does throttle, that is the
  setting to make per-account.
- **A half-configured account is reported, not silently skipped.** With one
  working account and one half-typed, dropping the second in silence makes
  Check Mail say "No new mail", which reads as "the new server doesn't work".
  The notice now says how many accounts aren't set up.
- **`save()` trims host and username, and carries the keys across when it
  does.** `keychainAccount` — which also keys the downloaded-UID set — is built
  from those two fields, so a pasted trailing space is a *different* account and
  every message still on the server comes down again into In. Trimming alone
  would have caused that once, on the first save of an already-untrimmed
  account, so the password and the UID set are moved to the new key.
- **A corrupt stored list no longer falls back to the legacy single account.**
  That would have silently resurrected the pre-migration setup — losing any
  account added since — with nothing to say it had happened. The legacy key is
  consulted only when the new one is *absent*; a present-but-unreadable list
  shows a warning in Settings and overwrites nothing.

### Gmail hands back your own sent mail (diagnosed, not a bug)

Seen during testing and worth recording, because it looks exactly like a
delivery bug: a message sent from Eudora 8 arrived correctly at its recipient,
and then reappeared in Eudora 8's **In** box a minute or two later.

The In copy and the Out copy had the *same* `Message-ID` — the same message, not
a copy — and the In copy carried `Received: … by smtp.gmail.com with **ESMTPSA**`
and `Return-Path: <…@gmail.com>`. `ESMTPSA` is authenticated submission: the
message had been sent *through Gmail's SMTP*. Gmail files everything submitted
through its SMTP into Sent Mail, and Gmail's POP serves All Mail — Sent
included. So the account had handed the message back to itself.

Cause was configuration, not code: outgoing mail was pointed at
`smtp.gmail.com` during testing. With outgoing set to musanim, as this design
assumes, Gmail never sees the message and there is nothing to hand back.

The general form survives that fix, though, and will matter if it ever becomes
annoying: **anything sent from Gmail itself** — the web interface, the phone —
lands in Gmail's Sent Mail and will be collected into In on the next check.
Options considered and deferred: leave it (the Who column reads correctly, since
the Gmail address is in the "me" set, so only the *filing* is wrong); skip
messages whose `From` is one of the user's own identities; or deliver them to Out
instead. Nothing built — Stephen is switching sending to musanim, and the
frequency isn't yet known.

Still open, deliberately not built:

- **No defence against duplicate delivery beyond the UID set.** Editing a
  configured account's host or username still starts it with an empty set, and
  Gmail can be reached under more than one hostname. The real fix is for
  `Delivery.deliverIncoming` to skip a message whose `Message-ID` is already in
  the target mailbox — worth doing before this points at the musanim archive.
- **A failed delete pass is never retried.** If deletion throws after delivery
  succeeded, those UIDs are already known, so the next check skips them and
  `deleteAfterDownload` quietly stops applying to them. No loss and no
  duplication; the setting just doesn't finish its job.
- **`POP3Client.fetchNew` holds every message body in memory** before any is
  delivered. Fine for a daily check, not for a first sync of a large account.
- **Editing a saved account orphans its old Keychain entry** in every case
  except the trimming one handled above.

---

## 8. Reading mail from the iPad — solved outside the app

**Decided 2026-08-12. Working at the desk; the first real night is still owed.**

Stephen reads in bed and wants to read and reply from the iPad, over an Edovia
Screens session to the Mac. Nothing here is Eudora code: it is `scripts/night-mode.lua`,
a Hammerspoon script, plus `m1ddc`.

### The answer

**Night mode changes nothing about the display configuration.** All four
displays stay connected and live. The built-in's backlight goes to 0 — Screens
captures the framebuffer, not the backlight, so the iPad still sees it perfectly
— and every external gets an opaque black cover, with DDC luminance and contrast
taken to 0 underneath where the monitor answers DDC. Eudora's windows are moved
onto the built-in and it is sized to fill. From the iPad the whole four-display
desktop is visible, three of the four as black rectangles, and Stephen works in
the built-in's area of it.

It is turned on by a menu-bar click and turned off by **a keypress on a keyboard
in the office** — either keyboard, or the numeric keypad. Sitting down and typing
means wanting the computer normally again.

Pointer events were included at first, so that a mouse twitch would do, and that
had to be withdrawn: night mode ended twice on evenings when nobody was at the
desk, both times while the iPad was in use. The likely mechanism is that Screens
moves the remote cursor with `CGWarpMouseCursorPosition` rather than by posting
an event, and a warp produces a `mouseMoved` attributed to the HID layer —
`pid=0, state=1`, indistinguishable from a hand on the desk. Keystrokes carry
Screens' own process id and are told apart reliably.

### The four things that had to be learned first, none of them obvious

**1. BetterDisplay broke the displays.** The first design used a BetterDisplay
virtual display, 4:3 to match the iPad (12.9-inch iPad Pro, 5th generation:
2732x2048, exactly 4:3), with Eudora parked on it. It worked for one evening.
BetterDisplay reapplies a display configuration at login, and after a night of it
the Mac could no longer make the U4320Q its main display — every display went
black on the attempt, across reboots. The recovery was to quit BetterDisplay,
remove it from Login Items, set the main display with it not running, and
restart. It is uninstalled and should stay that way.

**2. A virtual display guarantees a place for windows to hide.** With one, there
are always at least two displays, and cmd-N put the compose window on whichever
held the menu bar — not the one the iPad was showing. It could not be found at
all. This is why night mode targets the built-in: on an ordinary night nothing
can hide, and `sweepStrays` covers the mixed case.

**3. Screens cannot cope with a display that is connected but not scanning
out** — it stalls on "Reconnecting…" indefinitely. This is why "just power the
monitors off" cannot work, and it is longstanding, not new. Unplugging works.

**4. The three Dells do not agree on what powering off means.** Measured, with
`hs.screen.allScreens()` logged every five seconds across a power cycle:

| Display | On power-off |
|---|---|
| DELL U4320Q | disconnects cleanly |
| DELL 3008WFP | disconnects, then re-announces itself ~5 s later and holds `main` |
| DELL3007WFPHC | never leaves the display list at all |

So "the displays are off" is not a state the Mac can be asked about. Hence an
explicit night mode rather than detection.

### Facts worth keeping

- **DDC**: `m1ddc` (Apple Silicon; `/opt/homebrew/bin`, the *native* Homebrew —
  `/usr/local` is the Intel one). The U4320Q and the 3008WFP answer; the
  3007WFPHC answers nothing, so it only ever gets a black cover. DDC luminance 0
  is *dim*, not off. m1ddc has no power-mode command, so standby is out of reach
  without BetterDisplay.
- **Local input versus Screens**, established with a probe rather than a guess:
  a hardware keystroke reports `pid=0, state=1`; the same keystroke injected by
  Screens reports the Screens process id and `state=1973594324`. That
  discriminator is what lets a key at the desk end night mode without a reply
  typed from bed ending it too. It holds for keystrokes; it does **not** hold for
  pointer movement, which is why the wake trigger is keys only.
- **Nothing on the event-tap path may block.** An `hs.settings` read per event —
  an IPC round-trip to `cfprefsd` — was enough for macOS to disable the tap, and
  a disabled tap is a desk that cannot be woken. Every DDC call is asynchronous
  for the same reason.
- **"Click wallpaper to reveal desktop" sweeps the covers aside**, since they are
  ordinary windows. Deliberately not defended against: it is the life preserver
  that got Stephen out of a blacked-out desk twice.

### Consequences for the iPad client

The in-app HTTP server and web client stay parked, now for a reason rather than
by neglect: this costs no code in Eudora and introduces no second writer to the
mail files. Worth revisiting only if night mode proves fragile in use, or if
Stephen wants mail from somewhere the Mac's displays aren't.

**What macOS cannot do**, established along the way and worth not re-deriving: a
window lives on exactly one display in exactly one Space. Eudora cannot be
visible at the desk *and* independently on the iPad. Mirroring copies a display,
not a window.

---

## Through-line

Both security and encoding follow the same rule: **honor what's trustworthy,
repair the obvious lies, never fail to show something, and always let the user
see and override the decision.** Nothing consequential happens without a
deliberate human action.

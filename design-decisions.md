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

Status: **[partial]** — the tolerant decoder, UTF-8-mislabel repair, never-fail
Latin-1 fallback, RFC 2047 B/Q header decoding, and UTF-8 outgoing exist. Full
IANA coverage, cp1252-preferred fallback, the manual override menu, and RFC 2231
are **[planned]**.

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
  **Tools ▸ Rebuild Search Index** forces a rebuild. Background/incremental
  indexing for a large tree is a later refinement.

Status: **[done — pending Stephen's build & real-mail testing]** — code written
and passed two review agents (one compile/API-availability pass, one SQL/logic
pass; a real `openHit` selection bug and a date-parsing gap were found and
fixed). Not yet compiled on Stephen's Mac or tested against real HTML mail.

---

## Through-line

Both security and encoding follow the same rule: **honor what's trustworthy,
repair the obvious lies, never fail to show something, and always let the user
see and override the decision.** Nothing consequential happens without a
deliberate human action.

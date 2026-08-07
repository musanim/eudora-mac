# Enlarge mode — feasibility and practicality

**CLOSED 2026aug07. Not being built.** Stephen found the enlargement can be done
at the other end of a remote-desktop viewer, with little trouble and no change to
Eudora. That solves the actual need, so the work below is not scheduled. The
study is kept because its findings are worth not re-deriving — in particular §3's
result that `.scaleEffect` breaks the message list's window-coordinate
hit-testing, and that there is no whole-app scaling trick available here. Read
the rest as "what it would take", not as a queue item.

A study, not a plan. Written 2026aug06 by inspection only; nothing here has been
compiled or measured on screen. Where a claim rests on a measurement someone else
made, it cites the comment that records it.

The question: can Eudora be made to draw everything at ~120–140% of its current
size, with no functional change?

**Verdict: yes, and the app is unusually well set up for it — but not by one
lever.** There is no single knob, and the two obvious shortcuts both break things
that took real work to get right. The honest shape of the job is ~135 numbers
touched, done in three phases that each ship something usable, plus one asset
regeneration. The first phase is small and delivers most of the benefit.

---

## 1. "Enlarge" is three independent problems

They have different answers, and conflating them is the main way this goes wrong.

| Layer | What it is | Scaling mechanism |
|---|---|---|
| **Body text** | The mail itself — reading pane and composer | **Already shipped.** See §2. |
| **Chrome** | Message list, sidebar, column headers, status bar, toolbars, dialogs | Parameterized metrics. §5. |
| **Artwork** | The row and header glyphs | Regenerate at the target size. §6. |

## 2. A third of this already exists

Settings → "Default font" has a face and a **Size** picker (8…24, seeded Arial
12) at `SettingsView.swift:803-816`. It feeds `ComposeSettings.bodyFontName` /
`bodyFontSize`, and those two values drive **all three** body surfaces:

- HTML mail — baked into the wrapper document's CSS as `font-size: Npx`
  (`WebView.swift:167,177-179`), and `updateNSView` keys its reload on the
  wrapped document string (`:60-67`), so a size change re-renders live.
- Plain-text mail — `NSFont(name:size:)` over the whole range
  (`WebView.swift:267-268`).
- The composer — via `richTextDefaults` (`ComposeSettings.swift:114`).

So "make the mail bigger" is a supported action today, and `ComposeSettings`'
own header comment (`:11-14`) says why it is safe: *these describe the local
view, not the wire.* `RichTextAttributed` stores every run's style **relative**
to those defaults (`RichTextAttributed.swift:7-15,294-296`), so text left in the
default face and size still declares nothing on the wire and still assembles to
`text/plain`.

**Consequence for the design: enlarge mode must not touch `bodyFontSize`.** Not
because it would break — it wouldn't — but because it is already the user's own
setting with its own meaning, and a UI scale that silently overwrote it would be
a second cook. Enlarge mode scales the *chrome*; the body has its own knob, and
the two are meant to be independent. That also disposes of the one genuine
correctness hazard in this whole study, since the wire format is reached only
through `richTextDefaults`.

There is one rough edge worth noting separately, which exists today and is not
caused by enlarge mode: a draft containing an explicitly-sized 12 pt run,
reopened after the default has been raised to 17, still renders at 12 and now
looks *smaller* than the text around it. `FormatStrip.swift:71-79` deliberately
shows the selection's real size even when off-menu, so it surfaces honestly.

## 3. Two shortcuts, and why both fail

### `.scaleEffect` on the root view — **no**

One line, and it would be wrong in four ways at once.

The message list is a real `NSTableView`, reached by introspection, with
hand-written hit-testing in *window* coordinates: `MessageContextMenu.swift:136-138`
does `table.convert(event.locationInWindow, from: nil)` then `table.row(at:)`;
`MessageHeaderSort.swift:152-165` and `MessageColumnResizeController`
(`ContentView.swift:2339-2352,2381,2410-2419`) do the same for the header. A
SwiftUI `scaleEffect` is a layer transform that `NSView.convert` knows nothing
about, so every one of those silently reads the wrong point. Right-click would
select the wrong row. Column dragging would drift.

Also: the hosted `WKWebView` and both `NSTextView`s would rasterize at 1x and be
scaled up — blurry, which matters more than usual because Stephen is on a
non-Retina display (`ComposeSettings.swift:76-78`). The `±0.5` equality
thresholds scattered through the scroll bridge (`ContentView.swift:2762-2766,
3676`; `AppModel.swift:996,1004`) become meaningless at a non-integer scale. And
`PaneDividerHandle` uses `coordinateSpace: .global` deliberately
(`ContentView.swift:4217-4220`), which a scaled container would desynchronize
from its local points.

### Scaled display resolution — **the free option, worth trying first**

Costs nothing and takes a minute: set the Mac's display to a lower scaled
resolution. Everything grows, including other apps. On a non-Retina panel it will
be soft, which is probably the objection, but it is the cheapest way to find out
what 130% actually feels like before anyone writes code. macOS's own zoom
(⌥⌘8, or scroll-to-zoom) is the same idea for occasional use.

**Recommendation: do this before phase 1**, purely to settle the factor. Picking
130% from a description and then discovering 120% was right costs a retune of
every number below.

## 4. Where the numbers are

| | Count | Notes |
|---|---|---|
| Named metrics enums | 12 holding ~30 values | `EudoraFont`, `MessageTableMetrics`, `MessageColumnWidths`, `MessageRowMetrics`, `SidebarRowMetrics`, `PaneLayout`, `PaneDivider`, `HeaderPaneLayout`, `WhoGlyph`, `RowIcon`, `HeaderIcon`, `MessageColumnResizeController.slop` |
| Inline literals, main window | ~45 | Concentrated in the preview/header pane, `ContentView.swift:4460-4710` |
| Inline literals, other windows | ~45 | Compose, Settings, Find, Blacklist, format strip, recipient panel |
| `.font(…)` call sites | 42, of which **41 are semantic** | `.caption`, `.headline`, `.caption2`, `.callout` |
| Persisted point values | 4 | Who and Date column widths, `previewPaneHeight`, `headerPaneHeight` |

**The 41 semantic fonts are the sleeper.** macOS has no Dynamic Type, so
`.font(.caption)` is a fixed size that will not follow any scale factor. Left
alone, they desynchronize: the status bar's `.headline` mailbox path
(`ContentView.swift:3750`) would stay put while the list text beside it grew.
Each needs replacing with an explicit scaled size. Mechanical, but it is 41
edits and it is the single largest line-count in the job.

**Four SwiftUI↔AppKit agreement points** must scale together or the two grids
diverge — the failure mode the comment at `ContentView.swift:1002` warns about:
column widths (`TableColumn` at `:3908-3911` vs `TableHeaderIconStyler.enforce`
at `:2172-2199`); the glyph column width (`ColumnPin` at `:1968-69`,
`ImageHeaderCell.cellSize` at `:1394`); the cell insets that cancel SwiftUI's
own (`MessageTableMetrics`); and the header font
(`column.headerCell.font = EudoraFont.listNSFont`, `:2156-57`). All four already
read from a shared constant, so scaling the constant keeps them in agreement.
This is the part that could have been a nightmare and isn't, because the
alignment work was done properly the first time.

## 5. The mechanism

A single launch-time factor, read once from `UserDefaults`, with every constant
becoming a computed `static var`:

```swift
enum UIScale {
    /// 1.0, 1.2, 1.3, 1.4 — read at launch; changing it requires a restart.
    static let factor: CGFloat = …
    /// Scaled and rounded to a whole point.
    static func pt(_ v: CGFloat) -> CGFloat { (v * factor).rounded() }
}
```

**Launch-time, not live.** A published, live-updating scale would have to fight
`TableHeaderIconStyler.enforce`, the `pinRowHeight` KVO, and SwiftUI's cached
column grid, all of which re-assert on their own schedule. Requiring a restart
makes every one of those a non-issue for the cost of one alert. Take it.

**Round to whole points.** Half-points blur on a non-Retina display, and the
codebase is full of `±0.5` equality tests that assume integers.

Three things deliberately excluded from `pt()`:

- **`bodyFontSize`** — §2.
- **The 17 pt intercell spacing** (`ContentView.swift:929-935,2122,2138`),
  which is left alone on purpose because SwiftUI caches its grid from it. It
  stays 17 at every scale. The only casualty is cosmetic: `whoDefault 247` and
  `dateDefault 145` were chosen to cancel it so Date and Subject land at x=336
  and 476 (`:1000-1004`), and that arithmetic won't survive scaling. Those two
  numbers are explicitly labelled "taste, not measurement — retune freely", so
  this is one afternoon of eyeballing, not a correctness problem.
- **The image viewer** (`ImageViewerWindow.swift`), which shows pixels at true
  size by design and already has its own magnification (`:41-43`).

**The four persisted values need a stored scale tag**, or the user's dragged
column width from 100% mode comes back as a 100%-sized column in 130% mode. The
cheaper fix: store them divided by the factor, i.e. always in 1.0 units, and
multiply on read. One line each at `AppModel.swift:982-1006` and the two
`@AppStorage` sites.

## 6. The artwork

Eleven imagesets. Five carry 2x art and are fine. **Six are 1x-only pixel art**
drawn `.resizable().interpolation(.none)` — nearest-neighbour, deliberately, to
keep Eudora 7's pixels crisp (`ContentView.swift:1128-1135`):

`RowUnread` 14×14, `RowSendError` 14×14, `RowUnsent` 20×15, `RowAttachment`
17×16, `ColumnStatus` 21×22, `ColumnAttachment` 24×22.

At 130% nearest-neighbour would double some pixel rows of a circle and not
others, and the unread ball would come out visibly lopsided. **This exact problem
has already been solved once in this repo** — `assets/make-tree-newmail.py`'s
header comment works through it for the 14→20 sidebar ball and lands on
"generating art at the size it will actually be drawn", resampled smoothly, with
a 2x companion. Same treatment, same script pattern, six more files. Note
`HeaderIcon.width` reads the asset's native size (`ContentView.swift:1114-1118`),
so the column geometry follows the new art automatically — nothing downstream
needs editing.

The splash (`SplashWindow.swift:85-110`) is a 1x-only bitmap sized from the art
itself, drawn `.scaleNone` with a nearest magnification filter. It has no vector
source. Easiest answer: leave it unscaled. It is on screen for a second.

## 7. Suggested phasing

**Phase 1 — type only.** `EudoraFont.size`, `MessageRowMetrics.rowHeight`,
`SidebarRowMetrics.rowHeight`, the three `MessageColumnWidths` defaults, the
status bar's pinned 18, and the compose window's field heights and minimums.
Roughly **15 numbers**. Paddings, insets and glyphs stay put, so the layout just
gets proportionally tighter, which at 120–130% generally reads as *denser*
rather than *wrong*. This is where most of the perceived benefit is — enlarging
a mail client is 90% type size — and it is small enough to be one build
round-trip.

**Phase 2 — the semantic fonts and the artwork.** The 41 `.font()` sites and the
six regenerated glyphs. This is what removes the "some things grew and some
didn't" feeling.

**Phase 3 — paddings, insets, dialog geometry.** The remaining ~90 literals plus
the four persisted values. Diminishing returns; worth doing only if phases 1–2
leave it looking cramped.

Phase 1 is a genuine stopping point. If it looks right, phases 2 and 3 may never
need doing.

## 8. Cost, honestly

Claude cannot build, so the currency is build round-trips, not hours. Phase 1 is
one or two; phase 2 three or four, mostly because 41 mechanical edits will
produce at least one typo and the glyph regeneration needs looking at; phase 3 is
open-ended and best done incrementally. The risk is low throughout because
nothing here changes behaviour — every failure mode is visible on screen, and
the four dangerous couplings all read from shared constants already.

The two things that could still surprise us, and neither is provable by
inspection:

1. Whether `SidebarRowMetrics.rowHeight` actually takes at a larger value.
   `defaultMinListRowHeight` is a *minimum*, and the sidebar's rows self-size;
   the enum's comment lists five other levers measured inert. A 21→27 change
   should work, since it is asking a row to be taller rather than shorter, but
   the file's history is a list of things that looked like they should work here
   and didn't.
2. Whether `pinRowHeight`'s KVO re-assertion is happy at a value that no longer
   matches SwiftUI's self-sized estimate. Same mechanism as today, different
   number, so probably fine — but "probably" is what instrumentation is for.

## 9. Open questions for Stephen

- What factor? Try a scaled display resolution first (§3) to settle it, since
  the number gets baked into a retune of the column widths.
- Should the compose window and dialogs scale too, or only the main window?
  Scaling only the main window is cheaper and might be all that's wanted.
- Where does the control live — Settings, next to the existing font size, and
  with a "restart to take effect" note?
- Is the splash staying at 1x acceptable?

**All moot as of the close above — don't ask them.** The scale-factor question in
particular (120/130/140) no longer needs answering, since nothing gets baked into
a retune of the column widths.

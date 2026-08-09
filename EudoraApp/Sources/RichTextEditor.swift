import SwiftUI
import AppKit
import EudoraStore
import EudoraRichText

/// The composer's body editor: an `NSTextView` with rich text on, bridged to the
/// `RichText` model and driven by the format strip above it.
///
/// **Why AppKit and not `TextEditor`.** SwiftUI's `TextEditor` binds a plain
/// `String` — no way in to fonts, colour or the standard editing affordances.
/// An `NSTextView` gives ⌘Z, the ruler, the font panel and, most of all,
/// attributed text; the conversion to and from `RichText` (which is what makes
/// an unstyled message stay plain) lives in `EudoraRichText`, tested on its own.
///
/// The controller is the shared object: the representable hands it the text
/// view, the strip reads its published selection state and calls its mutators,
/// and `ComposeView` reads its `content` for dirty-tracking and assembly.

// MARK: - the text view

/// An `NSTextView` that renders body text one of three ways: normal macOS
/// smoothing, crisp (no antialiasing), or Eudora-7 style — a crisp solid core
/// with a flat-gray halo on the pixels orthogonally adjacent to ink.
///
/// AppKit smooths text through the graphics context, not a view property, so
/// crisp mode overrides `draw` to clear `shouldAntialias`. The Eudora style goes
/// further: it caches a crisp bitmap of the view, grays the white pixels
/// orthogonally (never diagonally) touching a black one — the exact, gradient-
/// free thing Windows Eudora 7 did — and blits it back, giving a distinct solid
/// core with a mild, adjustable halo. All three affect only how the body looks
/// locally (see `ComposeSettings.bodyAntialiasing`); nothing about what is sent.
final class BodyTextView: NSTextView {
    var renderingMode: BodyAntialiasing = .system {
        didSet { if renderingMode != oldValue { needsDisplay = true } }
    }
    /// The Eudora halo's lightness, 0…1 (1 = white/none, lower = a darker gray).
    var haloWhiteness: Double = 0.72 {
        didSet { if haloWhiteness != oldValue, renderingMode == .eudora { needsDisplay = true } }
    }

    /// Set while `cacheDisplay` re-enters `draw` for the offscreen crisp render,
    /// so that pass draws plainly instead of recursing into the halo.
    private var isCachingCrisp = false

    override func draw(_ dirtyRect: NSRect) {
        if isCachingCrisp {
            NSGraphicsContext.current?.shouldAntialias = false
            super.draw(dirtyRect)
            return
        }
        switch renderingMode {
        case .system: super.draw(dirtyRect)
        case .off:    drawCrisp(dirtyRect)
        case .eudora: drawEudoraStyle(dirtyRect)
        }
    }

    private func drawCrisp(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { super.draw(dirtyRect); return }
        ctx.saveGraphicsState()
        ctx.shouldAntialias = false
        super.draw(dirtyRect)
        ctx.restoreGraphicsState()
    }

    /// Eudora-7 anti-aliasing: cache a crisp bitmap, halo it, blit it back.
    private func drawEudoraStyle(_ dirtyRect: NSRect) {
        let rect = dirtyRect.intersection(bounds)
        guard !rect.isEmpty, let rep = bitmapImageRepForCachingDisplay(in: rect) else {
            drawCrisp(dirtyRect)
            return
        }
        isCachingCrisp = true
        cacheDisplay(in: rect, to: rep)
        isCachingCrisp = false
        Self.applyHalo(rep, whiteness: haloWhiteness)
        _ = rep.draw(in: rect, from: NSRect(origin: .zero, size: rect.size),
                     operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Gray the background pixels that orthogonally touch an ink pixel. Ink =
    /// luminance below mid; the halo is a flat gray at `whiteness`, and never
    /// lightens a pixel that's already darker than it. Works in place on the
    /// cached bitmap's 8-bit samples; only the alpha *position* matters (skipped
    /// via `c`), so RGBA/BGRA channel order is irrelevant to gray + luminance.
    static func applyHalo(_ rep: NSBitmapImageRep, whiteness: Double) {
        guard rep.bitsPerSample == 8, rep.samplesPerPixel >= 3, !rep.isPlanar,
              let data = rep.bitmapData else { return }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        guard w > 0, h > 0 else { return }
        // Where the three colour bytes start, so the alpha byte is never read as
        // colour nor overwritten with gray (which would make the halo translucent).
        // The cache bitmap is usually little-endian ARGB — bytes B,G,R,A, alpha
        // *last* — even though its format reports `.alphaFirst`; the alpha byte is
        // at index 0 only when exactly one of {alphaFirst, littleEndian} holds.
        let c: Int
        if spp >= 4 {
            let alphaFirst = rep.bitmapFormat.contains(.alphaFirst)
            let little = rep.bitmapFormat.contains(.thirtyTwoBitLittleEndian)
            c = (alphaFirst != little) ? 1 : 0     // alpha at byte 0 → colours 1,2,3
        } else {
            c = 0                                   // no alpha byte (spp == 3)
        }
        let gray = Int(max(0, min(255, Int((whiteness * 255).rounded()))))
        let threshold = 128

        func lum(_ p: UnsafeMutablePointer<UInt8>) -> Int {
            (Int(p[c]) + Int(p[c + 1]) + Int(p[c + 2])) / 3
        }

        var ink = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let row = data + y * bpr
            for x in 0..<w where lum(row + x * spp) < threshold {
                ink[y * w + x] = true
            }
        }
        for y in 0..<h {
            let row = data + y * bpr
            for x in 0..<w {
                let i = y * w + x
                if ink[i] { continue }
                let touches = (y > 0 && ink[i - w]) || (y < h - 1 && ink[i + w])
                    || (x > 0 && ink[i - 1]) || (x < w - 1 && ink[i + 1])
                guard touches else { continue }
                let p = row + x * spp
                if gray < lum(p) {          // only ever darken toward the halo gray
                    p[c] = UInt8(gray); p[c + 1] = UInt8(gray); p[c + 2] = UInt8(gray)
                }
            }
        }
    }

    // MARK: origin-aware paste
    //
    // Paste keeps the clipboard's formatting only when the copy happened inside
    // *this* draft's editor. Anything from elsewhere — another app, or even a
    // different compose window — comes in as plain text in the caret's own
    // format, exactly as if it had been typed there. Text pasted from within the
    // draft still behaves as it always has.
    //
    // How the origin is known: every copy/cut from this view tags the general
    // pasteboard with a private type carrying a token unique to this editor,
    // added *alongside* the rich types AppKit writes (`addTypes`, not
    // `declareTypes`, so its data survives). On paste we keep formatting only
    // when that token is present and matches — any other app writing the
    // pasteboard clears the tag, and a different compose window carries a
    // different token. `pasteAsPlainText` is AppKit's "paste and match style":
    // it inserts the pasteboard's plain string using the typing attributes at
    // the insertion point.

    private static let internalPasteType =
        NSPasteboard.PasteboardType("com.musanim.eudora.compose.internal")
    private let editorToken = UUID().uuidString

    /// The image representations a paste will embed, in preference order — the
    /// original encoding ahead of the TIFF rendering that sits beside it, so a
    /// PNG travels as the PNG it already is.
    ///
    /// **Read in two places, and it must be the same list in both**: once to
    /// decide whether ⌘V is even offered (`readablePasteboardTypes`) and once to
    /// decide what to embed (`pasteImage`). Two lists that drifted apart would
    /// give an enabled menu item and a paste that then declined — which is a
    /// worse failure than the one this fixed, because it looks deliberate.
    static let imagePasteTypes: [NSPasteboard.PasteboardType] = [
        .png,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        .tiff,
    ]

    /// The pasteboard types Paste is offered for.
    ///
    /// **This is why pasting a picture did nothing whatever (2026aug06).** AppKit
    /// validates the Paste menu item — and therefore ⌘V — against this list, and
    /// an `NSTextView` with `importsGraphics` off includes no image type in it.
    /// With only a picture on the pasteboard the menu item was *disabled*, so the
    /// action was never sent and `paste(_:)` never ran. Every line of the image
    /// path was correct and unreachable.
    ///
    /// The diagnostic is what settled it: pasting text logged its six types and
    /// its branch, and pasting an image logged **nothing at all** — not a
    /// declined branch, not an empty type list. A method that isn't called is a
    /// different fact from a method that declines, and only the log tells them
    /// apart. Inspection had already cleared every step inside `pasteImage`,
    /// twice, which is exactly when to stop reading and start measuring.
    ///
    /// `importsGraphics` is deliberately left off rather than being the fix.
    /// Turning it on also hands AppKit its own image handling — it inserts its
    /// own attachment from RTFD and accepts image drags — which would bypass
    /// `pasteImage`, and drag-and-drop is out of scope for now by Stephen's
    /// instruction. Widening this list changes what is *offered* and nothing
    /// about what happens next.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        let inherited = super.readablePasteboardTypes
        return inherited + Self.imagePasteTypes.filter { !inherited.contains($0) }
    }

    override func copy(_ sender: Any?) {
        super.copy(sender)
        tagPasteboardAsInternal()
    }

    override func cut(_ sender: Any?) {
        super.cut(sender)
        tagPasteboardAsInternal()
    }

    private func tagPasteboardAsInternal() {
        let pb = NSPasteboard.general
        pb.addTypes([Self.internalPasteType], owner: nil)
        pb.setString(editorToken, forType: Self.internalPasteType)
    }

    /// One-shot readout of what a paste actually saw. **Off. What it found is
    /// recorded below; switch it on again if a paste ever misbehaves.**
    ///
    /// Written for the 2026aug06 report that pasting an image from Preview did
    /// nothing at all, and it found the answer in one build: pasting text logged
    /// six pasteboard types and its branch, and pasting an image logged
    /// **nothing whatever** — not a declined branch, not an empty type list. The
    /// method was never called. See `readablePasteboardTypes` for why.
    ///
    /// That is the whole value of it. Inspection had cleared every step inside
    /// `pasteImage` twice and was right both times; a method that isn't called
    /// and a method that declines look identical on screen and identical in the
    /// source, and only the log tells them apart.
    ///
    /// Read it as: `[paste] types` is the ground truth in UTIs, which
    /// `clipboard info`'s Carbon names are not; the branch line says which arm of
    /// `paste(_:)` ran; `found` says whether a representation was accepted;
    /// `insert` says whether the storage actually changed; `readBack` says
    /// whether the model still had the image afterwards — the storage never
    /// changing and the model losing it again being two different bugs with one
    /// symptom. A healthy image paste prints `branch=image`, `found=image/png`,
    /// `insert storage N -> N+1`, `readBack images=1`.
    static var diagnosePaste = false

    private static func diag(_ message: @autoclosure () -> String) {
        if diagnosePaste { print("[paste] \(message())") }
    }

    override func paste(_ sender: Any?) {
        if Self.diagnosePaste {
            let pb = NSPasteboard.general
            // `types` is optional — an empty pasteboard has none.
            let types = pb.types ?? []
            Self.diag("types " + types.map(\.rawValue).joined(separator: ", "))
            // Byte counts, so a type that is *declared* but carries nothing is
            // distinguishable from one that was never there. A promised type
            // reads as 0 or -1 here, and is exactly the case that would defeat
            // the `!data.isEmpty` test in `pasteImage`.
            for t in types {
                Self.diag("  \(t.rawValue) = \(pb.data(forType: t)?.count ?? -1) bytes")
            }
        }
        if NSPasteboard.general.string(forType: Self.internalPasteType) == editorToken {
            Self.diag("branch=internal")
            super.paste(sender)          // copied here — keep its formatting
        } else if NSPasteboard.general.string(forType: .string)?.isEmpty == false {
            Self.diag("branch=text — string type present, image not attempted")
            // Text wins whenever there is any. Excel, Word, Keynote, Preview and
            // a selection in Safari all put a TIFF or PDF rendering on the
            // pasteboard *beside* the text, so preferring the picture would mean
            // copying a spreadsheet cell into a draft pasted a screenshot of it.
            pasteAsPlainText(sender)
        } else if pasteImage() {
            Self.diag("branch=image — handled")
            return                       // a picture and nothing else — embed it
        } else {
            Self.diag("branch=plain — pasteImage declined")
            pasteAsPlainText(sender)     // from elsewhere — plain, matching the caret
        }
    }

    /// Embed an image from the clipboard, returning whether there was one.
    ///
    /// A deliberate exception to the rule above, not a hole in it. That rule is
    /// about *formatting* — text arriving with a foreign font and size, which is
    /// nearly always unwanted. An image has no formatting to inherit, and
    /// `pasteAsPlainText` silently discards it: before this, pasting a
    /// screenshot into a draft did nothing at all, with no indication why.
    ///
    /// Takes the bytes as they are. A screenshot is a PNG of whatever size the
    /// screen made it, and re-encoding a picture of text to save bytes is
    /// exactly where it looks worst. If a server ever refuses one for size, it
    /// says so at send time and the draft survives — see `SMTPClient`.
    private func pasteImage() -> Bool {
        let pb = NSPasteboard.general
        // File promises and copied files arrive as URLs; a screenshot or a copy
        // out of Preview arrives as raw bytes. Try the typed data first, in the
        // order that keeps the original encoding rather than a re-render.
        var found: (data: Data, type: String)?
        // The same list `readablePasteboardTypes` offers Paste for. Don't inline
        // it back here — see the comment there.
        for type in Self.imagePasteTypes {
            if let data = pb.data(forType: type), !data.isEmpty,
               let mime = RichTextAttributed.mimeType(forUTIOrExtension: type.rawValue)
                        ?? RichTextAttributed.sniffedImageType(data) {
                found = (data, mime)
                break
            }
        }
        if found == nil,
           let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first, let data = try? Data(contentsOf: url),
           let mime = RichTextAttributed.mimeType(
                forUTIOrExtension: url.pathExtension) ?? RichTextAttributed.sniffedImageType(data) {
            found = (data, mime)
        }
        guard var found else {
            Self.diag("found=none — no representation accepted, and no file URL")
            return false
        }
        Self.diag("found=\(found.type) \(found.data.count) bytes")

        // TIFF is what Preview and most "Copy Image" commands give, and neither
        // Gmail nor Outlook renders an `image/tiff` part inline — the recipient
        // sees a broken picture. The conversion is lossless, so this is not the
        // re-encoding the doc comment above declines to do.
        if found.type == "image/tiff",
           let png = NSBitmapImageRep(data: found.data)?
            .representation(using: .png, properties: [:]) {
            found = (png, "image/png")
        }

        let attachment = RichTextImageAttachment(RichTextImage(mimeType: found.type,
                                                               data: found.data))
        let piece = NSAttributedString(attachment: attachment)
        let range = selectedRange()
        // Whether AppKit could decode the bytes into something drawable. A nil
        // here means the run is in the storage and the cell has nothing to
        // paint — which on screen is indistinguishable from the paste never
        // having happened, and is the first thing to rule in or out.
        Self.diag("attachment image=\(attachment.image.map { "\($0.size)" } ?? "nil")"
                  + " editable=\(isEditable) range=\(range.location),\(range.length)")
        // The placeholder, not nil: nil means "attributes only" to AppKit, which
        // registers an attribute undo, and ⌘Z would then leave the picture in place.
        guard shouldChangeText(in: range, replacementString: RichTextRun.imagePlaceholder)
        else {
            Self.diag("insert=refused by shouldChangeText")
            return true
        }
        let before = textStorage?.length ?? -1
        textStorage?.replaceCharacters(in: range, with: piece)
        let after = textStorage?.length ?? -1
        Self.diag("insert storage \(before) -> \(after)")
        didChangeText()
        // After `didChangeText`, so it reports what the model kept once
        // `readBack` had run — the storage changing and the model losing it
        // again are two different bugs with one symptom.
        if Self.diagnosePaste, let storage = textStorage {
            // `arial12` rather than the real defaults, which this view doesn't
            // hold — they affect text styling and not whether a run is an image,
            // which is all this counts.
            let images = RichTextAttributed.richText(storage, defaults: .arial12)
                .runs.filter { $0.image != nil }.count
            Self.diag("readBack images=\(images) storageLength=\(storage.length)")
        }
        setSelectedRange(NSRange(location: range.location + piece.length, length: 0))
        return true
    }

    // MARK: quick-add correction
    //
    // Extends — never replaces — AppKit's default editing menu, so the built-in
    // spell-check items (Learn / Ignore / suggestions) stay put; we just add a
    // "Correct 'word' to…" entry at the top for the word under the click (or the
    // current selection), plus any case-variant guesses (see `caseGuesses`).
    // The rule itself is saved by the controller.

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        // This class is also the read-only plain-text *reader* (`PlainMailView`),
        // where both of these items are wrong: nothing there should be rewritten,
        // and the quick-add has no controller to save through anyway.
        guard isEditable else { return menu }
        guard let menu, let target = correctionTarget(for: event) else { return menu }
        let item = NSMenuItem(title: "Correct “\(target.word)” to…",
                              action: #selector(addCorrection(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = target.word
        menu.insertItem(NSMenuItem.separator(), at: 0)
        menu.insertItem(item, at: 0)

        // Case guesses sit above that, at the very top, so they read the way the
        // built-in suggestions do. Inserted in reverse because each goes to 0.
        let guesses = caseGuesses(for: target.word, in: target.range)
        if !guesses.isEmpty {
            menu.insertItem(NSMenuItem.separator(), at: 0)
            for guess in guesses.reversed() {
                let g = NSMenuItem(title: guess.replacement,
                                   action: #selector(applyCaseGuess(_:)), keyEquivalent: "")
                g.target = self
                g.representedObject = guess
                menu.insertItem(g, at: 0)
            }
        }
        return menu
    }

    /// The word to offer a correction for: the selection if there is one, else
    /// the word under the click. Nil when neither yields a non-empty word.
    ///
    /// The range is the raw one — untrimmed, so it may be wider than `word`.
    /// Anything that *replaces* text must check the two still agree.
    private func correctionTarget(for event: NSEvent) -> (word: String, range: NSRange)? {
        let ns = string as NSString
        let range: NSRange
        let selected = selectedRange()
        if selected.length > 0 {
            range = selected
        } else {
            let point = convert(event.locationInWindow, from: nil)
            guard let layoutManager, let textContainer,
                  layoutManager.numberOfGlyphs > 0 else { return nil }
            var fraction: CGFloat = 0
            let glyph = layoutManager.glyphIndex(for: point, in: textContainer,
                                                 fractionOfDistanceThroughGlyph: &fraction)
            // `glyphIndex(for:)` clamps to numberOfGlyphs on an empty/short line;
            // don't ask for a glyph that isn't there.
            guard glyph < layoutManager.numberOfGlyphs else { return nil }
            let index = layoutManager.characterIndexForGlyph(at: glyph)
            guard index < ns.length else { return nil }
            range = selectionRange(forProposedRange: NSRange(location: index, length: 0),
                                   granularity: .selectByWord)
        }
        let word = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        return word.isEmpty ? nil : (word, range)
    }

    @objc private func addCorrection(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        (delegate as? RichTextEditorController)?.promptAddCorrection(for: word)
    }

    // MARK: case guesses
    //
    // macOS's spell checker will not offer a *case* change as a guess: type
    // "ritalin" and it flags the word, but "Ritalin" — which is in the
    // dictionary — is nowhere in the list. Eudora 7 offered it, so we do too, by
    // testing the capitalized and all-caps forms ourselves and adding whichever
    // ones the dictionary accepts. Picking one replaces just that occurrence; it
    // records nothing, unlike the "Correct … to…" item below it.

    /// One offered case change, carrying enough to verify the text hasn't moved
    /// between building the menu and picking from it.
    private struct CaseGuess {
        let original: String
        let replacement: String
        let range: NSRange
    }

    /// Case-only variants of `word` that the dictionary accepts, when `word`
    /// itself is misspelled. Empty for a correctly spelled word, and empty
    /// unless `range` holds exactly `word` — the replacement uses that range.
    private func caseGuesses(for word: String, in range: NSRange) -> [CaseGuess] {
        // The length cap is not cosmetic: a selection with no whitespace in it can
        // be a whole base64 blob or a long URL, and each `isMisspelled` is a
        // synchronous round-trip to AppleSpell on the main thread.
        guard (string as NSString).substring(with: range) == word,
              word.count <= 64,
              word.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              isMisspelled(word) else { return [] }

        var seen: Set<String> = [word]
        var guesses: [CaseGuess] = []
        let candidates = [word.prefix(1).uppercased() + String(word.dropFirst()),
                          word.uppercased()]
        for candidate in candidates where seen.insert(candidate).inserted {
            guard !isMisspelled(candidate) else { continue }
            guesses.append(CaseGuess(original: word, replacement: candidate, range: range))
        }
        return guesses
    }

    /// Whether the spell checker rejects `word`, honouring what has been learned
    /// or ignored in *this* document via the view's spell-checker tag.
    private func isMisspelled(_ word: String) -> Bool {
        let bad = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: nil, wrap: false,
            inSpellDocumentWithTag: spellCheckerDocumentTag, wordCount: nil)
        return bad.location != NSNotFound
    }

    @objc private func applyCaseGuess(_ sender: NSMenuItem) {
        guard let guess = sender.representedObject as? CaseGuess,
              let storage = textStorage else { return }
        // The menu was built on right-click; don't write to a range whose text
        // has changed underneath it.
        let ns = storage.string as NSString
        guard NSMaxRange(guess.range) <= ns.length,
              ns.substring(with: guess.range) == guess.original else { return }

        let attrs = storage.attributes(at: guess.range.location, effectiveRange: nil)
        // A distinct undo step, so one ⌘Z puts the original spelling back.
        breakUndoCoalescing()
        guard shouldChangeText(in: guess.range, replacementString: guess.replacement) else { return }
        storage.replaceCharacters(
            in: guess.range,
            with: NSAttributedString(string: guess.replacement, attributes: attrs))
        didChangeText()
        setSelectedRange(NSRange(location: guess.range.location
                                     + (guess.replacement as NSString).length,
                                 length: 0))
    }
}

// MARK: - font diagnostics

/// Reports what the Default font name actually resolves to.
///
/// Investigation (2026-07): the Default font is set to "Arial", but the on-
/// screen glyphs didn't look like the system Arial in Word/Font Book. This logs
/// the *resolved* font — its PostScript name, family and size — for each
/// `NSFont`-based body surface, plus a one-time dump of every installed family
/// whose name contains "arial", so a stray install (e.g. a "Pixel Arial") that
/// shadows the name couldn't hide.
///
/// **Finding: no bug.** "Arial" resolved to `ArialMT`, family Arial — the real
/// system Arial. The apparent difference was purely rendering: un-antialiased
/// AppKit Arial at a small size has ~1px solid-black stems and looks nothing
/// like the smoothed Arial in Word/Font Book, which surprised us both. Turning
/// antialiasing on and adjusting the size resolved it.
///
/// Switched off but kept intact, per CLAUDE.md's diagnostics convention.
/// Where first responder actually went while a composer opened.
///
/// Added 2026aug06 for the reply-caret bug (see `focusBody`), and switched off
/// the same day, once it had answered the question. Kept intact per CLAUDE.md.
///
/// **Finding, and it was not the hypothesis the fix was written for.** The log
/// read:
///
///     makeFirstResponder -> true   firstResponder=BODY     attempt=1
///     lost it again, re-asserting  firstResponder=WINDOW — nobody
///     makeFirstResponder -> true   firstResponder=BODY     attempt=15
///     settled                      firstResponder=BODY
///
/// So the grab succeeds first time and is *undone* one runloop turn later,
/// leaving first responder on the window — the caretless, keyless state, arrived
/// at from a success rather than from the refusal the fix was aimed at. The
/// culprit is the handshake's own `focus = nil`: `@FocusState` is bidirectional,
/// SwiftUI applies the nil on its own schedule, and it reads as "unfocus
/// everything". **The re-assert in `focusBody` is therefore load-bearing — do not
/// remove it as belt-and-braces.**
///
/// Reading the log if it is turned back on: the last line is the one that
/// matters. `settled` is working. A trail ending in `makeFirstResponder -> false`
/// twenty times over is the text view refusing the responder outright, which
/// would be a different bug.
enum ComposeFocusDiagnostics {
    static let enabled = false

    static func note(_ label: String, _ window: NSWindow?, extra: String = "") {
        guard enabled else { return }
        let responder: String
        switch window?.firstResponder {
        case let v as BodyTextView where v.window === window: responder = "BODY"
        case is NSTextView:                                   responder = "fieldEditor(a header field)"
        case let w as NSWindow where w === window:            responder = "WINDOW — nobody, no caret, keys go nowhere"
        case .none:                                           responder = "nil"
        case .some(let r):                                    responder = "\(type(of: r))"
        }
        print("[compose focus] \(label) key=\(window?.isKeyWindow ?? false) "
            + "firstResponder=\(responder) \(extra)")
    }
}

enum FontDiagnostics {
    static let enabled = false
    private static var dumpedFamilies = false

    static func logResolution(of name: String, size: Double, context: String) {
        guard enabled else { return }
        if let font = NSFont(name: name, size: CGFloat(size)) {
            print("[font] \(context): \"\(name)\" \(size)pt -> \(font.fontName) "
                + "(family \(font.familyName ?? "?"), \(font.pointSize)pt)")
        } else {
            print("[font] \(context): \"\(name)\" \(size)pt did NOT resolve -> fell back to "
                + NSFont.systemFont(ofSize: CGFloat(size)).fontName)
        }
        dumpArialFamiliesOnce()
    }

    private static func dumpArialFamiliesOnce() {
        guard !dumpedFamilies else { return }
        dumpedFamilies = true
        let manager = NSFontManager.shared
        for family in manager.availableFontFamilies
        where family.lowercased().contains("arial") {
            let members = (manager.availableMembers(ofFontFamily: family) ?? [])
                .compactMap { $0.first as? String }
            print("[font] installed family \"\(family)\": \(members)")
        }
    }
}

// MARK: - the controller

/// Mediates between the `NSTextView` and SwiftUI.
///
/// Owns nothing AppKit strongly (the text view is `weak`; the view hierarchy
/// owns it), publishes the current selection's formatting for the strip to
/// mirror, and exposes mutators the strip calls. `content` is the editor's live
/// `RichText`, republished on every edit.
///
/// **Deliberately not `@MainActor`.** Every method here runs on the main thread
/// at runtime — AppKit's delegate callbacks and SwiftUI both call in on it — but
/// annotating the class would make its methods actor-isolated, and the macOS 13
/// SDK's `NSTextViewDelegate` requirements are `nonisolated`, which Swift 5.7
/// then refuses to let an isolated method satisfy. Leaving it unannotated keeps
/// the conformance legal without changing where anything actually runs.
final class RichTextEditorController: NSObject, ObservableObject, NSTextViewDelegate {

    /// The live body, relative to `defaults`. `ComposeView` compares this for
    /// dirtiness and assembles from it.
    @Published private(set) var content = RichText(plain: "")

    // Selection formatting, mirrored into the strip's controls.
    @Published private(set) var selectionBold = false
    @Published private(set) var selectionItalic = false
    @Published private(set) var selectionFontName = "Arial"
    @Published private(set) var selectionFontSize: Double = 12
    /// The selection's colour, already resolved to sRGB for the colour well.
    @Published private(set) var selectionColor = Color(nsColor: .textColor)

    private(set) var defaults = RichTextDefaults.arial12
    weak var textView: BodyTextView?

    /// Set while the controller itself is writing to the text storage, so the
    /// resulting `textDidChange` doesn't re-read and republish in the middle of
    /// a mutation it already knows the outcome of.
    private var isMutating = false

    // MARK: auto-correction (the user's own list)

    /// The replacement for a just-completed word, or nil. Set by `ComposeView`
    /// from `AppModel`; defaults to no-op so the editor works uninjected.
    var lookupCorrection: (String) -> String? = { _ in nil }
    /// Persist a new correction (the right-click quick-add). Set by `ComposeView`.
    var saveCorrection: (_ trigger: String, _ replacement: String) -> Void = { _, _ in }

    /// When the last change was a typed word-terminator: where the word before it
    /// ends, and the terminator's own length (usually 1, but 2 for an astral-plane
    /// character). Consumed in `textDidChange`.
    private var pendingCorrection: (end: Int, terminatorLength: Int)?

    /// The default font, resolved once per `defaults` value.
    private var defaultFont: NSFont {
        NSFont(name: defaults.family, size: CGFloat(defaults.size))
            ?? NSFont(name: "Arial", size: CGFloat(defaults.size))
            ?? NSFont.systemFont(ofSize: CGFloat(defaults.size))
    }

    // MARK: setup

    /// Wire up the text view and load the seed once.
    ///
    /// The `@Published` writes are deferred to the next runloop turn: this runs
    /// inside the representable's `makeNSView`, which is a SwiftUI view-update
    /// pass, and mutating published state there draws the "Publishing changes
    /// from within view updates" warning. Setting the text storage itself is not
    /// published, so the content is on screen immediately; only the derived
    /// state waits a turn.
    func attach(_ textView: BodyTextView, seed: RichText, defaults: RichTextDefaults) {
        self.textView = textView
        self.defaults = defaults
        FontDiagnostics.logResolution(of: defaults.family, size: defaults.size,
                                      context: "compose editor")
        textView.delegate = self
        textView.typingAttributes = [.font: defaultFont, .foregroundColor: NSColor.textColor]
        textView.textStorage?.setAttributedString(
            RichTextAttributed.attributed(seed, defaults: defaults))
        DispatchQueue.main.async { [weak self] in
            self?.readBack()
            self?.refreshSelection()
        }
    }

    /// Put the caret at the very top of the body and give it first responder, so
    /// a reply opens ready to type the answer above the quoted text.
    ///
    /// Only for a draft that arrives with a recipient already filled in. On a new
    /// message the first thing wanted is the address, and AppKit's own choice —
    /// the first key view, which is To — is already right.
    ///
    /// Two mechanisms, because they cover different moments. `initialFirstResponder`
    /// is what AppKit consults the first time the window is made key, and setting
    /// it means our choice *is* AppKit's choice rather than a correction racing
    /// it; `makeFirstResponder` handles a window that is already key by the time
    /// this runs. Both are idempotent.
    ///
    /// The retry mirrors `WindowCloseGuard.install`: this is called from
    /// `onAppear`, and the text view has no window on the first pass. It only
    /// re-arms while there is no window, so it cannot yank focus from a user who
    /// has clicked somewhere — there is nothing on screen to click yet.
    ///
    /// `onFocused` must clear the composer's `@FocusState`, and taking the body
    /// is not finished until it has. `RecipientField` writes `focus = .to` from
    /// `controlTextDidBeginEditing` when AppKit's key-view loop hands To its
    /// field editor, and then re-grabs first responder from `updateNSView` on
    /// every pass where `focus == .to` and the field has no editor — which is
    /// exactly the state this leaves behind. `ComposeView.body` reads
    /// `editor.content`, so every republish (the deferred `readBack` here, then
    /// the first keystroke in the body) runs that pass. Without the handshake
    /// the caret jumps out of the body and into To after one character, and only
    /// sometimes, depending on whether the window became key first.
    /// **A refusal used to be abandoned, and that was the bug of 2026aug06.**
    /// `if window.makeFirstResponder(textView) { onFocused() }` did nothing at all
    /// when the grab was refused — and AppKit's documented behaviour on refusal is
    /// to leave the *window* as first responder, because the previous responder
    /// has already resigned by then. That single line produced both of the
    /// symptoms Stephen saw, separated only by whether another SwiftUI update pass
    /// happened to follow: one did, `RecipientField.updateNSView` re-grabbed To
    /// (caret back in To); none did, and nobody was first responder at all (no
    /// caret anywhere, keystrokes swallowed). Two additions close it — a refusal
    /// is retried rather than dropped, and a *success* is re-checked a turn later,
    /// because AppKit hands first responder to the first key view when a window
    /// becomes key and SwiftUI's focus machinery does the same when it rebuilds.
    /// `ContentView.applyPendingFocus` re-checks the message table for exactly
    /// that reason and is the precedent here.
    ///
    /// `window.initialFirstResponder` is kept but is close to decorative: it is
    /// only consulted when a window becomes key while the *window itself* holds
    /// first responder, and by the time this can run the grab below has usually
    /// settled the matter. It costs nothing and covers the one ordering where the
    /// window is not yet key.
    func focusBody(attemptsLeft: Int = 20, onFocused: @escaping () -> Void = {}) {
        // `superview` as well as `window`: a text view SwiftUI has replaced can
        // still answer a window while detached from its view tree, and the grab
        // below would then succeed on a view that draws no caret and takes no
        // keys — indistinguishable from the failure this exists to fix.
        guard let textView, textView.superview != nil, let window = textView.window else {
            guard attemptsLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.focusBody(attemptsLeft: attemptsLeft - 1, onFocused: onFocused)
            }
            return
        }
        let top = NSRange(location: 0, length: 0)
        textView.setSelectedRange(top)
        textView.scrollRangeToVisible(top)
        window.initialFirstResponder = textView

        let took = window.makeFirstResponder(textView)
        ComposeFocusDiagnostics.note("makeFirstResponder -> \(took)", window,
                                     extra: "attempt=\(20 - attemptsLeft)")
        guard took else {
            // Retried, not abandoned. Leaving a refusal to stand is what stranded
            // first responder on the window.
            guard attemptsLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.focusBody(attemptsLeft: attemptsLeft - 1, onFocused: onFocused)
            }
            return
        }
        // Only on success, as before: a refused change must not leave the
        // recipient fields believing focus is nowhere.
        onFocused()

        // Confirm it stuck. Budgeted deliberately short — `min(attemptsLeft, 6)`
        // is at most 0.3s, over well before a freshly-opened window is usable — so
        // this can re-assert against AppKit and SwiftUI without ever being able to
        // fight a user who has deliberately clicked into To.
        guard attemptsLeft > 0 else { return }
        let budget = min(attemptsLeft, 6) - 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak textView, weak window] in
            guard let self, let textView, let window else { return }
            guard window.firstResponder !== textView else {
                ComposeFocusDiagnostics.note("settled", window)
                return
            }
            ComposeFocusDiagnostics.note("lost it again, re-asserting", window)
            self.focusBody(attemptsLeft: budget, onFocused: onFocused)
        }
    }

    // MARK: delegate

    /// Note a typed word-terminator so `textDidChange` can correct the word that
    /// just closed. Only a single non-alphanumeric character inserted at a caret
    /// counts — not a paste, a deletion, or a multi-character change — so a
    /// correction never fires from anything but finishing a word by typing.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        // Not while an IME is mid-composition: those intermediate insertions
        // aren't finished words.
        if affectedCharRange.length == 0, !textView.hasMarkedText(),
           let s = replacementString, Self.isTypedBoundary(s) {
            pendingCorrection = (affectedCharRange.location, (s as NSString).length)
        } else {
            pendingCorrection = nil
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isMutating else { return }
        if let p = pendingCorrection {
            pendingCorrection = nil
            applyCorrection(endingBefore: p.end, terminatorLength: p.terminatorLength)
        }
        readBack()

        // **A workaround, not an explanation.** Text sometimes stops being drawn
        // after an edit: paste a URL, press Return twice, and the pasted run goes
        // invisible. It is still there — the caret walks through it — and it
        // comes back on anything that forces a full redraw.
        //
        // What was measured, 2026aug04: it happens with anti-aliasing set to
        // *System*, so `BodyTextView`'s custom halo drawing is not involved;
        // resizing the window brings the text back, so it is laid out and simply
        // not painted; and the pasted run carries no unusual attributes, since
        // `paste` routes external pastes through `pasteAsPlainText`. That places
        // it squarely in invalidation, and nothing this subclass overrides
        // touches invalidation — so the cause is upstream of anything here and
        // was not found.
        //
        // Invalidating the visible rect after every change costs one repaint of
        // what is already on screen, which for a compose body is nothing, and it
        // cannot leave a region unpainted. If the real cause ever surfaces, this
        // is the line to delete.
        if let textView { textView.setNeedsDisplay(textView.visibleRect) }
    }

    /// Replace the word ending just before `end` (where the terminator was typed)
    /// with its correction, if any. A single undo step, keeping the word's own
    /// formatting; leaves the terminator and the caret where they were.
    private func applyCorrection(endingBefore end: Int, terminatorLength: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        guard end > 0, end <= ns.length else { return }
        // Walk back over the word characters to the word's start.
        var start = end
        while start > 0, Self.isWordCharacter(ns.character(at: start - 1)) { start -= 1 }
        guard start < end else { return }

        let word = ns.substring(with: NSRange(location: start, length: end - start))
        guard let replacement = lookupCorrection(word) else { return }

        let range = NSRange(location: start, length: end - start)
        let attrs = storage.attributes(at: start, effectiveRange: nil)
        let attributed = NSAttributedString(string: replacement, attributes: attrs)
        // A distinct undo step from the surrounding typing, so one ⌘Z undoes just
        // the correction.
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        isMutating = true
        storage.replaceCharacters(in: range, with: attributed)
        textView.didChangeText()
        isMutating = false

        // The caret sat just after the terminator; shift it by the length change.
        let delta = (replacement as NSString).length - (end - start)
        let caret = min(end + terminatorLength + delta, (storage.string as NSString).length)
        textView.setSelectedRange(NSRange(location: max(0, caret), length: 0))
    }

    /// Show the quick-add prompt for `word` (the editor's right-click item), and
    /// save the rule the user confirms.
    func promptAddCorrection(for word: String) {
        let alert = NSAlert()
        alert.messageText = "Correct “\(word)” to:"
        alert.informativeText =
            "Whenever you type “\(word)” as a whole word, it will be replaced with what you enter here."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = word
        field.selectText(nil)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // At the pointer, anchored on the field. This one is reached by
        // right-clicking a word in the composer ("Correct “x” to…"), so the same
        // argument applies as for the New Mailbox and Rename prompts: the hand is
        // at the word, and the gesture is type-and-Return rather than a click.
        guard PointerAlert.runModal(alert, anchor: field) == .alertFirstButtonReturn else {
            return
        }
        saveCorrection(word, field.stringValue)
    }

    /// A character that is part of a word (letters, digits) — what we walk back
    /// over to find the word before a terminator.
    static func isWordCharacter(_ c: unichar) -> Bool {
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// A single typed character that ends a word: anything that isn't a word
    /// character — a space, return, or punctuation.
    static func isTypedBoundary(_ s: String) -> Bool {
        guard s.count == 1, let scalar = s.unicodeScalars.first else { return false }
        return !CharacterSet.alphanumerics.contains(scalar)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isMutating else { return }
        refreshSelection()
    }

    /// Republish `content` from the text storage.
    private func readBack() {
        guard let storage = textView?.textStorage else { return }
        content = RichTextAttributed.richText(storage, defaults: defaults)
    }

    // MARK: selection state → strip

    /// The attributes in force: the typing attributes when the selection is
    /// empty, or the selection's first character otherwise.
    ///
    /// **Typing attributes, not the character to the left, for an empty caret.**
    /// AppKit resets `typingAttributes` from the surrounding text on every
    /// selection change, so it already reflects the run the caret sits in — and,
    /// crucially, it is *also* what the empty-selection mutators write to. Read
    /// the left-hand character instead and toggling Bold with no selection would
    /// apply (to `typingAttributes`) but the strip would re-read the unchanged
    /// character and show the button snapping straight back off.
    private func currentAttributes() -> [NSAttributedString.Key: Any] {
        guard let textView, let storage = textView.textStorage else { return [:] }
        let sel = textView.selectedRange()
        if sel.length == 0 { return textView.typingAttributes }
        return storage.attributes(at: sel.location, effectiveRange: nil)
    }

    /// Republish the format strip's state from wherever the caret now is.
    ///
    /// **Every write here is guarded, and that is a performance fix, not tidiness
    /// (2026aug06).** This runs from `textViewDidChangeSelection`, so it runs on
    /// every arrow key — and an arrow key inside a run of uniform text changes
    /// none of these five values. Assigning a `@Published` fires
    /// `objectWillChange` whether or not the value differs, and `ComposeView.body`
    /// observes this controller, so each no-op write was re-running the whole
    /// composer body: the recipient fields, `isDirty` (which compares the entire
    /// `RichText`), and `reviewSnapshot`. Stephen measured the consequence as
    /// arrow-key repeat of about 10 characters a second in the composer against
    /// about 30 in TextEdit and in a browser, with the system key-repeat rate at
    /// maximum — so it was not the global setting, which is what I had wrongly
    /// told him. Comparing first turns the common case into no republish at all.
    ///
    /// The colour conversion is done last and only when needed: `usingColorSpace`
    /// allocates, and it was previously run on every caret move.
    private func refreshSelection() {
        let attrs = currentAttributes()
        let font = (attrs[.font] as? NSFont) ?? defaultFont

        let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
        if selectionBold != bold { selectionBold = bold }

        let obliqueness = (attrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0
        let italic = font.fontDescriptor.symbolicTraits.contains(.italic) || obliqueness > 0
        if selectionItalic != italic { selectionItalic = italic }

        let family = font.familyName ?? defaults.family
        if selectionFontName != family { selectionFontName = family }

        let size = Double(font.pointSize)
        if selectionFontSize != size { selectionFontSize = size }

        let nsColor = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB)
        let color = Color(nsColor: nsColor ?? .textColor)
        if selectionColor != color { selectionColor = color }
    }

    // MARK: mutators, called by the strip

    func toggleBold() { setBold(!selectionBold) }
    func toggleItalic() { setItalic(!selectionItalic) }

    func setBold(_ on: Bool) {
        transformFonts { font in
            let manager = NSFontManager.shared
            return on ? manager.convert(font, toHaveTrait: .boldFontMask)
                      : manager.convert(font, toNotHaveTrait: .boldFontMask)
        }
    }

    /// Italic, with synthetic slant for a face that has no real italic — the same
    /// fallback `RichTextAttributed` uses, so live editing and a reopened draft
    /// look the same and read back the same.
    func setItalic(_ on: Bool) {
        mutate { textView, storage, ranges in
            for range in ranges {
                storage.enumerateAttributes(in: range, options: []) { attrs, sub, _ in
                    let font = (attrs[.font] as? NSFont) ?? defaultFont
                    apply(italic: on, to: font, at: sub, in: storage)
                }
            }
            if ranges.isEmpty {
                let font = (textView.typingAttributes[.font] as? NSFont) ?? defaultFont
                let manager = NSFontManager.shared
                if on {
                    let italic = manager.convert(font, toHaveTrait: .italicFontMask)
                    textView.typingAttributes[.font] = italic
                    if italic.fontDescriptor.symbolicTraits.contains(.italic) {
                        textView.typingAttributes[.obliqueness] = nil
                    } else {
                        textView.typingAttributes[.obliqueness] = 0.2
                    }
                } else {
                    textView.typingAttributes[.font] = manager.convert(font, toNotHaveTrait: .italicFontMask)
                    textView.typingAttributes[.obliqueness] = nil
                }
            }
        }
    }

    /// Set italic on one homogeneous sub-range, choosing real vs synthetic.
    private func apply(italic on: Bool, to font: NSFont, at range: NSRange,
                       in storage: NSTextStorage) {
        let manager = NSFontManager.shared
        if on {
            let italic = manager.convert(font, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italic, range: range)
            if italic.fontDescriptor.symbolicTraits.contains(.italic) {
                storage.removeAttribute(.obliqueness, range: range)
            } else {
                storage.addAttribute(.obliqueness, value: 0.2, range: range)
            }
        } else {
            storage.addAttribute(.font, value: manager.convert(font, toNotHaveTrait: .italicFontMask),
                                 range: range)
            storage.removeAttribute(.obliqueness, range: range)
        }
    }

    func setFontFamily(_ family: String) {
        transformFonts { font in
            NSFontManager.shared.convert(font, toFamily: family)
        }
    }

    func setFontSize(_ size: Double) {
        transformFonts { font in
            NSFontManager.shared.convert(font, toSize: CGFloat(size))
        }
    }

    /// Set the foreground colour, or reset to the default when `color` is nil.
    func setColor(_ color: RichTextColor?) {
        let value = color.map(RichTextAttributed.nsColor) ?? NSColor.textColor
        mutate { textView, storage, ranges in
            for range in ranges { storage.addAttribute(.foregroundColor, value: value, range: range) }
            if ranges.isEmpty { textView.typingAttributes[.foregroundColor] = value }
        }
    }

    /// Apply a pure font transform (bold, family, size) over the selection, or to
    /// the typing attributes when the selection is empty.
    ///
    /// Clears a stale synthetic slant: if the transformed font has a *real*
    /// italic trait, any `.obliqueness` this run carried from the synthetic-
    /// italic path is now redundant and would double the slant. Removing it when
    /// (and only when) real italic is present leaves a genuinely synthetic run
    /// alone. `setItalic` owns adding obliqueness; this only tidies after a
    /// family/size/bold change moves a run onto a face that has the real thing.
    private func transformFonts(_ transform: @escaping (NSFont) -> NSFont) {
        mutate { textView, storage, ranges in
            for range in ranges {
                storage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
                    let font = (value as? NSFont) ?? defaultFont
                    let transformed = transform(font)
                    storage.addAttribute(.font, value: transformed, range: sub)
                    if transformed.fontDescriptor.symbolicTraits.contains(.italic) {
                        storage.removeAttribute(.obliqueness, range: sub)
                    }
                }
            }
            if ranges.isEmpty {
                let font = (textView.typingAttributes[.font] as? NSFont) ?? defaultFont
                let transformed = transform(font)
                textView.typingAttributes[.font] = transformed
                if transformed.fontDescriptor.symbolicTraits.contains(.italic) {
                    textView.typingAttributes[.obliqueness] = nil
                }
            }
        }
    }

    /// The one place text storage is edited: brackets the change so it is a
    /// single undo step, suppresses the delegate echo, and republishes after.
    ///
    /// `body` gets the non-empty selected ranges (empty means "caret only —
    /// change typing attributes"). An empty edit still updates typing attributes
    /// so the next character typed carries the new format.
    private func mutate(_ body: (BodyTextView, NSTextStorage, [NSRange]) -> Void) {
        guard let textView, let storage = textView.textStorage else { return }
        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }

        // Only a change that touches text needs the undo bracket; a typing-
        // attribute-only tweak is not a document edit and `shouldChangeText`
        // would refuse it on a read-only-at-that-instant view.
        let editsText = !ranges.isEmpty
        if editsText, !textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) },
                                                 replacementStrings: nil) {
            return
        }
        isMutating = true
        if editsText { storage.beginEditing() }
        body(textView, storage, ranges)
        if editsText {
            storage.endEditing()
            textView.didChangeText()
        }
        isMutating = false

        readBack()
        refreshSelection()
    }
}

// MARK: - the representable

struct RichTextEditor: NSViewRepresentable {
    @ObservedObject var controller: RichTextEditorController
    let seed: RichText
    let defaults: RichTextDefaults
    let antialiasing: BodyAntialiasing
    let haloWhiteness: Double

    func makeNSView(context: Context) -> NSScrollView {
        // A non-zero starting frame so the width-tracking text container isn't
        // momentarily zero-wide before SwiftUI assigns the real frame — that
        // showed as a one-frame collapsed flash. The autoresize mask corrects it
        // to the scroll view's width on first layout.
        let textView = BodyTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 220))
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        // Spell check: red-underline misspellings as you type, with right-click
        // suggestions / Learn / Ignore from AppKit's built-in menu. Grammar and
        // auto-correction stay off — the same conservative stance as the quote and
        // dash substitutions above, so nothing silently rewrites the text.
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.renderingMode = antialiasing
        textView.haloWhiteness = haloWhiteness

        // Grow vertically with the text; the scroll view supplies the clip.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // `CGFloat.greatestFiniteMagnitude` spelled out: bare `.greatest…` is
        // ambiguous between the Int/Double/CGFloat `NSSize` initialisers.
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize =
            NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        controller.attach(textView, seed: seed, defaults: defaults)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Antialiasing can be changed from Settings while a window is open; apply
        // it live. Content and defaults are loaded once in `attach` — re-running
        // them here would clobber edits.
        if let textView = scrollView.documentView as? BodyTextView {
            textView.renderingMode = antialiasing
            textView.haloWhiteness = haloWhiteness
        }
    }
}

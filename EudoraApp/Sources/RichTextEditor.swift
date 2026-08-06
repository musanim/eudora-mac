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

    override func paste(_ sender: Any?) {
        if NSPasteboard.general.string(forType: Self.internalPasteType) == editorToken {
            super.paste(sender)          // copied here — keep its formatting
        } else {
            pasteAsPlainText(sender)     // from elsewhere — plain, matching the caret
        }
    }

    // MARK: quick-add correction
    //
    // Extends — never replaces — AppKit's default editing menu, so the built-in
    // spell-check items (Learn / Ignore / suggestions) stay put; we just add a
    // "Correct 'word' to…" entry at the top for the word under the click (or the
    // current selection). The rule itself is saved by the controller.

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu, let word = correctionTarget(for: event) else { return menu }
        let item = NSMenuItem(title: "Correct “\(word)” to…",
                              action: #selector(addCorrection(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = word
        menu.insertItem(NSMenuItem.separator(), at: 0)
        menu.insertItem(item, at: 0)
        return menu
    }

    /// The word to offer a correction for: the selection if there is one, else
    /// the word under the click. Nil when neither yields a non-empty word.
    private func correctionTarget(for event: NSEvent) -> String? {
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
        return word.isEmpty ? nil : word
    }

    @objc private func addCorrection(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        (delegate as? RichTextEditorController)?.promptAddCorrection(for: word)
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

    private func refreshSelection() {
        let attrs = currentAttributes()
        let font = (attrs[.font] as? NSFont) ?? defaultFont
        selectionBold = font.fontDescriptor.symbolicTraits.contains(.bold)
        let obliqueness = (attrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0
        selectionItalic = font.fontDescriptor.symbolicTraits.contains(.italic) || obliqueness > 0
        selectionFontName = font.familyName ?? defaults.family
        selectionFontSize = Double(font.pointSize)
        if let color = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
            selectionColor = Color(nsColor: color)
        } else {
            selectionColor = Color(nsColor: .textColor)
        }
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

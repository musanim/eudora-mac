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

/// An `NSTextView` that can draw without antialiasing.
///
/// AppKit antialiases text through the graphics context, not a view property, so
/// turning it off means overriding `draw` to clear `shouldAntialias` first. This
/// is what serves Stephen's non-Retina, crisp-stem preference (see
/// `ComposeSettings.antialiasBody`); it affects only how the body looks locally
/// and nothing that is sent.
final class BodyTextView: NSTextView {
    var antialias: Bool = true {
        didSet { if antialias != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !antialias, let ctx = NSGraphicsContext.current else {
            super.draw(dirtyRect)
            return
        }
        ctx.saveGraphicsState()
        ctx.shouldAntialias = false
        super.draw(dirtyRect)
        ctx.restoreGraphicsState()
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

    func textDidChange(_ notification: Notification) {
        guard !isMutating else { return }
        readBack()
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
    let antialias: Bool

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
        textView.antialias = antialias

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
        // Antialiasing can be toggled from Settings while a window is open; apply
        // it live. Content and defaults are loaded once in `attach` — re-running
        // them here would clobber edits.
        (scrollView.documentView as? BodyTextView)?.antialias = antialias
    }
}

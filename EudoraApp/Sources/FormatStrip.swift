import SwiftUI
import AppKit
import EudoraStore

/// The compact formatting controls above the compose body: font, size, colour,
/// bold and italic. No Format menu — this strip is the whole of it.
///
/// Every control still reads the current selection and writes back to it — the
/// strip holds no state of its own and the text view remains the single source
/// of truth — but it does that through **plain values in and closures out**
/// rather than by observing the controller.
///
/// **That is a performance fix, and a measured one (2026aug07).** This used to be
/// `@ObservedObject var controller`, which meant *every* published change on the
/// controller re-evaluated this body — including `content`, which changes on
/// every keystroke. And this body is expensive: `fontPicker` enumerates every
/// installed font family, so a `Text` per face on the machine was being rebuilt
/// for each character typed or deleted.
///
/// A `sample` of ten seconds of held Delete put ~80% of the main thread in the
/// CoreAnimation commit → `NSHostingView.layout()` → SwiftUI view-graph update,
/// and inside that the biggest leaves were `PickerItemView.body`,
/// `PickerContentView.body`, `Toggle.body` and `Button.body` — this strip's
/// controls. The app's own code barely registered: `readBack()` took **10
/// samples out of 13,686**, which is the theory the notes had recorded for this
/// slowness, and it was wrong.
///
/// Taking values and being `Equatable` lets SwiftUI skip the body outright when
/// only the text changed, since none of the five things drawn here depend on it.
/// The caller must apply `.equatable()`; without it the conformance does nothing.
/// See `CLAUDE.md`: "New expensive views should take plain values and be
/// `Equatable`."
struct FormatStrip: View, Equatable {
    let fontName: String
    /// The selection's size unrounded; `roundedSize` is what is displayed and
    /// compared. Rounding here rather than at the call site keeps the tag-matching
    /// rule (below) in one place.
    let fontSize: Double
    let color: Color
    let bold: Bool
    let italic: Bool

    /// Writes back to the selection. Closures rather than a controller reference,
    /// so this view has no way to observe anything and cannot re-render on a
    /// change it doesn't draw.
    let setFamily: (String) -> Void
    let setSize: (Double) -> Void
    /// Takes the model's colour, not the well's `Color`: the "black means no
    /// override" rule is this control's business and is applied before the
    /// closure is called.
    let setColor: (RichTextColor?) -> Void
    let onToggleBold: () -> Void
    let onToggleItalic: () -> Void

    /// **Values only — the closures are deliberately not compared**, and cannot
    /// be. They are made fresh in the caller's `body` on every pass, so including
    /// them would make every comparison false and the `Equatable` conformance
    /// worthless. They close over the controller, which is a reference, so a
    /// stale-looking closure still writes to the live editor.
    ///
    /// Size is compared *rounded*, matching what is displayed: a fractional size
    /// drifting within the same whole point changes nothing on screen.
    static func == (a: FormatStrip, b: FormatStrip) -> Bool {
        a.fontName == b.fontName
            && a.roundedSize == b.roundedSize
            && a.color == b.color
            && a.bold == b.bold
            && a.italic == b.italic
    }

    var body: some View {
        HStack(spacing: 8) {
            fontPicker
            sizePicker
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .help("Text colour")

            Divider().frame(height: 16)

            Toggle(isOn: boldBinding) {
                Image(systemName: "bold")
            }
            .toggleStyle(.button)
            .help("Bold (⌘B)")

            Toggle(isOn: italicBinding) {
                Image(systemName: "italic")
            }
            .toggleStyle(.button)
            .help("Italic (⌘I)")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: font family

    private var fontPicker: some View {
        Picker("", selection: familyBinding) {
            // The current face is always selectable even if it somehow isn't in
            // the system list (a draft naming a font since uninstalled), so the
            // Picker never shows blank.
            if !Self.families.contains(fontName) {
                Text(fontName).tag(fontName)
            }
            ForEach(Self.families, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .labelsHidden()
        .frame(width: 160)
        .help("Font")
    }

    /// The installed families, resolved once. `availableFontFamilies` is sorted
    /// and stable for a session; recomputing it per render would be needless.
    private static let families: [String] = NSFontManager.shared.availableFontFamilies

    // MARK: size

    private var sizePicker: some View {
        Picker("", selection: sizeBinding) {
            // Whatever the selection's actual size is, offer it too, so a size
            // set from a draft (or a future stepper) shows rather than snapping.
            let current = roundedSize
            if !Self.sizes.contains(current) {
                Text(label(current)).tag(current)
            }
            ForEach(Self.sizes, id: \.self) { size in
                Text(label(size)).tag(size)
            }
        }
        .labelsHidden()
        .frame(width: 64)
        .help("Size")
    }

    private static let sizes: [Double] = [8, 9, 10, 11, 12, 13, 14, 16, 18, 24, 36, 48, 72]

    /// The selection size rounded to a whole point for tag-matching, so a
    /// fractional size read from a font doesn't fail to equal any menu tag.
    private var roundedSize: Double { fontSize.rounded() }

    private func label(_ size: Double) -> String {
        size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
    }

    // MARK: bindings

    private var boldBinding: Binding<Bool> {
        Binding(get: { bold }, set: { _ in onToggleBold() })
    }

    private var italicBinding: Binding<Bool> {
        Binding(get: { italic }, set: { _ in onToggleItalic() })
    }

    private var familyBinding: Binding<String> {
        Binding(get: { fontName }, set: { setFamily($0) })
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { roundedSize }, set: { setSize($0) })
    }

    /// The colour well hands back a `Color`; the conversion to the model's own
    /// type stays here rather than in the caller's closure, so the "black means
    /// no override" rule lives with the control that produces it.
    private var colorBinding: Binding<Color> {
        Binding(get: { color }, set: { setColor(Self.richColor(from: $0)) })
    }

    /// Convert the colour well's SwiftUI `Color` to a `RichTextColor`, or nil for
    /// the default text colour so picking black clears the override rather than
    /// pinning it (matching `RichTextAttributed`).
    private static func richColor(from color: Color) -> RichTextColor? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let c = RichTextColor(red: Double(rgb.redComponent),
                              green: Double(rgb.greenComponent),
                              blue: Double(rgb.blueComponent))
        return c.isBlack ? nil : c
    }
}

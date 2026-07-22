import SwiftUI
import AppKit
import EudoraStore

/// The compact formatting controls above the compose body: font, size, colour,
/// bold and italic. No Format menu — this strip is the whole of it.
///
/// Every control is a two-way `Binding` onto the editor controller: the getter
/// mirrors the current selection (so moving the caret updates the strip), the
/// setter applies to the selection (or to the typing attributes when the caret
/// is empty). The controls therefore never hold state of their own — the text
/// view is the single source of truth, and the strip is a window onto it.
struct FormatStrip: View {
    @ObservedObject var controller: RichTextEditorController

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
            if !Self.families.contains(controller.selectionFontName) {
                Text(controller.selectionFontName).tag(controller.selectionFontName)
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
    private var roundedSize: Double { (controller.selectionFontSize).rounded() }

    private func label(_ size: Double) -> String {
        size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
    }

    // MARK: bindings

    private var boldBinding: Binding<Bool> {
        Binding(get: { controller.selectionBold },
                set: { _ in controller.toggleBold() })
    }

    private var italicBinding: Binding<Bool> {
        Binding(get: { controller.selectionItalic },
                set: { _ in controller.toggleItalic() })
    }

    private var familyBinding: Binding<String> {
        Binding(get: { controller.selectionFontName },
                set: { controller.setFontFamily($0) })
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { roundedSize },
                set: { controller.setFontSize($0) })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { controller.selectionColor },
                set: { controller.setColor(Self.richColor(from: $0)) })
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

import Foundation
import SwiftUI
import EudoraRichText

/// The app-wide default body font: the face, size and antialiasing used to
/// *compose* a message and to *read* plain-text and unstyled mail. Surfaced in
/// Settings as "Default font". (The name predates the widening from composing-
/// only to all three body surfaces; kept to avoid churning the UserDefaults keys
/// and every reference.)
///
/// **These describe the *local* view, not the wire.** The face and size are what
/// Stephen sees on his own non-Retina screen; a run left in this default face
/// declares no face on the wire, so recipients see it in their own default
/// rather than having Stephen's screen font imposed. Seeded with Arial 12.
///
/// The three consumers all take these as plain values: the composer and the
/// plain-text reader render an `NSTextView` in this font (and honour the
/// antialiasing toggle via the `BodyTextView` draw override); the HTML reader
/// bakes the face/size into its document's base CSS, with
/// `-webkit-font-smoothing` for the toggle.
///
/// Persisted in UserDefaults, like `AccountStore`. A separate store rather than a
/// section of that one: these are view preferences, not mail-account identity,
/// and nothing about sending depends on them.
/// How body text is smoothed on screen. `.off` is crisp hard pixels; `.system`
/// is macOS font smoothing (which visibly bolds the type); `.eudora` keeps the
/// crisp solid core and adds a flat-gray orthogonal halo, Eudora-7 style — its
/// lightness set by `ComposeSettings.eudoraHaloWhiteness`.
enum BodyAntialiasing: String, CaseIterable, Identifiable {
    case off, system, eudora
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:    return "None"
        case .system: return "System"
        case .eudora: return "Eudora-style"
        }
    }
    /// The HTML reader (WKWebView) can't do the pixel halo, so only `.system`
    /// smooths there; `.off` and `.eudora` both render crisp (no bolding).
    var htmlSmoothingOn: Bool { self == .system }
}

@MainActor
final class ComposeSettings: ObservableObject {
    @Published var bodyFontName: String {
        didSet { UserDefaults.standard.set(bodyFontName, forKey: Self.faceKey) }
    }
    @Published var bodyFontSize: Double {
        didSet { UserDefaults.standard.set(bodyFontSize, forKey: Self.sizeKey) }
    }

    /// Antialiasing for the body text.
    ///
    /// Off suits a non-Retina display and the crisp, single-pixel-stem look
    /// Stephen is after (see the handoff and `EudoraFont`). Applied by the
    /// editor to its `NSTextView`; it does not affect what is sent.
    @Published var bodyAntialiasing: BodyAntialiasing {
        didSet { UserDefaults.standard.set(bodyAntialiasing.rawValue, forKey: Self.aaModeKey) }
    }
    /// The Eudora-style halo's lightness, 0…1 (1 = white/invisible, lower = a
    /// darker gray). Only consulted in `.eudora` mode.
    @Published var eudoraHaloWhiteness: Double {
        didSet { UserDefaults.standard.set(eudoraHaloWhiteness, forKey: Self.haloKey) }
    }

    private static let faceKey = "ComposeBodyFontName"
    private static let sizeKey = "ComposeBodyFontSize"
    private static let aaKey = "ComposeAntialiasBody"        // legacy Bool, migrated below
    private static let aaModeKey = "ComposeBodyAntialiasing"
    private static let haloKey = "ComposeEudoraHaloWhiteness"

    init() {
        let d = UserDefaults.standard
        bodyFontName = d.string(forKey: Self.faceKey) ?? "Arial"
        // `double(forKey:)` returns 0 for an absent key; treat that as unset.
        let storedSize = d.double(forKey: Self.sizeKey)
        bodyFontSize = storedSize > 0 ? storedSize : 12
        // Prefer the new tri-state; otherwise migrate the old on/off Bool
        // (on → system smoothing, off → crisp). Defaults to system, the norm.
        if let raw = d.string(forKey: Self.aaModeKey), let mode = BodyAntialiasing(rawValue: raw) {
            bodyAntialiasing = mode
        } else {
            bodyAntialiasing = (d.object(forKey: Self.aaKey) as? Bool ?? true) ? .system : .off
        }
        // Default a touch lighter than Eudora 7's mid-gray, per Stephen's eyes.
        let halo = d.double(forKey: Self.haloKey)
        eudoraHaloWhiteness = halo > 0 ? halo : 0.72
    }

    /// The defaults the editor measures runs against and renders unstyled text
    /// in. The one place the two numbers become a `RichTextDefaults`.
    var richTextDefaults: RichTextDefaults {
        RichTextDefaults(family: bodyFontName, size: bodyFontSize)
    }
}

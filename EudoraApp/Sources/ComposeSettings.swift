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
    @Published var antialiasBody: Bool {
        didSet { UserDefaults.standard.set(antialiasBody, forKey: Self.aaKey) }
    }

    private static let faceKey = "ComposeBodyFontName"
    private static let sizeKey = "ComposeBodyFontSize"
    private static let aaKey = "ComposeAntialiasBody"

    init() {
        let d = UserDefaults.standard
        bodyFontName = d.string(forKey: Self.faceKey) ?? "Arial"
        // `double(forKey:)` returns 0 for an absent key; treat that as unset.
        let storedSize = d.double(forKey: Self.sizeKey)
        bodyFontSize = storedSize > 0 ? storedSize : 12
        // Antialiasing defaults *on* — the platform norm — so a fresh install
        // looks ordinary; Stephen turns it off for the crisp look if he wants.
        antialiasBody = d.object(forKey: Self.aaKey) as? Bool ?? true
    }

    /// The defaults the editor measures runs against and renders unstyled text
    /// in. The one place the two numbers become a `RichTextDefaults`.
    var richTextDefaults: RichTextDefaults {
        RichTextDefaults(family: bodyFontName, size: bodyFontSize)
    }
}

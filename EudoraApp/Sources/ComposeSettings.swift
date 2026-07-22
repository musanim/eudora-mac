import Foundation
import SwiftUI
import EudoraRichText

/// The composer's display preferences: the face and size new messages are
/// written in, and whether the body is antialiased.
///
/// **These describe the *local* editing view, not the wire.** The face and size
/// here are what Stephen sees while composing on his own non-Retina screen;
/// outgoing HTML always declares Arial regardless (see
/// `RichTextHTML.wireFontFamily`). Seeded with Arial 12 until he settles on a
/// face — the size knob and the antialiasing toggle are both here so he can tune
/// the on-screen look without a rebuild.
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

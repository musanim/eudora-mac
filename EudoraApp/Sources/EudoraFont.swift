import SwiftUI
import AppKit

/// The typeface Eudora 7 used, for the parts of the UI that are meant to look
/// like it: 12-point Arial in the message list and the mailbox list.
///
/// **On the size.** Windows measures type at 96 dpi, macOS at 72, so Windows
/// "12 point" is 16 device pixels while macOS 12 point is 12. Matching Eudora's
/// *apparent* size therefore means about 16 here, not 12; matching the number in
/// its font panel means 12, which looks noticeably smaller on a Mac. `size`
/// below is the one knob — set it to 16 for the same visual weight as Eudora on
/// Windows, or leave it at 13 for something close to Mac convention.
///
/// Arial ships with macOS, but `Font.custom` falls back silently if a face is
/// missing, which would leave no clue why the app looked wrong on some machine.
/// `resolved` checks first and says so.
enum EudoraFont {
    static let name = "Arial"

    /// Point size for list text. The single value to change.
    static let size: CGFloat = 13

    /// Arial at `size`, or the system font if Arial isn't installed.
    static let list: Font = {
        guard NSFont(name: name, size: size) != nil else {
            print("[font] \(name) unavailable — falling back to the system font.")
            return .system(size: size)
        }
        return .custom(name, size: size)
    }()

    /// Same face, for AppKit-drawn text (the message-list column headers are
    /// `NSTableHeaderCell`s, not SwiftUI text — see TableHeaderIconStyler).
    static let listNSFont: NSFont =
        NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
}

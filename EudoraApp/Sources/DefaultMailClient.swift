import AppKit

/// Whether Eudora is the app macOS opens `mailto:` links with, and how to make
/// it so.
///
/// The setting itself is a LaunchServices registration. Apple's documented route
/// to it is Mail's own settings — which means launching Mail, letting it upgrade
/// its message store, and giving it the chance to adopt whatever accounts are
/// signed in at the system level and start fetching. Mid-cutover, with POP
/// accounts that can be configured to delete mail from the server once
/// collected, that is a bad trade for changing one preference. This sets the
/// same registration directly.
///
/// Reading the current handler also answers a question that is otherwise
/// awkward: *which copy* of Eudora is registered. LaunchServices identifies an
/// app by bundle path, not by bundle identifier, so a build in DerivedData and a
/// copy in /Applications are two different apps to it even though they share an
/// identifier — which is why the path is shown, not just the name.
enum DefaultMailClient {

    struct Current {
        /// The app bundle macOS would open a `mailto:` with, if there is one.
        let url: URL?
        /// Whether that is *this* running copy.
        let isThisBuild: Bool
        /// A *different* copy of Eudora — same bundle identifier, another path.
        /// Worth distinguishing, because "mailto: links open Eudora" beside an
        /// enabled "Make Eudora the default" button reads as a contradiction,
        /// and this is the case the whole feature was written to expose.
        let isAnotherEudora: Bool

        var name: String {
            guard let url else { return "no app" }
            if isAnotherEudora { return "another copy of Eudora" }
            return FileManager.default.displayName(atPath: url.path)
        }

        var path: String { url?.path ?? "" }
    }

    /// What macOS would do with a `mailto:` right now.
    static func current() -> Current {
        // `urlForApplication(toOpen:)` rather than a scheme-based call: this one
        // is already used elsewhere in the app, so it is known to compile and
        // behave against the SDK in use. Its one weakness is that with *no*
        // handler registered it can name some merely-capable app rather than
        // returning nil — which would be a confident false statement, so the
        // caller shows the path alongside and lets the user judge.
        guard let probe = URL(string: "mailto:someone@example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            return Current(url: nil, isThisBuild: false, isAnotherEudora: false)
        }
        // Compared by resolved path: `standardizedFileURL` alone would call two
        // bundles equal only if the strings match, and one side can arrive with
        // a symlinked prefix (/private/var vs /var, or a DerivedData path behind
        // a link). `resolvingSymlinksInPath` settles both.
        let a = handler.resolvingSymlinksInPath().standardizedFileURL.path
        let b = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let isThisBuild = (a == b)
        let sameIdentifier = Bundle(url: handler)?.bundleIdentifier != nil
            && Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
        return Current(url: handler,
                       isThisBuild: isThisBuild,
                       isAnotherEudora: sameIdentifier && !isThisBuild)
    }

    /// Whether this copy is running from the read-only App Translocation mount
    /// macOS uses for quarantined bundles. Registering *that* path would work
    /// until the next logout and then break with a path that no longer exists.
    static var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    enum Outcome {
        case succeeded
        /// macOS refused, or the user declined the system's confirmation.
        case failed(String)
        /// No API to do this without opening Mail on this OS version.
        case needsMailApp
    }

    /// Ask macOS to make *this* bundle the `mailto:` handler.
    ///
    /// macOS may put up its own confirmation; the completion fires after the
    /// user answers it, which is why this is asynchronous rather than a function
    /// that returns a verdict.
    ///
    /// Only implemented for macOS 14 and later. The older call —
    /// `LSSetDefaultHandlerForURLScheme` — still exists but is deprecated, and
    /// building against it would put a warning in every compile for a path that
    /// cannot run on the machine this is developed on. On 13 the honest answer
    /// is to point at Mail's setting.
    static func makeDefault(completion: @escaping (Outcome) -> Void) {
        // Every path answers asynchronously on the main queue, so the caller has
        // one contract rather than two.
        func answer(_ outcome: Outcome) {
            DispatchQueue.main.async { completion(outcome) }
        }
        guard !isTranslocated else {
            answer(.failed("Eudora is running from a temporary read-only copy. "
                           + "Move it to Applications, open it from there, and "
                           + "try again."))
            return
        }
        guard #available(macOS 14.0, *) else {
            answer(.needsMailApp)
            return
        }
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL,
            toOpenURLsWithScheme: "mailto"
        ) { error in
            answer(error.map { .failed($0.localizedDescription) } ?? .succeeded)
        }
    }
}

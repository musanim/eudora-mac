import SwiftUI
import AppKit

/// The contents of one compose window: the editor for a single draft, plus the
/// machinery for closing it.
///
/// Thin on purpose. `ComposeView` is the editor and knows nothing about windows;
/// this wraps it with the two things a *window* needs that a sheet didn't — a
/// title, and a way to intercept the close button.
struct ComposeWindow: View {
    /// Scene id, in one place so the scene and everything that opens it agree.
    static let groupID = "compose"

    @EnvironmentObject var model: AppModel
    let draftID: ComposeDraft.ID?

    var body: some View {
        Group {
            if let draftID, let draft = model.openDrafts[draftID] {
                ComposeView(draftID: draftID, seed: draft)
                    // Ties the editor's `@State` to this draft. Without it,
                    // SwiftUI could reuse one window's view state for a
                    // different draft and you would find yourself typing into
                    // the wrong message.
                    .id(draftID)
                    .navigationTitle(title(for: draft))
            } else {
                // A window restored by macOS at launch, pointing at a draft
                // that no longer exists — state restoration reopens windows by
                // their value, and `openDrafts` starts empty. Say so plainly
                // rather than showing an editor bound to nothing.
                VStack(spacing: 8) {
                    Text("This message is no longer open.")
                        .foregroundStyle(.secondary)
                    Text("Unsent messages are kept in Out; "
                            + "double-click one there to go on editing it.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(minWidth: 380, minHeight: 160)
                .padding(24)
            }
        }
    }

    /// The saved subject, or "New Message". Doesn't track what's being typed —
    /// the live subject is the editor's own `@State` and this only sees what has
    /// been written back to the model, so the title settles on save.
    private func title(for draft: ComposeDraft) -> String {
        draft.subject.trimmingCharacters(in: .whitespaces).isEmpty
            ? "New Message" : draft.subject
    }
}

/// Runs a check before a window is allowed to close.
///
/// **Why a proxy delegate.** `windowShouldClose` is the only hook that can stop
/// a close, and SwiftUI owns the window's delegate — assigning our own would
/// break whatever SwiftUI does with it. So this installs an object that
/// implements *only* `windowShouldClose` and forwards every other message to
/// SwiftUI's delegate through `forwardingTarget(for:)`, the ObjC runtime's own
/// mechanism for exactly this.
///
/// The check returns false to hold the window open — the compose editor uses
/// that to put up its Save prompt and then closes the window itself once the
/// user has answered.
struct WindowCloseGuard: NSViewRepresentable {
    /// Return true to let the window close, false to stop it.
    let shouldClose: () -> Bool

    /// Handed the window once it's found, so the view can close it the same way
    /// the title-bar button does.
    ///
    /// `dismiss()` is not good enough: `NSWindow.close()` does not consult
    /// `windowShouldClose`, and SwiftUI's dismissal is unconditional. A footer
    /// Close — or Escape, which shares its shortcut — would then skip the Save
    /// prompt entirely and silently discard the edits. Going through
    /// `performClose(_:)` makes every route identical.
    final class WindowHandle {
        weak var window: NSWindow?
    }
    let handle: WindowHandle

    final class Coordinator {
        var shouldClose: () -> Bool = { true }
        weak var view: NSView?
        var guardDelegate: CloseProxy?
        /// The window we installed on, so teardown can put things back.
        weak var installedOn: NSWindow?

        deinit {
            // Restore SwiftUI's delegate. Leaving ours in place on a window
            // that outlived this view would keep answering for a draft that no
            // longer exists.
            if let window = installedOn, window.delegate === guardDelegate {
                window.delegate = guardDelegate?.original
            }
        }
    }

    /// Implements `windowShouldClose` and passes everything else along.
    final class CloseProxy: NSObject, NSWindowDelegate {
        /// Strong, deliberately. `NSWindow.delegate` is a weak reference, so
        /// once we take the slot nothing else retains SwiftUI's delegate — and
        /// if it deallocated, every message we forward would vanish.
        var original: NSWindowDelegate?
        var shouldClose: () -> Bool = { true }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            // Ask SwiftUI's delegate first if it has an opinion, so this only
            // ever adds a veto rather than overriding one.
            if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
               original.windowShouldClose?(sender) == false {
                return false
            }
            return shouldClose()
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if aSelector == #selector(NSWindowDelegate.windowShouldClose(_:)) { return true }
            return super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if original?.responds(to: aSelector) == true { return original }
            return super.forwardingTarget(for: aSelector)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        // Refreshed every pass — the closure captures the editor's current
        // state, and a stale one would answer from whenever it was installed.
        coordinator.shouldClose = shouldClose
        coordinator.guardDelegate?.shouldClose = shouldClose
        coordinator.view = nsView

        // Re-take the slot if something replaced us. SwiftUI reassigns
        // `window.delegate` on some scene updates, and a guard silently dropped
        // means every close prompt silently stops appearing — a failure with no
        // symptom other than lost work.
        if let proxy = coordinator.guardDelegate,
           let window = coordinator.installedOn, window.delegate !== proxy {
            proxy.original = window.delegate
            window.delegate = proxy
            return
        }

        // The window isn't there on the first pass; retry until it is.
        guard coordinator.guardDelegate == nil else { return }
        DispatchQueue.main.async {
            install(coordinator: coordinator, attemptsLeft: 20)
        }
    }

    @MainActor
    private func install(coordinator: Coordinator, attemptsLeft: Int) {
        guard coordinator.guardDelegate == nil else { return }
        guard let window = coordinator.view?.window else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    install(coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }
        let proxy = CloseProxy()
        proxy.original = window.delegate
        proxy.shouldClose = coordinator.shouldClose
        window.delegate = proxy
        coordinator.guardDelegate = proxy
        coordinator.installedOn = window
        handle.window = window
    }
}

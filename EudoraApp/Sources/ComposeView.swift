import SwiftUI
import AppKit
import EudoraStore
import EudoraNet

struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var accounts: AccountStore

    let draftID: ComposeDraft.ID
    let seed: ComposeDraft

    /// Closes this window.
    @Environment(\.dismiss) private var dismiss

    /// The window this editor is in, filled in by `WindowCloseGuard`. Closing
    /// goes through it rather than `dismiss()`, so the footer's Close button and
    /// Escape take the same route as the title-bar button and can't bypass the
    /// Save prompt.
    @State private var windowHandle = WindowCloseGuard.WindowHandle()
    @State private var to: String
    @State private var cc: String
    @State private var bcc: String
    @State private var subject: String
    @State private var bodyText: String
    @State private var sending = false
    @State private var error: String?

    /// The draft as it stands, including where its record lives in Out and
    /// whether the user's content has ever been written there. Seeded from
    /// `seed` and updated by each save — `seed` itself is a `let`.
    @State private var draft: ComposeDraft

    /// Whether there are edits not yet written to Out.
    ///
    /// Compared against the last saved values rather than tracked with a flag on
    /// every keystroke, so undoing a change back to what was saved correctly
    /// reports clean — and so Close doesn't nag about a message you opened and
    /// didn't touch.
    private var isDirty: Bool {
        to != draft.to || cc != draft.cc || bcc != draft.bcc
            || subject != draft.subject || bodyText != draft.body
    }

    /// True for a message that has never been saved and never edited — ⌘N
    /// followed straight by Close. Nothing to ask about; the empty shell in Out
    /// just goes.
    private var isUntouched: Bool { !draft.hasBeenSaved && !isDirty }

    @State private var showingSavePrompt = false

    /// Set the instant SMTP accepts the message, before it is recorded.
    ///
    /// Between those two steps the draft is still marked unsent and unsaved, so
    /// if recording fails, Close would offer "Don't Save" — which would remove
    /// from Out a message that had genuinely been delivered. Once this is true
    /// nothing discards, and closing never prompts.
    @State private var wasSent = false

    init(draftID: ComposeDraft.ID, seed: ComposeDraft) {
        self.draftID = draftID
        self.seed = seed
        _draft = State(initialValue: seed)
        _to = State(initialValue: seed.to)
        _cc = State(initialValue: seed.cc)
        _bcc = State(initialValue: seed.bcc)
        _subject = State(initialValue: seed.subject)
        _bodyText = State(initialValue: seed.body)
        // A failure to pre-save shows here rather than as a banner: this window
        // goes up on top of the main one immediately, so a banner would be
        // hidden before it could be read.
        _error = State(initialValue: seed.openError)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerFields
            Divider()
            TextEditor(text: $bodyText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .focused($focus, equals: .body)
            Divider()
            footer
        }
        .frame(minWidth: 580, minHeight: 460)
        .background(BackTabCatcher { focus = Self.field(before: focus) })
        // Catches the window's own close button and ⌘W, not just the Close
        // button in the footer — the prompt has to appear however the window is
        // dismissed. Returning false holds it open; the dialog's buttons then
        // close it themselves.
        .background(WindowCloseGuard(shouldClose: {
            if wasSent { return true }
            if isUntouched { model.discardDraft(currentDraft()); return true }
            if isDirty { showingSavePrompt = true; return false }
            return true
        }, handle: windowHandle))
        .onDisappear { model.closeDraft(draftID) }
        .confirmationDialog("Save changes to this message?",
                            isPresented: $showingSavePrompt) {
            Button("Save") {
                if save() { forceClose() }
            }
            // Destructive only when it actually destroys something. On a
            // never-saved message Don't Save removes the record from Out; on one
            // with a saved version it reverts to that version, which is the
            // ordinary meaning and not worth a red button.
            Button("Don't Save", role: .destructive) {
                if !draft.hasBeenSaved { model.discardDraft(currentDraft()) }
                forceClose()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(draft.hasBeenSaved
                 ? "Your changes since the last save will be lost. "
                    + "The message stays in Out as unsent."
                 : "This message hasn't been saved. "
                    + "Discarding removes it from Out.")
        }
    }

    private var headerFields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            field("To", $to, .to)
            field("Cc", $cc, .cc)
            field("Bcc", $bcc, .bcc)
            GridRow {
                Text("Subject").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                TextField("", text: $subject)
                    .focused($focus, equals: .subject)
            }
        }
        .padding(12)
    }

    private func field(_ label: String, _ text: Binding<String>, _ id: Field) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: id)
        }
    }

    // MARK: focus order

    /// The editable fields, in the order Tab walks them.
    private enum Field: Hashable, CaseIterable {
        case to, cc, bcc, subject, body
    }

    @FocusState private var focus: Field?

    /// The field before `current`, wrapping around.
    ///
    /// Only the backward direction is handled here. Tab already walks forward
    /// through AppKit's key-view loop, and intercepting that as well would mean
    /// reimplementing behaviour that works — including the parts of it, like
    /// where focus starts, that nothing here knows about. Shift-Tab is the half
    /// that doesn't arrive, because `TextEditor` is an `NSTextView` and swallows
    /// it rather than passing it back up the loop.
    ///
    /// A nil focus (nothing in the window focused yet) goes to the last field,
    /// which is what shift-tabbing into a window should do.
    private static func field(before current: Field?) -> Field {
        let order = Field.allCases
        guard let current, let i = order.firstIndex(of: current) else { return order[order.count - 1] }
        return order[(i - 1 + order.count) % order.count]
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // "Close", not "Cancel". The message already exists in Out as
            // unsent, so closing isn't an undo — it's a decision about what to
            // do with edits since the last save.
            Button("Close") { attemptClose() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
            if !accounts.isReadyToSend {
                SettingsButton { Text("Settings…") }
            }
            Spacer()
            if let error {
                // An HStack rather than a `Label`, so `.textSelection` in
                // `copyable` lands on a real `Text` — a Label's title isn't
                // reliably selectable.
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                        .lineLimit(3)
                        .copyable(error)
                }
                .foregroundStyle(Color(red: 0.75, green: 0.05, blue: 0.05))
                .font(.callout.weight(.semibold))
            }
            if sending { ProgressView().controlSize(.small) }
            Button("Send") { send() }
                .keyboardShortcut("d", modifiers: .command)   // ⌘D, Eudora's Send
                // `wasSent` as well as `sending`: if delivery succeeded but
                // writing it to Out failed, the window stays open showing that
                // error — and Send must not still be live, or the obvious
                // response to the error message is to send the message twice.
                .disabled(sending || wasSent)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    /// Close, asking about unsaved work first.
    ///
    /// An untouched brand-new message doesn't prompt at all — being asked
    /// whether to save a message you never typed in is noise — but its empty
    /// record still has to come out of Out, since it was written on open.
    private func attemptClose() {
        // Deliberately thin: the footer's Close button just asks the window to
        // close, and `WindowCloseGuard` runs the same checks it would for the
        // title-bar button or ⌘W. Duplicating the decision here would mean two
        // places to keep in step, and they would drift.
        requestClose()
    }

    /// Close via the window itself, so the guard is consulted.
    ///
    /// `performClose(_:)` sends `windowShouldClose`; `dismiss()` and
    /// `NSWindow.close()` do not. Using `dismiss()` here would mean the footer's
    /// Close button — and Escape, which shares its shortcut — skipped the Save
    /// prompt and discarded the edits without a word. `dismiss()` survives only
    /// as a fallback for the moment before the window has been found.
    private func requestClose() {
        if let window = windowHandle.window {
            window.performClose(nil)
        } else {
            dismiss()
        }
    }

    /// Close *without* consulting the guard, for when the question has already
    /// been answered — the Save prompt, or a successful send.
    ///
    /// **Not a shortcut; the guard cannot be used here.** Its closure is
    /// refreshed by SwiftUI on each render pass, and the state these callers set
    /// (`wasSent`, or the saved `draft`) only takes effect on the *next* pass.
    /// Closing synchronously on the following line means the guard is still
    /// holding the closure captured before the change, sees the same unsaved
    /// draft, and vetoes — which showed up as "Save saved it but the window
    /// stayed open, and Close had to be pressed a second time".
    ///
    /// `NSWindow.close()` doesn't send `windowShouldClose`, which is exactly the
    /// semantics wanted: the decision is made, don't re-ask. `onDisappear` still
    /// runs, so the draft is still released from the model.
    private func forceClose() {
        if let window = windowHandle.window {
            window.close()
        } else {
            dismiss()
        }
    }

    /// The draft with the window's current fields folded in, and its record
    /// location taken from the model.
    ///
    /// The offset **must** come from `model.openDrafts`, not from this view's
    /// `@State`. Saving any earlier draft rewrites its record and moves every
    /// record after it; the model corrects all the open drafts, but a window's
    /// own copy is never told. Using the stale one means `locateDraft` can't
    /// find the record, the save falls through to appending, and Out ends up
    /// with a duplicate and an orphan. That is exactly the bug the model owning
    /// the drafts was meant to prevent, and this is where the ownership has to
    /// be honoured.
    private func currentDraft() -> ComposeDraft {
        var current = draft
        if let live = model.openDrafts[draftID] { current.outOffset = live.outOffset }
        current.to = to
        current.cc = cc
        current.bcc = bcc
        current.subject = subject
        current.body = bodyText
        return current
    }

    /// Write the current fields into the draft's record in Out, still unsent.
    /// - Returns: whether it succeeded, so callers can decline to close on
    ///   failure rather than closing over an error the user never saw.
    @discardableResult
    private func save() -> Bool {
        do {
            draft = try model.saveDraft(currentDraft())
            error = nil
            return true
        } catch {
            self.error = "Couldn't save to Out: " + model.describe(error)
            return false
        }
    }

    /// Turns Shift-Tab in the compose window into "focus the previous field".
    ///
    /// **Why this is needed at all.** Tab walks forward by itself: AppKit's
    /// key-view loop handles it and SwiftUI's `@FocusState` follows along. The
    /// backward half doesn't arrive, because the body is a `TextEditor` — an
    /// `NSTextView` — and text views consume Shift-Tab rather than passing it up
    /// the loop, so the cycle only ever runs one way.
    ///
    /// **Why an event monitor.** macOS 13 has no `.onKeyPress`; that's macOS 14.
    /// A local monitor is how this codebase already takes keys and clicks
    /// AppKit won't otherwise surrender (see `TableScrollStateSyncer`'s wheel
    /// handling and `MessageDoubleClickController`).
    ///
    /// **Scoped to one window.** The monitor is global to the process, so it
    /// checks the event's window against the one this view is in. Without that,
    /// Shift-Tab would be hijacked in the main window and the Find window too.
    private struct BackTabCatcher: NSViewRepresentable {
        let onShiftTab: () -> Void

        final class Coordinator {
            var onShiftTab: () -> Void = {}
            /// The backing view, not its window. `nsView.window` is usually nil
            /// on the first `updateNSView` — the view isn't in the hierarchy yet
            /// — so caching the window there would install a monitor that could
            /// never match, and recovery would depend on SwiftUI happening to
            /// update again. Resolving it live self-heals, and is what
            /// `TableScrollStateSyncer` does for the same reason.
            weak var view: NSView?
            var monitor: Any?
            deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        }

        func makeCoordinator() -> Coordinator { Coordinator() }
        func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

        func updateNSView(_ nsView: NSView, context: Context) {
            let coordinator = context.coordinator
            // Refreshed every pass: the closure captures the current `focus`,
            // and a stale one would always move back from wherever focus was
            // when the monitor was installed.
            coordinator.onShiftTab = onShiftTab
            coordinator.view = nsView
            guard coordinator.monitor == nil else { return }
            coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak coordinator] event in
                guard let coordinator else { return event }
                // 48 is Tab. Shift-Tab also arrives as keyCode 48 with the shift
                // flag; matching on the character would mean handling the
                // back-tab control code (0x19) as well, which is less clear.
                //
                // Shift and *only* shift: ⌥⇧Tab and ⌃⇧Tab are different
                // gestures and shouldn't be swallowed as if they were this one.
                guard event.keyCode == 48,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift,
                      let window = coordinator.view?.window,
                      event.window === window else { return event }
                coordinator.onShiftTab()
                return nil          // consumed, or the text view inserts a tab
            }
        }
    }

    private func send() {
        // Belt as well as the disabled button: ⌘D goes through the same action,
        // and delivering twice is not recoverable.
        guard !wasSent, !sending else { return }
        guard accounts.account.isConfigured else {
            error = "Set up your SMTP account first — use the Settings… button."; return
        }
        guard !accounts.password.isEmpty else {
            error = "No password saved — use the Settings… button."; return
        }
        let toList = model.splitAddresses(to)
        guard !toList.isEmpty else { error = "Add at least one recipient."; return }

        let account = accounts.account
        let password = accounts.password
        let message = OutgoingMessage(
            fromName: account.fromName, fromAddress: account.fromAddress,
            to: toList, cc: model.splitAddresses(cc), bcc: model.splitAddresses(bcc),
            subject: subject, body: bodyText,
            inReplyTo: seed.inReplyTo, references: seed.references)

        sending = true
        error = nil
        Task {
            do {
                let sent = try await SMTPClient.send(message, account: account, password: password)
                // Before recording, not after: the message is out of our hands
                // from here, and if writing it to Out fails we must not go on to
                // offer to discard it.
                wasSent = true
                // Rewrites the draft's own record as sent rather than appending
                // a second copy — otherwise the unsent original would sit in Out
                // next to it forever.
                try model.recordSent(currentDraft(), raw: sent.raw,
                                     who: toList.first ?? "", subject: subject)
                model.showBanner("Message sent.")
                sending = false
                // Not `requestClose()`: `wasSent` was set moments ago and the
                // guard's closure won't have been refreshed yet, so it would
                // still see an unsaved draft and ask about a message that has
                // already gone out.
                forceClose()
            } catch {
                sending = false
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                // Mark the message in Out as having failed to send, and save
                // what's in the window while we're at it. Two reasons: the list
                // should show *why* this message is still sitting there, and a
                // failure that also silently discarded the last edits would be
                // the worst possible moment to lose them.
                //
                // Only for a genuine send failure. A failure *after* delivery is
                // handled above — `wasSent` is already true there and the
                // message did go out.
                if !wasSent {
                    do {
                        draft = try model.markSendFailed(currentDraft())
                    } catch {
                        self.error = (self.error ?? "")
                            + " (It also couldn't be marked as unsent in Out: "
                            + model.describe(error) + ")"
                    }
                }
            }
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EudoraStore
import EudoraNet

struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var accounts: AccountStore
    @EnvironmentObject var composeSettings: ComposeSettings

    let draftID: ComposeDraft.ID
    let seed: ComposeDraft

    /// The body editor's shared controller. Owned here so it outlives render
    /// passes; handed to the `RichTextEditor` representable and the `FormatStrip`
    /// so the strip mirrors and drives the same text view.
    @StateObject private var editor = RichTextEditorController()

    /// The content the editor was seeded with, resolved once at init. Loading it
    /// is the representable's job (see `RichTextEditor.attach`); this just holds
    /// the value to hand over.
    private let seedContent: RichText

    /// Closes this window.
    @Environment(\.dismiss) private var dismiss

    /// The window this editor is in, filled in by `WindowCloseGuard`. Closing
    /// goes through it rather than `dismiss()`, so the footer's Close button and
    /// Escape take the same route as the title-bar button and can't bypass the
    /// Save prompt.
    @State private var windowHandle = WindowCloseGuard.WindowHandle()
    @State private var from: String
    @State private var to: String
    @State private var cc: String
    @State private var bcc: String
    @State private var subject: String
    /// Files attached to this message, shown in the Attachments row.
    @State private var attachments: [OutgoingMessage.Attachment]
    @State private var sending = false
    @State private var error: String?
    /// Whether a file drag is currently over the Attachments row.
    @State private var dropTargeted = false
    /// Recipient fields the server refused (highlighted red until edited).
    @State private var invalidFields: Set<Field> = []

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
        from != draft.from || to != draft.to || cc != draft.cc || bcc != draft.bcc
            || subject != draft.subject || editor.content != draft.content
            // Compare by identity, not bytes: attachments are only added or
            // removed whole, never edited in place, so the id list captures every
            // change without comparing (possibly large) `Data` on each render.
            || attachments.map(\.id) != draft.attachments.map(\.id)
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
        self.seedContent = seed.content
        _draft = State(initialValue: seed)
        _from = State(initialValue: seed.from)
        _to = State(initialValue: seed.to)
        _cc = State(initialValue: seed.cc)
        _bcc = State(initialValue: seed.bcc)
        _subject = State(initialValue: seed.subject)
        _attachments = State(initialValue: seed.attachments)
        // A failure to pre-save shows here rather than as a banner: this window
        // goes up on top of the main one immediately, so a banner would be
        // hidden before it could be read.
        _error = State(initialValue: seed.openError)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerFields
            Divider()
            FormatStrip(controller: editor)
            Divider()
            RichTextEditor(controller: editor,
                           seed: seedContent,
                           defaults: composeSettings.richTextDefaults,
                           antialiasing: composeSettings.bodyAntialiasing,
                           haloWhiteness: composeSettings.eudoraHaloWhiteness)
                // A floor, not a demand: it fills the slack below the header but
                // doesn't insist on maximum height (which inflated the whole stack
                // past the window, clipping To under the title bar and the buttons
                // off the bottom).
                .frame(minHeight: 200)
            Divider()
            footer
        }
        // Tall enough for the six header rows + Attach line, the format strip, a
        // usable body, and the footer — the Attach row pushed the old 460 minimum
        // past the content, so the window clipped its own top and bottom.
        .frame(minWidth: 580, minHeight: 540)
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
        // Keep the model's copy of this window's live content and dirty state
        // current, so a Quit can review (and save) unsaved edits even though the
        // save prompt itself lives in this SwiftUI view. One snapshot covers
        // every field the review cares about; `reviewSnapshot` folds them so a
        // single `onChange` fires for any of them. See `AppModel.reviewComposeBeforeQuit`.
        .onAppear {
            pushReview()
            // Wire the editor's auto-correction to the user's own list.
            editor.lookupCorrection = { model.correctionReplacement(for: $0) }
            editor.saveCorrection = { model.addCorrection(trigger: $0, replacement: $1) }
        }
        .onChange(of: reviewSnapshot) { _ in pushReview() }
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
            recipientField("To", $to, .to)
            GridRow {
                Text("From").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                // Click-only: rarely edited, so it's out of the Tab order (see
                // `ClickOnlyField`) and not one of the tracked focus fields.
                ClickOnlyField(text: $from).frame(height: 22)
            }
            recipientField("Cc", $cc, .cc)
            recipientField("Bcc", $bcc, .bcc)
            GridRow {
                Text("Subject").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                TextField("", text: $subject)
                    .focused($focus, equals: .subject)
            }
            GridRow {
                Text("Attach").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                attachmentsField
            }
        }
        .padding(12)
    }

    /// The Attachments line: chips for what's attached (each removable), a drop
    /// target for dragging files in, and a paperclip button to pick them.
    private var attachmentsField: some View {
        HStack(spacing: 6) {
            if attachments.isEmpty {
                Text("Drag files here")
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachmentChip($0) }
                    }
                }
                // A horizontal ScrollView is vertically greedy by default; pin its
                // height so it can't inflate the whole header block.
                .frame(height: 24)
            }
            Spacer(minLength: 6)
            Button { addAttachmentsViaPanel() } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.borderless)
            .help("Attach a file…")
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { addAttachments(from: $0) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }

    private func attachmentChip(_ att: OutgoingMessage.Attachment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "doc")
            Text(att.filename).lineLimit(1)
            Button {
                attachments.removeAll { $0.id == att.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Remove \(att.filename)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.15), in: Capsule())
    }

    // MARK: attaching files

    /// Read a dropped/picked file into an in-memory attachment. Reading now (not
    /// at send) is what lets the attachment survive the file being moved or the
    /// draft being saved and reopened.
    private func attachFile(at url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            error = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        attachments.append(.init(filename: url.lastPathComponent, mimeType: mime, data: data))
    }

    private func addAttachments(from providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                // The system usually hands a `public.file-url` back as Data, but
                // sometimes as an NSURL/URL — accept either rather than silently
                // dropping the file.
                let url: URL?
                switch item {
                case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
                case let u as URL:      url = u
                case let ns as NSURL:   url = ns as URL
                default:                url = nil
                }
                guard let url else { return }
                DispatchQueue.main.async { attachFile(at: url) }
            }
        }
        return handled
    }

    private func addAttachmentsViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { attachFile(at: url) }
    }

    /// A recipient field (To/Cc/Bcc) with recently-used auto-fill. It manages its
    /// own first responder against the shared `$focus`. It also carries a
    /// `.focused` modifier — not to *drive* the field (the representable does that
    /// from the same binding), but so SwiftUI knows a view claims this focus value
    /// and doesn't reset `$focus` to nil the instant `BackTabCatcher` sets it
    /// during a Shift-Tab, which would strand reverse focus with nowhere to land.
    private func recipientField(_ label: String, _ text: Binding<String>, _ id: Field) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            RecipientField(text: text,
                           focus: $focus,
                           id: id,
                           completions: { model.recipientCompletions(prefix: $0) },
                           remove: { model.removeRecentRecipient($0) })
                .frame(height: 22)
                .focused($focus, equals: id)
                // A red ring on the field the server refused; cleared the moment
                // the user edits it, so it never lingers past a fix.
                .overlay {
                    if invalidFields.contains(id) {
                        RoundedRectangle(cornerRadius: 6).stroke(Color.red, lineWidth: 2)
                    }
                }
                .onChange(of: text.wrappedValue) { _ in invalidFields.remove(id) }
        }
    }

    /// Which recipient fields contain `address` — the one(s) to flag when the
    /// server refuses it. A substring match on the raw text, so it finds the
    /// address whether it was typed bare or inside a "Name <addr>".
    private func fieldsContaining(_ address: String) -> Set<Field> {
        let needle = address.lowercased()
        guard !needle.isEmpty else { return [] }
        var result: Set<Field> = []
        if to.lowercased().contains(needle) { result.insert(.to) }
        if cc.lowercased().contains(needle) { result.insert(.cc) }
        if bcc.lowercased().contains(needle) { result.insert(.bcc) }
        return result
    }

    // MARK: focus order

    /// The editable header fields, in the order Tab walks them. The body is not
    /// here: it's an `NSTextView` that owns its own first-responder handling, so
    /// SwiftUI `@FocusState` neither tracks nor moves it. Shift-Tab from the
    /// first header field wraps to the last header field, not into the body.
    private enum Field: Hashable, CaseIterable {
        // From is deliberately absent — it's click-only, out of the Tab order.
        case to, cc, bcc, subject
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
        current.from = from
        current.to = to
        current.cc = cc
        current.bcc = bcc
        current.subject = subject
        // The plain text is authoritative; the styled body rides alongside it
        // only when the user actually formatted something, which is what keeps
        // an unstyled message on the plain-text path. See `ComposeDraft`.
        let content = editor.content
        current.body = content.plainText
        current.styledBody = content.isStyled ? content : nil
        current.attachments = attachments
        return current
    }

    /// Everything the Quit review needs to know about this window, folded into
    /// one `Equatable` value so a single `onChange` catches any change — a field
    /// edit, a body edit, or `isDirty` flipping after a save.
    private struct ReviewSnapshot: Equatable {
        var from: String, to: String, cc: String, bcc: String, subject: String
        var content: RichText
        // The attachment id list, not the attachments themselves — cheap to
        // compare and enough to notice one added or removed.
        var attachmentIDs: [String]
        var isDirty: Bool
    }

    private var reviewSnapshot: ReviewSnapshot {
        ReviewSnapshot(from: from, to: to, cc: cc, bcc: bcc, subject: subject,
                       content: editor.content, attachmentIDs: attachments.map(\.id),
                       isDirty: isDirty)
    }

    /// Push this window's live content and dirty state into the model, so a Quit
    /// can save or discard it. See `AppModel.reviewComposeBeforeQuit`.
    private func pushReview() {
        model.noteComposeLiveState(currentDraft(), isDirty: isDirty)
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

    /// A single-line field that takes focus on a click but is skipped by Tab, for
    /// the rarely-edited From line. `canBecomeKeyView` false removes it from the
    /// key-view (Tab) loop; a mouse click still makes it first responder.
    private struct ClickOnlyField: NSViewRepresentable {
        @Binding var text: String

        func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

        func makeNSView(context: Context) -> NSTextField {
            let field = TabSkippingTextField()
            field.delegate = context.coordinator
            field.isBordered = true
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.drawsBackground = true
            field.usesSingleLineMode = true
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            field.lineBreakMode = .byClipping
            field.stringValue = text
            return field
        }

        func updateNSView(_ field: NSTextField, context: Context) {
            if field.stringValue != text { field.stringValue = text }
        }

        final class Coordinator: NSObject, NSTextFieldDelegate {
            private let text: Binding<String>
            init(text: Binding<String>) { self.text = text }
            func controlTextDidChange(_ notification: Notification) {
                guard let field = notification.object as? NSTextField else { return }
                text.wrappedValue = field.stringValue
            }
        }

        final class TabSkippingTextField: NSTextField {
            override var canBecomeKeyView: Bool { false }
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
        // Same styling gate as the saved record: HTML only when the user
        // formatted something, so an unstyled message is delivered as exactly
        // today's text/plain bytes.
        let content = editor.content
        let html = content.isStyled ? RichTextHTML.html(from: content) : nil
        // The From the user set in the window (defaulted from the account), split
        // into name + address for assembly; the address is also the SMTP envelope
        // sender. Falls back to the account address only if somehow blank.
        let (fromName, fromAddress) =
            OutgoingMessage.splitFrom(from.isEmpty ? account.fromAddress : from)
        let message = OutgoingMessage(
            fromName: fromName, fromAddress: fromAddress,
            to: toList, cc: model.splitAddresses(cc), bcc: model.splitAddresses(bcc),
            subject: subject, body: content.plainText, htmlBody: html,
            attachments: attachments,
            inReplyTo: seed.inReplyTo, references: seed.references)

        sending = true
        error = nil
        invalidFields = []
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
                // Feed the To addresses into the auto-fill history (To only).
                model.recordSentRecipients(toList)
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
                // If the server named the address it refused, mark the field(s)
                // that address came from so the eye lands on what to fix.
                if let rejected = (error as? SMTPError)?.rejectedRecipient {
                    invalidFields = fieldsContaining(rejected)
                }
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

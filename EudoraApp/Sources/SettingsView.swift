import SwiftUI
import AppKit
import EudoraNet
import EudoraStore

/// A control that opens the Settings scene. On macOS 14+ this uses the
/// sanctioned `SettingsLink` (the selector hack is deprecated there and logs a
/// "Please use SettingsLink" warning); on macOS 13 it falls back to invoking the
/// menu action directly, which also works while a sheet is up.
struct SettingsButton<Label: View>: View {
    @ViewBuilder var label: () -> Label
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink(label: label)
        } else {
            Button(action: openSettingsWindowLegacy, label: label)
        }
    }
}

/// macOS 13 fallback opener. Deferred so it fires after the current menu closes.
@MainActor
func openSettingsWindowLegacy() {
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var accounts: AccountStore
    @EnvironmentObject var composeSettings: ComposeSettings
    /// The Settings window, so Save can close it. Captured by `WindowGrabber`.
    @State private var window: NSWindow?

    /// The "me" set editor's in-progress new entry and last rescan result.
    @State private var newIdentity = ""
    @State private var rescanNote: String?

    /// The corrections list's in-progress new rule.
    @State private var newCorrectionTrigger = ""
    @State private var newCorrectionReplacement = ""

    /// Installed font families, resolved once for the composing-face picker.
    private static let families: [String] = NSFontManager.shared.availableFontFamilies

    /// The pane's fixed width. Only the height is the user's to choose; the
    /// fields, captions and the two-column rows are laid out for this number.
    private static let windowWidth: CGFloat = 480

    /// Where AppKit files the window's frame. Any string works as long as it
    /// stays stable — changing it silently forgets the remembered size.
    private static let frameAutosaveName = "EudoraSettingsWindow"

    /// Make the Settings window vertically resizable, and have AppKit remember
    /// its frame across launches.
    ///
    /// Resizability is *not* set here — `.windowResizability(.contentSize)` on
    /// the scene does that, and it has to, because nothing done to the NSWindow
    /// survives SwiftUI's next layout pass. What this does is the part SwiftUI
    /// doesn't offer: remembering the frame across launches.
    ///
    /// **`.resizable` must be on before the restore.** `setFrameUsingName(_:)`
    /// is `setFrameUsingName(_:force:)` with `force: false`, and in that mode
    /// AppKit applies only the *origin* to a window that isn't resizable — the
    /// saved size is silently dropped. Hence the belt-and-braces insert below,
    /// ordered before the restore.
    private func configureWindow(_ w: NSWindow) {
        // Conditional: this runs on every body evaluation, which for a pane
        // whose stores publish per keystroke means every character typed.
        // `setStyleMask:` is not reliably a no-op on an equal value — it can
        // rebuild the title bar — so don't hand it one.
        //
        // Resizability itself comes from `.windowResizability(.contentSize)` on
        // the scene (see `EudoraApp`); SwiftUI sets this bit as a consequence.
        // It stays here because the frame restore below needs it: with
        // `force: false`, AppKit applies only the *origin* to a window that
        // isn't resizable, silently dropping the saved size.
        if !w.styleMask.contains(.resizable) { w.styleMask.insert(.resizable) }

        // Guarded because `updateNSView` can resolve the same window more than
        // once, and re-restoring would yank a window the user had just dragged
        // back to its saved frame.
        //
        // Restore *then* name: `setFrameUsingName` reads UserDefaults directly
        // and doesn't need the name to be set first, while naming first risks
        // AppKit writing the current frame out and clobbering the saved value
        // microseconds before it is read.
        if w.frameAutosaveName != Self.frameAutosaveName {
            w.setFrameUsingName(Self.frameAutosaveName)
            w.setFrameAutosaveName(Self.frameAutosaveName)
        }

        // Deliberately NOT setting contentMinSize/contentMaxSize. With
        // `.windowResizability(.contentSize)` SwiftUI derives both from the root
        // view's own minimum and maximum — which the `.frame` on the body
        // already states — and a second, hand-set copy of the same numbers is
        // one more thing to disagree with it. The earlier attempt set them and
        // they were simply overwritten.

        Self.logSizing(w)
    }

    /// Why the Settings window will or won't resize, in one line.
    ///
    /// Off, but intact — the way this codebase keeps its diagnostics. It earned
    /// its keep immediately: two attempts at a resizable Settings pane failed
    /// before the cause was found, and both failures would have been one line of
    /// output each. What to read: `contentMin` and `contentMax` with *equal*
    /// heights mean something is pinning the window to its fitting size, which
    /// is what `.windowResizability(.contentSize)` on the scene exists to stop.
    /// Printed twice because the telling value isn't the one right after
    /// configuring, it's the one a layout pass later once SwiftUI has had its
    /// say.
    private static var logSizingEnabled = false

    /// Whether the deferred dump has been queued. `configureWindow` runs on
    /// every body evaluation — every keystroke — and without this the pane would
    /// queue one deferred print per character typed.
    private static var didLogSettled = false

    private static func logSizing(_ w: NSWindow) {
        guard logSizingEnabled else { return }
        // `n` guards every number: `contentMaxSize` defaults to CGFLOAT_MAX on
        // both axes, and `Int(CGFloat.greatestFiniteMagnitude)` is a trap — the
        // diagnostic would crash on exactly the reading it was turned on for.
        func n(_ v: CGFloat) -> String { v > 1e6 ? "∞" : String(Int(v)) }
        func describe(_ o: AnyObject?) -> String {
            o.map { String(describing: type(of: $0)) } ?? "nil"
        }
        func report(_ when: String) {
            // `type(of:)` on the Optional itself would print
            // `Optional<NSViewController>` — the static type, and useless. The
            // hosting class is the whole point, and for a SwiftUI scene it may
            // be the content *view* rather than a controller.
            print("""
                [Settings/\(when)] resizable=\(w.styleMask.contains(.resizable)) \
                frame=\(n(w.frame.width))×\(n(w.frame.height)) \
                contentMin=\(n(w.contentMinSize.width))×\(n(w.contentMinSize.height)) \
                contentMax=\(n(w.contentMaxSize.width))×\(n(w.contentMaxSize.height)) \
                controller=\(describe(w.contentViewController)) \
                view=\(describe(w.contentView))
                """)
        }
        report("configured")
        guard !didLogSettled else { return }
        didLogSettled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { report("settled") }
    }

    /// The auto-check interval field, clamped to at least 1 minute on entry so
    /// the number field can never hold a zero or negative interval.
    private var autoCheckMinutes: Binding<Int> {
        Binding(get: { accounts.autoCheckMinutes },
                set: { accounts.autoCheckMinutes = max(1, $0) })
    }

    var body: some View {
        // Form on top, Save fixed at the bottom. The button used to be the last
        // Section, which put it inside the form's scroll view — so on a short
        // window it scrolled away with everything else. A dialog's confirming
        // action shouldn't be something you have to go looking for.
        VStack(spacing: 0) {
            settingsForm
            Divider()
            footer
        }
        // Fixed width, free height. The width is a deliberate constant — the
        // fields and captions are laid out for it — while the height is
        // whatever the user drags it to, remembered between launches. The
        // grouped form scrolls when the window is shorter than its content, so
        // there is no height at which anything becomes unreachable.
        //
        // 880 was the old fixed height and is kept as the *ideal*, so a first
        // run with no remembered frame opens showing everything as it used to —
        // plus ~50pt, because the Save row now sits outside the form rather than
        // being the last thing in it.
        //
        // One call: `width:` and `minHeight:` are different overloads and cannot
        // be mixed, so the fixed width is expressed as min == ideal == max.
        .frame(minWidth: Self.windowWidth, idealWidth: Self.windowWidth,
               maxWidth: Self.windowWidth,
               minHeight: 360, idealHeight: 930, maxHeight: .infinity)
        // Return moves to the next field, the way Tab does.
        //
        // Attached to the container rather than to each field: SwiftUI
        // propagates a submit outward through the hierarchy, so one handler here
        // serves every text field in the form, including the ones inside the
        // per-account rows that don't exist until an account is added.
        //
        // The traversal is AppKit's own, so the order is exactly the order Tab
        // already follows and the two can't disagree. It wraps at the end,
        // again like Tab.
        .onSubmit(advanceFocus)
        // Not `!==`-guarded any more. `configureWindow` is idempotent, and the
        // window has to be re-asserted rather than configured once: SwiftUI
        // rewrites the window's content min/max size from the root view on its
        // own schedule, and a single early pass can be undone by a later one.
        // The `window` *assignment* is still guarded, because reassigning the
        // same value would invalidate the view and spin.
        .background(WindowGrabber { resolved in
            if window !== resolved { window = resolved }
            if let resolved { configureWindow(resolved) }
        })
        .navigationTitle("Settings")
    }

    /// Move focus one step along the key-view loop — Tab's own traversal.
    ///
    /// Neither half of this is incidental.
    ///
    /// **The starting view is captured now.** `selectNextKeyView(nil)` works
    /// from `window.firstResponder`, and during a Return that is the shared
    /// *field editor* — an `NSTextView` whose place in the loop is not the
    /// field's — or, for an instant, the window itself, in which case AppKit
    /// falls back to `initialFirstResponder` and focus would leap to the top of
    /// the form rather than to the next field. The editor's delegate is the
    /// control being edited, which is the view actually wanted.
    ///
    /// **The move is deferred a runloop turn.** AppKit isn't finished when the
    /// submit action runs: after it returns, the Return movement ends editing
    /// and then *re-establishes* it on the same field with its text selected.
    /// Moving focus from inside that would simply be undone — the symptom being
    /// a Return that appears to do nothing but highlight the text.
    private func advanceFocus() {
        guard let window else { return }
        let editor = window.firstResponder as? NSTextView
        let start = (editor?.isFieldEditor == true ? editor?.delegate as? NSView : nil)
            ?? window.firstResponder as? NSView
        DispatchQueue.main.async {
            if let start, start.window === window {
                window.selectKeyViewFollowingView(start)
            } else {
                window.selectNextKeyView(nil)
            }
        }
    }

    /// The Save row, outside the form's scroll view so it is always on screen.
    private var footer: some View {
        HStack(spacing: 12) {
            if accounts.account.security == .startTLS {
                Label("STARTTLS (587) isn't implemented yet — use SSL/TLS on 465 for now.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(red: 0.75, green: 0.05, blue: 0.05))
            }
            Spacer()
            // Save writes to the Keychain and closes the window — the close is
            // the confirmation, which is why there's no "Saved" checkmark.
            Button("Save") {
                // Commit whatever is mid-edit first. `TextField(value:format:)`
                // — the Port and interval fields — writes through only on Return
                // or on losing focus, and neither ⌘S nor a click on this button
                // moves the first responder. Without this, saving while the
                // caret sits in Port stores the *old* port.
                window?.makeFirstResponder(nil)
                accounts.save()
                window?.close()
            }
            .help("Save your settings (⌘S)")
            // Deliberately NOT `.keyboardShortcut(.defaultAction)`. That made
            // Save the window's default button, so Return anywhere in the pane
            // saved and closed it — in a form of forty-odd fields, where Return
            // is a natural thing to press after typing one. Return now advances
            // the focus instead (see `onSubmit` on the body). ⌘S still saves.
            //
            // Kept prominent so it still reads as the confirming action, even
            // though it is no longer the Return target.
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var settingsForm: some View {
        Form {
            Section("Identity") {
                TextField("Your name", text: $accounts.account.fromName)
                TextField("Email address", text: $accounts.account.fromAddress)
            }
            Section("Outgoing mail (SMTP)") {
                TextField("Server", text: $accounts.account.host)
                TextField("Port", value: $accounts.account.port, format: .number)
                Picker("Security", selection: $accounts.account.security) {
                    ForEach(SMTPAccount.Security.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                TextField("Username", text: $accounts.account.username)
                SecureField("Password", text: $accounts.password)
            }
            Section("Incoming mail (POP3)") {
                // Only when the stored list existed and wouldn't decode. A blank
                // pane after a real loss looks exactly like a blank pane on a
                // fresh install, and the difference matters: here there is
                // something to recover, and nothing has been overwritten yet.
                if accounts.incomingLoadFailed {
                    Text("Your saved incoming accounts couldn't be read and are "
                            + "shown blank. They haven't been overwritten — if you "
                            + "have a backup, restore it before saving.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // One block per server. Mail from all of them is delivered into
                // the single In box — there is no per-account mailbox, by
                // design (design-decisions.md §7).
                ForEach($accounts.incoming) { $entry in
                    IncomingAccountEditor(
                        entry: $entry,
                        canRemove: accounts.incoming.count > 1,
                        onRemove: { remove(entry) })
                }
                Button {
                    accounts.incoming.append(IncomingAccount())
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                Divider()
                // One interval for the app, not one per account: Check Mail
                // collects them all on each tick.
                HStack(spacing: 6) {
                    Toggle("", isOn: $accounts.autoCheckEnabled)
                        .labelsHidden()
                    Text("Automatically check for new mail every")
                    TextField("", value: autoCheckMinutes, format: .number)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .disabled(!accounts.autoCheckEnabled)
                    Text("minutes")
                }
            }
            Section("Default font") {
                Picker("Font", selection: $composeSettings.bodyFontName) {
                    // Keep the current face selectable even if it's not installed,
                    // so the picker never shows blank.
                    if !Self.families.contains(composeSettings.bodyFontName) {
                        Text(composeSettings.bodyFontName).tag(composeSettings.bodyFontName)
                    }
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                }
                Picker("Size", selection: $composeSettings.bodyFontSize) {
                    ForEach([8.0, 9, 10, 11, 12, 13, 14, 16, 18, 24], id: \.self) { size in
                        Text(size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size))
                            .tag(size)
                    }
                }
                Picker("Antialiasing", selection: $composeSettings.bodyAntialiasing) {
                    ForEach(BodyAntialiasing.allCases) { Text($0.label).tag($0) }
                }
                if composeSettings.bodyAntialiasing == .eudora {
                    HStack {
                        Text("Halo lightness")
                        Slider(value: $composeSettings.eudoraHaloWhiteness, in: 0.4...0.95)
                    }
                    Text("Eudora-style keeps a crisp black core and adds a light gray "
                            + "edge, the way Eudora 7 did. Slide right for a lighter halo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Used to compose messages and to read plain-text and unstyled "
                        + "mail. On your screen only — sent mail carries no font "
                        + "unless you style it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Me — for the Who column") {
                // Every address (and whole-domain rule) that is you. The Who
                // column shows the *other* party and which way each message went,
                // so it needs to know which end is yours.
                ForEach(identityEntries, id: \.self) { entry in
                    HStack {
                        Text(entry)
                        Spacer()
                        Button {
                            model.removeMyIdentity(entry)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \u{201C}\(entry)\u{201D}")
                    }
                }
                HStack {
                    // Rounded-border, not the grouped Form's default borderless
                    // field — which was invisible until clicked.
                    TextField("Add address or *@domain", text: $newIdentity)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addIdentity)
                        // Stops the submit reaching the body's handler as well.
                        // Return here means "add this one", and the field clears
                        // ready for another — moving focus away too would be
                        // wrong, and adding several in a row is the normal way
                        // this field is used.
                        //
                        // Order matters and the failure is silent: the scope
                        // must be OUTSIDE the `onSubmit`, so the handler sits
                        // inside it. Reversed, `addIdentity` becomes an ancestor
                        // action relative to the trigger and Return does nothing
                        // at all — neither adds nor advances.
                        .submitScope()
                    Button("Add", action: addIdentity)
                        .disabled(newIdentity.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Scan Out mailbox for my addresses") {
                    let n = model.rescanOutForMyIdentity()
                    rescanNote = n == 0 ? "No new addresses found."
                                        : "Added \(n) address\(n == 1 ? "" : "es")."
                }
                if let rescanNote {
                    Text(rescanNote).font(.caption).foregroundStyle(.secondary)
                }
                Text("A domain rule like *@musanim.com counts every address at "
                        + "that domain as you. Changes take effect on the mailbox "
                        + "you're viewing right away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mailboxes") {
                Toggle("Show Junk mailbox", isOn: $model.showJunkMailbox)
                Text("Off hides the Junk mailbox from the sidebar and the move/search "
                        + "pickers. Nothing on disk changes — turning it back on just "
                        + "reveals it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Corrections — your auto-correct list") {
                // Your own set only; nothing from macOS's system dictionary or
                // text-replacement list. Same static-row + delete shape as "Me".
                ForEach(model.correctionRules) { rule in
                    HStack {
                        Text(rule.trigger)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(rule.replacement)
                        Spacer()
                        Button {
                            model.removeCorrection(trigger: rule.trigger)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \u{201C}\(rule.trigger)\u{201D}")
                    }
                }
                HStack {
                    // No `onSubmit` here on purpose: Return in "Word" should
                    // advance to "Replacement" (the body's handler does that),
                    // and only Return in "Replacement" adds the rule.
                    TextField("Word", text: $newCorrectionTrigger)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Replacement", text: $newCorrectionReplacement)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCorrection)
                        // As above: Return adds the rule and leaves both fields
                        // ready for the next one, rather than also advancing.
                        .submitScope()
                    Button("Add", action: addCorrection)
                        .disabled(newCorrectionTrigger.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newCorrectionReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Type the word on the left and it becomes the text on the right — "
                        + "case-sensitive. Adding a word that's already listed updates it. "
                        + "You can also right-click a word while writing a message to add it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Greedy, so the footer below is pinned to the bottom of the window
        // rather than floating under the last section on a tall window.
        .frame(maxHeight: .infinity)
    }

    /// The identity set as displayable rows: exact addresses, then domain rules
    /// shown in their `*@domain` form. Both sorted, so the list is stable.
    private var identityEntries: [String] {
        model.me.addresses.sorted()
            + model.me.domains.sorted().map { "*@\($0)" }
    }

    private func addIdentity() {
        let raw = newIdentity.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        model.addMyIdentity(raw)
        newIdentity = ""
        rescanNote = nil
    }

    private func addCorrection() {
        model.addCorrection(trigger: newCorrectionTrigger, replacement: newCorrectionReplacement)
        newCorrectionTrigger = ""
        newCorrectionReplacement = ""
    }

    /// Remove an incoming account, and forget its password.
    ///
    /// The row goes first, then `forgetPassword` — which checks that no
    /// remaining row still uses the same login before it touches the Keychain,
    /// so removing one of two rows pointing at the same server can't disarm the
    /// one being kept.
    ///
    /// The list never empties: the remove button is hidden at one row
    /// (`canRemove`), because a Settings pane with nothing to type into is a
    /// dead end. Clearing the last account is done by emptying its fields.
    private func remove(_ entry: IncomingAccount) {
        // Deferred to the next turn of the run loop. The button lives *inside*
        // the row being removed, and the row owns text fields that may still be
        // first responder — `TextField(value:format:)` for the port commits on
        // focus loss. Shrinking the array that `ForEach($accounts.incoming)`
        // indexes into, from within that row's own update pass, is the standard
        // way to get an index-out-of-range crash out of SwiftUI. Letting the
        // pass finish first costs nothing here.
        DispatchQueue.main.async {
            guard accounts.incoming.count > 1,
                  let i = accounts.incoming.firstIndex(where: { $0.id == entry.id })
            else { return }
            let removed = accounts.incoming[i].account
            accounts.incoming.remove(at: i)
            accounts.forgetPassword(for: removed)
            accounts.persistIncomingAccounts()
        }
    }
}

/// One incoming server's fields, extracted so the `ForEach` body is a single
/// row bound to a single element.
///
/// This is not a rendering optimisation and shouldn't be mistaken for one:
/// every keystroke writes through `$accounts.incoming`, which publishes, which
/// re-evaluates the whole of `SettingsView.body` — font pickers included. That
/// is the `AppModel`/store re-render caveat in CLAUDE.md, and it applies here.
/// Settings is a small, user-paced pane, so it doesn't matter; if it ever does,
/// the fix is to make this `Equatable` over plain values rather than to move
/// code around.
private struct IncomingAccountEditor: View {
    @Binding var entry: IncomingAccount
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // The server is the only thing that distinguishes one block from
                // the next at a glance, so it is the heading. Empty until it has
                // one, rather than showing a placeholder that looks like a value.
                Text(entry.account.host.isEmpty ? "New account" : entry.account.host)
                    .font(.headline)
                    .foregroundStyle(entry.account.host.isEmpty ? .secondary : .primary)
                Spacer()
                if canRemove {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this account")
                }
            }
            TextField("Server", text: $entry.account.host)
            TextField("Port", value: $entry.account.port, format: .number)
            TextField("Username", text: $entry.account.username)
            SecureField("Password", text: $entry.password)
            Toggle("Delete mail from server after downloading",
                   isOn: $entry.account.deleteAfterDownload)
            if entry.account.deleteAfterDownload {
                Text("Messages are deleted only after they're written to your local archive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Hands back the `NSWindow` hosting this view, once it exists — so Settings can
/// close itself on Save. `dismiss` isn't reliable for the Settings scene on
/// macOS 13, and `NSApp.keyWindow` can be the wrong window; the hosting view's
/// own `window` is unambiguous.
private struct WindowGrabber: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        // `window` is nil while the view is being made; read it next runloop turn.
        DispatchQueue.main.async { [weak v] in onResolve(v?.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in onResolve(nsView?.window) }
    }
}

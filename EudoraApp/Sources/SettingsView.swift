import SwiftUI
import AppKit
import EudoraNet

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
    @EnvironmentObject var accounts: AccountStore
    /// The Settings window, so Save can close it. Captured by `WindowGrabber`.
    @State private var window: NSWindow?

    var body: some View {
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
                TextField("Server", text: $accounts.pop.host)
                TextField("Port", value: $accounts.pop.port, format: .number)
                TextField("Username", text: $accounts.pop.username)
                SecureField("Password", text: $accounts.incomingPassword)
                Toggle("Delete mail from server after downloading",
                       isOn: $accounts.pop.deleteAfterDownload)
                if accounts.pop.deleteAfterDownload {
                    Text("Messages are deleted only after they're written to your local archive.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                // Save writes to the Keychain and closes the window — the close
                // is the confirmation now, so the old "Saved" checkmark is gone.
                Button("Save") {
                    accounts.save()
                    window?.close()
                }
                .keyboardShortcut(.defaultAction)
                if accounts.account.security == .startTLS {
                    Label("STARTTLS (587) isn't implemented yet — use SSL/TLS on 465 for now.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color(red: 0.75, green: 0.05, blue: 0.05))
                }
            }
        }
        .formStyle(.grouped)
        // Tall enough to show every section without the form scrolling. Sized by
        // estimate rather than measurement (there's no way to render here); if a
        // little dead space shows at the bottom, or a rare state still scrolls,
        // this height is the one number to nudge.
        .frame(width: 480, height: 740)
        // The `!==` guard matters: `updateNSView` re-resolves on every
        // invalidation, and assigning the same window back would re-invalidate
        // the view and spin once per runloop turn while Settings sits open.
        .background(WindowGrabber { if window !== $0 { window = $0 } })
        .navigationTitle("Settings")
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

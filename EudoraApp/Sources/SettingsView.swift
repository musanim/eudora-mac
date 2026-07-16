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
    @State private var saved = false

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
                HStack {
                    Button("Save") {
                        accounts.save()
                        saved = true
                    }
                    .keyboardShortcut(.defaultAction)
                    if saved {
                        Label("Saved to Keychain", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                }
                if accounts.account.security == .startTLS {
                    Label("STARTTLS (587) isn't implemented yet — use SSL/TLS on 465 for now.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color(red: 0.75, green: 0.05, blue: 0.05))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .onChange(of: accounts.password) { _ in saved = false }
        .navigationTitle("Settings")
    }
}

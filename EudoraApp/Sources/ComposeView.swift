import SwiftUI
import EudoraStore
import EudoraNet

struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var accounts: AccountStore

    let seed: ComposeDraft
    @State private var to: String
    @State private var cc: String
    @State private var bcc: String
    @State private var subject: String
    @State private var bodyText: String
    @State private var sending = false
    @State private var error: String?

    init(seed: ComposeDraft) {
        self.seed = seed
        _to = State(initialValue: seed.to)
        _cc = State(initialValue: seed.cc)
        _bcc = State(initialValue: seed.bcc)
        _subject = State(initialValue: seed.subject)
        _bodyText = State(initialValue: seed.body)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerFields
            Divider()
            TextEditor(text: $bodyText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
            Divider()
            footer
        }
        .frame(minWidth: 580, minHeight: 460)
    }

    private var headerFields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            field("To", $to)
            field("Cc", $cc)
            field("Bcc", $bcc)
            GridRow {
                Text("Subject").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                TextField("", text: $subject)
            }
        }
        .padding(12)
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel") { model.composing = nil }
                .keyboardShortcut(.cancelAction)
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
                .disabled(sending)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    private func send() {
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
                try model.recordSent(raw: sent.raw, who: toList.first ?? "", subject: subject)
                model.showBanner("Message sent.")
                sending = false
                model.composing = nil
            } catch {
                sending = false
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

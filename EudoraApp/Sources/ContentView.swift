import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var accounts: AccountStore

    private var hasSelection: Bool { model.selectedMessageID != nil }

    var body: some View {
        VStack(spacing: 0) {
            MenuBarView()
            if model.isIndexing { IndexingBar() }
            splitView
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 180)
        } detail: {
            // Classic Eudora: message list on top, preview below.
            VSplitView {
                MessageListView()
                    .frame(minWidth: 460, minHeight: 150)
                PreviewView()
                    .frame(minHeight: 140)
            }
        }
        .navigationTitle("Eudora")
        .navigationSubtitle(model.status)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.receiveMail(accounts: accounts) } } label: {
                    Label("Check Mail", systemImage: "arrow.down.circle")
                }.disabled(model.isChecking)
                Button { model.composeNew() } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                Button { model.reply(all: false) } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }.disabled(!hasSelection)
                Button { model.forward() } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                }.disabled(!hasSelection)

                Menu {
                    ForEach(model.moveTargets) { t in
                        Button(t.display) { model.moveSelected(to: t.id) }
                    }
                } label: {
                    Label("Move", systemImage: "tray.and.arrow.up")
                }.disabled(!hasSelection || model.moveTargets.isEmpty)

                Button { model.deleteSelected() } label: {
                    Label("Delete", systemImage: "trash")
                }.disabled(!hasSelection)
            }
        }
        .onAppear { model.openDefaultIfAvailable() }
        // React to selection *after* the view-update pass, so the follow-on
        // @Published mutations don't fire during it.
        .onChange(of: model.selectedMailboxID) { _ in model.loadListing() }
        .onChange(of: model.selectedMessageID) { _ in model.loadMessage() }
        .sheet(item: $model.composing) { draft in
            ComposeView(seed: draft)
                .environmentObject(model)
                .environmentObject(accounts)
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                Text(banner)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.top, 10)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        model.banner = nil
                    }
            }
        }
    }
}

// MARK: - Sidebar: mailbox tree

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.tree.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No mailboxes")
                        .foregroundStyle(.secondary)
                    Button("Open Eudora Folder…") { pickFolder(model) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedMailboxID) {
                    OutlineGroup(model.tree, children: \.children) { item in
                        MailboxRow(item: item)
                            .tag(item.id)
                    }
                }
            }
        }
    }
}

struct MailboxRow: View {
    let item: MailboxItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.isFolder ? .secondary : .primary)
                .frame(width: 18)
            Text(item.display)
                .fontWeight(item.hasUnread ? .semibold : .regular)
            Spacer()
            if !item.isFolder && item.messageCount > 0 {
                Text("\(item.messageCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Middle: message list (Eudora column set)

struct MessageListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.mailboxSummary.isEmpty {
                HStack {
                    Text(model.mailboxSummary)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !model.listingSource.isEmpty {
                        Text(model.listingSource)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                Divider()
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        if model.selectedMailboxID == nil {
            placeholder("Select a mailbox")
        } else if model.rows.isEmpty {
            placeholder("No messages")
        } else {
            Table(model.rows, selection: $model.selectedMessageID) {
                // Narrow glyph columns on the left, Eudora-style.
                TableColumn("") { r in
                    Text(r.statusGlyph)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(r.statusGlyph == "•" ? Color.accentColor : .primary)
                }.width(18)
                TableColumn("") { r in PriorityGlyph(level: r.priority) }.width(18)
                TableColumn("") { r in
                    if r.hasAttachment {
                        Image(systemName: "paperclip")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.width(18)
                TableColumn("") { r in LabelSwatch(label: r.label) }.width(12)
                TableColumn("Who", value: \.who)
                TableColumn("Date", value: \.date).width(min: 110, ideal: 132)
                TableColumn("K") { r in
                    Text(r.sizeK).foregroundStyle(.secondary)
                }.width(46)
                TableColumn("Subject", value: \.subject)
            }
            .contextMenu(forSelectionType: MessageRow.ID.self) { ids in
                if let id = ids.first {
                    Button("Reply") { model.selectedMessageID = id; model.reply(all: false) }
                    Button("Forward") { model.selectedMessageID = id; model.forward() }
                    Divider()
                    Button("Mark as Read") { model.selectedMessageID = id; model.markSelected(read: true) }
                    Button("Mark as Unread") { model.selectedMessageID = id; model.markSelected(read: false) }
                    Menu("Move to") {
                        ForEach(model.moveTargets) { t in
                            Button(t.display) { model.selectedMessageID = id; model.moveSelected(to: t.id) }
                        }
                    }
                    Divider()
                    Button("Delete") { model.selectedMessageID = id; model.deleteSelected() }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Eudora priority indicator: up-chevron for higher-than-normal (1–3),
/// down-chevron for lower (5–7), nothing for normal (4) or unknown (0).
struct PriorityGlyph: View {
    let level: Int
    var body: some View {
        if level >= 1 && level < 4 {
            Image(systemName: "chevron.up").font(.caption2).foregroundStyle(.red)
        } else if level > 4 {
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.blue)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

/// Placeholder for Eudora's color label column. Label data isn't in our `.toc`
/// parse yet, so this stays blank for now.
struct LabelSwatch: View {
    let label: String
    var body: some View {
        Color.clear.frame(width: 8, height: 8)
    }
}

// MARK: - Detail: message preview

struct PreviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let p = model.preview {
            VStack(alignment: .leading, spacing: 0) {
                headers(p)
                Divider()
                if p.isHTML {
                    HTMLMailView(html: p.content, images: p.images) { url in
                        model.banner = "Link copied: \(url)"
                    }
                } else {
                    ScrollView {
                        Text(p.content.isEmpty ? "(no text body)" : p.content)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
        } else {
            Text("Select a message")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func headers(_ p: MessagePreview) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(p.subject.isEmpty ? "(no subject)" : p.subject)
                .font(.headline)
            headerLine("From", p.from)
            headerLine("To", p.to)
            headerLine("Date", p.date)
            if !p.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(p.attachments) { att in
                            AttachmentChip(attachment: att)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func headerLine(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                Text(value).textSelection(.enabled)
            }
            .font(.caption)
        }
    }
}

/// A single attachment, shown as a chip. The menu offers only Save As… (and
/// View for images) — never open-in-default-app, per the "dumb client" stance.
struct AttachmentChip: View {
    let attachment: MessageAttachment

    var body: some View {
        Menu {
            Button("Save As…") { AttachmentActions.saveAs(attachment) }
            if attachment.isImage {
                Button("View") { AttachmentActions.viewImage(attachment) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: attachment.isImage ? "photo" : "paperclip")
                    .foregroundStyle(.secondary)
                Text(attachment.filename).lineLimit(1)
                Text(attachment.sizeText).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Save this attachment" + (attachment.isImage ? " or view it" : ""))
    }
}

// MARK: - Indexing progress bar

/// A slim bar under the menu strip shown while the search index (re)builds in
/// the background. Determinate once the mailbox total is known.
struct IndexingBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption)
            if model.indexProgress.total > 0 {
                ProgressView(value: model.indexProgress.fraction)
                    .frame(width: 140)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var label: String {
        let p = model.indexProgress
        return p.total > 0 ? "Indexing… \(p.done) of \(p.total) mailboxes" : "Indexing…"
    }
}

// MARK: - Folder picker (shared)

@MainActor
func pickFolder(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose the Eudora data folder (the directory containing descmap.pce)."
    if panel.runModal() == .OK, let url = panel.url {
        model.open(url)
    }
}

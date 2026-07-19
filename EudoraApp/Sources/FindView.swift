import SwiftUI
import EudoraStore
import EudoraSearch

// MARK: - Editable criterion (one Find row)

/// UI state for a single criteria row. Mirrors Eudora's `[where] [match] [value]`
/// with a text value (Anywhere/Headers/Subject) or a calendar value (Date).
struct FindCriterion: Identifiable {
    let id = UUID()
    var field: SearchWhere = .anywhere
    var textOp: TextMatchKind = .contains
    var dateOp: DateMatchKind = .isAfter
    var text: String = ""
    var date: Date = Date()
}

// MARK: - Find Messages window

/// Eudora 7's "Find Messages" window: a stack of criteria rows, Match All/Any,
/// More/Fewer, a Search button, and Results / Mailboxes tabs (Mailboxes = the
/// checkbox scope tree). Results open in the main window via `AppModel.openHit`.
struct FindView: View {
    @EnvironmentObject var model: AppModel

    @State private var rows: [FindCriterion] = [FindCriterion()]
    @State private var matchAll = true
    @State private var scope: Set<MailboxItem.ID> = []
    @State private var scopeInitialized = false
    @State private var tab: FindTab = .mailboxes
    @State private var resultSelection: ResultRow.ID?

    enum FindTab: Hashable { case results, mailboxes }

    var body: some View {
        VStack(spacing: 10) {
            criteriaBlock
            Divider()
            controlBar
            Divider()
            tabs
        }
        .padding(12)
        .frame(minWidth: 720, minHeight: 460)
        .onAppear(perform: initScopeIfNeeded)
        // A newly opened tree resets the scope to "all selected".
        .onChange(of: model.tree.count) { _ in
            scopeInitialized = false
            initScopeIfNeeded()
        }
    }

    // MARK: criteria rows

    private var criteriaBlock: some View {
        VStack(spacing: 6) {
            ForEach($rows) { $row in
                rowEditor($row)
            }
        }
    }

    @ViewBuilder
    private func rowEditor(_ row: Binding<FindCriterion>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: row.field) {
                ForEach(SearchWhere.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)

            if row.wrappedValue.field == .date {
                Picker("", selection: row.dateOp) {
                    ForEach(DateMatchKind.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)

                DatePicker("", selection: row.date, displayedComponents: .date)
                    .labelsHidden()
                Spacer()
            } else {
                Picker("", selection: row.textOp) {
                    ForEach(TextMatchKind.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)

                TextField("text to find", text: row.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runSearch)
            }
        }
    }

    // MARK: control bar (More/Fewer, All/Any, Search)

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button("More") { rows.append(FindCriterion()) }
            Button("Fewer") { if rows.count > 1 { rows.removeLast() } }
                .disabled(rows.count <= 1)

            Picker("", selection: $matchAll) {
                Text("Match All").tag(true)
                Text("Match Any").tag(false)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()

            Spacer()

            Text(model.searchStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button(action: runSearch) {
                Label("Search", systemImage: "magnifyingglass")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.isIndexing)
        }
    }

    // MARK: Results / Mailboxes tabs

    private var tabs: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Results").tag(FindTab.results)
                    Text("Mailboxes").tag(FindTab.mailboxes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                if tab == .mailboxes {
                    Text("\(scope.count) of \(model.allLeafMailboxIDs.count) mailboxes selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("All") { scope = model.allLeafMailboxIDs }
                    Button("None") { scope = [] }
                }
            }

            if tab == .results { resultsView } else { mailboxesView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: results table

    /// Identifiable wrapper — `SearchHit` isn't Identifiable and hits can repeat
    /// a mailbox, so the row's array position is the id.
    struct ResultRow: Identifiable {
        let id: String
        let hit: SearchHit
    }

    private var resultRows: [ResultRow] {
        model.searchResults.enumerated().map { ResultRow(id: "\($0.offset)", hit: $0.element) }
    }

    @ViewBuilder
    private var resultsView: some View {
        if resultRows.isEmpty {
            Text(model.searchStatus.isEmpty ? "No search yet." : model.searchStatus)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(resultRows, selection: $resultSelection) {
                TableColumn("Mailbox") { Text(model.mailboxDisplay($0.hit.mailbox)) }
                    .width(min: 90, ideal: 130)
                TableColumn("Date") { Text(AppModel.eudoraDate($0.hit.date) ?? $0.hit.date) }
                    .width(min: 90, ideal: 130)
                TableColumn("Subject") {
                    Text($0.hit.subject.isEmpty ? "(no subject)" : $0.hit.subject)
                }
                TableColumn("Snippet") { Text($0.hit.snippet).foregroundStyle(.secondary) }
            }
            .onChange(of: resultSelection) { sel in
                guard let sel, let rr = resultRows.first(where: { $0.id == sel }) else { return }
                model.openHit(rr.hit)
            }
        }
    }

    // MARK: mailbox scope tree

    @ViewBuilder
    private var mailboxesView: some View {
        if model.tree.isEmpty {
            Text("No mailboxes — open a Eudora folder.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                OutlineGroup(model.tree, children: \.children) { item in
                    Toggle(isOn: scopeBinding(for: item)) {
                        HStack(spacing: 6) {
                            Image(systemName: item.systemImage)
                                .foregroundStyle(item.isFolder ? .secondary : .primary)
                            Text(item.display)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    /// All leaf mailbox ids under an item (the item itself if it's a leaf).
    private func leafIDs(_ item: MailboxItem) -> [MailboxItem.ID] {
        if let kids = item.children { return kids.flatMap(leafIDs) }
        return [item.id]
    }

    /// Checkbox state for a row: a leaf toggles itself; a folder toggles all its
    /// leaf descendants and reads "on" only when every descendant is selected.
    private func scopeBinding(for item: MailboxItem) -> Binding<Bool> {
        let ids = leafIDs(item)
        return Binding(
            get: { !ids.isEmpty && ids.allSatisfy { scope.contains($0) } },
            set: { on in
                if on { ids.forEach { scope.insert($0) } }
                else { ids.forEach { scope.remove($0) } }
            }
        )
    }

    // MARK: actions

    private func initScopeIfNeeded() {
        guard !scopeInitialized else { return }
        let all = model.allLeafMailboxIDs
        if !all.isEmpty {
            scope = all
            scopeInitialized = true
        }
    }

    private func runSearch() {
        let all = model.allLeafMailboxIDs
        guard !scope.isEmpty else {
            model.searchResults = []
            model.searchStatus = "No mailboxes selected."
            tab = .results
            return
        }

        var criteria: [Criterion] = []
        for r in rows {
            switch r.field {
            case .date:
                criteria.append(.date(op: r.dateOp, day: r.date))
            case .anywhere, .headers, .subject:
                let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                let target: TextTarget = r.field == .headers ? .headers
                                       : r.field == .subject ? .subject : .anywhere
                criteria.append(.text(target: target, op: r.textOp, value: t))
            }
        }

        // Whole tree selected → pass nil (search everything) rather than a huge
        // IN-list; a strict subset is passed through.
        let scopeArg: Set<MailboxItem.ID>? = (scope == all) ? nil : scope
        model.runSearch(SearchQuery(criteria: criteria, matchAll: matchAll,
                                    mailboxes: scopeArg, limit: 500))
        tab = .results
    }
}

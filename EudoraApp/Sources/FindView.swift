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

    /// Closes this window. `Window` scenes opened with `openWindow` respond to
    /// `dismiss` on macOS 13, the same as a sheet would.
    @Environment(\.dismiss) private var dismiss

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
        // Escape closes the window, as it did in Eudora.
        //
        // `.onExitCommand` rather than a zero-sized Button carrying
        // `.keyboardShortcut(.cancelAction)`: this is the sanctioned way to take
        // the Escape ("exit") command, and it doesn't put an invisible control in
        // the layout or in the tab order. It fires for the focused view's
        // ancestors, so attaching it to the root covers the whole window
        // wherever focus happens to be.
        .onExitCommand { dismiss() }
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
                .copyable(model.searchStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Two buttons rather than one with conditional modifiers: the
            // prominent and bordered styles are different types, so they can't
            // be swapped on one view.
            //
            // The prominent blue is what invites the click; going plain and
            // saying "Searching…" both reports the state and removes the
            // invitation, which is what a disabled control should look like.
            // The spinner earns its place on the long searches — a whole-tree
            // query over a large index — and is harmless on the quick ones,
            // where the whole thing is gone before it can draw.
            if model.isSearching {
                Button(action: {}) {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("Searching…")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(true)
            } else {
                Button(action: runSearch) {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.isIndexing)
            }
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
    ///
    /// The sort keys are precomputed here rather than in the columns because the
    /// table sorts by key paths: the mailbox's *display* name (not its raw id),
    /// a real parsed `Date` (so Date sorts chronologically, not by the string's
    /// spelling), and the subject. `dateText` is what the Date column shows.
    struct ResultRow: Identifiable {
        let id: String
        let hit: SearchHit
        let mailbox: String
        let dateSort: Date
        let dateText: String
        let subject: String
        let snippet: String
    }

    private var resultRows: [ResultRow] {
        model.searchResults.enumerated().map { i, hit in
            ResultRow(id: "\(i)",
                      hit: hit,
                      mailbox: model.mailboxDisplay(hit.mailbox),
                      dateSort: EudoraDateFormat.parse(hit.date) ?? .distantPast,
                      dateText: AppModel.eudoraDate(hit.date) ?? hit.date,
                      subject: hit.subject.isEmpty ? "(no subject)" : hit.subject,
                      snippet: hit.snippet)
        }
    }

    /// Empty until the user clicks a header, so results first appear in the
    /// engine's own order — relevance for a text search, newest-first for a date
    /// search (see `SearchIndex`) — which is more useful than any fixed column
    /// sort would be. A click then sorts by that column; clicking again reverses.
    @State private var sortOrder: [KeyPathComparator<ResultRow>] = []

    private var sortedRows: [ResultRow] {
        sortOrder.isEmpty ? resultRows : resultRows.sorted(using: sortOrder)
    }

    @ViewBuilder
    private var resultsView: some View {
        if resultRows.isEmpty {
            Text(model.searchStatus.isEmpty ? "No search yet." : model.searchStatus)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(sortedRows, selection: $resultSelection, sortOrder: $sortOrder) {
                TableColumn("Mailbox", value: \.mailbox) { Text($0.mailbox) }
                    .width(min: 90, ideal: 130)
                TableColumn("Date", value: \.dateSort) { Text($0.dateText) }
                    .width(min: 90, ideal: 130)
                TableColumn("Subject", value: \.subject) { Text($0.subject) }
                // Given a `value:` like the rest so every column carries the same
                // `KeyPathComparator<ResultRow>` — mixing a value-less column in
                // makes the builder's comparator type ambiguous. Sorting by a
                // snippet is rarely useful, but harmless, and keeps this uniform.
                TableColumn("Snippet", value: \.snippet) {
                    Text($0.snippet).foregroundStyle(.secondary)
                }
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
                OutlineGroup(model.visibleTree, children: \.children) { item in
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

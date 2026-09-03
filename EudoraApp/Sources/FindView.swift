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
        // Matches the scene's minimum in `EudoraApp.swift`, raised when the
        // preview pane was added. The two have to agree.
        .frame(minWidth: 720, minHeight: 620)
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
        // A rendered message can hold a few MB of embedded images. The window
        // closing is the natural point to let that go — and it means reopening
        // Find shows an empty pane rather than a message from a search two days
        // ago, which would look like a result that isn't there.
        // The selection is cleared alongside the preview: `onChange` fires only
        // on a *change*, so a row left highlighted over an empty pane could not
        // be brought back by clicking it again.
        .onDisappear {
            resultSelection = nil
            model.clearFindPreview()
        }
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
                      // A hit's date is usually the message's own RFC-822
                      // `Date:` header, but for anything Eudora 7 composed the
                      // index falls back to the string Eudora cached in the
                      // `.toc` ("07:21 PM 7/13/2026"), which the RFC-822 parsers
                      // can't read. `tocDate`/`displayCached` try that format
                      // first and the header format second, so both shapes sort
                      // and display correctly — without them a pre-cutover
                      // message showed its raw cached string and sorted to the
                      // beginning of time.
                      dateSort: EudoraDateFormat.tocDate(hit.date)
                          ?? EudoraDateFormat.parse(hit.date) ?? .distantPast,
                      dateText: EudoraDateFormat.displayCached(hit.date),
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
            // Results above, the message below. A split rather than a fixed
            // divider so the balance is the user's: some searches are read from
            // the list, some from the messages.
            VSplitView {
                Table(sortedRows, selection: $resultSelection, sortOrder: $sortOrder) {
                    TableColumn("Mailbox", value: \.mailbox) { Text($0.mailbox) }
                        .width(min: 90, ideal: 130)
                    TableColumn("Date", value: \.dateSort) { Text($0.dateText) }
                        .width(min: 90, ideal: 130)
                    TableColumn("Subject", value: \.subject) { Text($0.subject) }
                    // Given a `value:` like the rest so every column carries the
                    // same `KeyPathComparator<ResultRow>` — mixing a value-less
                    // column in makes the builder's comparator type ambiguous.
                    // Sorting by a snippet is rarely useful, but harmless, and
                    // keeps this uniform.
                    TableColumn("Snippet", value: \.snippet) {
                        Text($0.snippet).foregroundStyle(.secondary)
                    }
                }
                // Right-click a result. `forSelectionType:` hands over the rows
                // under the click — which is *not* necessarily the selection:
                // right-clicking an unselected row leaves the selection where it
                // was. So the command moves the selection itself, or the pane
                // would go on showing one message while View in Mailbox jumped
                // to another. Applied directly to the Table, before the frame,
                // since the modifier only works on a container that has a
                // selection.
                .contextMenu(forSelectionType: ResultRow.ID.self) { ids in
                    if let id = ids.first,
                       let rr = sortedRows.first(where: { $0.id == id }) {
                        Button("View in Mailbox") {
                            resultSelection = id
                            model.openHit(rr.hit)
                        }
                    }
                }
                .frame(minHeight: 120)

                // The same renderer as the main window's reading pane, handed a
                // message instead of following the selection. See
                // `PreviewView.Source`.
                PreviewView(source: .given(model.findPreview,
                                           isLoading: model.isLoadingFindPreview))
                    .frame(minHeight: 140)
            }
            // Selection *only* previews. Opening the message in its mailbox is
            // the right-click item above — Stephen's call, and the right one:
            // jumping the main window on every arrow key re-listed a mailbox per
            // keystroke, which on a large one is a whole-file read.
            .onChange(of: resultSelection) { sel in
                guard let sel, let rr = resultRows.first(where: { $0.id == sel }) else {
                    model.clearFindPreview()
                    return
                }
                model.loadFindPreview(for: rr.hit)
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
        // A new search invalidates whatever was being read. Cleared here rather
        // than reacting to the results arriving: row ids are array positions, so
        // a surviving selection would point at a different message the moment
        // the new results land — the preview would change under you without the
        // selection appearing to move.
        resultSelection = nil
        model.clearFindPreview()

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
            case .anywhere, .headers, .subject, .body:
                let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                let target: TextTarget
                switch r.field {
                case .headers: target = .headers
                case .subject: target = .subject
                case .body:    target = .body
                default:       target = .anywhere
                }
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

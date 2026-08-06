import SwiftUI
import AppKit
import EudoraStore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var accounts: AccountStore
    @Environment(\.openWindow) private var openWindow

    /// Any selection at all — Delete acts on the whole set.
    private var hasSelection: Bool { !model.selectedMessageIDs.isEmpty }

    /// Height of the preview pane, remembered across launches.
    ///
    /// `@AppStorage`, not `ViewState`. `ViewState` is deliberately per-Eudora-
    /// folder — it remembers selections and sort orders, which are properties of
    /// a particular tree — whereas where you like the divider is a property of
    /// the window and shouldn't change because a different folder was opened.
    ///
    /// The *preview* is the pane that's stored, so the message list absorbs a
    /// window resize and the reading pane stays the size you set it to. Every
    /// read of it is clamped by `PaneLayout` rather than trusted: a value
    /// written on a large display is nonsense on a small one, and the defaults
    /// database outlives any particular screen.
    @AppStorage("previewPaneHeight") private var storedPreviewHeight: Double =
        PaneLayout.defaultPreviewHeight

    /// The preview height when the current drag began; nil when not dragging.
    @State private var dragStartHeight: Double?

    /// The height being dragged to, before it is committed. Nil when not
    /// dragging, and the displayed height falls back to the stored one.
    @State private var liveHeight: Double?

    var body: some View {
        VStack(spacing: 0) {
            MenuBarView()
            // **The indexing bar is a safe-area inset on the split view, not a
            // third row of this stack. Don't move it back.**
            //
            // As a row, its appearing and disappearing changed the height
            // offered to the `NavigationSplitView`, and the split view kept its
            // old frame — overlapping upward, so the menu bar was drawn only
            // across the sidebar's width and Transfer/Special/Tools/Window
            // vanished behind it. Every indexing run, gone when the run ended,
            // and cured by dragging the window.
            //
            // Three attempts to *recover* from that failed, and are worth
            // recording so nobody spends the afternoon again:
            //   1. `layoutSubtreeIfNeeded()` on the content view — too weak.
            //   2. The same, but the window came from `NSApp.mainWindow`, which
            //      is nil during launch and while the app is inactive, which is
            //      exactly when indexing starts. It never ran at all.
            //   3. A genuine one-point resize of the window, which is the only
            //      thing a *user* can do that fixes it. Two `setFrame` calls in
            //      one runloop turn evidently coalesce to nothing.
            //
            // A safe-area inset changes nothing about the height the split view
            // is offered — the inset lives inside it — so the trigger is gone
            // rather than compensated for. Which is what should have been done
            // first: this is the mechanism SwiftUI provides for a bar that comes
            // and goes above content.
            splitView
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.isIndexing { IndexingBar() }
                }
        }
        // Tells SplashWindow which window is SwiftUI's, so it doesn't have to
        // guess from NSApp.windows (which raced with window placement).
        .background(DeleteBackspaceShortcut())
        .background(MailboxReorderShortcuts())
        .background(MainWindowAccessor())
        // Strips the now-duplicate ⌘M from Window ▸ Minimize; see the type.
        .background(MinimizeKeyStripper())
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 180)
        } detail: {
            // Classic Eudora: message list on top, preview below.
            //
            // Hand-built rather than a `VSplitView`. That gave a draggable region
            // barely wider than a hairline, and there is no way to widen it: the
            // AppKit answer is a delegate method, and SwiftUI's split view is
            // managed by an `NSSplitViewController`, which refuses to give up its
            // delegate (see PaneDivider). Owning the split outright also means
            // the position can be remembered, which VSplitView never offered.
            GeometryReader { geo in
                let previewHeight = PaneLayout.previewHeight(liveHeight ?? storedPreviewHeight,
                                                             total: geo.size.height)
                VStack(spacing: 0) {
                    MessageListView()
                        .frame(maxHeight: .infinity)
                    PaneDividerHandle { translation in
                        // A fresh gesture always reports zero first (the handle
                        // uses `minimumDistance: 0`). Clearing on that rather
                        // than trusting `onEnded` is what makes a *cancelled*
                        // drag harmless — SwiftUI doesn't promise to end a
                        // gesture the window resigned or another gesture won,
                        // and a stale base would teleport the divider on the
                        // next mouse-down.
                        if translation == 0 { dragStartHeight = nil }
                        // `translation` is measured from where the drag began,
                        // not since the last event, so the height it applies to
                        // must also be the one from where the drag began —
                        // otherwise each event compounds the last and the divider
                        // runs away from the pointer.
                        //
                        // The base is the *clamped* height, not the stored one.
                        // They differ whenever the window is shorter than it was
                        // when the value was written, and starting from the
                        // stored value then means the first part of the drag is
                        // spent re-clamping to the same number — the divider
                        // looks stuck until the pointer has covered the gap.
                        let base = dragStartHeight ?? Double(previewHeight)
                        if dragStartHeight == nil { dragStartHeight = base }
                        // Dragging down makes the preview *smaller*.
                        liveHeight = Double(
                            PaneLayout.previewHeight(base - Double(translation),
                                                     total: geo.size.height))
                    } onEnded: {
                        // Committed once, here, rather than on every frame:
                        // `@AppStorage` writes to UserDefaults, and a drag
                        // produces these at the refresh rate.
                        if let liveHeight { storedPreviewHeight = liveHeight }
                        liveHeight = nil
                        dragStartHeight = nil
                    }
                    PreviewView()
                        .frame(height: previewHeight)
                }
            }
            .frame(minWidth: 460, minHeight: PaneLayout.minimumTotal)
        }
        .navigationTitle("Eudora")
        .navigationSubtitle(model.status)
        .toolbar {
            // Centered between the window title and the action buttons — the
            // same spot Xcode puts its activity view. Spinner + "Checking mail"
            // during a fetch (⌘M / File ▸ Check Mail — there's no toolbar button
            // for it), then the outcome, which `showCheckMailNotice` retires
            // after a few seconds.
            ToolbarItem(placement: .principal) {
                if model.isChecking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking mail").foregroundStyle(.secondary)
                    }
                } else if let notice = model.checkMailNotice {
                    Text(notice).foregroundStyle(.secondary)
                }
            }
            ToolbarItemGroup {
                Button { model.composeNew() } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                // `SettingsButton` opens the Settings scene the version-correct
                // way (SettingsLink on 14+, the menu action on 13). The gear is
                // `assets/settings.png`, template-rendered so it tints like the SF
                // Symbol icons beside it; sized to sit with them rather than at
                // the artwork's own resolution.
                SettingsButton {
                    Image("settings")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                }
                .help("Settings")
                // Reply, Forward and Move-to are deliberately *not* here: each is
                // reachable from the Message/Transfer menus, the message-list
                // right-click, and (Reply) ⌘R, so a toolbar button for them is
                // redundant. `MoveToMenuButton` still exists — the Transfer menu
                // uses it — and `model.reply/forward/moveSelected` are still the
                // handlers those routes call.
                // The exception to the rule stated just above. Eudora 7 put Blah
                // Blah Blah on the toolbar and Stephen reached for it there for
                // thirty years; it is also a *mode* rather than an action, so
                // unlike Reply it wants somewhere that shows its current state at
                // a glance. Tinted when on, for that reason.
                // A `Toggle` in `.button` style rather than a `Button` with a
                // hand-tinted label: it carries a real pressed-in on-state, which
                // is what a mode button wants, and it avoids fighting the toolbar
                // button style for the symbol's tint — an outer `.foregroundStyle`
                // is unreliable there on macOS 13, and hand-setting the *off*
                // colour would leave this button a different shade from the three
                // beside it.
                Toggle(isOn: $model.showAllHeaders) {
                    Label("Blah Blah Blah", systemImage: "text.alignleft")
                }
                .toggleStyle(.button)
                .help(model.showAllHeaders ? "Hide all headers" : "Show all headers")
                Button { model.deleteSelected() } label: {
                    Label("Delete", systemImage: "trash")
                }.disabled(!hasSelection)
            }
        }
        // Deferred on purpose: openDefaultIfAvailable blocks the main thread for
        // several seconds on a large tree, and the splash (shown in
        // EudoraApp.init) has to be drawn before that starts, not after.
        //
        // 50 ms, not a plain async hop: onAppear runs inside AppKit's display
        // pass, and a main-queue block posted there is drained in the *same*
        // run-loop iteration — before CoreAnimation commits. That could block
        // the thread for seconds in the very iteration that would have put the
        // splash on screen. A short delay guarantees an idle pass first.
        .onAppear {
            // Drafts are assembled from the account's From identity, and they
            // can be created from places that never see the AccountStore — the
            // message list's right-click Reply, for one. Handed over once here.
            model.accounts = accounts
            // Compose is a window per message now, not a sheet, and only a view
            // can reach `openWindow`. Handing the action over once means the
            // model can present a draft window even with no window on screen —
            // ⌘N used to write a record into Out and show nothing in that case.
            //
            // `openWindow(id:value:)` brings an existing window for the same
            // value forward rather than opening a second, which is what makes
            // double-clicking an already-open draft focus it.
            model.presentDraftWindow = { openWindow(id: ComposeWindow.groupID, value: $0) }
            // Route the app-terminate decision through the model, so Quit by any
            // route asks about unsaved compose windows first. Set here because
            // this is where the model is in hand; the closure is main-actor work
            // behind a plain closure type, as `AppDelegate.onQuit` documents.
            AppDelegate.shared?.onQuit = { model.reviewComposeBeforeQuit() }
            // Same shape, for mailto: links arriving from other apps. Setting
            // this flushes any URL that came in during launch — the model then
            // holds it until there is a tree to save the draft into.
            AppDelegate.shared?.onOpenURLs = { urls in
                for url in urls { model.handleMailto(url) }
            }
            // Splash first — the main window exists by now, so it can be
            // centered over it, and the run loop is running, so it paints.
            SplashWindow.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                model.openDefaultIfAvailable()
                // After the folder is open (so a launch-time check can find the
                // In box). Starts the timer and, if auto-check is on, fetches once
                // right away. Reconfigured below when the settings change.
                model.configureAutoCheck()
                // A mailto: link that launched the app arrived before any of
                // this; now there is a tree to save the draft into, open it.
                // Does nothing in the ordinary case.
                model.drainPendingMailtos(announcingIfBlocked: true)
            }
        }
        // Auto-check is a live preference: persist it the moment it changes (the
        // Save button isn't required for it), and reconfigure — which restarts
        // the timer and does an immediate check when it's on.
        .onChange(of: accounts.autoCheckEnabled) { _ in
            accounts.persistAutoCheck()
            model.configureAutoCheck()
        }
        .onChange(of: accounts.autoCheckMinutes) { _ in
            accounts.persistAutoCheck()
            model.configureAutoCheck()
        }
        // React to selection *after* the view-update pass, so the follow-on
        // @Published mutations don't fire during it.
        //
        // `.onChange` alone isn't enough: when the change originates in a
        // selection binding (clicking a mailbox in the sidebar List), SwiftUI
        // may run the handler inside the same update, and loadListing()'s
        // @Published writes then draw "Publishing changes from within view
        // updates is not allowed." Hopping to the next runloop turn puts those
        // writes safely outside the update. Ordering is unchanged — both still
        // run before any user interaction can follow.
        .onChange(of: model.selectedMailboxID) { _ in
            DispatchQueue.main.async { model.loadListing() }
        }
        // `primaryMessageID`, not `selectedMessageIDs`: the primary is what the
        // preview shows, so this now fires exactly when the shown message
        // changes. It catches a case the old form missed — a right-click inside
        // an existing multi-selection moves the primary without changing the
        // membership, and the preview used to stay on the previous message — and
        // it drops a pointless reload when rows leave a selection whose primary
        // survives.
        .onChange(of: model.primaryMessageID) { _ in
            DispatchQueue.main.async { model.loadMessage() }
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                HStack(spacing: 8) {
                    if model.bannerIsError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(red: 0.75, green: 0.05, blue: 0.05))
                    }
                    Text(banner)
                        .copyable(banner)
                    if model.bannerIsError {
                        Button {
                            model.dismissBanner()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Dismiss")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.top, 10)
                // Successes time out; failures don't. A "Check mail failed: …"
                // that erases itself after two and a half seconds can't be read
                // to the end, let alone right-clicked and copied — and it's the
                // one message worth quoting verbatim, since it carries the
                // server's own code and wording.
                //
                // Keyed on `bannerGeneration`, not the text, so a second message
                // always restarts the timer rather than inheriting the first
                // one's — see the comment on that property.
                .task(id: model.bannerGeneration) {
                    guard !model.bannerIsError else { return }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    model.dismissBanner()
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
                MailboxTree(tree: model.visibleTree,
                            treeVersion: model.treeVersion,
                            treeIdentityVersion: model.treeIdentityVersion,
                            selected: model.selectedMailboxID,
                            inboxHasNewMail: model.inboxHasNewMail,
                            selection: model.mailboxSelection,
                            expansionRoot: model.rootURL?.path ?? "",
                            savedExpansion: { model.savedSidebarExpansion },
                            onExpansionChanged: { model.recordSidebarExpansion($0) },
                            mailboxIsDeletablyEmpty: { model.mailboxIsDeletablyEmpty($0) },
                            onDeleteMailbox: { model.deleteMailbox($0) },
                            folderIsDeletablyEmpty: { model.folderIsDeletablyEmpty($0) },
                            onDeleteFolder: { model.deleteFolder($0) },
                            canMove: { model.canMove($0, up: $1) },
                            onMove: { model.moveTreeItem($0, up: $1) },
                            onRename: { model.renameTreeItem($0) },
                            onMoveToGroup: { model.moveIntoGroup($0, into: $1) },
                            onSortSiblings: { model.sortSiblingsAlphabetically($0) },
                            onSortContents: { model.sortFolderContents($0) },
                            recentFilings: { model.recentFilings() },
                            onPickRecent: { model.openRecent($0) })
                    .equatable()
            }
        }
    }
}

/// The mailbox tree, deliberately insulated from the rest of the model.
///
/// `SidebarView` observes `AppModel` through `@EnvironmentObject`, which means
/// *any* published change — a row arriving, a preview rendering, a banner
/// appearing — invalidates it and rebuilds the outline over every *visible*
/// mailbox in the tree. On a real Eudora folder that is 2,723 nodes, and it was
/// costing ~0.7 s of main-thread render on **every** state change: the reason a
/// click took a perceptible moment to blank the message list even when both
/// mailboxes held a single message.
///
/// Taking the tree as plain values and declaring `Equatable` lets SwiftUI skip
/// the rebuild entirely unless something this view actually shows has changed.
/// Equality is on `treeVersion` rather than the tree itself: comparing 2,723
/// nested structs on every render would just move the cost around.
///
/// `selected` is compared even though the `List` reads selection through the
/// binding, because a *programmatic* selection change (restoring at launch,
/// opening a search hit) must still be able to move the highlight.
struct MailboxTree: View, Equatable {
    let tree: [MailboxItem]
    let treeVersion: Int
    /// Bumped when the tree's identity graph changes — a move, a new or deleted
    /// group — but *not* on a rename, and never when a mailbox merely gains
    /// unread mail. Used as the `List`'s identity, which is what stops SwiftUI
    /// diffing a restructured outline. See the `.id()` in `body`.
    let treeIdentityVersion: Int
    let selected: MailboxItem.ID?
    /// Whether In is carrying unlooked-at new mail — drives the unread glyph on
    /// the In row. In `==` so the badge appearing/clearing re-renders the tree.
    let inboxHasNewMail: Bool
    let selection: Binding<MailboxItem.ID?>

    /// The Eudora folder's path, used only as the identity of the remembered
    /// expansion: opening a different tree must re-seed from *that* tree's saved
    /// state rather than inherit this one's. Excluded from `==` because it cannot
    /// change without `treeVersion` changing too — a new root reloads the tree.
    let expansionRoot: String
    /// The expansion saved for this Eudora folder, read fresh rather than passed
    /// as a value so that a stale copy of this view (see `==`) still seeds from
    /// what the model holds now. Excluded from `==`.
    let savedExpansion: () -> Set<String>
    /// Write-through for a disclosure click. The model persists and prunes; it
    /// does not publish, so this does not re-render anything. Excluded from `==`.
    let onExpansionChanged: (Set<String>) -> Void

    /// Live checks and actions, queried only when a row's context menu is
    /// actually opened. Closures rather than the model itself, so this view stays
    /// insulated from `AppModel`'s publishes (the whole point of its `Equatable`
    /// — see the type comment). Excluded from `==`.
    let mailboxIsDeletablyEmpty: (MailboxItem.ID) -> Bool
    let onDeleteMailbox: (MailboxItem.ID) -> Void
    let folderIsDeletablyEmpty: (MailboxItem.ID) -> Bool
    let onDeleteFolder: (MailboxItem.ID) -> Void
    let canMove: (MailboxItem.ID, _ up: Bool) -> Bool
    let onMove: (MailboxItem.ID, _ up: Bool) -> Void
    let onRename: (MailboxItem.ID) -> Void
    /// Move a mailbox/folder into a destination folder (`nil` = the tree root /
    /// Top Level). See `AppModel.moveIntoGroup`.
    let onMoveToGroup: (_ item: MailboxItem.ID, _ destination: MailboxItem.ID?) -> Void
    /// Sort the list this item sits in. See `AppModel.sortSiblingsAlphabetically`.
    let onSortSiblings: (MailboxItem.ID) -> Void
    /// Sort what's inside this folder. Folders only.
    let onSortContents: (MailboxItem.ID) -> Void

    /// The Recents list, read when its menu opens rather than passed as a value —
    /// so filing a message doesn't have to re-render the sidebar for the next
    /// open of the menu to be current. Excluded from `==` for that reason.
    let recentFilings: () -> [(id: MailboxItem.ID, display: String)]
    /// Open a mailbox picked from Recents. See `AppModel.openRecent`.
    let onPickRecent: (MailboxItem.ID) -> Void

    static func == (a: MailboxTree, b: MailboxTree) -> Bool {
        a.treeVersion == b.treeVersion && a.selected == b.selected
            && a.inboxHasNewMail == b.inboxHasNewMail
    }
    // `treeIdentityVersion` is deliberately *not* in `==`. It only ever moves
    // when `treeVersion` does — both are published in the same synchronous
    // block, in `startTreeReload` and in `open` — so comparing it would be
    // redundant, and this view has to re-render on a structural change anyway.
    //
    // Nor is the expansion, and that one is worth being explicit about: it is
    // `@State` below, owned here. `@State` invalidates *this* view directly,
    // which no `==` can suppress — `EquatableView` only short-circuits an update
    // pushed down by the parent. So a disclosure click still re-renders the tree
    // (it has to, that's the change being drawn) while an unrelated `AppModel`
    // publish still doesn't.

    /// The live expansion, or `nil` for "untouched this session".
    ///
    /// `nil` rather than seeding in `.onAppear`, because `.onAppear` runs *after*
    /// the first render: the tree would paint fully collapsed and then visibly
    /// snap open a frame later. Reading through to `savedExpansion()` while nil
    /// makes the first paint already correct.
    @State private var liveExpansion: Set<String>?

    private var expandedIDs: Set<String> { liveExpansion ?? savedExpansion() }

    /// `expandedIDs`, reported once per actual change on the way past.
    ///
    /// A side effect in a getter, which is normally not on — but this is the only
    /// point where the value the rows will be built from is in hand, and one line
    /// per real change is what distinguishes "the write was dropped" from "the
    /// outline view ignored a collapse". Both look identical on screen. Reverts to
    /// plain `expandedIDs` when `SidebarExpansionProbe` goes off.
    private var renderExpandedIDs: Set<String> {
        let ids = expandedIDs
        SidebarExpansionProbe.rendered(ids)
        return ids
    }

    /// Open or close one folder.
    ///
    /// **This must be called through a closure made in `body`, and that is not a
    /// style preference.** The first version handed `OutlineRows` the whole
    /// `MailboxTree` and let it build its disclosure bindings from that stored
    /// copy. Writing `@State` through a view struct a *child* is holding updates
    /// the value but does **not invalidate the view**, so nothing re-renders.
    ///
    /// **The visible effect of a click was arbitrary; the stored state was always
    /// right.** Both halves of that matter. Two sequences were observed on the same
    /// build: clicking a closed group's chevron sometimes opened it and sometimes
    /// left it shut, and a group that had been opened would not close — and in
    /// every case a quit and relaunch showed the state had been recorded correctly
    /// all along. What decided the appearance was only whether the outline view
    /// happened to act on the click locally before a reconciliation it never got.
    ///
    /// The reason the state stayed right is that the write-through to `AppModel` is
    /// a separate path, so persistence never broke. Clicking any other row changed
    /// `selected`, which *is* in `==`, forcing the first genuine re-render — which
    /// is why the tree would suddenly agree with itself after an unrelated click.
    ///
    /// (An earlier version of this comment said the write was dropped and predicted
    /// a group would come back closed after a quit. It came back open. The
    /// distinction is worth the words: a missing invalidation is invisible to
    /// anything that inspects state, and a test asserting on the model cannot
    /// catch it.)
    ///
    /// Passing `expandedIDs` down as a plain value and this as a closure keeps both
    /// halves in the generation SwiftUI is actually tracking.
    private func setExpanded(_ id: MailboxItem.ID, _ isExpanded: Bool) {
        var next = expandedIDs
        if isExpanded { next.insert(id) } else { next.remove(id) }
        SidebarExpansionProbe.set(id, isExpanded, resulting: next)
        guard next != expandedIDs else { return }
        liveExpansion = next
        onExpansionChanged(next)
    }

    var body: some View {
        List(selection: selection) {
            // The row height, and note where this sits: **inside** the `List`,
            // wrapped around its content, not on the `List` itself.
            //
            // That is the whole finding of three failed attempts. `List` writes
            // its own `defaultMinListRowHeight` into its content's environment
            // from the list style, so the same modifier applied outside is
            // overwritten before any row reads it — measured, not assumed: with 24
            // set on the `List`, a row still read 32. A `Group` here is below that
            // write, so the value reaches the rows.
            //
            // Why it has to be this value and nothing else: the outline
            // coordinator answers `heightOfRowByItem`, so the AppKit `rowHeight`
            // is inert (forced to 20, `rect(ofRow:)` stayed 32); `intercellSpacing`
            // is already 0, so there is no between-row gap to take; and
            // `hosted.h == rowView.h == 32` says the height is imposed on the
            // content rather than derived from it, which is why `.listRowInsets`
            // could never have worked either. See `SidebarRowMetrics`.
            Group {
                // System mailboxes (In/Out/Junk/Trash) are pinned at the top and
                // have no children, so they're a flat ForEach; a divider then sets
                // them off from the user's own mailboxes and folders below.
                ForEach(systemMailboxes) { item in row(for: item) }
                // Recents is its own set, between the system mailboxes and the
                // user's own: a divider above it as well as below. Stephen's
                // reason, and the one to keep in mind before moving it — unlike
                // everything else in the sidebar, it is not a mailbox. Sharing a
                // set with rows that are would say it was.
                //
                // Placed after the whole system block rather than after the Trash
                // row, because descmap order isn't guaranteed to put Trash last
                // (see `MailboxTreeMutator.moveEntry`) — the block is hoisted here
                // whatever order the file is in, so this is the only stable way to
                // say "below Trash". Inside the `Group`, so it inherits the 21 pt
                // row height along with everything else.
                RecentsRow(entries: recentFilings, onPick: onPickRecent,
                           ruleAbove: !systemMailboxes.isEmpty,
                           ruleBelow: !otherMailboxes.isEmpty)
                // `DisclosureGroup`s bound to `expandedIDs`, not an
                // `OutlineGroup`. The swap buys exactly one thing: expansion this
                // app can read and write. `OutlineGroup` keeps it inside
                // `NSOutlineView` with no public accessor, so it could neither be
                // saved across launches nor restored after the `.id()` rebuild
                // below — see `SidebarExpansion`.
                OutlineRows(items: otherMailboxes, owner: self,
                            expanded: renderExpandedIDs, setExpanded: setExpanded)
            }
            .environment(\.defaultMinListRowHeight, SidebarRowMetrics.rowHeight)
        }
        // The row height's actual owner, after five builds of measurement: the
        // list style. Everything reachable from AppKit is inert on this view —
        // `rowHeight` forced to 20 left `rect(ofRow:)` at 32, `rowSizeStyle` set
        // to `.small` left it at 32, `intercellSpacing` is already 0 — and
        // `defaultMinListRowHeight` demonstrably reaches the rows but is only a
        // floor, so it cannot lower anything. The sidebar style's 32 pt row is
        // computed inside SwiftUI's outline coordinator and exposed nowhere else.
        //
        // `.plain` is therefore not a cosmetic preference, it is the lever. It
        // costs the native sidebar look — rectangular selection instead of the
        // rounded translucent capsule, and no sidebar material behind the rows —
        // which is a trade Stephen made explicitly rather than one taken quietly.
        // Reverting is this one line; the 24 above then goes back to being a
        // floor that never binds and the rows return to 32.
        .listStyle(.plain)
        // Rebuild the outline outright when the tree's shape changes, rather
        // than letting SwiftUI diff it.
        //
        // This fixes a crash, not a cosmetic problem. `OutlineGroup` in a `List`
        // is backed by `NSOutlineView` through SwiftUI's `OutlineListCoordinator`,
        // and it keeps expansion state internally, keyed on item identity. Moving
        // an **expanded** group into another group — creating PEOPLE and moving
        // the by-letter groups into it, on 2026jul30 — makes the diff delete an
        // expanded subtree from one parent and insert it under another inside a
        // single animated batch. SwiftUI asserts partway through:
        //
        //     _assertionFailure  ←  ViewListTree.visitItem(_:force:)
        //     ←  OutlineListCoordinator.outlineView(_:child:ofItem:)
        //     ←  -[NSOutlineView _recursiveCollapseItemEntry:…]
        //     ←  OutlineListCoordinator.recursivelyDiffRows(_:with:by:expandAll:)
        //
        // Changing the identity makes SwiftUI discard the outline and build a
        // fresh one, so there is no diff to get wrong.
        //
        // Chosen over the two subtler options deliberately. Wrapping the publish
        // in `disablesAnimations` governs how a diff is *applied*, not whether it
        // runs, and only avoids the crash on versions where it happens to route
        // `List` down a reload path — an implementation accident, where `.id()`
        // is a documented identity contract. And swapping `OutlineGroup` for
        // `DisclosureGroup`s does not help by itself: both compile down to the
        // same `NSOutlineView` and the same coordinator, so it changes who owns
        // the expansion bool, not who runs the diff. What *would* help there is
        // collapsing a subtree before moving it — a day's work, and the reason to
        // reach for it is that, not the DisclosureGroups.
        //
        // **That swap has since happened, and this `.id()` stays.** The tree is
        // built from `DisclosureGroup`s now, for persistence (`SidebarExpansion`),
        // and the paragraph above is the reason that did not also retire the
        // guard: same coordinator, same diff, same crash. What changed is only
        // the cost, below.
        //
        // The cost, as it was: a move *between* groups, a new group or a deleted
        // group collapsed the sidebar to its default expansion — which meant
        // Move to ▸ New…, the most-used way of filing, closed the tree under you
        // every time. That is gone. The rebuild still happens, but expansion no
        // longer lives inside the view being discarded, so the fresh outline
        // comes up open exactly where the old one was. Being a fresh build rather
        // than a diff is also why it cannot hit the assertion above.
        //
        // Move Up/Down is deliberately *not* in that set. It was at first, and
        // it made the feature unusable: reordering a mailbox inside a group
        // closed the group under you every time. A sibling reorder can't
        // reparent anything (`MailboxTreeMutator.moveEntry` swaps two lines
        // within one descmap, which is the whole reason it can't change any
        // item's parent), so it isn't the
        // shape that crashed and doesn't need the blunt instrument. See
        // `AppModel.identitySignature`.
        //
        // `treeIdentityVersion`, NOT `treeVersion` and NOT `treeStructureVersion`.
        // `treeVersion` bumps on every tree walk, including after each delivery,
        // which would throw the outline away whenever mail arrived.
        // `treeStructureVersion` also moves on a *rename*, which rewrites only a
        // display name — every row keeps its identity, nothing reparents, and
        // SwiftUI's diff is safe for it. Only the identity graph matters here.
        .id(treeIdentityVersion)
        // Prints once per rebuild, so the next reorganise says plainly whether
        // this fired, when, and how often. The crash it prevents is a SwiftUI
        // assertion with none of our frames on the stack — there is nothing to
        // instrument on the failing side, so instrument the fix instead.
        .onAppear { PerfLog.mark("sidebar outline built (identity \(treeIdentityVersion))") }
        // Drop back to "read from the model" whenever the Eudora folder changes,
        // so a newly opened tree seeds from its own saved expansion instead of
        // inheriting the set the previous one was left with. Also fires once on
        // first appearance, where it is a no-op.
        .task(id: expansionRoot) { liveExpansion = nil }
        // Reads the resulting row geometry and prints it once — it sets nothing.
        // Here rather than deleted because `defaultMinListRowHeight` above is a
        // request, and this is how we know what the outline view did with it.
        // Applied after `.id()`, so it isn't rebuilt when `treeIdentityVersion`
        // changes; `attach` handles that itself by re-finding the table when the
        // one it holds has left the window.
        .background(SidebarRowHeightPin())
    }

    /// The pinned system boxes and everything else, split off `tree` (already
    /// Junk-filtered by the caller via `visibleTree`).
    private var systemMailboxes: [MailboxItem] { tree.filter { Self.isSystem($0.type) } }
    private var otherMailboxes: [MailboxItem] { tree.filter { !Self.isSystem($0.type) } }

    private static func isSystem(_ type: MailboxType) -> Bool {
        switch type {
        case .inbox, .outbox, .trash, .junk: return true
        case .folder, .mailbox: return false
        }
    }

    @ViewBuilder
    private func row(for item: MailboxItem) -> some View {
        MailboxRow(item: item, newMail: inboxHasNewMail && item.type == .inbox)
            .tag(item.id)
            // A SwiftUI `.contextMenu`, and deliberately so despite the
            // "menus over the mailbox tree must be AppKit" rule. That rule exists
            // because SwiftUI builds *nested* menu content eagerly — a Move submenu
            // materialised all 2,657 mailboxes per right-click. This menu is one
            // flat item, built only when the row is actually right-clicked; there
            // is nothing for the eager builder to be eager about. If this menu ever
            // grows a submenu that walks the tree, it must move to AppKit (see
            // MessageContextMenu for the pattern).
            .contextMenu { contextMenu(for: item) }
    }

    /// A regular mailbox or a folder gets Move Up / Move Down (mailboxes and
    /// folders intermix; only the system mailboxes are pinned)
    /// and Delete (only when empty; a non-empty item shows the reason, greyed).
    /// System mailboxes (In/Out/Junk/Trash) get no menu at all — an empty
    /// `@ViewBuilder` result means none appears.
    ///
    /// Kept to flat items on purpose: no submenu that walks the tree (see the
    /// note at the call site). The `canMove`/emptiness closures run only on the
    /// right-click that opens this menu, so this stays cheap.
    @ViewBuilder
    private func contextMenu(for item: MailboxItem) -> some View {
        if item.isFolder {
            Button("Rename…") { onRename(item.id) }
            Divider()
            moveItems(for: item)
            // Two sorts on a folder, and the names carry the difference rather
            // than leaving it to be inferred from what was clicked: the first
            // sorts the list this folder is *in*, like Move Up and Move Down
            // beside it; the second sorts what's inside it.
            Button("Sort Alphabetically") { onSortSiblings(item.id) }
            Button("Sort Contents Alphabetically") { onSortContents(item.id) }
            moveToGroupMenu(for: item)
            Divider()
            if folderIsDeletablyEmpty(item.id) {
                Button("Delete") { onDeleteFolder(item.id) }
            } else {
                Button("Delete (not empty)") {}.disabled(true)
            }
        } else if item.type == .mailbox {
            Button("Rename…") { onRename(item.id) }
            Divider()
            moveItems(for: item)
            Button("Sort Alphabetically") { onSortSiblings(item.id) }
            moveToGroupMenu(for: item)
            Divider()
            if mailboxIsDeletablyEmpty(item.id) {
                Button("Delete") { onDeleteMailbox(item.id) }
            } else {
                Button("Delete (not empty)") {}.disabled(true)
            }
        }
    }

    @ViewBuilder
    private func moveItems(for item: MailboxItem) -> some View {
        // The ⌥↑/⌥↓ hints are decorative here, as everywhere in an in-window
        // menu — the working keys are `MailboxReorderShortcuts` in the main
        // window. They earn their place by being the only way anyone would find
        // out the shortcuts exist, and this menu is where you already are when
        // you want to reorder something.
        //
        // Note the difference in what they act on: these move the row that was
        // right-clicked, the keystrokes move the sidebar selection. Usually the
        // same row, because right-clicking selects — but not always.
        Button("Move Up") { onMove(item.id, true) }
            .keyboardShortcut(.upArrow, modifiers: .option)
            .disabled(!canMove(item.id, true))
        Button("Move Down") { onMove(item.id, false) }
            .keyboardShortcut(.downArrow, modifiers: .option)
            .disabled(!canMove(item.id, false))
    }

    /// "Move to group ▸ …", hierarchical: Top Level, then each top-level group as
    /// a nested submenu. The destinations are *folders only*, and the whole menu
    /// is built eagerly on right-click (SwiftUI doesn't build submenus lazily) —
    /// fine for a modest number of groups; if a tree ever grows a large, deep
    /// group hierarchy and this drags, it's the thing to move to an AppKit lazy
    /// menu (see MessageContextMenu / MailboxMenuBuilder).
    @ViewBuilder
    private func moveToGroupMenu(for item: MailboxItem) -> some View {
        Menu("Move to group") {
            Button("Top Level") { onMoveToGroup(item.id, nil) }
            let groups = Self.subGroups(of: tree, excluding: item.id)
            if !groups.isEmpty {
                Divider()
                ForEach(groups) { group in
                    GroupSubmenu(folder: group, moving: item.id,
                                 onMove: { onMoveToGroup(item.id, $0) })
                }
            }
        }
    }

    /// The folders directly inside `items`, minus the item being moved and its
    /// own subtree — you can't file a folder inside itself.
    private static func subGroups(of items: [MailboxItem]?,
                                  excluding moving: MailboxItem.ID) -> [MailboxItem] {
        (items ?? []).filter {
            $0.isFolder && $0.id != moving && !$0.id.hasPrefix(moving + "/")
        }
    }

    /// One group in the hierarchical Move-to-group menu. A leaf group is a plain
    /// button (click to move into it); a group with sub-groups is a submenu whose
    /// *own label* moves into it (`primaryAction`) while the chevron opens its
    /// sub-groups — so every group is a direct destination, no "Move here" needed.
    /// It's a `View` struct because a `some View` function can't call itself,
    /// which SwiftUI recursion needs.
    /// One level of the mailbox tree, recursing into folders.
    ///
    /// A `View` struct rather than a `@ViewBuilder` function for the same reason
    /// `GroupSubmenu` below is one: a function returning `some View` cannot call
    /// itself. Carrying the whole `MailboxTree` as `owner` rather than its dozen
    /// closures keeps the recursive call to one line and keeps the row builders
    /// and the context menu where they already are.
    ///
    /// A folder is any item with non-nil `children`, which is exactly the test
    /// the `OutlineGroup` this replaced applied through `children: \.children`.
    /// The emptiness of that array deliberately doesn't matter: an empty folder
    /// gets `[]` (a mailbox gets nil), so it keeps the disclosure triangle it has
    /// always had rather than silently becoming a leaf.
    ///
    /// **The tag and the context menu go on the label, not on the
    /// `DisclosureGroup`** — that is, `row(for:)` is used unchanged, exactly as
    /// the `OutlineGroup` used it. A `DisclosureGroup` in a `List` flattens to
    /// several rows, its label plus everything inside it, and a modifier on the
    /// group applies to that whole span: `.contextMenu` there would put a
    /// folder's menu on every row nested under it, and `.tag` there would very
    /// likely make clicking a child select its parent. Keeping both on the label
    /// keeps them where they demonstrably work today.
    ///
    /// If a folder row turns out not to be selectable, *this* is the thing to
    /// change and the only known candidate — see the note in
    /// `EudoraDevelopmentNotes.txt`.
    private struct OutlineRows: View {
        let items: [MailboxItem]
        let owner: MailboxTree
        /// The expansion **as a plain value**, resolved by `owner`'s `body` for
        /// this render. Not read back out of `owner`: that is what broke collapsing
        /// (see `setExpanded`). `owner` is still carried, but only for `row(for:)`
        /// and the context menu, neither of which touches `@State`.
        let expanded: Set<String>
        let setExpanded: (MailboxItem.ID, Bool) -> Void

        var body: some View {
            ForEach(items) { item in
                if let children = item.children {
                    DisclosureGroup(
                        isExpanded: Binding(get: { expanded.contains(item.id) },
                                            set: { setExpanded(item.id, $0) })
                    ) {
                        OutlineRows(items: children, owner: owner,
                                    expanded: expanded, setExpanded: setExpanded)
                    } label: {
                        owner.row(for: item)
                    }
                } else {
                    owner.row(for: item)
                }
            }
        }
    }

    private struct GroupSubmenu: View {
        let folder: MailboxItem
        let moving: MailboxItem.ID
        let onMove: (MailboxItem.ID) -> Void

        var body: some View {
            let subgroups = MailboxTree.subGroups(of: folder.children, excluding: moving)
            if subgroups.isEmpty {
                Button(folder.display) { onMove(folder.id) }
            } else {
                Menu(folder.display) {
                    ForEach(subgroups) { GroupSubmenu(folder: $0, moving: moving, onMove: onMove) }
                } primaryAction: {
                    onMove(folder.id)
                }
            }
        }
    }
}

/// **`.listRowInsets` does not change this sidebar's row height.** Tried
/// 2026aug04, halving the vertical inset: no visible effect at all. The same
/// lesson the message table already learned — SwiftUI floors the row height
/// regardless of the content, which is why `MessageRowMetrics.rowHeight` is
/// forced directly on the `NSTableView` and re-enforced through KVO when SwiftUI
/// resets it (see `pinRowHeight` / `enforceRowHeight`).
///
/// That conclusion — reach for the backing `NSOutlineView` — was tried and is
/// **wrong for this view**: SwiftUI answers `heightOfRowByItem` here, so the
/// AppKit `rowHeight` is inert. The height is set by `defaultMinListRowHeight` on
/// the `List`; see `SidebarRowMetrics` for the measurements. The note stays for
/// the part that held up: nothing added to *this* view changes its row height.
struct MailboxRow: View {
    let item: MailboxItem
    /// Whether to draw the new-mail glyph. Only ever true for the In row — the
    /// caller gates it on `item.type == .inbox` (see `AppModel.inboxHasNewMail`).
    let newMail: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.isFolder ? .secondary : .primary)
                .frame(width: 18)
            Text(item.display)
                .font(EudoraFont.list)
                .fontWeight(item.hasUnread ? .semibold : .regular)
            // Eudora's green "unsent" glyph, just right of the label, when Out
            // holds mail waiting to go. Native art, drawn crisp (no smoothing),
            // at its own size. Only ever set for the Out row — see
            // `MailboxItem.hasUnsent`.
            if item.hasUnsent {
                Image(RowIcon.unsent)
                    .interpolation(.none)
                    .help("Unsent mail waiting to be sent")
            }
            // The new-mail glyph next to In when In's newest message is unread —
            // the In counterpart of the unsent glyph above. Goes out by itself
            // when that message is read, because it is derived rather than
            // dismissed; see `AppModel.inboxNewestIsUnread`.
            //
            // `TreeIcon.newMail`, not `RowIcon.unread`: bigger and green, to be
            // seen from across the room. See the comment on TreeIcon.
            if newMail {
                Image(TreeIcon.newMail)
                    .help("New unread mail")
            }
            Spacer()
            if !item.isFolder && item.messageCount > 0 {
                Text("\(item.messageCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Message-list geometry

/// The one place the message table's horizontal geometry is decided.
///
/// Two layout systems share this table: AppKit places the column *headers* from
/// `NSTableView.intercellSpacing`, and SwiftUI places the cell *content* on a
/// grid it derives from that same property. They agree — but only as long as
/// nobody changes the property behind SwiftUI's back.
///
/// **Why we no longer zero `intercellSpacing`.** An earlier version set it to 0
/// to butt the columns up, from an async callback because the `NSTableView`
/// doesn't exist during SwiftUI's layout pass. By then SwiftUI had already laid
/// out at the old spacing, so AppKit's headers collapsed and SwiftUI's content
/// did not, and per-column offsets of −17 × i were added to drag the content
/// back. That worked at launch and *only* at launch: the first window resize
/// made SwiftUI relayout, it re-read the now-zero spacing, its grid collapsed
/// onto AppKit's — and the offsets, no longer cancelling anything, threw every
/// column 17 × i too far left. Instrumentation caught it directly:
///
///     SwiftUI grid at launch    16   78  370  527   (read spacing 17)
///     SwiftUI grid after resize 16   61  336  476   (read spacing 0)
///     AppKit headers            10   61  336  476
///
/// No constant can be right in both states, so the spacing is now left alone.
/// Both sides stay on the 17 pt grid, and all that remains is a flat inset
/// SwiftUI adds inside each cell — 6 pt on the glyph column, 8 pt on the text
/// columns, the same at launch, after a resize, and at every window width.
///
/// The closed-up look is preserved through `MessageColumnWidths` instead: the
/// widths are chosen so the columns land where zeroing the spacing used to put
/// them. Those widths are a layout choice and safe to retune; the two insets
/// below are measured, and changing them means re-measuring.
///
/// The displacement is an `.offset`, not `.padding`: padding would take the
/// space out of the cell's width and start truncating long subjects, whereas an
/// offset only moves the drawing.
///
/// If headers and content ever drift apart again, note *which way*: a constant
/// error across all columns is one of the insets below, whereas an error growing
/// linearly left to right means something has started changing the intercell
/// spacing again, and the history above is the thing to re-read.
enum MessageTableMetrics {
    /// SwiftUI's inset inside the leading glyph cell. Measured.
    ///
    /// It differs from the text columns' because that cell is an `HStack` of
    /// fixed-width frames while the text cells are a bare `Text`, and SwiftUI
    /// treats the two differently.
    static let leadingGlyphInset: CGFloat = 6

    /// SwiftUI's inset inside a text cell. Measured.
    static let textCellInset: CGFloat = 8

    /// How far left column `index`'s content must be drawn to meet its header.
    static func contentOffset(column index: Int) -> CGFloat {
        index == 0 ? -leadingGlyphInset : -textCellInset
    }
}

/// The message list's column widths, as a single table both sides read from.
///
/// **Why these are fixed rather than flexible.** SwiftUI's `Table` and the
/// `NSTableView` backing it each negotiate flexible column widths *separately*,
/// and they do not arrive at the same answer: instrumentation showed AppKit's
/// columns 73 pt short of filling the table at launch but only 20 pt short after
/// a window resize, while SwiftUI's content grid filled the width throughout.
/// Headers are drawn from AppKit's widths and content from SwiftUI's, so the two
/// drifted apart by an amount that *changed when the window was resized* — the
/// symptom being one misalignment at launch and a different one afterwards.
///
/// No constant in `MessageTableMetrics` can fix that, because there is no single
/// error to cancel. Pinning the widths removes the negotiation instead: a column's
/// origin depends only on the widths *before* it, so with every column but the
/// last one fixed, both grids compute identical origins in every state. Only the
/// trailing column is left flexible, and nothing's origin depends on its width.
///
/// `TableHeaderIconStyler.enforce` pins the same numbers on the AppKit side. The
/// two must agree, or the sides will overwrite each other on every layout pass.
///
/// **Why these particular numbers.** With the 17 pt intercell spacing left in
/// place (see `MessageTableMetrics`), each column starts 17 pt further right than
/// it would have with the spacing zeroed. These widths give that back, so Date
/// and Subject land at 336 and 476 — exactly where the old zeroed-spacing layout
/// put them. Who alone starts ~11 pt further right, because the only way to
/// recover that last gap would be to shrink the glyph column below its 45 pt of
/// artwork. Retune freely: unlike the metrics, these are taste, not measurement.
enum MessageColumnWidths {
    /// The starting widths, used until the user drags a header divider. Who and
    /// Date are then user-adjustable and remembered globally (see `AppModel`);
    /// Subject is the trailing flexible column and takes the remainder.
    static let whoDefault: CGFloat = 247
    // Date was widened from 123 to fit "2026jul22 16:26:35" — the YYYYmmmDD
    // HH:mm:ss date runs ~111 pt at Arial 13, which the old width left no room for.
    static let dateDefault: CGFloat = 145

    /// The narrowest each column may be dragged. Kept a little above each header
    /// label so it can never be hidden. Taste, not measurement — retune freely.
    static let whoMin: CGFloat = 55
    static let dateMin: CGFloat = 55
    /// Subject is flexible; this floor keeps a very wide Date from squeezing it
    /// out of sight.
    static let subjectMin: CGFloat = 80

    /// The widest Who or Date may be dragged.
    static let maxWidth: CGFloat = 1000

    static let whoWidthKey = "messageColumn.who.width"
    static let dateWidthKey = "messageColumn.date.width"

    /// A persisted column width, clamped to its minimum, or the default when none
    /// is stored.
    static func loaded(key: String, default def: CGFloat, min minimum: CGFloat) -> CGFloat {
        let stored = (UserDefaults.standard.object(forKey: key) as? Double).map { CGFloat($0) }
        return Swift.max(minimum, stored ?? def)
    }
}

extension View {
    /// Draws a table cell's content where its column header actually is.
    /// The column index must match the `TableColumn` order.
    func tableCell(column index: Int) -> some View {
        offset(x: MessageTableMetrics.contentOffset(column: index))
    }

    /// Makes text the user may need verbatim — error messages above all —
    /// selectable, right-click-copyable, and readable in full as a tooltip even
    /// when the layout truncates it.
    ///
    /// Errors from the network layer are exactly the strings worth quoting: an
    /// SMTP rejection carries the server's numeric code and its own explanation,
    /// and the difference between a 534 and a 535 is the difference between two
    /// completely different fixes. Text you can't copy is text that gets
    /// retyped, or paraphrased, or truncated with an ellipsis.
    ///
    /// `.textSelection` alone isn't enough: it requires selecting first, and
    /// these labels are often one truncated line in a crowded footer. The
    /// explicit Copy item takes the whole `text`, not the visible part of it.
    ///
    /// A `.contextMenu` is fine here despite the trouble SwiftUI menus caused
    /// over the mailbox tree (see `MessageContextMenu`): the problem there was
    /// SwiftUI eagerly building 2,657 nested items on every right-click. This is
    /// one button over no data.
    func copyable(_ text: String) -> some View {
        self
            .textSelection(.enabled)
            .help(text)
            .contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
    }
}

// MARK: - Message-list column headers

/// A Eudora 7 column-header icon, taken from the original app's artwork and
/// shipped in `Assets.xcassets`.
///
/// Both icons live in a *single* table column, and that's deliberate.
///
/// As separate columns they were pushed apart by the table's 17 pt intercell
/// spacing, and that spacing can't be reduced: SwiftUI derives its cell grid from
/// that property but only re-reads it on a relayout, so changing it slides every
/// header out of line with its content, cumulatively, left to right, until
/// something forces SwiftUI to catch up (see `MessageTableMetrics`). Drawing the
/// icons out into the gap doesn't work either — AppKit clips the header cell to
/// its frame.
///
/// One column sidesteps all of it. There is no gap *within* a column, so the two
/// icons sit flush against each other in the header and the two glyphs line up
/// under them in each row. The column is exactly as wide as the two icons.
///
/// `TableHeaderIconStyler` still has to paint the header via AppKit: a SwiftUI
/// header is a `Text` and gets inset, and there's no API to stop that.
struct HeaderIcon {
    let assetName: String

    static let status = HeaderIcon(assetName: "ColumnStatus")
    static let attachment = HeaderIcon(assetName: "ColumnAttachment")

    /// The icons sharing the leading column, left to right.
    static let leadingColumns = [status, attachment]

    /// Combined width of that column: the icons laid side by side.
    static var leadingColumnWidth: CGFloat {
        leadingColumns.reduce(0) { $0 + $1.width }
    }

    /// Fallback width if the asset is missing (it shouldn't be).
    static let fallbackWidth: CGFloat = 22

    var nsImage: NSImage? { NSImage(named: assetName) }

    /// The icon's native width in points — the art is 1x, so this is its pixels.
    var width: CGFloat {
        guard let size = nsImage?.size, size.width > 0 else { return Self.fallbackWidth }
        return size.width
    }
}

/// Eudora 7's own row glyphs: the unread dot and the attachment mark that appear
/// in each message row, under the matching header icon.
///
/// Separate art from `HeaderIcon` — these are the smaller in-row marks (14 and 17
/// px) rather than the header's bezelled buttons (21 and 24 px) — but they sit in
/// the same two sub-columns, so each is centred in the *header* icon's width and
/// the two stay in register down the list.
///
/// Drawn `.resizable()` at its own native size with `.interpolation(.none)`: the
/// art is 1x pixel art, and nearest-neighbour keeps it crisp at 2x instead of
/// smoothing it into mush. The `.resizable()` is load-bearing — `.interpolation`
/// is silently ignored on a non-resizable `Image`, which is exactly the trap this
/// comment exists to stop someone falling into again.
/// The art in the catalog is *not* the art in `assets/`: the originals came with
/// an opaque near-white background, which showed as a white block on a selected
/// (blue) row. `assets/make-row-icons.py` regenerates the catalog copies with a
/// real alpha channel — rerun it if the source art is ever replaced.
enum RowIcon {
    static let unread = "RowUnread"
    static let attachment = "RowAttachment"
    /// A message composed but not sent — a draft in Out.
    static let unsent = "RowUnsent"
    /// A message whose send was attempted and failed.
    static let sendError = "RowSendError"

    /// Height of the glyph slot.
    ///
    /// Given explicitly so a row with no glyph is the same height as one with:
    /// the cell used to always hold a `Text` (status was `" "` for read mail) and
    /// so always had a line box, whereas an empty `Group` would collapse to zero.
    ///
    /// **Not** the row-density knob. The probe proved SwiftUI's `Table` floors
    /// the row no matter how short the content is, so density is forced directly
    /// — see `MessageRowMetrics.rowHeight`. This only needs to be ≤ that row
    /// height so the glyph isn't clipped. Held equal to it: the attachment icon
    /// is 16 pt tall, so at a 16 pt row the slot has to be 16 too, or that icon
    /// loses a half-pixel top and bottom.
    static let height: CGFloat = 16

    /// A row glyph centred in its sub-column, or empty space of the same size.
    static func view(_ name: String, show: Bool, width: CGFloat) -> some View {
        let art = NSImage(named: name)?.size ?? CGSize(width: width, height: height)
        return Group {
            if show {
                Image(name)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: art.width, height: art.height)
            }
        }
        .frame(width: width, height: height)
    }
}

/// Glyphs for the mailbox tree, which has different needs from a message row.
///
/// A row glyph is read at arm's length while working. A tree glyph is read from
/// wherever the window happens to be — Stephen parks it on a far display when he
/// isn't using it, and Eudora 7's 14 px blue-lavender ball is neither big enough
/// nor saturated enough to notice from there.
///
/// So `newMail` is the same art, recoloured and enlarged: 20 pt, and green to
/// match Out's unsent glyph. Sharing the colour is deliberate rather than
/// careless — both mean "there is something here you'll want to do", which is the
/// only thing that needs to carry at that distance; *which* mailbox is saying it
/// is told by which row it's on.
///
/// The message rows keep `RowIcon.unread` unchanged: that is Eudora 7's own
/// glyph, and it is read close up where it works fine.
///
/// Generated by `assets/make-tree-newmail.py`, which also explains why this one
/// is resampled smoothly where the row icons are not. Regenerate rather than
/// hand-editing, and note the imageset carries 1x and 2x art, so — unlike
/// `RowIcon` — it needs neither `.resizable()` nor `.interpolation(.none)`.
///
/// **20 pt does not change the row height**, which was the open question: it is
/// taller than anything else in a `MailboxRow` (the unsent glyph, next tallest,
/// is 15) and the sidebar's rows self-size, so it might have pushed In taller
/// than its neighbours. Observed 2026aug03: In sits level with Out and Trash, so
/// the macOS sidebar row has enough height to absorb it. Going much beyond 20
/// would need checking again.
enum TreeIcon {
    static let newMail = "TreeNewMail"
}

/// The Who column's direction marker — a small "S ▶"/"▶ S" glyph saying which
/// way a message went relative to me. A message I sent (`.fromMe`) shows the
/// *leading* `Sto` mark ("S ▶") hugging the name's left; one I received
/// (`.toMe`) shows the *trailing* `toS` mark ("▶ S") pinned to the right, next
/// to the Date column. `.selfToSelf` and `.neither` show nothing. Each slot
/// reserves its width whether or not a mark is drawn — that fixed leading slot
/// is what makes the names line up in one column whichever way a message went,
/// and the trailing mark keeps a constant position on the right.
///
/// The art is Stephen's own PNGs (`Sto`/`toS` imagesets), knocked out to a
/// transparent background and scaled to a 17×11 pt box so it sits on the text
/// line with a little air above and below. To restyle, swap the imagesets or
/// the box size here — this enum is the only place the marks are drawn.
enum WhoGlyph {
    /// Width reserved for each mark's slot — the 17 pt art plus a hair of margin.
    static let slotWidth: CGFloat = 18

    /// Leading slot — the "S ▶" mark when the message is one I sent, else space.
    static func leading(_ direction: WhoDirection) -> some View {
        mark("Sto", shown: direction == .fromMe)
    }

    /// Trailing slot — the "▶ S" mark when the message is one I received, else space.
    static func trailing(_ direction: WhoDirection) -> some View {
        mark("toS", shown: direction == .toMe)
    }

    private static func mark(_ name: String, shown: Bool) -> some View {
        // `Color.clear`, not an empty branch: a bare `if` with no content
        // collapses to nothing and the `.frame(width:)` around it reserves no
        // space, so a blank slot would let the name slide left. Drawing a clear
        // fill of the same size holds the slot open, so the "or blank" is
        // exactly as wide as the mark — names line up whichever way mail went.
        Group {
            if shown {
                Image(name)   // asset catalog picks @1x/@2x; native 17×11 pt box
            } else {
                Color.clear
            }
        }
        .frame(width: slotWidth, height: RowIcon.height)
    }
}

/// The message list's row height, forced onto the underlying `NSTableView`.
///
/// SwiftUI's `Table` gives every row a self-sizing ~25 pt on macOS and offers no
/// API to change it, so the only lever is the AppKit `rowHeight` (with automatic
/// row heights turned off), set and re-asserted by `TableScrollStateSyncer`. The
/// Arial-13 text line box is ~15 pt and the attachment icon is 16 pt, so 16 is
/// the floor — below it text and that icon start to clip. Tuned down from the
/// original ~25 to here.
///
/// The scroll bridge reads `rowHeight` live for its step arithmetic, so changing
/// it here stays consistent with `rect(ofRow:)` and the wheel math.
enum MessageRowMetrics {
    static let rowHeight: CGFloat = 16
}

/// One-shot readout of the message list's real row geometry.
///
/// Investigation (2026-07): trimming `RowIcon.height` didn't tighten the rows.
/// The probe found why — SwiftUI's `Table` runs with *automatic* row heights, so
/// the `rowHeight` property was only an estimate (settable to 20 while
/// `rect(ofRow:)` stayed ~25) and each row self-sized to its content plus
/// SwiftUI's cell padding. The fix was `usesAutomaticRowHeights = false` plus a
/// forced `rowHeight` (see `MessageRowMetrics.rowHeight`); density then landed at
/// 16, the floor set by the Arial-13 text and the 16 pt attachment icon.
///
/// Switched off but kept intact, per CLAUDE.md's diagnostics convention.
enum RowDensityProbe {
    static let enabled = false
    private static var scheduled = false

    static func reportOnce(_ table: NSTableView) {
        guard enabled, !scheduled else { return }
        scheduled = true
        // A beat later: `rowHeight` is set by SwiftUI's own layout, which may not
        // have run when the table is first found, and rows may not be in yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let rowRect = table.numberOfRows > 0 ? table.rect(ofRow: 0).height : -1
            print("[rowdensity] rowHeight \(table.rowHeight)"
                + "  intercellSpacing.h \(table.intercellSpacing.height)"
                + "  rect(ofRow:0).height \(rowRect)"
                + "  rows \(table.numberOfRows)"
                + "  RowIcon.height \(RowIcon.height)")
        }
    }
}

/// An `NSTableHeaderCell` that draws an image across its entire frame: no inset,
/// no title, no separator. The Eudora art carries its own bezel, so the default
/// header chrome would only fight with it.
final class ImageHeaderCell: NSTableHeaderCell {
    /// Stretch the icon to fill the header, versus centering it at native size.
    /// The header row is usually a couple of points taller than the 22 px art.
    static let fillsHeader = false

    /// Held directly rather than in the inherited `NSCell.image`: AppKit ties
    /// that property to the cell *type*, and on a cell built with
    /// `initTextCell:` it can read back nil — which would silently draw nothing.
    private let icons: [NSImage]

    /// Which of the two icons the list is currently sorted by, and which way, or
    /// nil when the sort is on another column.
    ///
    /// AppKit's own `setIndicatorImage(_:in:)` can't help here: it draws one
    /// indicator per *column*, and these two sortable things share a column (see
    /// `HeaderIcon`). So the triangle is drawn here, under the icon it belongs to.
    var sortedIcon: Int?
    var sortAscending = true

    init(icons: [NSImage]) {
        self.icons = icons
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `NSCell`'s inherited copy is a shallow, non-retaining one, which would
    /// leave `icons` dangling. Copy explicitly instead.
    ///
    /// The sort state has to be carried across: AppKit draws through a copy on
    /// some paths, and a copy that lost it would drop the indicator at random.
    override func copy(with zone: NSZone? = nil) -> Any {
        let clone = ImageHeaderCell(icons: icons)
        clone.sortedIcon = sortedIcon
        clone.sortAscending = sortAscending
        return clone
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Lay the icons left to right at their native widths, so they touch.
        var x = cellFrame.minX
        for (index, icon) in icons.enumerated() {
            let slot = NSRect(x: x, y: cellFrame.minY,
                              width: icon.size.width, height: cellFrame.height)
            let target: NSRect
            if Self.fillsHeader {
                target = slot
            } else {
                target = NSRect(x: x, y: cellFrame.midY - icon.size.height / 2,
                                width: icon.size.width, height: icon.size.height)
            }
            // respectFlipped matters: NSTableHeaderView is flipped, and without
            // it the icons would draw upside down.
            icon.draw(in: target, from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            if index == sortedIcon { drawSortIndicator(in: slot) }
            x += icon.size.width
        }
    }

    /// A small triangle in the bottom-right of one icon's slot, standing in for
    /// the indicator AppKit would draw if these were separate columns.
    ///
    /// Drawn rather than stamped from `NSImage(named: "NSAscendingSortIndicator")`
    /// because the system art is sized for a text header and, laid over artwork
    /// only 21 px wide, covers the icon it is meant to annotate.
    private func drawSortIndicator(in slot: NSRect) {
        let size: CGFloat = 5
        let inset: CGFloat = 1.5
        let right = slot.maxX - inset
        let left = right - size
        // NSTableHeaderView is flipped, so minY is the *top* edge: "up" here
        // means toward minY.
        let bottom = slot.maxY - inset
        let top = bottom - size

        let path = NSBezierPath()
        if sortAscending {
            path.move(to: NSPoint(x: (left + right) / 2, y: top))
            path.line(to: NSPoint(x: right, y: bottom))
            path.line(to: NSPoint(x: left, y: bottom))
        } else {
            path.move(to: NSPoint(x: (left + right) / 2, y: bottom))
            path.line(to: NSPoint(x: right, y: top))
            path.line(to: NSPoint(x: left, y: top))
        }
        path.close()
        NSColor.secondaryLabelColor.setFill()
        path.fill()
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        NSSize(width: icons.reduce(0) { $0 + $1.size.width },
               height: icons.map(\.size.height).max() ?? rect.height)
    }
}

/// Locates the `NSTableView` backing the message list, for the two places that
/// have to talk to AppKit directly (header icons, scroll position).
///
/// Care is needed because the mailbox sidebar is a table too. As of macOS 13 the
/// window contains:
///
///     SwiftUIOutlineTableView  columns=4  headerView=NSTableHeaderView
///     SwiftUIOutlineListView   columns=1  headerView=nil
///
/// The first is our `Table`, the second the sidebar `List`. Note that both are
/// `NSOutlineView` subclasses — an earlier version rejected outline views to
/// protect the sidebar and threw away the message table with it. So the
/// discriminator is the column count: the message table has four (glyphs, Who,
/// Date, Subject), the sidebar one. Climbing outward from the caller's own
/// backing view also biases toward the adjacent table.
enum MessageTableFinder {
    /// Minimum columns to be the message table rather than the sidebar.
    ///
    /// The table has four; three is deliberate slack, so that adding or removing
    /// a column doesn't silently stop the table being found — which would show up
    /// as blank headers and drifting columns rather than as an obvious failure.
    static let columnsAtLeast = 3

    static func table(near view: NSView) -> NSTableView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let found = search(in: current) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func search(in root: NSView) -> NSTableView? {
        if let table = root as? NSTableView, table.tableColumns.count >= columnsAtLeast {
            return table
        }
        for child in root.subviews {
            if let found = search(in: child) { return found }
        }
        return nil
    }
}

/// Locates the `NSTableView` backing the mailbox sidebar — the other half of
/// `MessageTableFinder`, and deliberately its mirror image.
///
/// Same window, two `NSOutlineView` subclasses (see the layout in
/// `MessageTableFinder`), so this discriminates the opposite way: **one** column
/// *and* no header view. The message table has four columns and an
/// `NSTableHeaderView`, so it can't match either test, and requiring both means
/// a future column added to the sidebar fails to find it — no change to density —
/// rather than quietly tightening the message list instead.
enum SidebarOutlineFinder {
    static func outline(near view: NSView) -> NSTableView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let found = search(in: current) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func search(in root: NSView) -> NSTableView? {
        if let table = root as? NSTableView,
           table.tableColumns.count == 1,
           table.headerView == nil {
            return table
        }
        for child in root.subviews {
            if let found = search(in: child) { return found }
        }
        return nil
    }
}

/// The mailbox sidebar's row height. **This constant is the only knob**; the
/// mechanism around it took five builds to establish, so it is worth stating as a
/// conclusion rather than a trail.
///
/// Two conditions have to hold together, and neither works alone:
///
/// 1. `.listStyle(.plain)` on the `List`. The sidebar style imposes a fixed 32 pt
///    row that nothing else can reach.
/// 2. `.environment(\.defaultMinListRowHeight, rowHeight)` applied **inside** the
///    `List`, around its content. `List` writes its own value into the content
///    environment from the list style, so the same modifier applied to the `List`
///    is overwritten before any row reads it — measured, not assumed: with 24 set
///    on the `List`, a row read back 32.
///
/// Everything else was tried and measured inert on this view, which is worth
/// knowing before reaching for any of it again: the AppKit `rowHeight` (forced to
/// 20, `rect(ofRow:)` stayed 32 — SwiftUI's outline coordinator answers
/// `heightOfRowByItem`, so the property is only an estimate here, unlike the
/// message table's `Table` where the same code does work — see
/// `MessageRowMetrics`); `usesAutomaticRowHeights`; `intercellSpacing`, already 0,
/// so there is no between-row gap to reclaim; `rowSizeStyle`, set to `.small`
/// with `rect(ofRow:)` staying 32; and `.listRowInsets`, which never moved the
/// height in 2026aug04.
///
/// And KVO-pinning the AppKit height the way `TableScrollStateSyncer` does
/// **stack-overflows here** — the guard that bounds it there depends on
/// `rowHeight` being authoritative, which it isn't.
///
/// **The floor on the value is 20 pt, set by artwork rather than by text.** The
/// tallest thing in any row is `TreeIcon.newMail`, the green new-mail badge on In:
/// a 20×20 PNG drawn at native size, no `.frame`, not resizable. Next is the SF
/// Symbol row icon at ~16 (it gets no `.font`, so it is *not* Arial 13), then the
/// Arial-13 text line box at ~15. So 21 keeps a point of slack over the badge and
/// is the tightest value available without touching art; going below that means
/// bounding the badge — `.resizable()` into a 16 pt frame, or a 16 pt imageset —
/// and that would visibly shrink a glyph chosen to be seen from across the room.
///
/// 32 → 24 halved the space around ~16 pt of content; 21 takes most of what is
/// left.
enum SidebarRowMetrics {
    static let rowHeight: CGFloat = 21

    /// The rule between sets of sidebar rows.
    ///
    /// Deliberately darker than `NSColor.separatorColor`, which is what the
    /// `List` already draws *between* rows. The two lines have different jobs —
    /// one parts neighbours, one parts groups — and at the same weight the set
    /// break was the least visible line on screen. `Color.primary` rather than a
    /// fixed grey so it inverts with the appearance.
    static let setDividerColor = Color.primary.opacity(0.45)
    static let setDividerThickness: CGFloat = 1

    /// How far the set rules reach past the row's content on each side, to cross
    /// the list's own row inset and meet the window edges. Generous on purpose —
    /// an overlay wider than it needs to be is invisible if the row clips it and
    /// correct if it doesn't.
    static let setRuleOverhang: CGFloat = 40

    /// How far each set rule is nudged out of the Recents row, away from its
    /// label.
    ///
    /// The rules hang on the row's edges, and a row edge is not the middle of the
    /// gap between two rows' text: the Recents label fills its row, while a
    /// mailbox row leaves a few points under its text. So a rule drawn exactly on
    /// the boundary is flush against "Recents" and clear of "Trash". This offset
    /// centres it in the space instead — and it moves only the line, so the text
    /// spacing Stephen confirmed as correct doesn't change.
    static let setRuleOffset: CGFloat = 3

    /// Breathing room above and below the Recents label, which is what sets its
    /// distance from the two rules.
    ///
    /// The rules hang on the row's edges, so padding the label pushes them away
    /// from it without moving them relative to Trash and the first folder above
    /// and below — a row grows downward from a fixed top edge. It does lengthen
    /// the sidebar by twice this, which Stephen accepted for the clearance.
    ///
    /// This is the knob for "the rules crowd the word Recents"; `setRuleOffset`
    /// is the one for "the rules aren't centred in the gap". They are easy to
    /// confuse and they move different things.
    static let recentsRowPadding: CGFloat = 2
}

/// The rule between sets in the sidebar: system mailboxes, Recents, and the
/// user's own.
///
/// **Drawn on the edges of the Recents row, not as a row of its own — and that
/// is the whole point.** Three attempts, worth recording so the next one starts
/// from the end:
///
/// 1. `Divider()`. A `Divider` in a `List` is a row, so the list drew its own
///    separator above *and* below it: three rules stacked where one was meant,
///    and the only one that read as a set break was the faintest.
/// 2. A drawn `Rectangle` row with `.listRowSeparator(.hidden)` and
///    `.listRowInsets(EdgeInsets())`. Correct line, correct width, but ~20 pt of
///    air around it — because it was still a row, and a row cannot be shorter
///    than `defaultMinListRowHeight`, which the sidebar pins at 21 for the
///    new-mail badge.
/// 3. Writing `defaultMinListRowHeight` again on that one row, nested inside the
///    one `MailboxTree` applies to its whole content. **Measured: no change.**
///    So the key is read once for the list, not per row — one more entry for the
///    list in `SidebarRowMetrics` of things that look like they should work here
///    and don't.
///
/// Which leaves: don't have a row. These are `overlay`s on `RecentsRow`, so they
/// occupy no vertical space at all and the gap is just the two neighbouring rows'
/// own padding — about half what a dedicated row cost, which is what Stephen
/// asked for. `RecentsRow` also hides its own list separators, or the hairlines
/// would sit a point away from these.
///
/// The negative horizontal padding is what takes them full width: an overlay is
/// bounded by the row's content, which the list insets. **If the rules come out
/// short of the window edges**, the row is clipping the overlay and the answer is
/// to zero `RecentsRow`'s `.listRowInsets` and re-add the same inset as padding
/// on its `HStack` — which is only avoided here because guessing that inset wrong
/// would misalign the Recents icon against In/Out/Trash, a worse fault than a
/// short rule.
///
/// The within-set separators are untouched and should stay: they part rows that
/// belong together, which is the one place a hairline reads correctly.
struct SidebarSetRule: View {
    var body: some View {
        Rectangle()
            .fill(SidebarRowMetrics.setDividerColor)
            .frame(height: SidebarRowMetrics.setDividerThickness)
            .padding(.horizontal, -SidebarRowMetrics.setRuleOverhang)
    }
}

/// Traces the sidebar's disclosure state: every toggle, and every change to the
/// set the rows are actually built from.
///
/// Off, and intact. It was written for a nested group that would open but not
/// close, whose candidate causes were indistinguishable on screen; in the end the
/// bug was settled by a quit-and-reopen test instead (see `setExpanded`), which
/// showed the state had been correct all along and only the redraw was missing.
///
/// Still the right tool if a disclosure ever misbehaves again, because it
/// separates the three cases that look the same from outside:
///
/// - `set` then a `render` line, and the row still wrong → the state moved and the
///   outline view ignored it.
/// - `set` with no `render` line → the write isn't invalidating the view. This was
///   the actual bug.
/// - no `set` line at all → the click never reached the disclosure, and the label's
///   `.tag`/`.contextMenu` are the suspects.
enum SidebarExpansionProbe {
    static let enabled = false
    private static var lastRendered: Set<String>?

    static func set(_ id: String, _ isExpanded: Bool, resulting: Set<String>) {
        guard enabled else { return }
        print("[sbexp] set \(id) -> \(isExpanded)  resulting \(resulting.sorted())")
    }

    /// Prints only when the set changes, so a render storm doesn't bury the trace.
    static func rendered(_ ids: Set<String>) {
        guard enabled, ids != lastRendered else { return }
        lastRendered = ids
        print("[sbexp] render \(ids.sorted())")
    }
}

/// One-shot readout of the sidebar's real row geometry.
///
/// Off, and intact, per CLAUDE.md's convention. It earned its keep: five builds
/// of density work were decided by its output, and it is what identified the
/// height's real owner (`delegateItemHeight true`) after two wrong theories. Turn
/// it back on if the row height ever stops answering to `SidebarRowMetrics` — the
/// numbers it prints are the ones that distinguish "the finder missed" from "the
/// lever is inert" from "the value never arrived", and those look identical from
/// the outside.
enum SidebarDensityProbe {
    static let enabled = false
    private static var scheduled = false

    /// Call with the table **before** the height is forced — the whole point is
    /// the value SwiftUI chose, and one line of it.
    ///
    /// Split into two moments, because the two halves aren't available at the
    /// same time. The properties can be read now and must be, since forcing the
    /// height destroys them; the row geometry can't, because rows may not be in
    /// yet and SwiftUI's layout may not have run. Same 0.3 s `RowDensityProbe`
    /// settled on for exactly that reason. Reading `rect(ofRow:)` at attach time
    /// instead would have reported `rows 0` and latched, spending the build and
    /// learning nothing.
    static func reportOnce(_ table: NSTableView) {
        guard enabled, !scheduled else { return }
        scheduled = true
        let before = [
            "rowHeight \(table.rowHeight)",
            "automatic \(table.usesAutomaticRowHeights)",
            "spacing.h \(table.intercellSpacing.height)",
            // The likeliest reason forcing `rowHeight` does nothing at all: a
            // delegate height callback overrides it whether automatic heights are
            // on or off. SwiftUI's outline coordinator behind `List` is a
            // different object from the one behind `Table`, so the message
            // table's success here proves nothing about the sidebar — and a
            // no-change outcome would otherwise be indistinguishable from the
            // finder having missed.
            //
            // Two selectors because the delegate could answer either: `List` is
            // backed by an `NSOutlineView`, so the item-based callback is the
            // likelier of the two, but the row-based one would win just as
            // completely. Both are `#selector` — the string form warns, and the
            // usual double-parens suppression didn't take here.
            "delegateRowHeight \(table.delegate?.responds(to: #selector(NSTableViewDelegate.tableView(_:heightOfRow:))) ?? false)",
            "delegateItemHeight \(table.delegate?.responds(to: #selector(NSOutlineViewDelegate.outlineView(_:heightOfRowByItem:))) ?? false)",
        ].joined(separator: "  ")
        // Built by joining an array rather than concatenating interpolations:
        // this file has already paid for that shape once — a six-element
        // `+`-chain of interpolated literals is what trips "unable to type-check
        // in reasonable time" (see the note on `MessageRowMetrics`' neighbours).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak table] in
            guard let table else { return }
            let rows = table.numberOfRows
            let rowRect: CGFloat = rows > 0 ? table.rect(ofRow: 0).height : -1
            let after = ["rect(ofRow:0).height \(rowRect)", "rows \(rows)"]
                .joined(separator: "  ")
            print("[sidebardensity] was: " + before + "  |  is: " + after)
            reportRowAnatomy(table)
        }
    }

    /// Where the 32 pt actually lives: content, or padding around content.
    ///
    /// This is the question two builds have now failed to answer by inference.
    /// `defaultMinListRowHeight` is a *floor*, so it can only lower a row whose
    /// measured height is above it — setting 24 changed nothing, which means
    /// either the value never reached the `List` (`reportEnvironment` answers
    /// that, from the SwiftUI side) or the row measures 32 on its own and the
    /// floor never bound.
    ///
    /// The frames separate those. A 32 pt row view wrapping a ~16 pt hosting view
    /// is padding, and the lever is `.listRowInsets` or the list style. A 32 pt
    /// hosting view is content, and the lever is inside `MailboxRow` — most
    /// likely the SF Symbol, which gets no `.font` and so takes the default body
    /// size rather than Arial 13.
    private static func reportRowAnatomy(_ table: NSTableView) {
        guard table.numberOfRows > 0 else { return }
        let rowView = table.rowView(atRow: 0, makeIfNecessary: false)
        let cellView = table.view(atColumn: 0, row: 0, makeIfNecessary: false)
        let hosted = cellView?.subviews.first
        let fields = [
            "rowView.h \(rowView?.frame.height ?? -1)",
            "cellView.h \(cellView?.frame.height ?? -1)",
            "hosted.h \(hosted?.frame.height ?? -1)",
            "cellView.y \(cellView?.frame.origin.y ?? -1)",
            "rowSizeStyle \(table.rowSizeStyle.rawValue)",
        ].joined(separator: "  ")
        print("[sidebaranatomy] " + fields)
    }

    /// **The SwiftUI half, and it was the decisive one — how to put it back.**
    /// Give `MailboxRow` an `@Environment(\.defaultMinListRowHeight)` property and
    /// an `.onAppear` that prints it. It has to be read inside a *row*, not in
    /// `MailboxTree`: `.environment` applies to the list's content, so reading it
    /// in the view that sets it reports the old value and proves nothing. That one
    /// line is what showed a row seeing 32 while 24 had been set on the `List`,
    /// which is the finding the whole mechanism rests on.
    ///
    /// Not left in place because `MailboxRow` is the hot view here — 2,723 of them
    /// — and it is the one place in this file where an unused environment
    /// dependency isn't free.
}

/// Finds the sidebar's outline view and reports its geometry, once.
///
/// **Measurement only — it no longer sets anything.** It began as the mirror of
/// the message table's row-height forcing, and two runs retired that: the KVO
/// pinning stack-overflowed, and the plain assignment it was reduced to turned
/// out to be inert, because SwiftUI answers `heightOfRowByItem` on this view. The
/// height is now set in SwiftUI (`defaultMinListRowHeight`, applied in
/// `MailboxTree.body`); this stays because the number that lever produces is
/// worth being able to read rather than infer from looking at the window.
///
/// Attached to the mailbox `List` as a zero-sized `.background`, the same
/// reach-through `TableHeaderIconStyler` and `TableScrollStateSyncer` use on the
/// message table. Entirely defensive: if the outline view isn't found, nothing
/// happens and nothing prints.
struct SidebarRowHeightPin: NSViewRepresentable {
    final class Coordinator {
        weak var table: NSTableView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Nothing to do when both diagnostics are off, which is the shipped state.
        // Worth an explicit guard rather than relying on the probes' own: `attach`
        // walks the window's view tree to find the outline view, and doing that
        // to then discover there is nothing to report is the kind of cost that
        // survives because it is invisible.
        guard SidebarDensityProbe.enabled || SidebarRowSizeStyleTrial.enabled else { return }
        let coordinator = context.coordinator
        // Async, and with retries: the backing view is not in the window
        // hierarchy on the first pass, and `attach` finding nothing is the
        // ordinary first outcome rather than a failure.
        DispatchQueue.main.async {
            attach(near: nsView, coordinator: coordinator, attemptsLeft: 5)
        }
    }

    @MainActor
    private func attach(near view: NSView, coordinator: Coordinator, attemptsLeft: Int) {
        // Still pinned to a live table — return without walking the view tree.
        // `MailboxTree` re-renders on every selection change, so this is the path
        // an arrow-key press through the sidebar takes; the search is a recursive
        // descent of the window and has no business running there. Tested on
        // `window != nil` rather than identity for the same reason
        // `MessageColumnResizeInstaller.install` does: a table that has left the
        // hierarchy is the one case that must re-attach.
        if let existing = coordinator.table, existing.window != nil { return }
        guard let table = SidebarOutlineFinder.outline(near: view) else {
            guard attemptsLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                attach(near: view, coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        SidebarDensityProbe.reportOnce(table)
        SidebarRowSizeStyleTrial.tryOnce(table)
        coordinator.table = table
    }
}

/// Tests one hypothesis and reports the answer: is the 32 pt row coming from
/// `NSTableView.rowSizeStyle`?
///
/// Where the evidence points. `defaultMinListRowHeight` now demonstrably reaches
/// the rows — a row reads back 24 — and `rect(ofRow:)` is still 32, so the floor
/// is not what sets the height; a floor can only raise. What remains on the chain
/// is the list style, and the one number it left in view is `rowSizeStyle 2`
/// (`.medium`). If SwiftUI's outline coordinator answers `heightOfRowByItem` with
/// something like `max(defaultMinListRowHeight, standardHeight(rowSizeStyle))`,
/// then `.medium` is the 32 and `.small` should move it while `defaultMinListRowHeight`
/// keeps the floor at 24.
///
/// **Deliberately an experiment, not a fix.** It is a single assignment, no KVO
/// (that route already stack-overflowed here), and it changes nothing visible if
/// SwiftUI ignores it — the cheap, non-destructive way to separate this from the
/// alternative, which is `.listStyle(.plain)` and does change the sidebar's
/// appearance. If the printed pair shows no movement, `rowSizeStyle` joins
/// `rowHeight`, `intercellSpacing` and `.listRowInsets` as inert here and the
/// style is the only thing left.
enum SidebarRowSizeStyleTrial {
    /// Off. The trial ran and the answer was no: `styleNow 1  before 32.0
    /// after 32.0` — the assignment took and the row did not move, so the
    /// coordinator does not derive its height from `rowSizeStyle`. Left switched
    /// off rather than deleted, per CLAUDE.md, and it must stay off: it mutates
    /// the table mid-run, which would confound any later density measurement.
    static let enabled = false
    private static var tried = false

    static func tryOnce(_ table: NSTableView) {
        guard enabled, !tried else { return }
        tried = true
        // A beat first, so the "before" is SwiftUI's settled layout rather than a
        // table that hasn't been laid out yet — the mistake the density probe
        // made on its first outing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak table] in
            guard let table, table.numberOfRows > 0 else { return }
            let before = table.rect(ofRow: 0).height
            table.rowSizeStyle = .small
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak table] in
                guard let table, table.numberOfRows > 0 else { return }
                let fields = [
                    "before \(before)",
                    "after \(table.rect(ofRow: 0).height)",
                    "styleNow \(table.rowSizeStyle.rawValue)",
                ].joined(separator: "  ")
                print("[sidebarstyletrial] " + fields)
            }
        }
    }
}

/// Installs `ImageHeaderCell` on the leading column of the `Table` it is attached
/// to (as a `.background`), and pins the fixed column widths on the AppKit side
/// so they can't drift from the ones SwiftUI was given.
///
/// This is deliberate SwiftUI-to-AppKit reach-through: from the backing view we
/// find the enclosing window's `NSTableView` and replace the header cells. It is
/// cosmetic and defensive throughout — if the hierarchy ever changes shape and
/// the table isn't found, the headers simply stay blank rather than breaking.
/// One column's width rule for `TableHeaderIconStyler.enforce`: hold it fixed at
/// `target` (min == max) when set, or — for the trailing flexible column — give
/// it only a `minWidth` floor and let it autoresize to fill (`target` nil).
struct ColumnPin {
    let target: CGFloat?
    let minWidth: CGFloat
}

struct TableHeaderIconStyler: NSViewRepresentable {
    let icons: [HeaderIcon]

    /// `@unchecked Sendable` for the same reason as `TableScrollStateSyncer`'s:
    /// the frame-change block below is `@Sendable` and captures this, but every
    /// access is on the main thread and the compiler can't see that through
    /// `addObserver`'s queue argument.
    final class Coordinator: @unchecked Sendable {
        weak var table: NSTableView?
        var observer: NSObjectProtocol?
        /// The resolved header art, kept so the frame-change block can re-assert
        /// the geometry without reaching back into the (non-`Sendable`) struct.
        var art: [NSImage] = []
        /// The per-column geometry to enforce, refreshed each `apply` so the
        /// frame-change re-enforce uses the current widths.
        var pins: [ColumnPin?] = []

        deinit {
            if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        // The table doesn't exist yet during this pass of layout, so apply once
        // SwiftUI has committed the hierarchy — and retry a few times, since the
        // backing view can be in the tree before the Table's NSTableView is.
        // The budget is generous because `openDefaultIfAvailable` blocks the main
        // thread for several seconds at launch, and the table isn't there until
        // it returns. The retries are chained rather than scheduled up front, so
        // 20 attempts is ~4 s of real waiting; it stops as soon as it succeeds,
        // so the ceiling only costs anything in the case where it was needed.
        DispatchQueue.main.async {
            apply(near: nsView, coordinator: coordinator, attemptsLeft: 20)
        }
    }

    // Deliberately not `@MainActor`: it is only ever called from `DispatchQueue
    // .main`, but annotating it makes those non-isolated closures illegal call
    // sites. Left nonisolated, as the rest of this file's AppKit reach-through is.
    private func apply(near view: NSView, coordinator: Coordinator, attemptsLeft: Int) {
        func retry() {
            guard attemptsLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                apply(near: view, coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
            }
        }

        guard let table = MessageTableFinder.table(near: view) else {
            retry()
            return
        }

        // A table that hasn't been sized yet would tile its flexible columns over
        // nothing, and the first window resize would then redistribute them
        // differently — which looks exactly like a stale metric but isn't. Wait
        // for a real width. (The splash hides the main window with `alphaValue`
        // rather than `orderOut`, so the window is on screen at full size the
        // whole time; a zero width here is SwiftUI not having sized the table
        // yet, not the splash.)
        guard table.bounds.width > 1 else {
            retry()
            return
        }

        // Before the art guard below, which returns for good if an asset is
        // missing. Dragging a column to a new position would break more than it
        // looks: cell content is offset onto its header by *index*
        // (`tableCell(column:)`) and the header-click sort maps index to sort key
        // the same way, so a reorder would leave both pointing at the wrong
        // column — and the pinned widths would then be applied to whatever column
        // had moved into each slot. Nothing here supports reordering, so it must
        // not survive a missing icon. `enforce` re-asserts it on every relayout,
        // since this path only runs when SwiftUI state changes. No `tile()`: the
        // flag is behavioural, not geometric.
        if table.allowsColumnReordering { table.allowsColumnReordering = false }

        // Note this bails out of the width pinning too, not just the art: a
        // missing asset means the headers can drift from the content on resize,
        // rather than merely leaving the header blank. Deliberate — and it
        // doesn't `retry()`, because an asset that failed to load won't appear on
        // a later attempt.
        let art = icons.compactMap(\.nsImage)
        guard !art.isEmpty else { return }

        // Only the glyph column is pinned here. Who and Date are resizable
        // SwiftUI columns (`.width(min:ideal:max:)`) whose width is driven by
        // `MessageColumnResizeController` setting the NSTableColumn directly —
        // SwiftUI keeps its content in step for a *resizable* column, which it
        // won't do for a fixed one. Pinning Who/Date here (min == max) would lock
        // them non-resizable again, so `enforce` must leave them alone. `nil` =
        // don't touch. Stored on the coordinator so the frame-change re-enforce
        // uses the same list.
        let pins: [ColumnPin?] = [
            ColumnPin(target: HeaderIcon.leadingColumnWidth,
                      minWidth: HeaderIcon.leadingColumnWidth),
            nil, nil, nil,
        ]

        let previousTable = coordinator.table
        coordinator.table = table
        coordinator.art = art
        coordinator.pins = pins
        Self.enforce(table: table, art: art, pins: pins)
        // The listing takes 6-7 s to build behind the splash, so a dump taken now
        // would measure an empty table; this one lands after the rows exist.
        // Costs nothing when `diagnoseGeometry` is off.
        if Self.diagnoseGeometry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                Self.dump(table: table, stage: "launch + 10s, rows loaded")
            }
        }

        // Re-assert on every relayout, not just on `updateNSView`, which runs only
        // when SwiftUI *state* changes — and resizing the window changes no state.
        // Without this, anything AppKit resets during a relayout (notably the
        // pinned column widths) would stay reset until the next model change.
        //
        // `enforce` is idempotent and only tiles when it actually changed
        // something, so the `tile()` it does can't feed itself a second frame
        // change.
        //
        // A rebuilt Table means a *new* NSTableView, and an observer registered
        // against the old one never fires again — which would look exactly like
        // this bug returning, but only after switching mailboxes. So re-register
        // on a swap rather than returning early on a token pointed at nothing.
        if previousTable !== table, let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
            coordinator.observer = nil
        }

        guard coordinator.observer == nil else { return }

        // The enclosing scroll view rather than the table itself: its frame
        // changes on every window or split resize just the same, but `tile()`
        // cannot change it, so this hook can't feed itself the way observing the
        // table's own frame can. The flag is additive — several observers may
        // want it, so it is only ever turned on, never off in teardown.
        let source: NSView = table.enclosingScrollView ?? table
        source.postsFrameChangedNotifications = true
        // Captures the coordinator weakly: it owns the token and the token owns
        // this block, so a strong capture would be a cycle and the observer would
        // outlive every teardown of the Table (which happens whenever a mailbox
        // lists empty), accumulating one per rebuild.
        coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: source,
            queue: .main
        ) { [weak coordinator] _ in
            guard let coordinator = coordinator, let table = coordinator.table else { return }
            Self.dump(table: table, stage: "frame change")
            Self.enforce(table: table, art: coordinator.art, pins: coordinator.pins)
            // Again on the next runloop turn, in case SwiftUI resets the column
            // widths *after* this notification within the same layout pass — we
            // can't order ourselves against its internal relayout. `enforce`
            // no-ops when nothing has drifted, so the second pass is almost free.
            DispatchQueue.main.async {
                guard let table = coordinator.table else { return }
                Self.enforce(table: table, art: coordinator.art, pins: coordinator.pins)
                Self.dump(table: table, stage: "after resize, settled")
            }
        }
    }

    /// Instrumentation for the header/content alignment work. Flip
    /// `diagnoseGeometry` to true to re-enable it.
    ///
    /// Kept rather than deleted because the alignment has now needed measuring
    /// twice, and pixel-measuring a screenshot cannot distinguish "AppKit moved
    /// the header" from "SwiftUI moved the content" — which was exactly the
    /// distinction that finally identified the bug. The `drew` lines are the
    /// valuable part: they report where SwiftUI actually placed each cell, which
    /// no AppKit query will tell you.
    ///
    /// The number that matters is **header − cell** on each column: that is the
    /// gap `MessageTableMetrics` is trying to cancel. If it is identical at launch
    /// and after a resize, the remaining error is a constant to be dialled out. If
    /// it differs, something is still moving and no constant can fix both states.
    static let diagnoseGeometry = false

    /// Finding (kept per the diagnostics convention): while hovering a divider,
    /// this printed *nothing* — `enforce` does not run and does not re-tile. So
    /// the resize-cursor flicker is not our re-tiling; it's SwiftUI's own Table
    /// header failing to show the cursor. The drag works regardless. Both the
    /// cursor and the drag are now owned by `MessageColumnResizeController`, with
    /// the columns pinned fixed. Left switched off.
    static let diagnoseResize = false

    private static func dump(table: NSTableView, stage: String) {
        guard diagnoseGeometry else { return }
        func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }

        var lines = ["[geometry] \(stage)",
                     "  table.bounds.width \(f(table.bounds.width))"
                        + "  intercellSpacing \(f(table.intercellSpacing.width))"
                        + "  scale \(f(table.window?.backingScaleFactor ?? 0))"]
        for index in table.tableColumns.indices {
            let cell = table.rect(ofColumn: index)
            let header = table.headerView?.headerRect(ofColumn: index) ?? .zero
            let title = table.tableColumns[index].title
            lines.append("  col \(index) \(title.isEmpty ? "(icons)" : title)"
                            + "  width \(f(table.tableColumns[index].width))"
                            + "  cell.x \(f(cell.minX))"
                            + "  header.x \(f(header.minX))"
                            + "  header-cell \(f(header.minX - cell.minX))"
                            + "  swiftUIOffset \(f(MessageTableMetrics.contentOffset(column: index)))")
        }
        // Where SwiftUI actually *drew* the first row's content, as opposed to
        // where AppKit's column rects say it should be. This is the measurement
        // the AppKit numbers above cannot give: `Table` positions its cell views
        // on its own grid, so a drift between the two shows up here and nowhere
        // else. Compare `drew.x` against the matching `cell.x` — the difference,
        // minus that column's `swiftUIOffset`, is the raw error to cancel.
        // Walk the table's own view tree rather than asking for row 0 via
        // `rowView(atRow:makeIfNecessary:)`: that returned nil every time, so
        // SwiftUI's outline view either reports no rows or doesn't vend them
        // through that API. The real views are in the hierarchy regardless.
        lines.append("  numberOfRows \(table.numberOfRows)"
                        + "  subviews \(table.subviews.count)")
        // No filtering by position: the table is flipped *and* scrolled, so the
        // visible rows are nowhere near y = 0. AppKit recycles row views, so the
        // whole tree is only a few dozen nodes and can just be dumped.
        var emitted = 0
        func walk(_ view: NSView, depth: Int) {
            for sub in view.subviews where sub.frame.width > 1 && sub.frame.height > 1 {
                guard emitted < 60 else { return }
                emitted += 1
                let box = sub.convert(sub.bounds, to: table)
                lines.append("  drew"
                                + String(repeating: ">", count: depth)
                                + " \(type(of: sub))"
                                + "  x \(f(box.minX))  w \(f(box.width))"
                                + "  y \(f(box.minY))")
                if depth < 4 { walk(sub, depth: depth + 1) }
            }
        }
        walk(table, depth: 0)
        if emitted == 0 { lines.append("  (no subviews with a drawable size)") }

        print(lines.joined(separator: "\n"))
    }

    /// Pins the fixed column widths on the AppKit side, and puts the art in the
    /// leading header.
    ///
    /// The widths must match the ones SwiftUI was given in `MessageColumnWidths`
    /// exactly. Headers are drawn from AppKit's widths and content from SwiftUI's,
    /// so any disagreement shows up as misalignment that changes with the window
    /// width. Note this does *not* touch `intercellSpacing` — see
    /// `MessageTableMetrics` for why that would reintroduce the original bug.
    ///
    /// Every write is guarded on the *live AppKit value* rather than a stored
    /// "already applied" flag, which is what makes this safe to call from a frame
    /// -change notification: it is a no-op unless something has actually drifted,
    /// so it neither thrashes layout nor retriggers its own notification. Reading
    /// the table itself also means a rebuilt `Table`, or anything that resets
    /// these behind our back, is picked up rather than latched off forever.
    private static func enforce(table: NSTableView, art: [NSImage], pins: [ColumnPin?]) {
        // AppKit rounds and clamps these, so exact equality can read "changed"
        // forever — which would tile on every notification, post another frame
        // change, and loop at low grade for as long as the app is open. Half a
        // point is far below anything visible.
        func differs(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > 0.5 }

        // `intercellSpacing` is deliberately NOT touched here — see
        // MessageTableMetrics. Writing it from this async callback is what caused
        // the launch-vs-resize misalignment, because SwiftUI has already laid out
        // by the time this runs and only re-reads the property on its next
        // relayout. Leave it alone and both sides stay on the same grid.
        var geometryChanged = false

        // An `if`, not a `guard ... else { return }`: returning here would skip
        // the tile below.
        if let column = table.tableColumns.first, !(column.headerCell is ImageHeaderCell) {
            column.headerCell = ImageHeaderCell(icons: art)
            geometryChanged = true
        }

        // Headers are `NSTableHeaderCell`s drawn by AppKit, not SwiftUI text, so
        // they don't inherit the font set on the cells and have to be told.
        // Guarded like everything else here: this runs on every relayout.
        for column in table.tableColumns.dropFirst()
        where column.headerCell.font != EudoraFont.listNSFont {
            column.headerCell.font = EudoraFont.listNSFont
            geometryChanged = true
        }

        // Hold every column to the same width SwiftUI was given, so the two grids
        // can't negotiate different answers and drift apart. Each column's origin
        // depends only on the widths before it, so holding all but the trailing
        // one is enough to fix every origin. Extra columns beyond the table are
        // ignored, so the two lists can be edited independently without crashing.
        //
        //   • Fixed (glyph): min = max = width, no user resize.
        //   • Flexible (`target` nil): a floor only; it autoresizes to fill.
        // (Who and Date carry no pin — they are resizable SwiftUI columns driven
        // by `MessageColumnResizeController`, so `enforce` leaves them alone.)
        for (index, pin) in pins.enumerated() {
            guard let pin, index < table.tableColumns.count else { continue }
            let column = table.tableColumns[index]

            guard let target = pin.target else {
                // Flexible column: keep a floor so a neighbour can't squeeze it
                // away; leave its width and autoresizing alone.
                if differs(column.minWidth, pin.minWidth) {
                    column.minWidth = pin.minWidth
                    geometryChanged = true
                }
                continue
            }

            // Fixed: min == max == width, no user resize.
            if differs(column.minWidth, target) || differs(column.maxWidth, target)
                || differs(column.width, target) {
                // Raise the ceiling before the floor, so `minWidth` never briefly
                // exceeds `maxWidth`.
                column.maxWidth = .greatestFiniteMagnitude
                column.minWidth = target
                column.maxWidth = target
                column.width = target
                geometryChanged = true
            }
            if !column.resizingMask.isEmpty {
                column.resizingMask = []
                geometryChanged = true
            }
        }

        // Re-asserted here as well as in `apply`, because this is the path the
        // frame-change observer takes: a relayout that re-enabled column dragging
        // would otherwise leave it enabled until the next model change. Outside
        // `geometryChanged` deliberately — it moves nothing, so it must not cause
        // a `tile()`.
        if table.allowsColumnReordering { table.allowsColumnReordering = false }

        // One re-tile, after every input is final, or none at all. `tile()`
        // recomputes the column origins *and* the header view's frame and marks
        // both for display, so no separate header invalidation is needed.
        if diagnoseResize {
            let whoTarget = pins.count > 1 ? (pins[1]?.target.map { Int($0) } ?? -1) : -1
            let whoActual = table.tableColumns.count > 1 ? Int(table.tableColumns[1].width) : -1
            print("[resize] enforce tiled=\(geometryChanged) whoTarget=\(whoTarget) "
                + "whoActualColumnWidth=\(whoActual)")
        }
        if geometryChanged {
            table.tile()
            table.headerView?.needsDisplay = true
        }
    }
}

/// Owns the message list's column-divider interaction end to end: the resize
/// cursor on hover, and the drag that changes a column's width.
///
/// **Why we do it ourselves.** SwiftUI's `Table` on macOS 13 shows the resize
/// cursor unreliably (it keeps clearing it) and its native drag zone is only a
/// few points wide and hard to hit. Both were confirmed the hard way. So the
/// columns are pinned fixed (header and content share one width — see
/// `MessageColumnWidths` / `TableHeaderIconStyler`), SwiftUI resizes nothing,
/// and this controller does the whole job with a comfortable catch zone. It
/// updates `AppModel`'s widths, which re-render the Table and re-pin the header
/// to match — the same number on both sides, so nothing drifts.
///
/// A local event monitor, like the header-sort and scroll monitors, because the
/// `NSTableView` backing a SwiftUI `Table` can't be subclassed or given a
/// delegate of ours. Mouse-moved events are turned on for the window so the
/// cursor can track a hover.
@MainActor
final class MessageColumnResizeController: NSObject {
    var model: AppModel
    private weak var table: NSTableView?
    private var monitor: Any?

    /// Columns whose right edge is a draggable divider: Who (1) → the Who|Date
    /// divider, Date (2) → the Date|Subject divider.
    private static let resizableColumns = [1, 2]
    /// Half-width of the catch zone around a divider, in points — generous so the
    /// divider is easy to grab. The sort monitor skips the same band so a click
    /// here resizes rather than sorts (see `MessageHeaderSortController`).
    static let slop: CGFloat = 6

    /// Trace the divider drag (install, header mouse-downs with the geometry
    /// tested, and the drag). Off; flip on if the drag ever misbehaves again.
    static let diagnose = false

    /// The drag in progress: which column's right edge, the pointer x where it
    /// began, and that column's width then.
    private var dragColumn: Int?
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    init(model: AppModel, table: NSTableView) {
        self.model = model
        self.table = table
        super.init()
        table.window?.acceptsMouseMovedEvents = true
        installEventMonitor()
        if Self.diagnose {
            print("[resize] controller installed; window=\(table.window != nil), "
                + "columns=\(table.numberOfColumns)")
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func installEventMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    /// Show the resize cursor, deferred to the end of the runloop turn.
    ///
    /// A local event monitor runs *before* the event is dispatched to the header,
    /// so anything the header's own cursor management does afterwards (it keeps
    /// resetting to the arrow as SwiftUI redraws the header, wiping its resize
    /// cursor rect) would overwrite an immediate `set()`. Setting it last, on the
    /// next turn, is what makes it hold — otherwise it flickers on every move.
    private func showResizeCursor() {
        DispatchQueue.main.async { NSCursor.resizeLeftRight.set() }
    }

    /// The column whose right edge is within the catch zone of header point `x`,
    /// or nil. Only the resizable columns count.
    private func dividerColumn(atHeaderX x: CGFloat, header: NSTableHeaderView) -> Int? {
        guard let table else { return nil }
        for col in Self.resizableColumns where col < table.numberOfColumns {
            if abs(x - header.headerRect(ofColumn: col).maxX) <= Self.slop { return col }
        }
        return nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // A live drag: while the button is held, only dragged/up events arrive,
        // so route just those to it. ANY other event type means the drag already
        // ended without us seeing the up — released while the app was hung, or
        // outside our window — so end it and handle the event normally. This is
        // what keeps a stuck drag from swallowing later clicks (which had
        // frozen mailbox switching until the next mouse-up cleared it).
        if dragColumn != nil {
            switch event.type {
            case .leftMouseDragged, .leftMouseUp:
                return serviceActiveDrag(event)
            default:
                dragColumn = nil
            }
        }

        guard let table, let header = table.headerView, let window = table.window,
              event.window === window else { return event }

        let overHeader = window.contentView?.hitTest(event.locationInWindow)
            .map { $0 === header || $0.isDescendant(of: header) } ?? false

        switch event.type {
        case .mouseMoved:
            guard overHeader else { return event }
            let x = header.convert(event.locationInWindow, from: nil).x
            if dividerColumn(atHeaderX: x, header: header) != nil {
                showResizeCursor()
            }
            return event

        case .leftMouseDown:
            let x = header.convert(event.locationInWindow, from: nil).x
            let col = dividerColumn(atHeaderX: x, header: header)
            if Self.diagnose {
                let m1 = 1 < table.numberOfColumns ? header.headerRect(ofColumn: 1).maxX : -1
                let m2 = 2 < table.numberOfColumns ? header.headerRect(ofColumn: 2).maxX : -1
                print("[resize] DOWN overHeader=\(overHeader) x=\(Int(x)) "
                    + "whoMaxX=\(Int(m1)) dateMaxX=\(Int(m2)) matched=\(col.map(String.init) ?? "nil")")
            }
            guard overHeader, let col else { return event }
            dragColumn = col
            dragStartX = x
            // The column's *actual* current width, not the model's — they can
            // differ (SwiftUI lays the resizable column out itself), and starting
            // from the model value snaps the column on the first drag frame.
            dragStartWidth = table.tableColumns[col].width
            showResizeCursor()
            return nil          // consumed: don't sort, don't let AppKit resize

        default:
            return event
        }
    }

    /// Handle events once a drag has begun, wherever the pointer goes.
    private func serviceActiveDrag(_ event: NSEvent) -> NSEvent? {
        guard let table, let header = table.headerView, let col = dragColumn else {
            dragColumn = nil
            return event
        }
        let x = header.convert(event.locationInWindow, from: nil).x
        let width = dragStartWidth + (x - dragStartX)

        switch event.type {
        case .leftMouseDragged:
            apply(width: width, toColumn: col, table: table)
            showResizeCursor()
            return nil
        case .leftMouseUp:
            apply(width: width, toColumn: col, table: table)   // also persists via the model
            dragColumn = nil
            return nil
        default:
            return nil          // swallow stray events during a drag
        }
    }

    /// Set the dragged column's width directly on the NSTableColumn, clamped to
    /// its minimum and so Subject keeps at least its floor (a column can't be
    /// dragged so wide it hides the last one). SwiftUI mirrors this into its
    /// content because the column is resizable.
    @discardableResult
    private func apply(width: CGFloat, toColumn col: Int, table: NSTableView) -> CGFloat {
        let minW = (col == 1) ? MessageColumnWidths.whoMin : MessageColumnWidths.dateMin
        // The most this column may take: what's left after the others and
        // Subject's floor.
        let others = table.tableColumns.enumerated().reduce(CGFloat.zero) { sum, pair in
            (pair.offset == col || pair.offset == 3) ? sum : sum + pair.element.width
        }
        let spacing = table.intercellSpacing.width * CGFloat(max(0, table.numberOfColumns - 1))
        let ceiling = max(minW,
                          table.bounds.width - others - spacing - MessageColumnWidths.subjectMin)
        let clamped = min(max(minW, width), ceiling)
        table.tableColumns[col].width = clamped
        // Keep the model (the column's `ideal`) in step, so a re-render — which a
        // big mailbox fires constantly while still enriching — re-applies the
        // *same* width instead of snapping the column back to its launch value.
        // This is what makes the drag hold on a large mailbox, and it persists
        // the width for next launch as a side effect.
        if col == 1 { model.setWhoColumnWidth(clamped) } else { model.setDateColumnWidth(clamped) }
        return clamped
    }
}

/// Installs `MessageColumnResizeController` on the message table, rebuilding it
/// when the `Table` (and its `NSTableView`) is remade.
struct MessageColumnResizeInstaller: NSViewRepresentable {
    @ObservedObject var model: AppModel

    final class Coordinator {
        weak var table: NSTableView?
        var controller: MessageColumnResizeController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        let model = self.model
        DispatchQueue.main.async {
            install(near: nsView, coordinator: coordinator, model: model, attemptsLeft: 20)
        }
    }

    @MainActor
    private func install(near view: NSView, coordinator: Coordinator,
                         model: AppModel, attemptsLeft: Int) {
        if let known = coordinator.table, known.window != nil, coordinator.controller != nil {
            coordinator.controller?.model = model
            return
        }
        guard let table = MessageTableFinder.table(near: view) else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    install(near: view, coordinator: coordinator, model: model,
                            attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }
        if coordinator.table !== table || coordinator.controller == nil {
            coordinator.table = table
            coordinator.controller = MessageColumnResizeController(model: model, table: table)
        }
        coordinator.controller?.model = model
    }
}

/// Keeps the message list's scroll position in sync with `AppModel`: records
/// where the user scrolled to, and restores it when a mailbox is listed.
///
/// AppKit again, for the same reason as the header icons — SwiftUI's `Table` on
/// macOS 13 offers no way to read or set a scroll offset. Working through the
/// enclosing `NSScrollView` also means the position is expressed as *the topmost
/// visible row*, which survives the window being resized; a raw pixel offset
/// wouldn't.
struct TableScrollStateSyncer: NSViewRepresentable {
    @ObservedObject var model: AppModel

    /// Scroll the message list one row per wheel notch, in the system's own
    /// direction.
    enum Scrolling {
        /// Flip the direction the wheel moves the list. False follows the
        /// system's scroll direction, which is what Stephen wants; set true to
        /// reverse it.
        ///
        /// In a flipped clip view AppKit's own handling is `origin.y -=
        /// scrollingDeltaY`, so reproducing the system direction means stepping
        /// the row index *down* by the delta; `inverted` steps it up instead.
        static let inverted = false

        /// Points of precise (trackpad) scrolling worth one row step. Anchoring
        /// to the row height keeps a swipe covering the distance it normally
        /// would, just snapped to rows.
        static func pointsPerRowStep(rowHeight: CGFloat) -> CGFloat { max(rowHeight, 1) }

        /// The row at the top of the visible *content* area.
        ///
        /// Deliberately not `table.rows(in: table.visibleRect).location`, which
        /// is what this used to be and what broke the wheel.
        ///
        /// The clip view carries a 28 pt top content inset — the band the column
        /// header sits over. That band is part of the clip view's bounds, so it
        /// is part of `visibleRect` too, and the row hidden underneath the header
        /// still counts as visible. Reading the top row that way while *writing*
        /// the new position with the inset subtracted (see `originY`) meant the
        /// two disagreed by 28 pt — a little over one row — so every notch
        /// computed a target at or behind where the list already was:
        ///
        ///     In (134 rows)     rows 0 and 1 map to origins −23 and 2, and the
        ///                       old `max(0, …)` clamp turned −23 into 0. Two
        ///                       reachable positions two pixels apart, with
        ///                       `rows(in:)` reporting row 0 at both — so the
        ///                       list jittered and never moved.
        ///     CUSTOMERS (3155)  at origin 5288 the header covered row 218 while
        ///                       `rows(in:)` still called it the top row, so a
        ///                       step "down" to 219 resolved to origin 5265 —
        ///                       above where the list already was. Both
        ///                       directions scrolled toward the top.
        ///
        /// **Do not reach for `row(at:)` here.** It is the obvious API for "which
        /// row is at this point" and it does not work in this table: the clip
        /// view is wider than the table (1439 vs 1127 pt), so
        /// `clipView.bounds.minX` is −312 and any probe point built from it is
        /// outside the table horizontally. `row(at:)` rejects that and returns −1
        /// for *every* row, whatever the y, which sends the caller to its
        /// fallback on every call and pins the list to a single row. That was a
        /// real bug here, not a hypothetical — it is what the second attempt at
        /// this did.
        ///
        /// So the range comes from `rows(in:)` instead, over a rect built from
        /// the clip origin with the header band taken off the top.
        ///
        /// Two deliberate details in that rect, both removing a dependency this
        /// would otherwise rest on:
        ///
        /// - The y comes from `clipView.bounds`, not from `table.visibleRect`.
        ///   `visibleRect` is intersected with the table's own bounds, so at the
        ///   legal top origin (−28 … −23) it reports `minY` 0 and the probe lands
        ///   28 pt down — inside row 0 *only* because row 0 happens to run to
        ///   y=30. Two points of margin is not something to rely on; if SwiftUI
        ///   ever drops the 5 pt leading pad, that spelling would report row 1
        ///   while row 0 was plainly on screen.
        /// - The half-point offset puts the probe inside the row rather than on
        ///   its edge. `rows(in:)` excludes a zero-area intersection at the max
        ///   edge, so an exactly-aligned origin already resolves to the row below
        ///   — but if it didn't, `topVisibleRow` and `originY` would stop being
        ///   inverses and a down-notch would compute the position it is already
        ///   at. That is the classic stick, and half a point rules it out for
        ///   free.
        ///
        /// - Returns: -1 when there is no top row to report — the table has no
        ///   rows yet, or the clip is still parked where a previous, longer
        ///   mailbox left it and the rect intersects nothing. Callers must treat
        ///   that as "don't touch anything"; recording it would overwrite a good
        ///   remembered position.
        static func topVisibleRow(table: NSTableView, clipView: NSClipView) -> Int {
            let visible = visibleRows(table: table, clipView: clipView)
            guard visible.length > 0 else { return -1 }
            return visible.location
        }

        /// Every row intersecting the visible content area, or a zero-length
        /// range when there are none.
        ///
        /// This is `topVisibleRow`'s rect, factored out unchanged — every detail
        /// of it is load-bearing and the reasoning is in that method's comment,
        /// which is the one to read before touching any of this. Split out
        /// because the *end* of the range answers a second question that
        /// `topVisibleRow` computed and discarded: whether the last row is on
        /// screen, which is what "stick to the bottom" is decided by.
        static func visibleRows(table: NSTableView, clipView: NSClipView) -> NSRange {
            let hidden = clipView.contentInsets.top
            let top = table.convert(NSPoint(x: 0, y: clipView.bounds.minY + hidden),
                                    from: clipView).y
            let height = clipView.bounds.height - hidden - clipView.contentInsets.bottom
            // The table's own x, so this doesn't lean on `rows(in:)` tolerating
            // the clip's negative one (it does, but there's no reason to depend
            // on it).
            let content = NSRect(x: table.bounds.minX, y: top + 0.5,
                                 width: max(table.bounds.width, 1),
                                 height: max(height, 1))
            let visible = table.rows(in: content)
            guard visible.length > 0, visible.location >= 0 else {
                return NSRange(location: 0, length: 0)
            }
            return visible
        }

        /// Whether the list has been **scrolled to its end** — not merely whether
        /// its last row happens to be on screen.
        ///
        /// The distinction is the whole correctness of "stick to the bottom".
        /// A mailbox shorter than the pane shows its last row at every scroll
        /// position, because it has only one; calling that "at the bottom" would
        /// record the flag for practically every small mailbox in the tree, and
        /// then the first delivery that pushed one past a screenful would scroll
        /// it to its end. Under a newest-first sort that means scrolling *away*
        /// from the mail that just arrived — the exact opposite of the point.
        /// Hence `visible.location > 0`: the list is at its end only if it could
        /// have been somewhere else.
        ///
        /// The obvious cost — a list parked at the bottom of a small window
        /// losing the flag once the window is grown until everything fits — does
        /// **not** apply, because a resize doesn't reach the recorder at all
        /// (see the observers in `attach`). The flag survives the growing, and
        /// shrinking back re-pins. Recording only ever happens on a scroll.
        ///
        /// No tolerance at the other end either — one row short of the end is
        /// not the end. A fuzzy test would make the list creep: a delivery would
        /// scroll you the rest of the way down, and being "near enough" after
        /// that, the next one would too, walking a position you chose
        /// deliberately to the end one message at a time.
        ///
        /// `>=` rather than `==` because `rows(in:)` can report a range running
        /// one past the last row when the document is taller than its rows (the
        /// trailing pad, or SwiftUI still refining row-height estimates).
        /// Prints what the recorder saw, per bounds change: the visible range,
        /// the row count, the resulting flag and the clip origin.
        ///
        /// Off, intact, in the manner of `diagnose` and `diagnoseRestore` beside
        /// it. The two questions it exists to settle without argument are "was
        /// the list recorded as being at its end when I left it" and "did the
        /// reveal land and hold" — both of which turn on geometry that is still
        /// settling for several turns after a listing lands, and neither of
        /// which can be reasoned out from the code.
        static let diagnoseBottom = false

        /// Which geometry notification arrived, with the size and origin it
        /// carried and whether we called it a resize.
        ///
        /// Off, intact. This one settles a question the documentation doesn't:
        /// AppKit posts bounds-changed and frame-changed for a clip view for
        /// different reasons and in an order it doesn't specify, and a resize can
        /// produce one or both. Everything about the pin's dedupe rests on that
        /// behaviour, and one drag with this on records it for good instead of
        /// leaving the next reader to reason it out.
        static func diagnoseGeometry(_ note: Notification, clipView: NSClipView,
                                     resized: Bool) {
            guard diagnoseGeometryOn else { return }
            let name = note.name == NSView.frameDidChangeNotification ? "frame" : "bounds"
            print("geom diag: \(name)  frame \(clipView.frame.size)"
                  + "  originY \(clipView.bounds.origin.y)  resized \(resized)")
        }
        static let diagnoseGeometryOn = false

        static func lastRowVisible(_ visible: NSRange, rowCount: Int) -> Bool {
            guard visible.length > 0, rowCount > 0, visible.location > 0 else { return false }
            return visible.location + visible.length >= rowCount
        }

        /// The clip origin that puts `row` flush at the top of the visible
        /// content area, clamped where a normal scroll view would stop.
        ///
        /// The floor is `-contentInsets.top`, **not** zero. The inset band is
        /// inside the clip view's bounds, so an origin of 0 already has the first
        /// row tucked up under the header; clamping there made the true top
        /// unreachable, which is half of the `In` symptom above.
        ///
        /// The one place this geometry is expressed. The wheel and the
        /// remembered-position restore both come through here, so they cannot
        /// drift apart the way the read and the write just did.
        static func originY(forTopRow row: Int, table: NSTableView,
                            clipView: NSClipView, document: NSView) -> CGFloat {
            clampOriginY(unclampedTopOriginY(forRow: row, table: table,
                                             clipView: clipView, document: document),
                         clipView: clipView, document: document)
        }

        /// Where the clip view would have to sit to put `row` at the top, with no
        /// clamping.
        ///
        /// Split out because a *centred* origin is this value less half a
        /// viewport, and the subtraction has to happen before the clamp: taking
        /// half a viewport off an origin that has already been pinned to the
        /// bottom of the document scrolls the row clean out of sight — which is
        /// what the last screenful of every mailbox would have done.
        private static func unclampedTopOriginY(forRow row: Int, table: NSTableView,
                                                clipView: NSClipView,
                                                document: NSView) -> CGFloat {
            // Into the clip view's own bounds space rather than assuming the
            // document sits at its origin. `topVisibleRow` converts clip → table
            // directly, so without this the two would be exact inverses only
            // while `document.frame.origin` happens to be zero — which is true
            // today and is precisely the kind of assumption this pair must not
            // rest on, given they exist because a read and a write drifted apart.
            let target = table.convert(table.rect(ofRow: row), to: document)
            let wanted = clipView.convert(target.origin, from: document).y
            return wanted - clipView.contentInsets.top
        }

        /// The legal range of clip-view origins. One implementation, because two
        /// copies of this arithmetic is how a read and a write drift apart.
        private static func clampOriginY(_ y: CGFloat, clipView: NSClipView,
                                         document: NSView) -> CGFloat {
            let minY = -clipView.contentInsets.top
            let maxY = max(minY, document.frame.maxY + clipView.contentInsets.bottom
                                    - clipView.bounds.height)
            return min(max(minY, y), maxY)
        }

        /// The clip-view origin that puts a row as near the middle of the visible
        /// area as the document allows.
        ///
        /// Built on `originY(forTopRow:)` rather than beside it, for the reason
        /// that helper's own comment gives: a read and a write of this geometry
        /// drifted apart once already, and the 28 pt inset under the column
        /// header is exactly where that happens. Asking for "the origin that puts
        /// row R at the top, less half a viewport" keeps one implementation of
        /// the awkward part, and inherits its clamping — which is what makes a
        /// row in the first or last screenful settle at the edge instead of
        /// leaving blank space, i.e. "as close to centred as possible".
        static func originY(forCenteredRow row: Int, table: NSTableView,
                            clipView: NSClipView, document: NSView) -> CGFloat {
            let top = unclampedTopOriginY(forRow: row, table: table,
                                          clipView: clipView, document: document)
            let rowHeight = table.rect(ofRow: row).height
            // Visible area, not bounds: the inset band is covered by the header.
            // Computed the same way `visibleRows` does, which is the consistency
            // that matters most here.
            let viewport = clipView.bounds.height
                - clipView.contentInsets.top - clipView.contentInsets.bottom
            let shift = max(0, (viewport - rowHeight) / 2)
            // Clamped once, at the end. A row in the first or last screenful
            // settles against the edge, which *is* "as close to centred as the
            // document allows".
            return clampOriginY(top - shift, clipView: clipView, document: document)
        }

        /// Scroll so `row` sits as near the middle as the document allows.
        static func center(row: Int, table: NSTableView) {
            guard let scrollView = table.enclosingScrollView,
                  let document = scrollView.documentView else {
                table.scrollRowToVisible(row)
                return
            }
            let clip = scrollView.contentView
            guard table.rect(ofRow: row).height > 0 else {
                table.scrollRowToVisible(row)
                return
            }
            let y = originY(forCenteredRow: row, table: table,
                            clipView: clip, document: document)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            // Without this the scroller thumb and the clip view disagree — the
            // list moves and the scrollbar doesn't.
            scrollView.reflectScrolledClipView(clip)
        }

        /// Whether the list is already where a centred reveal of `row` wants it.
        ///
        /// Compares clip origin against the target origin rather than measuring
        /// the row's distance from the geometric middle — the same idiom
        /// `verifyPendingScroll` uses, and for the same reason. A row in the
        /// first or last screenful can never *reach* the middle, so a distance
        /// test would report it permanently wrong and re-scroll forever while
        /// hiding the real drift this check exists to catch.
        static func isCentered(row: Int, table: NSTableView) -> Bool {
            guard let scrollView = table.enclosingScrollView,
                  let document = scrollView.documentView,
                  table.rect(ofRow: row).height > 0 else { return true }
            let clip = scrollView.contentView
            let wanted = originY(forCenteredRow: row, table: table,
                                 clipView: clip, document: document)
            return abs(clip.bounds.origin.y - wanted) <= 0.5
        }

        /// One console block per wheel event, reporting every number the monitor
        /// computes and where the list actually ended up. Off; flip to true.
        ///
        /// Kept because it earned its place. The wheel misbehaved *differently
        /// per mailbox* — a two-pixel jitter in a 134-row one, always-toward-the-
        /// top in a 3,155-row one — while the scrollbar and arrow keys were both
        /// fine. Nothing about that can be read off the screen: it looks the same
        /// whether `rows(in:)` reports the wrong row, `rect(ofRow:)` returns a
        /// degenerate rect, or the scroll is applied and then reverted.
        ///
        /// One run settled it, and not in favour of the obvious suspect.
        /// `rect(ofRow:)` was perfectly healthy (row 0 at y=5, row 1 at 30, row
        /// 133 at 3215) — the guess had been that SwiftUI's table subclass didn't
        /// implement it, since it already doesn't implement
        /// `rowView(atRow:makeIfNecessary:)`. The culprit was the line nobody was
        /// looking at, `clip.insets.top 28.0`: see `topVisibleRow`.
        ///
        /// Two things to note if this is ever turned on again. `rowHeight`
        /// reports 24 while the rects are 25 tall, so row offsets must come from
        /// `rect(ofRow:)` and never from arithmetic on `rowHeight`. And
        /// `document.frame.height` grows by a few points between consecutive
        /// events on a long list (76208 → 76228 → 76247…) as SwiftUI refines its
        /// row estimates — so treat any single height reading as approximate.
        static let diagnose = false

        /// Restore-path diagnostics: one line per apply / verify / confirm /
        /// clear in `applyPendingScroll` and `verifyPendingScroll`, with the
        /// clip origin, the computed target, the row count and the document
        /// height at that instant. Turn on if the removal veil ever again
        /// drops onto a list that then moves: the line whose `wantY` changes
        /// *after* a PASS names the geometry that was still settling, and the
        /// stage that cleared prematurely is the one to fix.
        static let diagnoseRestore = false
    }

    /// `@unchecked Sendable` because the notification block below is `@Sendable`
    /// and captures this. Every access — from the block (delivered on `.main`),
    /// from `updateNSView`, from the `@MainActor` helpers — is on the main
    /// thread; the compiler just can't see that through `addObserver`'s queue
    /// argument. AppKit's own classes don't need this only because they're
    /// `@MainActor`, which would make the block's synchronous reads illegal here.
    final class Coordinator: @unchecked Sendable {
        weak var table: NSTableView?
        var observer: NSObjectProtocol?
        /// Frame changes on the clip view. **Load-bearing, not insurance —
        /// don't "simplify" it away.**
        ///
        /// `NSViewBoundsDidChangeNotification` is posted when the bounds change
        /// *independently of the frame*; a frame-driven resize does not reliably
        /// post it. Dragging the list/preview divider shortens the clip view's
        /// frame without touching its origin, so the bounds observer alone hears
        /// nothing at all and the list silently stops following its end.
        ///
        /// It has its own handler, which only ever pins and never records. A
        /// frame change is by definition not a user scroll, so it has no
        /// business in the recorder — and letting it in meant a window widened
        /// by its right edge, or the sidebar being resized, cleared In's
        /// new-mail badge.
        var frameObserver: NSObjectProtocol?
        /// KVO pins that keep the forced row height in place against SwiftUI's
        /// resets — see `pinRowHeight`. Invalidated automatically when this
        /// coordinator (and so the array) deallocates, or replaced on re-attach.
        var rowHeightObservers: [NSKeyValueObservation] = []
        var scrollMonitor: Any?
        /// Leftover trackpad delta below one row's worth, carried to the next
        /// event so slow scrolling still advances instead of rounding to nothing
        /// each time. Reset when a gesture starts or reverses, so a leftover
        /// from one direction can't bias the next flick the other way.
        var scrollRemainder: CGFloat = 0
        /// Bumped per focus attempt, so overlapping attempts don't fight.
        var focusGeneration = 0
        /// The same, for reveal-after-sort attempts: `updateNSView` runs on any
        /// published change, so several chains can be in flight, and a stale one
        /// exhausting its attempts would clear a newer reveal.
        var revealGeneration = 0
        /// True while we're programmatically scrolling, so the bounds
        /// notification that results isn't recorded as a user scroll.
        var isRestoring = false
        /// The same idea for a *reveal*, but narrower: a reveal's resulting
        /// position is meant to be recorded (it moves the list the way the user
        /// would have), so this doesn't suppress recording. It suppresses only
        /// the new-mail badge dismissal, which must happen on real user input
        /// alone — see the observer in `attach`. Cleared a turn after the scroll,
        /// by which time the notification has been delivered.
        var isRevealing = false
        /// True from the moment a pin is *scheduled* until the notification its
        /// scroll produces has been delivered.
        ///
        /// Set synchronously in the notification handler, not inside the pin
        /// itself: the handler is what tests it, and a flag raised a turn later
        /// is not in force where it is read. It guards the *recorder*, which is
        /// the thing that would otherwise be fed two bad readings — the pin's own
        /// echo, and the twin notification of a resize that posted both frame and
        /// bounds. Either would record a mid-resize position and drop the very
        /// flag the pin is acting on.
        ///
        /// Cleared unconditionally by whoever set it, never inside the pin's
        /// guards: a pin that declines (not parked at the end, a listing in
        /// flight) must still lower it, or the recorder is dead for the session.
        var isPinningBottom = false
        /// Bumped per pin, so the confirmation passes of a drag's ~120 frames
        /// don't all fire. Only the newest survives.
        var pinGeneration = 0
        /// The clip view's height at the last notification, so a *resize* can be
        /// told from a *scroll*. Both arrive as bounds changes and they need
        /// opposite treatment: a scroll is the user choosing a position and is
        /// recorded, a resize is the viewport changing under a position the user
        /// already chose and must not be.
        var lastClipHeight: CGFloat = 0
        /// Bumped per restore attempt. `updateNSView` runs on *any* model
        /// change, so several restore chains can be in flight at once; only the
        /// newest may touch `isRestoring`, or an older one finishing would
        /// re-arm recording mid-restore.
        var restoreGeneration = 0

        deinit {
            if let observer = observer { NotificationCenter.default.removeObserver(observer) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            if let scrollMonitor = scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            attach(near: nsView, coordinator: coordinator, attemptsLeft: 5)
            // Backstop only. The row height is really held by the KVO pins set
            // up in `attach` (see `pinRowHeight`), which catch SwiftUI's reset
            // synchronously; this re-enforce is here in case those ever miss.
            if let table = coordinator.table { Self.enforceRowHeight(table) }
            applyPendingScroll(coordinator: coordinator, attemptsLeft: 5)
            // 15, not 5. The budget was set when a reveal only ever followed a
            // re-sort, where the rows already exist and one retry is generous.
            // It now also carries "a 22,515-row mailbox has just been handed to
            // `Table` and hasn't realized its rows yet" — and since a reveal
            // that runs out of attempts silently doesn't happen, the failure is
            // invisible. 15 × 0.2s = 3s, still bounded.
            applyPendingReveal(coordinator: coordinator, attemptsLeft: 15)
            applyPendingFocus(coordinator: coordinator, attemptsLeft: 5)
        }
    }

    /// Force the row height SwiftUI's `Table` won't otherwise let us set.
    ///
    /// **Two things, not one.** SwiftUI runs the table with *automatic* row
    /// heights, so the `rowHeight` property is only an estimate and each row
    /// self-sizes to its content plus SwiftUI's cell padding (~25 pt) — which is
    /// why setting `rowHeight` alone changed the property but not the rows.
    /// Turning automatic heights off makes `rowHeight` authoritative, and then 20
    /// is what every row gets. The content (17 pt glyph slot, ~15 pt text) fits
    /// inside 20 with room, so nothing clips.
    ///
    /// Keep the forced row height pinned against SwiftUI, without a flash.
    ///
    /// SwiftUI re-enables automatic row heights on its updates (a selection
    /// change included), and correcting that from `updateNSView` — async *or*
    /// sync — let a padded 24 pt frame paint before the fix landed, the visible
    /// flicker. KVO catches the reset **synchronously, inside SwiftUI's own
    /// setter**, so the table never lays out at the wrong height and nothing
    /// wrong ever reaches the screen.
    ///
    /// Both properties are pinned: `usesAutomaticRowHeights` back to false (which
    /// makes `rowHeight` authoritative) and `rowHeight` back to our value.
    /// Reentrancy is bounded — assigning re-fires the observer, but the guard
    /// then sees the value already correct and stops after one hop.
    static func pinRowHeight(_ table: NSTableView) -> [NSKeyValueObservation] {
        enforceRowHeight(table)
        return [
            table.observe(\.usesAutomaticRowHeights, options: [.new]) { t, _ in
                if t.usesAutomaticRowHeights { t.usesAutomaticRowHeights = false }
            },
            table.observe(\.rowHeight, options: [.new]) { t, _ in
                if t.rowHeight != MessageRowMetrics.rowHeight {
                    t.rowHeight = MessageRowMetrics.rowHeight
                }
            },
        ]
    }

    /// Guarded so it only assigns when values differ: each assignment triggers a
    /// relayout, and doing that every pass would be visible. If SwiftUI restores
    /// the defaults on a re-list, the next `updateNSView` puts these back.
    static func enforceRowHeight(_ table: NSTableView) {
        if table.usesAutomaticRowHeights { table.usesAutomaticRowHeights = false }
        if table.rowHeight != MessageRowMetrics.rowHeight {
            table.rowHeight = MessageRowMetrics.rowHeight
        }
    }

    /// Scrolls just far enough to show a row, if the model is asking for one.
    ///
    /// Distinct from `applyPendingScroll` in both effect and bookkeeping: that
    /// one restores a remembered *top* row and suppresses the scroll recorder
    /// while it does, so the restore can't overwrite what it is restoring. This
    /// one is a reveal after a re-sort — it moves the list the way the user would
    /// have, so the resulting position is left to be recorded normally.
    @MainActor
    private func applyPendingReveal(coordinator: Coordinator, attemptsLeft: Int) {
        guard let row = model.pendingRevealRow else { return }
        // Never during a restore. `applyPendingScroll` runs first in this same
        // turn and only clears `isRestoring` a turn later, so scrolling now would
        // both override the restore and have its own bounds notification
        // swallowed by the recorder — leaving the remembered position describing
        // somewhere the list isn't. Waiting costs nothing: clearing the pending
        // scroll republishes, which brings us straight back here.
        guard model.pendingScrollTopRow == nil, !coordinator.isRestoring else { return }

        coordinator.revealGeneration += 1
        let generation = coordinator.revealGeneration

        guard let table = coordinator.table, table.numberOfRows > row else {
            // The reorder has been published but the table hasn't caught up.
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard coordinator.revealGeneration == generation else { return }
                    applyPendingReveal(coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
                }
            } else {
                model.clearPendingReveal()
            }
            return
        }

        // One turn later, not now: the row *count* doesn't change across a
        // re-sort, so the readiness check above passes even when SwiftUI hasn't
        // committed the reordered rows yet, and scrolling here would reveal the
        // row that used to be at this position.
        DispatchQueue.main.async {
            guard coordinator.revealGeneration == generation,
                  let table = coordinator.table, table.numberOfRows > row else { return }
            coordinator.isRevealing = true
            let centered = model.pendingRevealCentered
            if centered {
                Scrolling.center(row: row, table: table)
            } else {
                table.scrollRowToVisible(row)
            }
            model.clearPendingReveal()

            // One confirmation pass, for the reason `verifyPendingScroll` has a
            // whole state machine: SwiftUI keeps refining the table's row-height
            // estimates for several turns after a listing lands, so the document
            // grows *under* a scroll that was correct when it was issued. On a
            // long mailbox that leaves a reveal of the last row a row or two
            // short of the end — the newest message half under the bottom edge,
            // which is exactly the thing this feature is judged on. One re-scroll
            // is enough; this isn't chasing a moving target, just letting the
            // first estimate settle.
            //
            // Only re-scrolls when the row is genuinely not fully in view, so a
            // reveal that landed correctly costs one geometry read and nothing
            // else. `isRevealing` is cleared here, after the notification from
            // the scroll above has been delivered.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                defer { coordinator.isRevealing = false }
                guard coordinator.revealGeneration == generation,
                      let table = coordinator.table, table.numberOfRows > row,
                      let clip = table.enclosingScrollView?.contentView else { return }
                let visible = Scrolling.visibleRows(table: table, clipView: clip)
                let shown = visible.length > 0
                    && row >= visible.location && row < visible.location + visible.length
                if centered {
                    // A centred reveal is judged on being centred, not merely on
                    // being visible: the row-height estimates that shift a plain
                    // reveal by a row or two shift a centring by the same amount,
                    // and there the error is plainly visible against the middle
                    // of the pane.
                    if !Scrolling.isCentered(row: row, table: table) {
                        Scrolling.center(row: row, table: table)
                    }
                } else if !shown {
                    table.scrollRowToVisible(row)
                }
            }
        }
    }

    /// Put the list back at its end after the viewport changed size, if that is
    /// where the user left it.
    ///
    /// The case this exists for is dragging the list/preview divider: the clip
    /// view gets shorter while its origin stays put, so the last row slides out
    /// below the new bottom edge and a list that was at its end no longer is. A
    /// window resize is the same event. Any mailbox, not just In.
    ///
    /// Guarded on the pending channels for the usual reason — a restore or a
    /// reveal that hasn't landed yet is the position the list is *going* to be
    /// at, and pinning now would fight it and then be undone.
    @MainActor
    private func pinToBottom(coordinator: Coordinator) {
        // `isListing` and `isRevealing` are the two windows where the rows on
        // screen aren't the ones this decision is about. During a mailbox switch
        // the table still holds the *previous* mailbox's rows while
        // `selectedMailboxWasAtBottom` already answers for the new one — and the
        // summary bar appearing and disappearing changes the clip height on
        // every switch, so the resize path really does fire there. `rememberScroll`
        // defends against the same class of thing with `listedMailboxID`.
        //
        // `isRevealing` covers the 0.15s in which `applyPendingReveal` has
        // cleared `pendingRevealRow` but its confirmation pass hasn't run: a
        // resize landing there would pin to the bottom over a reveal of the
        // *selected* row, and the confirmation would then yank it back. A
        // visible jump.
        guard model.selectedMailboxWasAtBottom, !model.isListing,
              !coordinator.isRevealing,
              model.pendingScrollTopRow == nil, model.pendingRevealRow == nil,
              let table = coordinator.table, table.numberOfRows > 0 else { return }
        let row = table.numberOfRows - 1
        table.scrollRowToVisible(row)

        // One confirmation, for the reason recorded twice already in this file:
        // SwiftUI keeps refining row-height estimates for several turns, so the
        // document grows under a scroll that was right when it was issued. Mid-
        // drag that self-corrects — the next frame re-pins — but the *last*
        // frame of a drag has no successor, so a short landing there is what
        // sticks: you let go and the newest message sits half under the edge.
        //
        // Generation-guarded, and that matters more here than for the reveal: a
        // two-second drag would otherwise queue ~120 of these.
        coordinator.pinGeneration += 1
        let generation = coordinator.pinGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard coordinator.pinGeneration == generation,
                  let table = coordinator.table, table.numberOfRows > 0,
                  let clip = table.enclosingScrollView?.contentView else { return }
            let visible = Scrolling.visibleRows(table: table, clipView: clip)
            if !Scrolling.lastRowVisible(visible, rowCount: table.numberOfRows) {
                table.scrollRowToVisible(table.numberOfRows - 1)
            }
        }
    }

    /// Starts listening for scrolls, once.
    ///
    /// `@MainActor` because it touches `model`, which is main-actor isolated —
    /// a plain method on a representable is *nonisolated*; only the protocol
    /// witnesses inherit isolation.
    @MainActor
    private func attach(near view: NSView, coordinator: Coordinator, attemptsLeft: Int) {
        // The camera is (re)installed on every pass, BEFORE the already-
        // attached early-return: SwiftUI can replace the representable's
        // NSView at will, and a camera installed once would keep a weak
        // reference to the dead anchor and photograph nothing ever after.
        installCamera(anchor: view)

        guard coordinator.table == nil else { return }
        guard let table = MessageTableFinder.table(near: view),
              let clipView = table.enclosingScrollView?.contentView else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    attach(near: view, coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }

        coordinator.table = table
        coordinator.rowHeightObservers = Self.pinRowHeight(table)
        RowDensityProbe.reportOnce(table)
        clipView.postsBoundsChangedNotifications = true
        installScrollMonitor(coordinator: coordinator)

        // `coordinator` is captured weakly: strongly would be a cycle —
        // coordinator owns the token, the token owns the block — and the
        // observer would then never be removed, so each teardown of the Table
        // (which happens whenever a mailbox lists empty) would leave a live
        // observer behind and register another. `self` *is* captured now, by
        // value, because the pin needs `model`; that's a struct copy, not a
        // retain, so it doesn't reopen the cycle.
        let model = self.model
        coordinator.lastClipHeight = clipView.bounds.height
        clipView.postsFrameChangedNotifications = true

        // A frame change is a resize and nothing else, so this handler only ever
        // pins — it never records. See `Coordinator.frameObserver` for why a
        // frame change must not reach the recorder.
        // **Not `@Sendable`** — and passed through `MainQueueHandler` at the
        // registration below rather than converted implicitly.
        //
        // The SDK does import `addObserver(forName:object:queue:using:)` with a
        // `@Sendable` block, and there is no spelling of this handler that
        // satisfies it cleanly on a macOS 13 target. Annotating it `@Sendable`
        // turns every AppKit read in here into "main actor-isolated property …
        // from a Sendable closure" (eight warnings); leaving it plain moves the
        // complaint to the conversion (two). Hopping to the main actor to do the
        // reads would silence both and change when the geometry is sampled,
        // which is not a trade worth making in code this carefully timed.
        //
        // So the requirement is satisfied honestly at the boundary instead: the
        // block genuinely only ever runs on the main thread, because it is
        // registered with `queue: .main`, and `MainQueueHandler` is where that
        // promise is written down.
        let onFrameChange: (Notification) -> Void = {
            [weak clipView, weak coordinator] note in
            guard let clipView, let coordinator, !coordinator.isRestoring else { return }
            let height = clipView.bounds.height
            let resized = abs(height - coordinator.lastClipHeight) > 0.5
            coordinator.lastClipHeight = height
            Scrolling.diagnoseGeometry(note, clipView: clipView, resized: resized)
            guard resized else { return }
            schedulePin(coordinator: coordinator)
        }

        // Not `@Sendable`, and likewise wrapped at registration — see
        // `onFrameChange` above.
        let onBoundsChange: (Notification) -> Void = {
            [weak table, weak clipView, weak coordinator] note in
            guard let table, let clipView, let coordinator,
                  !coordinator.isRestoring else { return }

            // A resize, not a scroll? Then the user didn't move the list — the
            // viewport moved around it — and a list parked at its end should
            // still be at its end afterwards. Dragging the list/preview divider
            // up shortens the clip view, so the last row slides out below the
            // new bottom edge and the list appears to drift away from where it
            // was left. Re-pin instead, and don't record: the position reported
            // mid-resize is an artefact of the resize, and recording it would
            // drop the very flag that says to re-pin. Any mailbox; a window
            // resize is the same event from here.
            //
            // A resize never *confers* bottom-ness either — this path returns
            // without recording, so growing the window until the last row comes
            // into view doesn't mark the list as parked at its end. Only
            // scrolling there does. Bottom-ness records a choice.
            let height = clipView.bounds.height
            let resized = abs(height - coordinator.lastClipHeight) > 0.5
            coordinator.lastClipHeight = height
            Scrolling.diagnoseGeometry(note, clipView: clipView, resized: resized)
            if resized, table.numberOfRows > 0 {
                schedulePin(coordinator: coordinator)
                return
            }
            // Our own echo, or the twin of a resize that posted frame *and*
            // bounds — same height as the one just handled, so `resized` is
            // false and it would otherwise fall through to the recorder carrying
            // a reading taken before the pin ran, dropping the flag.
            if coordinator.isPinningBottom { return }
            // The same inset-aware reading the wheel uses, so the position that
            // gets remembered is the one the user sees at the top rather than
            // the row hidden under the header — otherwise every restore came
            // back a row higher than where they left off.
            // One geometry read, two answers — the top row to remember and
            // whether the end of the list is on screen. Read together so they
            // can't disagree: computing them from two separate probes would let
            // a bounds change land between them and record a top row from one
            // scroll position with the bottom-ness of another.
            let visible = Scrolling.visibleRows(table: table, clipView: clipView)
            let top = visible.length > 0 ? visible.location : -1
            let atBottom = Scrolling.lastRowVisible(visible, rowCount: table.numberOfRows)
            if Scrolling.diagnoseBottom {
                print("bottom diag: visible \(visible.location)+\(visible.length)"
                      + " of \(table.numberOfRows)  atBottom \(atBottom)"
                      + "  clipY \(clipView.bounds.origin.y)")
            }
            // -1 covers the mid-reload case as well as an empty table: the clip
            // can still be parked at an origin inherited from the mailbox being
            // left — a deep position in a 3,155-row mailbox landing on a 134-row
            // one — and `topVisibleRow` reports the intersection is empty rather
            // than guessing. Recording a guess would persist a wrong position
            // for the mailbox just opened.
            guard top >= 0 else { return }
            // AppModel is @MainActor and this closure is not, so hop rather than
            // assume isolation (MainActor.assumeIsolated is macOS 14+).
            Task { @MainActor in
                // A restore that hasn't been applied yet is still authoritative;
                // the snap-to-top that follows a reload must not clobber it.
                //
                // `pendingRevealRow` for the same reason, which is newly load-
                // bearing: the stick-to-the-bottom path deliberately leaves
                // `pendingScrollTopRow` nil, and `isRestoring` is only set by
                // `applyPendingScroll`. So without this guard every bounds change
                // a freshly-published table emits before the reveal lands gets
                // recorded — `top 0, atBottom false` — which erases the very flag
                // the reveal is acting on. In the happy path the reveal follows a
                // beat later and re-records; in the unhappy one (attempts
                // exhausted, mailbox switched) a failed restore has destroyed the
                // remembered position.
                guard model.pendingScrollTopRow == nil, model.pendingRevealRow == nil else { return }
                // A badge clear used to live here, on the theory that scrolling In
                // counted as engaging with it. Removed with the rest of that
                // machinery: the In badge is now derived from whether In's newest
                // message is unread (see `AppModel.inboxNewestIsUnread`), so
                // scrolling past a message without reading it must *not* dismiss
                // it — that is precisely the case the new rule exists to keep lit.
                //
                // Kept as a note because the deleted line came with a hard-won
                // guard, `!coordinator.isRevealing`: a reveal clears
                // `pendingRevealRow` before its own bounds notification arrives,
                // so that one notification looks exactly like a user scroll. If
                // anything is ever hung off this notification again and must
                // distinguish a real user scroll, that is the trap.
                model.rememberScroll(topRow: top, atBottom: atBottom)
            }
        }
        let bounds = MainQueueHandler(onBoundsChange)
        let frame = MainQueueHandler(onFrameChange)
        coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { bounds.run($0) }
        coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clipView,
            queue: .main
        ) { frame.run($0) }
    }

    /// Schedule a pin, and hold the recorder off until its scroll has echoed.
    ///
    /// The flag goes up **here**, synchronously, because the notification
    /// handlers are what test it; raised inside `pinToBottom` — a turn later —
    /// it would never be in force where it is read. It comes down
    /// unconditionally, outside that method's guards, because a pin that
    /// declines still has to lower it or the recorder stays shut for good.
    /// `nonisolated` because the notification handlers that call it are not
    /// main-actor isolated. Nothing here needs to be: the flag lives on
    /// `Coordinator`, which is `@unchecked Sendable`, and the actual work hops
    /// to the main actor itself.
    nonisolated private func schedulePin(coordinator: Coordinator) {
        coordinator.isPinningBottom = true
        Task { @MainActor in
            pinToBottom(coordinator: coordinator)
            DispatchQueue.main.async { coordinator.isPinningBottom = false }
        }
    }

    /// The removal veil's camera (see `AppModel.removalVeilImage`):
    /// window-server capture of the *anchor* view's region — NOT the scroll
    /// view's, and NOT via `cacheDisplay`. Two dead ends are recorded here so
    /// nobody re-treads them (frame-stepped screen recording +
    /// /tmp/eudora-veil.png, 2026 jul 22):
    ///
    /// • The Table's internal NSScrollView is WIDER than the visible pane —
    ///   measured 1238 pt against a ~920 pt pane — because
    ///   NavigationSplitView extends the detail content under the sidebar.
    ///   Capturing `scrollView.bounds`, by any mechanism, therefore yields a
    ///   picture ~318 pt (one sidebar) wider than the overlay that displays
    ///   it, and top-leading alignment then shows alien pixels at the pane's
    ///   left with the list shoved right.
    ///
    /// • The anchor — the representable's own background NSView — is sized
    ///   by SwiftUI to exactly the Table's frame, which is exactly what the
    ///   veil overlay covers. Capturing *it* makes the capture and the
    ///   display agree by construction, whatever AppKit does with underlap.
    ///
    /// `CGWindowListCreateImage` (whole window by ID, cropped locally) copies
    /// the composited pixels the user is actually looking at — selection
    /// highlight included, which is what the veil wants to freeze — and
    /// capturing our own window needs no screen-recording permission. The
    /// crop uses only window-local math; a CG *global* rect was tried and is
    /// not trustworthy. Only the anchor is captured, weakly: holding `model`
    /// would cycle (model owns the closure), and a replaced anchor should
    /// yield nil — which is why `attach` reinstalls this on every pass.
    @MainActor
    private func installCamera(anchor view: NSView) {
        model.captureListSnapshot = { [weak view] in
            guard let anchor = view,
                  let window = anchor.window, window.windowNumber > 0 else {
                if Scrolling.diagnoseRestore { print("[restore] SNAPSHOT failed: no anchor/window") }
                return nil
            }
            let bounds = anchor.bounds
            guard bounds.width > 0, bounds.height > 0 else {
                if Scrolling.diagnoseRestore { print("[restore] SNAPSHOT failed: bounds \(bounds)") }
                return nil
            }
            let rectInWindow = anchor.convert(bounds, to: nil)
            guard let full = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                     CGWindowID(window.windowNumber),
                                                     [.boundsIgnoreFraming, .bestResolution]) else {
                if Scrolling.diagnoseRestore { print("[restore] SNAPSHOT failed: CG capture") }
                return nil
            }
            // Pixels per point, from the image actually returned rather than
            // an assumed screen scale. The captured image spans the window's
            // frame (shadow excluded by `boundsIgnoreFraming`); window-base
            // coordinates are y-up, CGImage rows are y-down, hence the flip.
            let frame = window.frame
            guard frame.width > 0, frame.height > 0 else { return nil }
            let scale = CGFloat(full.width) / frame.width
            let crop = CGRect(x: rectInWindow.minX * scale,
                              y: (frame.height - rectInWindow.maxY) * scale,
                              width: rectInWindow.width * scale,
                              height: rectInWindow.height * scale).integral
            guard let cg = full.cropping(to: crop) else {
                if Scrolling.diagnoseRestore { print("[restore] SNAPSHOT failed: crop \(crop)") }
                return nil
            }
            if Scrolling.diagnoseRestore {
                print("[restore] SNAPSHOT ok \(bounds.size) cg \(cg.width)x\(cg.height)"
                        + "  paneInWindow \(rectInWindow)  windowFrame \(frame)  scale \(scale)")
                // The exact bitmap the veil will show, openable in Preview.
                // It must start at the message list's first column — no
                // sidebar — and end at the pane's right edge.
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/eudora-veil.png"))
            }
            // Point size = the pane's, whatever the pixel scale, so the
            // picture overlays the live table 1:1.
            return NSImage(cgImage: cg, size: bounds.size)
        }
    }

    /// Takes over the wheel for the message list: one row per notch, reversed.
    ///
    /// A local event monitor rather than an `NSScrollView` subclass, because the
    /// scroll view belongs to SwiftUI and can't be substituted. Anything that
    /// isn't a vertical scroll over this table is passed straight through.
    @MainActor
    private func installScrollMonitor(coordinator: Coordinator) {
        guard coordinator.scrollMonitor == nil else { return }
        coordinator.scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak coordinator] event in
            guard let coordinator,
                  let table = coordinator.table,
                  let scrollView = table.enclosingScrollView,
                  event.window === scrollView.window else {
                Self.diagnoseBail("no live table / wrong window",
                                  table: coordinator?.table)
                return event
            }

            // Only claim events actually over this list — hit-testing rather
            // than a bounds check, so an overlay or popover in front of the
            // table keeps its own scrolling, and the preview pane and sidebar
            // are unaffected.
            guard let hit = scrollView.window?.contentView?.hitTest(event.locationInWindow),
                  hit === scrollView || hit.isDescendant(of: scrollView) else {
                Self.diagnoseBail("hit test missed the scroll view", table: table)
                return event
            }

            // Horizontal scrolling isn't ours; let the table handle its columns.
            if event.scrollingDeltaY == 0 {
                Self.diagnoseBail("deltaY == 0", table: table)
                return event
            }

            // Momentum ("glide" after the fingers lift) would send a long
            // uncontrolled run of row steps. Swallow it: this list steps in whole
            // rows under direct control only.
            guard event.momentumPhase == [] else {
                Self.diagnoseBail("momentum phase", table: table)
                return nil
            }

            let steps: CGFloat
            if event.hasPreciseScrollingDeltas {
                let unit = Scrolling.pointsPerRowStep(rowHeight: table.rowHeight
                                                        + table.intercellSpacing.height)
                if event.phase.contains(.began)
                    || (coordinator.scrollRemainder < 0) != (event.scrollingDeltaY < 0) {
                    coordinator.scrollRemainder = 0
                }
                coordinator.scrollRemainder += event.scrollingDeltaY
                steps = (coordinator.scrollRemainder / unit).rounded(.towardZero)
                coordinator.scrollRemainder -= steps * unit
            } else {
                // A wheel notch reports a line count the driver has already
                // accelerated — 1 when turned slowly, 3+ when spun. Ignore the
                // magnitude: a notch is a row.
                steps = event.scrollingDeltaY > 0 ? 1 : -1
            }
            guard steps != 0 else {
                Self.diagnoseBail("steps rounded to 0", table: table)
                return nil
            }

            let clipView = scrollView.contentView
            let document = scrollView.documentView ?? table

            // The row you can actually see, not the one under the header — see
            // `Scrolling.topVisibleRow`, which is where this went wrong.
            let currentTop = Scrolling.topVisibleRow(table: table, clipView: clipView)
            guard currentTop >= 0 else {
                Self.diagnoseBail("no rows", table: table)
                return nil
            }

            let direction: CGFloat = Scrolling.inverted ? 1 : -1
            let targetRow = min(max(currentTop + Int(steps * direction), 0),
                                max(table.numberOfRows - 1, 0))

            // Already showing that row. Consume the notch and do nothing, rather
            // than re-deriving the origin: at the very top the clip can sit a few
            // points above row 0's own origin (−28 vs −23), and recomputing would
            // nudge the list *down* by that difference — an up-notch visibly
            // moving the wrong way. Also spares a pointless scroller flash at
            // both ends of the list.
            guard targetRow != currentTop else { return nil }

            // NSClipView.scroll(to:) doesn't constrain, so `originY` stops where
            // a normal scroll view would: the first row clear of the header at
            // one end, the last row at the bottom at the other.
            let y = Scrolling.originY(forTopRow: targetRow, table: table,
                                      clipView: clipView, document: document)
            let before = clipView.bounds.origin.y
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clipView)
            scrollView.flashScrollers()     // consuming the event skips this
            Self.diagnoseScroll(event: event, table: table,
                                clipView: clipView, document: document,
                                steps: steps, currentTop: currentTop,
                                targetRow: targetRow, y: y, before: before)
            return nil                      // consumed
        }
    }

    // MARK: wheel diagnostics

    private static func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
    private static func f(_ r: NSRect) -> String {
        "(\(f(r.minX)),\(f(r.minY)) \(f(r.width))×\(f(r.height)))"
    }

    /// Why a wheel event was passed through or swallowed without scrolling.
    private static func diagnoseBail(_ reason: String, table: NSTableView?) {
        guard Scrolling.diagnose else { return }
        print("[wheel] BAIL: \(reason)  rows \(table?.numberOfRows ?? -1)")
    }

    /// Everything the monitor computed, and where the list actually ended up.
    ///
    /// Read it in this order:
    ///
    /// 1. **`currentTop` across consecutive notches.** It should move by exactly
    ///    one per notch and in the direction of `steps`. If it stands still, or
    ///    moves the wrong way, the reading of the current position is wrong —
    ///    which is what it was, and `topVisibleRow` records why.
    /// 2. **`rect(ofRow:)`** — the four sample rows should step by one row height
    ///    each. If they are identical or zero-height, AppKit's row geometry isn't
    ///    working on SwiftUI's table subclass and every notch computes the same
    ///    `y`. (Checked: it is fine. Don't spend a second round here.)
    /// 3. **`wanted y` vs `after` vs `settled`** — if `y` is right but `after` or
    ///    `settled` differ, the scroll is being applied and then reverted by
    ///    something else and this monitor's arithmetic is innocent.
    private static func diagnoseScroll(event: NSEvent, table: NSTableView,
                                       clipView: NSClipView,
                                       document: NSView, steps: CGFloat,
                                       currentTop: Int, targetRow: Int,
                                       y: CGFloat, before: CGFloat) {
        guard Scrolling.diagnose else { return }
        let last = max(table.numberOfRows - 1, 0)
        // Type pinned: a six-element literal of concatenated interpolations is
        // exactly the shape that trips "unable to type-check in reasonable time".
        let lines: [String] = [
            "[wheel] deltaY \(f(event.scrollingDeltaY))"
                + "  precise \(event.hasPreciseScrollingDeltas)"
                + "  steps \(f(steps))"
                + "  inverted \(Scrolling.inverted)",
            "  rows \(table.numberOfRows)"
                + "  rowHeight \(f(table.rowHeight))"
                + "  spacing.h \(f(table.intercellSpacing.height))",
            "  visibleRect \(f(table.visibleRect))"
                + "  currentTop \(currentTop)"
                + "  -> targetRow \(targetRow)",
            "  rect(ofRow:) 0 \(f(table.rect(ofRow: 0)))"
                + "  1 \(f(table.rect(ofRow: min(1, last))))"
                + "  target \(f(table.rect(ofRow: targetRow)))"
                + "  last[\(last)] \(f(table.rect(ofRow: last)))",
            "  documentView \(document === table ? "IS the table" : String(describing: type(of: document)))"
                + "  document.frame \(f(document.frame))"
                + "  clip.bounds \(f(clipView.bounds))"
                + "  clip.insets.top \(f(clipView.contentInsets.top))",
            "  wanted y \(f(y))"
                + "  before \(f(before))  after \(f(clipView.bounds.origin.y))",
        ]
        print(lines.joined(separator: "\n"))
        // One turn later: if something else reverts the scroll, this is where it
        // shows up — `after` above would be right and this one wrong.
        DispatchQueue.main.async { [weak clipView, weak table] in
            guard let clipView, let table else { return }
            print("  [wheel] settled clip.origin.y \(f(clipView.bounds.origin.y))"
                    + "  topVisibleRow \(Scrolling.topVisibleRow(table: table, clipView: clipView))")
        }
    }

    /// Gives the message list keyboard focus after a restored selection, so the
    /// highlight is the active one and the arrow keys move from that row.
    @MainActor
    private func applyPendingFocus(coordinator: Coordinator, attemptsLeft: Int) {
        guard model.pendingListFocus else { return }
        coordinator.focusGeneration += 1
        let generation = coordinator.focusGeneration

        guard let table = coordinator.table, table.numberOfRows > 0,
              let window = table.window, window.makeFirstResponder(table) else {
            // Not ready: the window may not be key yet, or the rows may not
            // exist. makeFirstResponder can also simply refuse.
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard coordinator.focusGeneration == generation else { return }
                    applyPendingFocus(coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
                }
            } else {
                model.clearPendingListFocus()
            }
            return
        }

        // SwiftUI's own focus machinery can hand first responder back when it
        // rebuilds the Table, so confirm it stuck before giving up the flag.
        DispatchQueue.main.async {
            guard coordinator.focusGeneration == generation else { return }
            if window.firstResponder === table || attemptsLeft == 0 {
                model.clearPendingListFocus()
            } else {
                applyPendingFocus(coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    /// One restore-path diagnostic line; see `Scrolling.diagnoseRestore`.
    private static func diagnoseRestore(_ stage: String, table: NSTableView,
                                        clipView: NSClipView, attemptsLeft: Int) {
        guard Scrolling.diagnoseRestore else { return }
        let doc = table.enclosingScrollView?.documentView ?? table
        print("[restore] \(stage)  clip.y \(clipView.bounds.origin.y)"
                + "  rows \(table.numberOfRows)"
                + "  doc.h \(doc.frame.height)  attempts \(attemptsLeft)")
    }

    /// Scrolls to the remembered row, if the model is asking for one.
    @MainActor
    private func applyPendingScroll(coordinator: Coordinator, attemptsLeft: Int) {
        guard let row = model.pendingScrollTopRow else { return }
        guard let table = coordinator.table, table.numberOfRows > row,
              let scrollView = table.enclosingScrollView else {
            // Rows aren't realized yet — the listing has only just been published.
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    applyPendingScroll(coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
                }
            } else {
                model.clearPendingScroll()
            }
            return
        }

        coordinator.restoreGeneration += 1
        let generation = coordinator.restoreGeneration
        coordinator.isRestoring = true

        // Through `Scrolling.originY`, the one place that knows how a row index
        // becomes a clip origin — so a restore lands exactly where the wheel
        // would have put it, and neither can be fixed without the other.
        let clipView = scrollView.contentView
        let document = scrollView.documentView ?? table
        let targetY = Scrolling.originY(forTopRow: row, table: table,
                                        clipView: clipView, document: document)
        Self.diagnoseRestore("APPLY row \(row) y \(targetY)", table: table,
                             clipView: clipView, attemptsLeft: attemptsLeft)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)

        // Let the resulting bounds notification land before recording again.
        DispatchQueue.main.async {
            guard coordinator.restoreGeneration == generation else { return }
            coordinator.isRestoring = false
            verifyPendingScroll(coordinator: coordinator, generation: generation,
                                row: row, attemptsLeft: attemptsLeft, confirmed: false)
        }
    }

    /// The gatekeeper between "the scroll was applied" and "the restore is
    /// done" (`clearPendingScroll` — which is also what drops the removal
    /// veil). Two lessons are encoded here, each learned from a visible jerk:
    ///
    /// 1. **The apply can land on stale geometry.** After a delete, the
    ///    previous listing's rows can still be realized when the scroll is
    ///    applied (a delete only *shrinks* the count, so the numberOfRows
    ///    guard passes), and SwiftUI's row diff then moves the clip. So the
    ///    target is recomputed against the table as it is *now*, and a clip
    ///    that isn't there gets the scroll applied again.
    ///
    /// 2. **Geometry that matches once can still be settling.** SwiftUI
    ///    refines the table's row-height estimates for several turns after a
    ///    listing lands — `document.frame.height` visibly grows between turns
    ///    (recorded in the `Scrolling` diagnostics comment) — so a check one
    ///    turn after the apply can pass and *then* the rows shift. Hence the
    ///    two-step: a passing check only schedules a **confirmation** a beat
    ///    later, and the restore is finished only when the position has held
    ///    across both. Any drift in between re-applies and starts over.
    ///
    /// A superseding chain (every apply bumps `restoreGeneration`) kills
    /// pending verifications, so at most one chain is ever live; exhaustion
    /// of `attemptsLeft` clears unconditionally, and the model's veil backstop
    /// covers anything this could conceivably miss.
    @MainActor
    private func verifyPendingScroll(coordinator: Coordinator, generation: Int,
                                     row: Int, attemptsLeft: Int, confirmed: Bool) {
        guard coordinator.restoreGeneration == generation else { return }
        guard model.pendingScrollTopRow != nil else { return }

        if attemptsLeft > 0,
           let table = coordinator.table, table.numberOfRows > row,
           let scrollView = table.enclosingScrollView {
            let clip = scrollView.contentView
            let doc = scrollView.documentView ?? table
            let wantY = Scrolling.originY(forTopRow: row, table: table,
                                          clipView: clip, document: doc)
            if abs(clip.bounds.origin.y - wantY) > 0.5 {
                Self.diagnoseRestore("DRIFT want \(wantY)", table: table,
                                     clipView: clip, attemptsLeft: attemptsLeft)
                applyPendingScroll(coordinator: coordinator,
                                   attemptsLeft: attemptsLeft - 1)
                return
            }
            if !confirmed {
                Self.diagnoseRestore("PASS want \(wantY), confirming", table: table,
                                     clipView: clip, attemptsLeft: attemptsLeft)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    verifyPendingScroll(coordinator: coordinator, generation: generation,
                                        row: row, attemptsLeft: attemptsLeft,
                                        confirmed: true)
                }
                return
            }
            Self.diagnoseRestore("CONFIRMED want \(wantY), clearing", table: table,
                                 clipView: clip, attemptsLeft: attemptsLeft)
        }

        model.clearPendingScroll()
        // Write the restored position straight back: recording was
        // suppressed throughout the restore, so without this the remembered
        // value would only ever be rewritten by a later user scroll.
        //
        // Bottom-ness is measured from the geometry we have right here rather
        // than carried in with `row`. This path restores a *top row*, and
        // whether that leaves the end of the list on screen depends on the row
        // count and the pane height — a position recorded as mid-list in a tall
        // window is the bottom in a short one. Asking the table is the only
        // answer that can't be stale.
        //
        // Re-bound here: the `table`/`scrollView` above are scoped to the
        // `attemptsLeft > 0` branch, and this line is also reached when the
        // attempts ran out. If the table has gone away entirely there is nothing
        // to measure, so the remembered flag is carried through unchanged rather
        // than being cleared on no evidence.
        let restoredAtBottom: Bool
        if let table = coordinator.table, let scrollView = table.enclosingScrollView {
            restoredAtBottom = Scrolling.lastRowVisible(
                Scrolling.visibleRows(table: table, clipView: scrollView.contentView),
                rowCount: table.numberOfRows)
        } else {
            restoredAtBottom = model.selectedMailboxWasAtBottom
        }
        model.rememberScroll(topRow: row, atBottom: restoredAtBottom)
    }
}

// MARK: - Middle: message list (Eudora column set)

struct MessageListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.mailboxSummary.isEmpty {
                HStack {
                    // Which mailbox this is, ahead of how much is in it.
                    // The sidebar shows the selection, but only while the
                    // enclosing group is expanded — collapse GOVERNMENT and the
                    // USPTO messages are still on screen with nothing left
                    // saying what they are. This is the only always-visible
                    // answer to "what am I looking at".
                    //
                    // Primary against the summary's secondary: the name is the
                    // thing being read, the counts are reference.
                    if !model.selectedMailboxPath.isEmpty {
                        // `.headline`, the same face and size as the subject
                        // line in the reading pane — this is a heading for what
                        // is on screen, so it should read like one. Note the
                        // bar's pinned height below was raised to fit it.
                        Text(model.selectedMailboxPath)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            // A deep path truncates in the middle, keeping the
                            // mailbox's own name — the part that identifies it —
                            // rather than the groups above it.
                            .truncationMode(.middle)
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(model.mailboxSummary)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                    // The rows are usable while this runs — Who, Date and the
                    // attachment mark are still settling — so this is a quiet
                    // note rather than a blocking indicator. It also explains why
                    // those columns change under you a few seconds in, and why a
                    // very large mailbox (Trash) feels sluggish — resizing,
                    // scrolling — until it finishes. Hence "settling", in
                    // secondary rather than tertiary so it's easy to spot.
                    if model.isEnriching {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text("settling — reading messages…")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.listingSource.isEmpty {
                        Text(model.listingSource)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                // Fixed height, because the bar's natural height CHANGED when
                // the enrichment spinner appeared — the small NSProgressIndicator
                // has a ~17 pt intrinsic box (`scaleEffect` shrinks only the
                // drawing), taller than the caption line, so the whole list
                // below nudged down a couple of pixels mid-veil (caught in a
                // frame-stepped recording). Pinning the *spinner's* frame
                // instead triggered AppKit min<=max constraint complaints; the
                // bar is the right thing to pin.
                //
                // 18, raised from 14 when the mailbox path went to `.headline`:
                // a headline line box doesn't fit in 14 and the descenders
                // clipped. The extra room incidentally fixes what the old number
                // fudged — 14 was a hair under the spinner's ~17 pt intrinsic
                // box, which it "overdrew invisibly at 0.6 scale". It now fits
                // properly.
                //
                // **Whatever this number is, it must stay fixed.** A bar that
                // sizes to its content changes height when the spinner appears,
                // and the message list below nudges down mid-veil — caught in a
                // frame-stepped recording, and now also a trigger for the
                // stick-to-the-bottom pin, which reads a clip-height change as a
                // resize.
                .frame(height: 18)
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
        } else if model.isListing && model.rows.isEmpty {
            // Before this, a mailbox mid-listing was indistinguishable from an
            // empty one — it said "No messages" for however long the read took,
            // which on Trash is several seconds of the app confidently
            // asserting something false.
            busy("Listing messages…")
        } else if model.rows.isEmpty {
            placeholder("No messages")
        } else {
            Table(model.rows, selection: model.messageSelection) {
                // One narrow glyph column on the left, Eudora-style: status and
                // attachment side by side, each sitting under its own icon in the
                // header. (Priority and color-label columns were dropped —
                // Stephen doesn't use either.) They share a column because
                // separate ones can't be butted together; see HeaderIcon.
                //
                // The header is blank here on purpose: TableHeaderIconStyler
                // paints Eudora 7's own icons via AppKit, the only way to get
                // them flush to the edges.
                // Each column's content is drawn back onto its header — see
                // MessageTableMetrics. The index passed to `tableCell` must match
                // this column's position.
                TableColumn("") { r in
                    HStack(spacing: 0) {
                        // Eudora 7's own row art, each centred under its header
                        // icon. Unread gets the dot; the other states Eudora
                        // tracks — replied, forwarded, redirected, queued, sent —
                        // keep their letter, because there is only art for the
                        // unread case and dropping the letters would lose real
                        // information from the list.
                        Group {
                            // Draft states before unread: neither is ever
                            // unread, but testing them first keeps the
                            // precedence explicit rather than incidental. All
                            // three are Eudora's own art; the states that only
                            // have a letter fall through.
                            if r.isSendError {
                                RowIcon.view(RowIcon.sendError,
                                             show: true,
                                             width: HeaderIcon.status.width)
                            } else if r.isUnsent {
                                RowIcon.view(RowIcon.unsent,
                                             show: true,
                                             width: HeaderIcon.status.width)
                            } else if r.isUnread {
                                RowIcon.view(RowIcon.unread,
                                             show: true,
                                             width: HeaderIcon.status.width)
                            } else if !r.statusGlyph.trimmingCharacters(in: .whitespaces).isEmpty {
                                Text(r.statusGlyph)
                                    .font(EudoraFont.list)
                                    .frame(width: HeaderIcon.status.width,
                                           height: RowIcon.height)
                            } else {
                                Color.clear
                                    .frame(width: HeaderIcon.status.width,
                                           height: RowIcon.height)
                            }
                        }
                        RowIcon.view(RowIcon.attachment,
                                     show: r.hasAttachment,
                                     width: HeaderIcon.attachment.width)
                    }
                    .tableCell(column: 0)
                }.width(HeaderIcon.leadingColumnWidth)
                // Explicit content closures rather than the `value:` keypath
                // form, so the text can carry the offset. Nothing is lost:
                // sorting is done on `model.rows` and the header clicks come from
                // `MessageHeaderSortInstaller`, so this table still has no
                // `sortOrder` binding and `value:` would supply only the text.
                // Fixed widths, not flexible: see MessageColumnWidths for why.
                // Subject alone is left to flex, and nothing's origin depends on
                // its width because it is last.
                TableColumn("Who") { r in
                    // One column, filled as three regions so the names line up:
                    // a fixed leading slot (the "S ▶" sent mark, or blank space
                    // of the same width), then the name, then the "▶ S" received
                    // mark pinned to the right by the Spacer — hard against the
                    // Date column. The fixed leading slot is what keeps every
                    // name starting at the same x whichever way the message went
                    // (see WhoGlyph). `.tableCell(column: 1)` still carries the
                    // whole cell back under the "Who" header, exactly as the
                    // bare Text did — none of the column geometry changes.
                    HStack(spacing: 3) {
                        WhoGlyph.leading(r.direction)
                        Text(r.who).font(EudoraFont.list).lineLimit(1)
                        Spacer(minLength: 0)
                        WhoGlyph.trailing(r.direction)
                    }
                    .tableCell(column: 1)
                }.width(min: MessageColumnWidths.whoMin,
                        ideal: model.whoColumnWidth,
                        max: MessageColumnWidths.maxWidth)
                TableColumn("Date") { r in
                    Text(r.date).font(EudoraFont.list).tableCell(column: 2)
                }.width(min: MessageColumnWidths.dateMin,
                        ideal: model.dateColumnWidth,
                        max: MessageColumnWidths.maxWidth)
                TableColumn("Subject") { r in
                    Text(r.subject).font(EudoraFont.list).tableCell(column: 3)
                }
            }
            // The right-click menu is AppKit, not `.contextMenu` — see
            // MessageContextMenuInstaller. SwiftUI builds nested menus eagerly,
            // which made every right-click construct all 2,657 mailboxes.
            .background(MessageContextMenuInstaller(model: model))
            .background(MessageHeaderSortInstaller(model: model))
            .background(TableHeaderIconStyler(icons: HeaderIcon.leadingColumns))
            .background(MessageColumnResizeInstaller(model: model))
            .background(TableScrollStateSyncer(model: model))
            // The removal veil: during a delete/move the stale rows stay up as
            // a picture — washed halfway to white, label on top — instead of
            // the old blank → wrong offset → jump. The Color swallows clicks
            // (the rows beneath describe a mailbox that no longer exists);
            // the AppKit right-click and double-click monitors stand down on
            // their own (they check `removalVeil` — see MessageContextMenu).
            // Comes down when the re-listed rows and their restored scroll
            // position are both in; see `AppModel.afterRemoval`.
            .overlay {
                if let veil = model.removalVeil {
                    ZStack {
                        // The frozen pre-removal picture, opaque, so nothing
                        // the live table does underneath — the row diff, the
                        // scroll restore, geometry settling — can show
                        // through. (A translucent wash over the live table
                        // let every one of those read as a jerk.) Natural
                        // size, pinned to the top-left the way the list is;
                        // clipped if the pane resized under it.
                        if let frozen = model.removalVeilImage {
                            Image(nsImage: frozen)
                                .frame(maxWidth: .infinity, maxHeight: .infinity,
                                       alignment: .topLeading)
                                .clipped()
                        }
                        Color.white.opacity(0.5)
                        Text(veil)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                } else if let notice = model.removalNotice {
                    // The completion message, in the veil label's exact spot
                    // and dress — the capsule reads Deleting… → Moved to
                    // Trash. without moving. Hit-testing off: the list under
                    // it is live again and a click should reach it.
                    Text(notice)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A placeholder that says work is happening, rather than one that states a
    /// fact which isn't true yet.
    private func busy(_ text: String) -> some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail: message preview

/// The rule marking the split between the message list and the message view.
///
/// Drawn by `PaneDividerHandle`, which also carries the drag.
///
/// **Historical note, so nobody re-treads it.** This used to be a cosmetic
/// overlay on top of a `VSplitView`, whose own divider stayed a hairline and was
/// fiddly to grab. The obvious AppKit repair is
/// `splitView(_:additionalEffectiveRectOfDividerAt:)`, which adds to both the
/// drag region and the cursor region — but it is a *delegate* method, and
/// SwiftUI's `VSplitView` is managed by an `NSSplitViewController`, which throws
/// the moment you assign to its split view's delegate: *"A SplitView managed by
/// a SplitViewController cannot have its delegate modified."* The slot is not
/// available, interposed or otherwise. Hence the hand-built split.
///
/// All values here are taste, not measurement. Retune freely.
/// The drawn rule and the draggable strip are the same thing: the whole
/// thickness takes the drag, so what you can see is exactly what you can grab.
///
/// It was briefly a 5 pt rule inside an 11 pt invisible grab band, which worked
/// but meant the target didn't match the target you could see, and the surplus
/// showed as a strip of bare window background above the preview.
enum PaneDivider {
    /// 9 rather than the 5 this was for a long time — two points more above and
    /// below, which is the difference between fiddly and easy to hit.
    static let thickness: CGFloat = 9

    /// `.primary` rather than `.separatorColor` — the system separator is
    /// deliberately faint, which is the thing being corrected here. Going
    /// through the semantic colour keeps it legible in both appearances instead
    /// of being a dark grey that disappears in dark mode.
    static let color = Color.primary.opacity(0.35)
}

/// Where the divider is allowed to be.
///
/// Every read of the stored height goes through `previewHeight`, so a stored
/// value can never put either pane below its minimum however it was arrived at
/// — dragged on a taller window, restored from an older build, or hand-edited in
/// the defaults database.
/// Carries a main-thread-only notification handler across the `@Sendable`
/// requirement of `NotificationCenter.addObserver(forName:object:queue:using:)`.
///
/// **The unchecked part is a real assertion, not a shrug.** It is safe only
/// because every handler wrapped here is registered with `queue: .main`, so the
/// block is delivered on the main thread and the AppKit reads inside it are
/// legitimate. If one of these is ever registered on another queue, this box is
/// the thing that stopped the compiler from saying so.
///
/// It exists because there is no clean spelling on a macOS 13 target: marking
/// the handler `@Sendable` makes every AppKit read inside it a warning, and
/// leaving it plain makes the conversion one. The third option — hopping to the
/// main actor before reading — silences both and samples the geometry a runloop
/// turn later, which in the scroll code is a behavioural change rather than a
/// tidy-up. So the promise is stated here instead, once, where it can be read.
private struct MainQueueHandler: @unchecked Sendable {
    let run: (Notification) -> Void
    init(_ run: @escaping (Notification) -> Void) { self.run = run }
}

/// ⌘⌫ for Delete, carried by an invisible button rather than a menu item.
///
/// The Message menu advertises **⌘D**, which is Eudora's key and the one to
/// show. ⌘⌫ is the Mac-native spelling and worth keeping, but a second Delete
/// item next to the first — same title, different key — reads as a mistake, the
/// objection already recorded against advertising ⌘N twice.
///
/// Living in the main window rather than in `eudoraCommands` also scopes it
/// correctly for free: a window's own key equivalents only fire while that
/// window is key, so this cannot reach into a compose window or Settings the way
/// a menu shortcut would.
///
/// Gated on the same condition as the menu item, so the two keys can never
/// disagree about whether Delete is available.
/// ⌥↑ / ⌥↓ move the selected mailbox within its group.
///
/// Reordering is otherwise a right-click and a menu pick *per step*, which is a
/// poor fit for what the job actually is: nudging something several places and
/// overshooting once. From the keyboard a repeat is one keystroke and a
/// correction is instant.
///
/// **Scoped to the main window on purpose.** These are window key equivalents,
/// not menu shortcuts. A menu shortcut is matched before any window's own key
/// handling, which would take ⌥↑/⌥↓ away from every text field in every compose
/// window — where they are ordinary paragraph-movement keys. Living here, they
/// exist only where a sidebar does. Same reasoning as `DeleteBackspaceShortcut`.
///
/// They act on the sidebar *selection*, whereas the context menu acts on the row
/// that was right-clicked. That is the natural reading of each: a keystroke has
/// no click position to refer to.
struct MailboxReorderShortcuts: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            Button("Move Mailbox Up") { move(up: true) }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(!canMove(up: true))
            Button("Move Mailbox Down") { move(up: false) }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(!canMove(up: false))
        }
        // Present but effectively invisible — see `DeleteBackspaceShortcut` for
        // why `.hidden()` won't do.
        .frame(width: 1, height: 1)
        .opacity(0.01)
        .accessibilityHidden(true)
    }

    private func canMove(up: Bool) -> Bool {
        guard let id = model.selectedMailboxID else { return false }
        return model.canMove(id, up: up)
    }

    private func move(up: Bool) {
        guard let id = model.selectedMailboxID else { return }
        model.moveTreeItem(id, up: up)
    }
}

struct DeleteBackspaceShortcut: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button("Delete") { model.deleteSelected() }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!(model.openDrafts.isEmpty && model.canActOnSelection))
            // One point square and all but transparent, not `.hidden()`: a
            // hidden view is removed from layout and stops registering its key
            // equivalent. This is the shape `HiddenSettingsLink` uses, which is
            // known to work here.
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
    }
}

enum PaneLayout {
    /// Enough to see a useful number of rows.
    static let listMinimum: CGFloat = 150
    /// Enough for the header block and a line or two of body.
    static let previewMinimum: CGFloat = 140
    static let defaultPreviewHeight: Double = 300

    /// The smallest the detail area may be, which becomes the window's own
    /// minimum. `VSplitView` used to impose this implicitly, from the two panes'
    /// `minHeight`s; stating it keeps the window from being resized into the
    /// degenerate case below.
    static var minimumTotal: CGFloat { listMinimum + previewMinimum + PaneDivider.thickness }

    /// The preview's height, clamped to what `total` can actually accommodate.
    static func previewHeight(_ stored: Double, total: CGFloat) -> CGFloat {
        let available = max(0, total - PaneDivider.thickness)
        let mostThePreviewMayTake = available - listMinimum
        // `>=`, not `>`: at exactly `minimumTotal` the two minimums fit precisely,
        // and `>` would send the one window height this layout is designed
        // around down the degenerate path below — giving the list 145 pt when
        // its stated minimum is 150.
        guard mostThePreviewMayTake >= previewMinimum else {
            // Not enough room for both minimums — the window is smaller than the
            // layout supports, which `minimumTotal` should prevent but a display
            // change or a restored frame can still produce. Halve it rather than
            // let either pane go negative, which lays out as a hard crash in
            // some SwiftUI versions and as nothing at all in others.
            return available / 2
        }
        return min(max(CGFloat(stored), previewMinimum), mostThePreviewMayTake)
    }
}

/// The divider: draws the rule, takes the drag, and shows the resize cursor.
struct PaneDividerHandle: View {
    /// Distance dragged since the gesture began, positive downward.
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    /// Whether *we* put a cursor on the stack. See the hover handler.
    @State private var pushedCursor = false

    var body: some View {
        Rectangle()
            .fill(PaneDivider.color)
            .frame(height: PaneDivider.thickness)
            .contentShape(Rectangle())
            // Push/pop rather than `set()`: `set` is undone by the next view that
            // has an opinion, which over a scrolling list is immediately.
            //
            // The flag is what keeps the pair balanced. `onHover(true)` can arrive
            // without a matching `false` — the window hidden with ⌘H, a menu opening
            // over the pointer, the app deactivating — and the two leaks are not
            // symmetric: a spare `pop` is documented as a no-op, but a spare `push`
            // means someone else's cursor gets popped later.
            .onHover { inside in
                if inside, !pushedCursor {
                    NSCursor.resizeUpDown.push()
                    pushedCursor = true
                } else if !inside, pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
            // The other half of the pair, for the case `onHover` cannot cover:
            // this view being *destroyed* while the pointer is over it. SwiftUI
            // does not deliver `onHover(false)` on removal, and it takes the
            // `@State` flag with it, so the push would leak — and per the note
            // above, a spare push means someone else's cursor gets popped later.
            //
            // Not hypothetical since the header divider appeared: it exists only
            // while Blah Blah Blah is on, so hovering the rule and pressing
            // ⇧⌘B destroys it under the pointer. It also goes away on every
            // selection change, because `loadMessage` clears `preview` before it
            // renders — so arrow-keying down the list with the pointer resting
            // where the drag left it would leak one push per message.
            .onDisappear {
                if pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
            // `minimumDistance: 0` so the drag starts on mouse-down rather than
            // after a few points of slop, which on a divider reads as stickiness.
            //
            // **`coordinateSpace: .global` is load-bearing — do not drop it.**
            // `DragGesture` defaults to `.local`, meaning local to this view, and
            // this view is the thing being dragged. Every frame the divider moves,
            // its local origin moves with it, so the same pointer position reports a
            // different translation, which moves the divider again. It is a feedback
            // loop, and it looks like the divider fighting the mouse: frantic
            // jittering that never settles under the cursor. A space that doesn't
            // move with the handle breaks the loop.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { onChanged($0.translation.height) }
                    .onEnded { _ in onEnded() }
            )
    }
}

/// Sizing for the raw header block, when "Blah Blah Blah" is on.
///
/// Separate from `PaneLayout` because the two clamps answer different questions.
/// `PaneLayout` splits the whole detail area between two panes that both matter;
/// this one carves a strip off the top of a pane whose remainder is the message
/// itself, so it is stated as "leave at least this much for the body" rather
/// than as two competing minimums.
/// (Note for anyone tempted to make the preview pane self-sizing: `PreviewView`
/// is handed an explicit `.frame(height:)` by the split view, and the header
/// handle only redistributes space *inside* that fixed frame. So dragging it
/// posts no geometry notification on the message list's clip view, and the
/// list's stick-to-the-bottom behaviour is untouched by it. A self-sizing
/// preview would change that.)
enum HeaderPaneLayout {
    /// Two or three header lines — below this the strip isn't worth having.
    static let minimum: CGFloat = 44
    /// What must be left for everything that isn't the block: the padding (24),
    /// the subject (up to two lines, ~40), the attachment chips when present
    /// (~33), the 9 pt handle, and a usable amount of body.
    ///
    /// Approximate on purpose. Measuring the real chrome would make the ceiling
    /// depend on the message being shown — which is the "the app resized the
    /// pane behind my back" problem the `GeometryReader` below exists to
    /// prevent. But it has to be generous rather than tight: the chrome sits
    /// *above* the block, so under-reserving pushes the handle itself past the
    /// bottom of a `.clipped()` pane, where it cannot be grabbed to drag back.
    /// The subject is capped at two lines for the same reason — an unbounded
    /// `.headline` wrapping to four lines would blow any fixed figure.
    static let reservedForTheRest: CGFloat = 185
    static let defaultHeight: Double = 120

    /// `stored`, clamped to what a pane of `pane` points can give it.
    static func height(_ stored: Double, pane: CGFloat) -> CGFloat {
        let ceiling = pane - reservedForTheRest
        // A pane too short to honour both: give the headers the floor and let
        // the body be clipped. Showing two header lines and no message beats
        // showing a negative-height view, which lays out as a crash in some
        // SwiftUI versions and as nothing at all in others.
        guard ceiling >= minimum else { return minimum }
        return min(max(CGFloat(stored), minimum), ceiling)
    }
}

struct PreviewView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var fontSettings: ComposeSettings

    /// Where this pane gets the message it shows.
    ///
    /// The main window's pane follows the model's selection; the Find window's
    /// result pane is handed a message directly. Two sources, one renderer — so
    /// a search result gets the link-safety checks, "Blah Blah Blah", embedded
    /// images and everything added later, without a second implementation
    /// drifting quietly out of step with this one.
    enum Source {
        /// Follow `AppModel.preview` and the main window's selection.
        case mainSelection
        /// Show exactly this, with this loading state. Used by the Find window.
        case given(MessagePreview?, isLoading: Bool)
    }

    var source: Source = .mainSelection

    /// The message to draw, whichever way it arrived.
    private var shown: MessagePreview? {
        switch source {
        case .mainSelection:            return model.preview
        case .given(let preview, _):    return preview
        }
    }

    private var isLoading: Bool {
        switch source {
        case .mainSelection:            return model.isLoadingPreview
        case .given(_, let loading):    return loading
        }
    }

    /// Whether the actions in the message body act on what is being shown.
    ///
    /// False in the Find window: `model.forward()` forwards the *main window's*
    /// selected message, which is not the one on screen here. Rather than wire a
    /// second path through the web view, Forward is simply not offered — the
    /// context menu's View in Mailbox takes you to the message, where every
    /// action applies to the message you are looking at.
    private var actsOnShownMessage: Bool {
        // Single selection only. Now that a multi-selection previews its primary,
        // this pane renders where it used to show a count — and `model.forward()`
        // goes through `selectedMessageID`, which is deliberately nil for a
        // multi-selection, so the item would have appeared and silently done
        // nothing. Offering an action that no-ops is worse than not offering it.
        if case .mainSelection = source { return model.selectedMessageIDs.count == 1 }
        return false
    }

    /// Height of the raw header block, remembered across launches. `@AppStorage`
    /// for the same reason `previewPaneHeight` is: where you like a divider is a
    /// property of the window, not of the tree that happens to be open. Every
    /// read is clamped by `HeaderPaneLayout`, never trusted.
    @AppStorage("headerPaneHeight") private var storedHeaderHeight: Double =
        HeaderPaneLayout.defaultHeight

    /// The header height when the current drag began; nil when not dragging.
    @State private var headerDragStart: Double?

    /// The height being dragged to, before it is committed.
    @State private var liveHeaderHeight: Double?

    /// Wrapped in a `GeometryReader` so the pane's height is decided by the
    /// split view and the user, never by the message being shown.
    ///
    /// `VSplitView` sizes its panes from their content's minimum height, and
    /// this pane's minimum used to change with every selection: the detached
    /// attachment bar is `fixedSize`d and so demands up to 120 pt on a message
    /// that has attachments and nothing on one that doesn't, and the header block
    /// grows and shrinks with the To line, the attachment chips and a subject
    /// long enough to wrap. Switching messages therefore moved the divider —
    /// which looks like the app resizing the pane behind your back, because it is.
    ///
    /// A `GeometryReader` has no intrinsic size of its own: it reports no
    /// minimum, takes whatever height it is offered, and hands it down. That
    /// leaves exactly one thing deciding this pane's size — the explicit
    /// `.frame(height:)` it is given in `splitView`, which is `PaneLayout`'s
    /// clamp of wherever the user last dragged the divider. The content is then
    /// pinned to that height rather than asking for one, and clipped, since a
    /// very short pane can't fit a tall header block.
    ///
    /// (The `GeometryReader` was originally here to defend against `VSplitView`
    /// sizing panes from their content's minimum, which made the divider jump
    /// whenever a selection changed the header block's height. The split is
    /// hand-built now and no longer asks, but the reasoning still holds: this
    /// pane must take the height it is given and not ask for one.)
    var body: some View {
        GeometryReader { geo in
            content(paneHeight: geo.size.height)
                .frame(width: geo.size.width, height: geo.size.height,
                       alignment: .topLeading)
                .clipped()
                // Turning the block off destroys the divider, and if that
                // happens mid-drag `onEnded` never runs — leaving `liveHeaderHeight`
                // set for the rest of the session, honoured on screen but never
                // committed, so the height silently reverts at the next launch.
                // Discarded rather than committed, matching this file's stance
                // that a cancelled drag should be harmless.
                .onChange(of: model.showAllHeaders) { _ in
                    liveHeaderHeight = nil
                    headerDragStart = nil
                }
                // The rule that used to be overlaid here is now drawn by
                // `PaneDividerHandle`, which sits above this pane in the stack
                // and carries the drag as well as the line.
        }
    }

    @ViewBuilder private func content(paneHeight: CGFloat) -> some View {
        // A multi-selection used to render "N messages selected" here instead of
        // a message, following Mail. It no longer does: ⇧-arrowing down a run of
        // mail is done in order to *read* each one as it joins the selection, and
        // a count is not something you can read. `AppModel.loadMessage` previews
        // the primary, which follows the moving end of the extension.
        //
        // The count is simply gone rather than relocated — the highlighted rows
        // in the list say how many there are, more precisely than a number does.
        //
        // The old branch also served to keep a stale render from lingering under
        // a selection it no longer describes. That is now handled the same way it
        // always was for a single selection: `loadMessage` clears `preview`
        // before it starts loading.
        if let p = shown {
            let headerHeight = HeaderPaneLayout.height(liveHeaderHeight ?? storedHeaderHeight,
                                                       pane: paneHeight)
            VStack(alignment: .leading, spacing: 0) {
                headers(p, blockHeight: headerHeight)
                // Draggable only while the raw block is showing. The three-line
                // From/To/Date summary has nothing to reveal, so a resize handle
                // over it would be a control that does nothing — and it would
                // put the resize cursor on a rule the user has looked at without
                // touching for months.
                if model.showAllHeaders {
                    PaneDividerHandle { translation in
                        // The same three rules as the list/preview divider, for
                        // the same reasons: clear the base when a fresh gesture
                        // reports its zero (so a cancelled drag can't teleport
                        // the next one), measure from where the drag began
                        // rather than compounding each event, and start from the
                        // *clamped* height so a short window doesn't spend the
                        // first inch of the drag re-clamping to where it already
                        // was.
                        if translation == 0 { headerDragStart = nil }
                        let base = headerDragStart ?? Double(headerHeight)
                        if headerDragStart == nil { headerDragStart = base }
                        // Dragging down makes the header block *larger* — the
                        // opposite sense to the pane divider above, because here
                        // the thing being sized is above the handle rather than
                        // below it.
                        liveHeaderHeight = Double(
                            HeaderPaneLayout.height(base + Double(translation),
                                                    pane: paneHeight))
                    } onEnded: {
                        // Committed once, not per frame: `@AppStorage` writes to
                        // UserDefaults and a drag emits at the refresh rate.
                        if let liveHeaderHeight { storedHeaderHeight = liveHeaderHeight }
                        liveHeaderHeight = nil
                        headerDragStart = nil
                    }
                } else {
                    Divider()
                }
                if p.isHTML {
                    HTMLMailView(html: p.content, images: p.images,
                                 // The banner is drawn by `ContentView`, so from
                                 // the Find window's pane it would appear behind
                                 // the window you are looking at. Copy Link still
                                 // copies; it just doesn't announce itself where
                                 // the announcement can't be seen.
                                 onCopyLink: actsOnShownMessage
                                    ? { url in model.showBanner("Link copied: \(url)") }
                                    : { _ in },
                                 onOpenLink: { url in model.openLinkFromMessage(url) },
                                 onForward: actsOnShownMessage ? { model.forward() } : nil,
                                 fontName: fontSettings.bodyFontName,
                                 fontSize: fontSettings.bodyFontSize,
                                 antialias: fontSettings.bodyAntialiasing.htmlSmoothingOn)
                } else if p.content.isEmpty {
                    // An attachment-only message genuinely has no text, so say
                    // that rather than implying something failed.
                    Text(p.detached.isEmpty ? "(no text body)"
                                            : "(no message text — attachment only)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // The default font, matching the composer and honouring the
                    // antialiasing toggle — an NSTextView rather than SwiftUI
                    // `Text`, because only the former can turn smoothing off.
                    PlainMailView(text: p.content,
                                  fontName: fontSettings.bodyFontName,
                                  fontSize: fontSettings.bodyFontSize,
                                  antialiasing: fontSettings.bodyAntialiasing,
                                  haloWhiteness: fontSettings.eudoraHaloWhiteness)
                }
                // After the body, where Eudora put them — but *pinned* below it
                // rather than inline, and outside the web view. Native views keep
                // them out of reach of the message's own CSS, which could restyle
                // or hide them inside the WKWebView's document; pinning means a
                // long message doesn't bury the attachment list off-screen. The
                // height cap is what stops a message with many attachments from
                // squeezing the body to nothing.
                if !p.detached.isEmpty {
                    Divider()
                    ScrollView {
                        DetachedAttachmentBar(items: p.detached)
                    }
                    .frame(maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if isLoading {
            // `loadMessage` clears `preview` and then reads and renders off the
            // main actor, which on a large mailbox is a noticeable wait. Without
            // this the pane sat on "Select a message" throughout — telling the
            // user to do the thing they had just done.
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Opening message…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a message")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func headers(_ p: MessagePreview, blockHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Capped so a very long subject can't grow the chrome past what
            // `HeaderPaneLayout.reservedForTheRest` allows for it, which would
            // push the drag handle off the bottom of the pane.
            Text(p.subject.isEmpty ? "(no subject)" : p.subject)
                .font(.headline)
                .lineLimit(2)
            if model.showAllHeaders {
                // Branching on the toggle alone, not on the text being non-empty:
                // if the re-read failed, the panel has to say so. Falling back to
                // the ordinary summary would leave the button lit and the pane
                // unchanged, which reads as "the button is broken".
                rawHeaderBlock(p.rawHeaders.isEmpty
                    ? "(headers unavailable — the message couldn't be re-read)"
                    : p.rawHeaders,
                               height: blockHeight)
            } else {
                headerLine("From", p.from)
                headerLine("To", p.to)
                headerLine("Date", p.date)
            }
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

    /// The raw block, in place of the From/To/Date summary.
    ///
    /// Monospaced because that is how a header block is meant to be read — the
    /// `Received:` chain you open this for is a column of aligned timestamps and
    /// hostnames, and a proportional face makes it soup. `.system(design:
    /// .monospaced)` rather than the body font from Settings: this is not the
    /// message, it is the envelope, and it shouldn't follow a font choice made
    /// for reading prose.
    ///
    /// Independently scrollable so a long chain — a dozen `Received:` lines is
    /// ordinary for a forwarded message — can't push the body off the bottom of
    /// the pane. `height`, not `maxHeight`: the strip takes exactly what the
    /// divider below it was dragged to, so its size is the user's decision and
    /// doesn't change from one message to the next. `.fixedSize` is gone with
    /// the cap — it would have fought the explicit height.
    ///
    /// The tradeoff, taken deliberately: a short block no longer shrinks to fit,
    /// so three lines of headers leave whitespace above the rule. A block that
    /// sized itself to each message would move the rule out from under the
    /// pointer every time the selection changed — which is the behaviour this
    /// pane has been carefully arranged not to have.
    private func rawHeaderBlock(_ text: String, height: CGFloat) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
        }
        .frame(height: height)
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

/// The attachments Eudora detached to disk, listed after the body the way
/// Eudora 7 listed them: a file icon and the filename.
///
/// Unlike `AttachmentChip` these have no bytes in the message — the file is out
/// in the Attachments folder — so the actions differ: **Reveal in Finder** and
/// **Save a Copy**, plus **View** for images through the existing native viewer.
/// Never open-in-default-app, per the "dumb client" stance (design-decisions §3):
/// handing a `.doc` to Word is exactly the message-triggered behaviour that stance
/// exists to prevent, and it would be no less dangerous for the file having been
/// unpacked to disk by Eudora years ago.
///
/// A file Eudora recorded but that isn't on disk is still listed, greyed and
/// unclickable, with the recorded Windows path as its tooltip — that path is the
/// only remaining clue to where it went, and silently dropping the row would
/// misrepresent the message as having had no attachment.
struct DetachedAttachmentBar: View {
    let items: [LocatedAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Keyed by position, not by value: a forwarded message can record the
            // same file twice, and identical values would collide as IDs.
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if item.isFound {
                    Menu {
                        Button("Reveal in Finder") { DetachedAttachmentActions.reveal(item) }
                        Button("Save a Copy…") { DetachedAttachmentActions.saveCopy(item) }
                        if DetachedAttachmentActions.isImage(item) {
                            Button("View") { DetachedAttachmentActions.viewImage(item) }
                        }
                    } label: {
                        row(item, enabled: true)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(item.url?.path ?? item.filename)
                } else {
                    row(item, enabled: false)
                        .help("Not found in the Attachments folder. Eudora recorded it as: "
                                + item.recordedPath)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ item: LocatedAttachment, enabled: Bool) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: icon(for: item))
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .opacity(enabled ? 1 : 0.4)
            // `.underline` before `.lineLimit`, so this uses `Text`'s own
            // underline rather than the `View` one that needs macOS 13.
            Text(item.filename)
                .underline(enabled)
                .lineLimit(1)
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
        }
        .font(.callout)
    }

    /// The system's icon for the file, so a .doc looks like a Word document and
    /// a .pdf like a PDF — as Eudora's own list did. Looked up from the *path*
    /// for files that exist, and from the extension otherwise, so a missing file
    /// still gets a plausible icon rather than a blank.
    private func icon(for item: LocatedAttachment) -> NSImage {
        if let url = item.url {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let ext = (item.filename as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
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

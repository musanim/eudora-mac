import SwiftUI
import AppKit

@main
struct EudoraApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var accounts = AccountStore()

    /// Arms the splash before SwiftUI builds its scenes, so the main window can
    /// be hidden the instant it's created rather than after it has been shown.
    /// This only registers an observer — see SplashWindow.arm, and note that
    /// creating a window here does *not* work.
    init() {
        SplashWindow.arm()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(accounts)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            // Keep the system (top-of-screen) menu bar minimal: the real menus
            // live in-window (MenuBarView). Strip the groups we've relocated so
            // their shortcuts don't double-register against the in-window items.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .undoRedo) {}
        }

        // The Eudora "Find Messages" window (⌘F / Edit ▸ Find… / Tools ▸ Search…).
        // Shares the single AppModel so results open in the main window.
        Window("Find Messages", id: "find") {
            FindView()
                .environmentObject(model)
                .environmentObject(accounts)
                .frame(minWidth: 720, minHeight: 460)
        }

        Settings {
            SettingsView()
                .environmentObject(accounts)
        }
    }
}

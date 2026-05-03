import SwiftUI

@main
struct SafariTabsApp: App {
    @StateObject private var store = TabsStore()

    var body: some Scene {
        WindowGroup("Safari Tabs") {
            ContentView()
                .environmentObject(store)
                .onAppear { store.start() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("View") {
                Button("Refresh") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Focus Search") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

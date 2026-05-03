import SwiftUI
import AppKit

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, ["activate", "close", "list"].contains(first) {
            CLI.run(args)
            return
        }
        SafariTabsApp.main()
    }
}

struct SafariTabsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = TabsStore()

    var body: some Scene {
        WindowGroup("Safari Tabs") {
            ContentView()
                .environmentObject(store)
                .onAppear {
                    AppDelegate.shared?.store = store
                    store.start()
                }
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

/// Silent CLI mode: invoked when the binary runs with a known subcommand as
/// argv[1]. Used by external integrations (Hammerspoon Spoon) to drive Safari
/// without launching the GUI.
///
/// Usage:
///   SafariTabs activate <url>
///   SafariTabs close <url>
///   SafariTabs list [<output-path>]
enum CLI {
    static func run(_ args: [String]) {
        guard let cmd = args.first else { exit(2) }
        switch cmd {
        case "activate":
            guard args.count >= 2 else { exit(2) }
            _ = SafariBridge.activate(url: args[1])
        case "close":
            guard args.count >= 2 else { exit(2) }
            _ = SafariBridge.closeTab(url: args[1])
        case "list":
            let path = args.count >= 2 ? args[1] : URLActions.defaultListPath
            URLActions.writeTabList(to: path)
            print(path)
        default:
            FileHandle.standardError.write(Data("unknown command: \(cmd)\n".utf8))
            exit(2)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    weak var store: TabsStore?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    /// Handle `safaritabs://` URLs.
    /// - `safaritabs://activate?url=<encoded URL>`
    /// - `safaritabs://close?url=<encoded URL>`
    /// - `safaritabs://list[?out=<path>]`
    func application(_ application: NSApplication, open urls: [URL]) {
        let hadVisibleWindow = NSApp.windows.contains { $0.isVisible }
        for url in urls { handle(url) }
        if !hadVisibleWindow {
            DispatchQueue.main.async {
                for w in NSApp.windows { w.orderOut(nil) }
                NSApp.hide(nil)
            }
        }
    }

    private func handle(_ incoming: URL) {
        guard incoming.scheme == "safaritabs" else { return }
        let action = incoming.host ?? ""
        let comps = URLComponents(url: incoming, resolvingAgainstBaseURL: false)
        let queryURL = comps?.queryItems?.first(where: { $0.name == "url" })?.value
        switch action {
        case "activate":
            guard let target = queryURL else { return }
            Task.detached { SafariBridge.activate(url: target) }
        case "close":
            guard let target = queryURL else { return }
            let s = store
            Task { @MainActor in s?.removeByURL(target) }
            Task.detached { SafariBridge.closeTab(url: target) }
        case "list":
            let outPath = comps?.queryItems?.first(where: { $0.name == "out" })?.value
                ?? URLActions.defaultListPath
            Task.detached { URLActions.writeTabList(to: outPath) }
        default:
            break
        }
    }
}

enum URLActions {
    static var defaultListPath: String {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.velppa.SafariTabs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tabs.json").path
    }

    static func writeTabList(to path: String) {
        let windows = SafariBridge.fetchWindows()
        var rows: [[String: Any]] = []
        for (i, w) in windows.enumerated() {
            for tab in w.tabs {
                rows.append([
                    "window": i + 1,
                    "url": tab.url,
                    "title": tab.title
                ])
            }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: rows,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

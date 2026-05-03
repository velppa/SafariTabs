import Foundation
import AppKit

enum SafariBridge {
    /// Enumerate every tab in every Safari window. Returns one SafariWindow per window.
    static func fetchWindows() -> [SafariWindow] {
        let script = """
        tell application "Safari"
            set out to {}
            repeat with w from 1 to count of windows
                set winID to id of window w
                set tabList to {}
                repeat with t from 1 to count of tabs of window w
                    set tabTitle to name of tab t of window w
                    set tabURL to URL of tab t of window w
                    set end of tabList to {tabTitle, tabURL, (winID as text), (w as text), (t as text)}
                end repeat
                set end of out to tabList
            end repeat
            return out
        end tell
        """

        guard let descriptor = run(script), descriptor.numberOfItems > 0 else { return [] }

        var windows: [SafariWindow] = []
        for w in 1...descriptor.numberOfItems {
            guard let tabsDesc = descriptor.atIndex(w), tabsDesc.numberOfItems > 0 else { continue }
            var tabs: [SafariTab] = []
            for t in 1...tabsDesc.numberOfItems {
                guard
                    let row = tabsDesc.atIndex(t),
                    row.numberOfItems >= 5,
                    let title = row.atIndex(1)?.stringValue,
                    let url = row.atIndex(2)?.stringValue,
                    let wIDStr = row.atIndex(3)?.stringValue, let wID = Int(wIDStr),
                    let wIdxStr = row.atIndex(4)?.stringValue, let wIdx = Int(wIdxStr),
                    let tIdxStr = row.atIndex(5)?.stringValue, let tIdx = Int(tIdxStr)
                else { continue }
                tabs.append(SafariTab(
                    windowID: wID,
                    windowIndex: wIdx,
                    tabIndex: tIdx,
                    title: title,
                    url: url
                ))
            }
            if let first = tabs.first {
                windows.append(SafariWindow(id: first.windowID, index: first.windowIndex, tabs: tabs))
            }
        }
        var seen = Set<Int>()
        let deduped = windows.filter { seen.insert($0.id).inserted }
        return deduped.sorted { $0.id < $1.id }
    }

    /// Activate a specific tab and bring its window to front.
    /// Re-fetches Safari's window list first so the indexes used are current —
    /// Safari's z-order shifts whenever a window is brought to front.
    static func activate(_ tab: SafariTab) {
        log("activate request: url=\(tab.url) title=\(tab.title) cachedW=\(tab.windowIndex) cachedT=\(tab.tabIndex)")
        guard let fresh = locate(tab) else {
            log("activate: no match in fresh fetch — aborting")
            return
        }
        log("activate: matched freshW=\(fresh.windowIndex) freshT=\(fresh.tabIndex)")
        // Set the target tab and bring its window to the front *before* `activate`,
        // so the OS-level app switch can't race with a Safari window restoration.
        let script = """
        tell application "Safari"
            set current tab of window \(fresh.windowIndex) to tab \(fresh.tabIndex) of window \(fresh.windowIndex)
            set index of window \(fresh.windowIndex) to 1
            activate
        end tell
        """
        _ = run(script)
    }

    /// Close a specific tab.
    static func closeTab(_ tab: SafariTab) {
        guard let fresh = locate(tab) else {
            log("closeTab: no match for url=\(tab.url) title=\(tab.title)")
            return
        }
        let script = """
        tell application "Safari"
            close tab \(fresh.tabIndex) of window \(fresh.windowIndex)
        end tell
        """
        _ = run(script)
    }

    /// Activate the first Safari tab whose URL matches.
    @discardableResult
    static func activate(url: String) -> Bool {
        guard let tab = findByURL(url) else {
            log("activate(url:) no match for \(url)")
            return false
        }
        activate(tab)
        return true
    }

    /// Close the first Safari tab whose URL matches.
    @discardableResult
    static func closeTab(url: String) -> Bool {
        guard let tab = findByURL(url) else {
            log("closeTab(url:) no match for \(url)")
            return false
        }
        closeTab(tab)
        return true
    }

    private static func findByURL(_ url: String) -> SafariTab? {
        fetchWindows().flatMap { $0.tabs }.first { $0.url == url }
    }

    /// Re-fetch Safari and find the current windowIndex/tabIndex for the given tab.
    private static func locate(_ tab: SafariTab) -> SafariTab? {
        let windows = fetchWindows()
        let all = windows.flatMap { $0.tabs }
        log("locate: fresh fetch has \(windows.count) windows, \(all.count) tabs")
        if let exact = all.first(where: { $0.url == tab.url && $0.title == tab.title }) {
            return exact
        }
        if let urlOnly = all.first(where: { $0.url == tab.url }) {
            log("locate: URL-only match (title differed)")
            return urlOnly
        }
        log("locate: no match. Fresh URLs: \(all.map { $0.url }.prefix(20))")
        return nil
    }

    private static let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SafariTabs.log")
    }()

    private static func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        NSLog("SafariTabs: \(msg)")
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("SafariBridge AppleScript error: \(error)")
            return nil
        }
        return result
    }
}

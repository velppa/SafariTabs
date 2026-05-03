import Foundation
import AppKit

enum SafariBridge {
    /// Enumerate every tab in every Safari window. Returns one SafariWindow per window.
    static func fetchWindows() -> [SafariWindow] {
        let script = """
        tell application "Safari"
            set out to {}
            repeat with w from 1 to count of windows
                set tabList to {}
                repeat with t from 1 to count of tabs of window w
                    set tabTitle to name of tab t of window w
                    set tabURL to URL of tab t of window w
                    set end of tabList to {tabTitle, tabURL, w, t}
                end repeat
                set end of out to tabList
            end repeat
            return out
        end tell
        """

        guard let descriptor = run(script) else { return [] }

        var windows: [SafariWindow] = []
        for w in 1...max(descriptor.numberOfItems, 0) {
            guard let tabsDesc = descriptor.atIndex(w) else { continue }
            var tabs: [SafariTab] = []
            for t in 1...max(tabsDesc.numberOfItems, 0) {
                guard
                    let row = tabsDesc.atIndex(t),
                    row.numberOfItems >= 4,
                    let title = row.atIndex(1)?.stringValue,
                    let url = row.atIndex(2)?.stringValue,
                    let wIdx = row.atIndex(3)?.int32Value,
                    let tIdx = row.atIndex(4)?.int32Value
                else { continue }
                tabs.append(SafariTab(
                    windowIndex: Int(wIdx),
                    tabIndex: Int(tIdx),
                    title: title,
                    url: url
                ))
            }
            if let first = tabs.first {
                windows.append(SafariWindow(index: first.windowIndex, tabs: tabs))
            }
        }
        return windows
    }

    /// Activate a specific tab and bring its window to front.
    static func activate(_ tab: SafariTab) {
        let script = """
        tell application "Safari"
            activate
            set current tab of window \(tab.windowIndex) to tab \(tab.tabIndex) of window \(tab.windowIndex)
            set index of window \(tab.windowIndex) to 1
        end tell
        """
        _ = run(script)
    }

    /// Close a specific tab.
    static func closeTab(_ tab: SafariTab) {
        let script = """
        tell application "Safari"
            close tab \(tab.tabIndex) of window \(tab.windowIndex)
        end tell
        """
        _ = run(script)
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

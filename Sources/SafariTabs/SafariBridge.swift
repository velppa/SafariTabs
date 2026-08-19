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
            var urlCounts: [String: Int] = [:]
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
                let occurrence = urlCounts[url, default: 0]
                urlCounts[url] = occurrence + 1
                tabs.append(SafariTab(
                    windowID: wID,
                    windowIndex: wIdx,
                    tabIndex: tIdx,
                    title: title,
                    url: url,
                    occurrence: occurrence
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
        log("activate: matched freshW=\(fresh.windowIndex) freshT=\(fresh.tabIndex) winID=\(fresh.windowID)")
        // Address the window by its stable id, not its z-order index. And
        // `set index to 1` only reorders the AppleScript list — on `activate`
        // macOS still fronts Safari's last-focused window, so activating a tab
        // in another window brought the wrong window forward. Cycling
        // `visible` is the one scripting hook that actually makes the target
        // window key.
        let script = """
        tell application "Safari"
            set current tab of window id \(fresh.windowID) to tab \(fresh.tabIndex) of window id \(fresh.windowID)
            set visible of window id \(fresh.windowID) to false
            set visible of window id \(fresh.windowID) to true
            activate
        end tell
        """
        _ = run(script)
    }

    /// What a close request actually did. `unknown` means Safari never
    /// replied (timeout) — the close may or may not have landed, so the
    /// caller must reconcile against a fresh fetch instead of assuming
    /// failure and re-closing a twin.
    enum CloseOutcome {
        case closed, notFound, unknown
    }

    /// Close a specific tab.
    @discardableResult
    static func closeTab(_ tab: SafariTab) -> CloseOutcome {
        close(windowID: tab.windowID, url: tab.url, occurrence: tab.occurrence)
    }

    /// Close one occurrence of a URL in a specific window, in a single
    /// AppleScript round-trip. Matching and closing inside one script
    /// removes the fetch-then-close-by-index race, and the window is
    /// addressed by its stable id, never by z-order. `occurrence` is
    /// 0-based; when fewer twins remain than remembered (an earlier one
    /// already closed and renumbered the rest), the last match is closed —
    /// twins show the same page, so any of them satisfies the request.
    static func close(windowID: Int, url: String, occurrence: Int) -> CloseOutcome {
        let script = """
        tell application "Safari"
            set matchIdx to {}
            repeat with t from 1 to count of tabs of window id \(windowID)
                if (URL of tab t of window id \(windowID)) as text is "\(escape(url))" then
                    set end of matchIdx to t
                end if
            end repeat
            if (count of matchIdx) is 0 then return "notfound"
            set target to \(occurrence + 1)
            if target > (count of matchIdx) then set target to (count of matchIdx)
            close tab (item target of matchIdx) of window id \(windowID)
            return "closed"
        end tell
        """
        guard let result = run(script) else {
            log("close: no reply for url=\(url) win=\(windowID) occ=\(occurrence)")
            return .unknown
        }
        let outcome: CloseOutcome = result.stringValue == "closed" ? .closed : .notFound
        log("close: \(outcome) url=\(url) win=\(windowID) occ=\(occurrence)")
        return outcome
    }

    /// Escape a string for embedding in an AppleScript string literal.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
        return closeTab(tab) != .notFound
    }

    private static func findByURL(_ url: String) -> SafariTab? {
        fetchWindows().flatMap { $0.tabs }.first { $0.url == url }
    }

    /// Re-fetch Safari and find the current windowIndex/tabIndex for the given tab.
    /// Ranks candidates instead of taking the first URL hit, so when the same
    /// page is open in several tabs we act on the one the user pointed at
    /// (same window, same position) rather than an arbitrary twin.
    private static func locate(_ tab: SafariTab) -> SafariTab? {
        let windows = fetchWindows()
        let all = windows.flatMap { $0.tabs }
        log("locate: fresh fetch has \(windows.count) windows, \(all.count) tabs")
        let byURL = all.filter { $0.url == tab.url }
        if let best = byURL.max(by: { score($0, against: tab) < score($1, against: tab) }) {
            if best.title != tab.title { log("locate: URL match (title differed)") }
            return best
        }
        // The page may have navigated since our fetch; fall back to the tab
        // sitting at the remembered position if at least the title agrees.
        if let sameSlot = all.first(where: {
            $0.windowID == tab.windowID && $0.tabIndex == tab.tabIndex && $0.title == tab.title
        }) {
            log("locate: positional match (URL changed)")
            return sameSlot
        }
        log("locate: no match. Fresh URLs: \(all.map { $0.url }.prefix(20))")
        return nil
    }

    private static func score(_ candidate: SafariTab, against tab: SafariTab) -> Int {
        var s = 0
        if candidate.windowID == tab.windowID { s += 4 }
        if candidate.tabIndex == tab.tabIndex { s += 2 }
        if candidate.title == tab.title { s += 1 }
        return s
    }

    private static let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SafariTabs.log")
    }()

    private static func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        // Tab titles and URLs routinely contain "%" sequences; never let them
        // reach NSLog as the format string or it parses them as specifiers.
        NSLog("%@", "SafariTabs: \(msg)")
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
        // Bound the wait for Safari's AppleEvent reply. The default is to
        // wait indefinitely, and a stalled Safari then wedges every caller
        // behind AppleScript's process-global lock.
        let bounded = """
        with timeout of 5 seconds
        \(source)
        end timeout
        """
        guard let script = NSAppleScript(source: bounded) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("%@", "SafariBridge AppleScript error: \(error)")
            return nil
        }
        return result
    }
}

import Foundation
import SwiftUI

@MainActor
final class TabsStore: ObservableObject {
    @Published var windows: [SafariWindow] = []
    @Published var query: String = ""
    @Published var lastRefresh: Date = .distantPast
    @Published private(set) var customNames: [Int: String] = [:]
    @Published private(set) var orderedWindowIDs: [Int] = []

    private var timer: Timer?

    /// The persisted drag order is intentionally discarded once per launch:
    /// the board starts alphabetized, and manual reordering takes over from
    /// there until the next launch.
    private var needsStartupSort = true

    /// Tabs the user just closed, with the time we issued the close.
    /// A periodic refresh can snapshot Safari before the async close commits;
    /// without this the closed tab would momentarily reappear. We filter these
    /// out of every fetch until Safari confirms (the tab drops out on its own)
    /// or the grace window lapses.
    ///
    /// Scoped to a window and consuming one occurrence each: a bare URL set
    /// would also hide an unrelated tab that happens to show the same page,
    /// which then "reappears" when the tombstone expires.
    struct PendingClose {
        let windowID: Int
        let url: String
        let at: Date
    }

    private var pendingCloses: [PendingClose] = []
    private let closeGrace: TimeInterval = 8

    private let namesKey = "SafariTabs.customNames"
    private let orderKey = "SafariTabs.windowOrder"

    init() {
        loadPersisted()
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Activate a tab in Safari. Always dispatched off the main thread:
    /// the AppleEvent blocks until Safari replies, and a busy Safari would
    /// otherwise beachball this app along with it.
    func activate(_ tab: SafariTab) {
        Task.detached(priority: .userInitiated) {
            SafariBridge.activate(tab)
        }
    }

    /// One fetch in flight at a time. AppleScript serializes all calls on a
    /// process-global lock, so when Safari stalls, a fetch per poll tick
    /// piles up threads that all wedge on that lock.
    private var refreshInFlight = false

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Task.detached(priority: .userInitiated) {
            let result = SafariBridge.fetchWindows()
            await MainActor.run {
                self.refreshInFlight = false
                let pruned = self.applyPendingCloses(result)
                if !pruned.isEmpty || self.windows.isEmpty {
                    // Assign only on real change: the 5s poll usually returns
                    // an identical snapshot, and republishing it makes the
                    // whole board repaint for nothing.
                    if pruned != self.windows {
                        withAnimation(.easeOut(duration: 0.15)) {
                            self.windows = pruned
                        }
                        if self.needsStartupSort, !pruned.isEmpty {
                            self.needsStartupSort = false
                            self.orderedWindowIDs = Self.nameSortedIDs(pruned, customNames: self.customNames)
                            self.persistOrder()
                        }
                        self.reconcileOrder()
                    }
                }
                self.lastRefresh = Date()
            }
        }
    }

    /// Drop tabs the user just closed from a fresh fetch, and purge tombstones
    /// once they expire (the close has long since committed by then).
    private func applyPendingCloses(_ wins: [SafariWindow]) -> [SafariWindow] {
        let now = Date()
        pendingCloses = pendingCloses.filter { now.timeIntervalSince($0.at) < closeGrace }
        return Self.prune(wins, pending: pendingCloses)
    }

    /// Remove, per tombstone, one tab with the matching URL from the matching
    /// window. Windows left empty are dropped.
    nonisolated static func prune(_ wins: [SafariWindow], pending: [PendingClose]) -> [SafariWindow] {
        guard !pending.isEmpty else { return wins }
        var budget: [String: Int] = [:]
        for p in pending {
            budget["\(p.windowID)|\(p.url)", default: 0] += 1
        }
        return wins.compactMap { w in
            let kept = w.tabs.filter { tab in
                let key = "\(w.id)|\(tab.url)"
                guard let n = budget[key], n > 0 else { return true }
                budget[key] = n - 1
                return false
            }
            guard !kept.isEmpty else { return nil }
            return SafariWindow(id: w.id, index: w.index, tabs: kept)
        }
    }

    func filtered(_ window: SafariWindow) -> [SafariTab] {
        window.tabs.filter { $0.matches(query) }
    }

    /// Windows in user-defined display order.
    var displayWindows: [SafariWindow] {
        let map = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        var out: [SafariWindow] = []
        var seen = Set<Int>()
        for id in orderedWindowIDs {
            if let w = map[id] {
                out.append(w)
                seen.insert(id)
            }
        }
        for w in windows where !seen.contains(w.id) {
            out.append(w)
        }
        return out
    }

    /// Window IDs ordered by display name (custom name when set, "Window N"
    /// fallback), compared the way Finder sorts: case-insensitive and
    /// numeric-aware, so "Window 2" precedes "Window 10".
    nonisolated static func nameSortedIDs(_ windows: [SafariWindow], customNames: [Int: String]) -> [Int] {
        func name(_ w: SafariWindow) -> String {
            if let custom = customNames[w.id], !custom.isEmpty { return custom }
            return "Window \(w.index)"
        }
        return windows
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
            .map(\.id)
    }

    func displayName(for window: SafariWindow) -> String {
        if let custom = customNames[window.id], !custom.isEmpty { return custom }
        return "Window \(window.index)"
    }

    func rename(_ windowID: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customNames.removeValue(forKey: windowID)
        } else {
            customNames[windowID] = trimmed
        }
        persistNames()
    }

    /// Move the window with `sourceID` to the position currently held by `targetID`.
    func moveWindow(sourceID: Int, before targetID: Int) {
        guard sourceID != targetID else { return }
        var order = currentOrderIDs()
        order.removeAll { $0 == sourceID }
        guard let targetIdx = order.firstIndex(of: targetID) else { return }
        order.insert(sourceID, at: targetIdx)
        orderedWindowIDs = order
        persistOrder()
    }

    func moveWindow(sourceID: Int, after targetID: Int) {
        guard sourceID != targetID else { return }
        var order = currentOrderIDs()
        order.removeAll { $0 == sourceID }
        guard let targetIdx = order.firstIndex(of: targetID) else { return }
        order.insert(sourceID, at: targetIdx + 1)
        orderedWindowIDs = order
        persistOrder()
    }

    /// Close a tab: tombstone it, drop it optimistically, then close in Safari
    /// and re-sync once Safari confirms. If the close fails, retract the
    /// tombstone right away — the tab is still open, and it should come back
    /// on the next refresh instead of popping in when the grace lapses.
    func close(_ tab: SafariTab) {
        pendingCloses.append(PendingClose(windowID: tab.windowID, url: tab.url, at: Date()))
        withAnimation(.easeOut(duration: 0.15)) {
            windows = windows.compactMap { window in
                let kept = window.tabs.filter { $0.id != tab.id }
                guard !kept.isEmpty else { return nil }
                return SafariWindow(id: window.id, index: window.index, tabs: kept)
            }
        }
        reconcileOrder()
        Task.detached {
            let ok = SafariBridge.closeTab(tab)
            await MainActor.run {
                if !ok { self.retractPendingClose(windowID: tab.windowID, url: tab.url) }
                self.refresh()
            }
        }
    }

    func closeByURL(_ url: String) {
        // Route through close(_:) when we know the tab, so the tombstone is
        // window-scoped and only one occurrence disappears.
        if let tab = windows.flatMap(\.tabs).first(where: { $0.url == url }) {
            close(tab)
            return
        }
        Task.detached {
            SafariBridge.closeTab(url: url)
            await MainActor.run { self.refresh() }
        }
    }

    private func retractPendingClose(windowID: Int, url: String) {
        if let i = pendingCloses.lastIndex(where: { $0.windowID == windowID && $0.url == url }) {
            pendingCloses.remove(at: i)
        }
    }

    var totalCount: Int { windows.reduce(0) { $0 + $1.tabs.count } }

    var matchCount: Int {
        windows.reduce(0) { $0 + $1.tabs.filter { $0.matches(query) }.count }
    }

    private func currentOrderIDs() -> [Int] {
        displayWindows.map(\.id)
    }

    private func reconcileOrder() {
        let liveIDs = Set(windows.map(\.id))
        var order = orderedWindowIDs.filter { liveIDs.contains($0) }
        for w in windows where !order.contains(w.id) {
            order.append(w.id)
        }
        if order != orderedWindowIDs {
            orderedWindowIDs = order
            persistOrder()
        }
    }

    private func loadPersisted() {
        let d = UserDefaults.standard
        if let dict = d.dictionary(forKey: namesKey) as? [String: String] {
            var out: [Int: String] = [:]
            for (k, v) in dict { if let i = Int(k) { out[i] = v } }
            customNames = out
        }
        if let arr = d.array(forKey: orderKey) as? [Int] {
            orderedWindowIDs = arr
        }
    }

    private func persistNames() {
        let dict = Dictionary(uniqueKeysWithValues: customNames.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(dict, forKey: namesKey)
    }

    private func persistOrder() {
        UserDefaults.standard.set(orderedWindowIDs, forKey: orderKey)
    }
}

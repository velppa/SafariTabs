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
    /// without this the closed tab would momentarily reappear.
    ///
    /// `expectedRemaining` is how many tabs with this URL the window should
    /// hold once the close commits. A fetch is only corrected down to that
    /// number — hiding a fixed count instead would eat a surviving twin
    /// whenever the fetch already reflects the close. Once a fetch shows the
    /// expected number, Safari has confirmed and the tombstone is dropped;
    /// the grace window is the fallback for a close that never commits.
    struct PendingClose {
        let windowID: Int
        let url: String
        let expectedRemaining: Int
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

    /// Drop tabs the user just closed from a fresh fetch. Tombstones Safari
    /// has confirmed are retired; unconfirmed ones expire with the grace.
    private func applyPendingCloses(_ wins: [SafariWindow]) -> [SafariWindow] {
        let now = Date()
        pendingCloses = pendingCloses.filter { now.timeIntervalSince($0.at) < closeGrace }
        let (pruned, still) = Self.prune(wins, pending: pendingCloses)
        pendingCloses = still
        return pruned
    }

    /// Correct a fresh fetch down to each tombstone's expected tab count:
    /// hide only the surplus over `expectedRemaining`, never a fixed count,
    /// so a fetch that already reflects the close hides nothing. Surplus is
    /// hidden from the tail, keeping the surviving twins' ids (and rows)
    /// stable. Windows left empty are dropped. Returns the corrected windows
    /// and the tombstones not yet confirmed by this fetch.
    nonisolated static func prune(
        _ wins: [SafariWindow], pending: [PendingClose]
    ) -> ([SafariWindow], [PendingClose]) {
        guard !pending.isEmpty else { return (wins, pending) }
        var expected: [String: Int] = [:]
        for p in pending {
            let key = "\(p.windowID)|\(p.url)"
            expected[key] = min(expected[key] ?? Int.max, p.expectedRemaining)
        }
        var counts: [String: Int] = [:]
        for w in wins {
            for t in w.tabs { counts["\(w.id)|\(t.url)", default: 0] += 1 }
        }
        var surplus: [String: Int] = [:]
        for (key, exp) in expected {
            surplus[key] = max(0, (counts[key] ?? 0) - exp)
        }
        let out: [SafariWindow] = wins.compactMap { w in
            var kept: [SafariTab] = []
            for tab in w.tabs.reversed() {
                let key = "\(w.id)|\(tab.url)"
                if let n = surplus[key], n > 0 {
                    surplus[key] = n - 1
                } else {
                    kept.append(tab)
                }
            }
            guard !kept.isEmpty else { return nil }
            return SafariWindow(id: w.id, index: w.index, tabs: kept.reversed())
        }
        let still = pending.filter { p in
            let key = "\(p.windowID)|\(p.url)"
            return (counts[key] ?? 0) > (expected[key] ?? 0)
        }
        return (out, still)
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
    /// and re-sync once Safari confirms. Retract the tombstone only when
    /// Safari definitely had no such tab; on a timeout the close may still
    /// have landed, and retracting would show the tab as alive and bait a
    /// second close that kills an unrelated twin.
    func close(_ tab: SafariTab) {
        let matches = windows.first(where: { $0.id == tab.windowID })?
            .tabs.filter { $0.url == tab.url }.count ?? 1
        pendingCloses.append(PendingClose(
            windowID: tab.windowID, url: tab.url,
            expectedRemaining: max(0, matches - 1), at: Date()))
        withAnimation(.easeOut(duration: 0.15)) {
            windows = windows.compactMap { window in
                let kept = window.tabs.filter { $0.id != tab.id }
                guard !kept.isEmpty else { return nil }
                return SafariWindow(id: window.id, index: window.index, tabs: kept)
            }
        }
        reconcileOrder()
        Task.detached {
            let outcome = SafariBridge.closeTab(tab)
            await MainActor.run {
                if outcome == .notFound {
                    self.retractPendingClose(windowID: tab.windowID, url: tab.url)
                }
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

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

    /// URLs of tabs the user just closed, with the time we issued the close.
    /// A periodic refresh can snapshot Safari before the async close commits;
    /// without this the closed tab would momentarily reappear. We filter these
    /// out of every fetch until Safari confirms (the URL drops out on its own)
    /// or the grace window lapses.
    private var pendingCloses: [String: Date] = [:]
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

    func refresh() {
        Task.detached(priority: .userInitiated) {
            let result = SafariBridge.fetchWindows()
            await MainActor.run {
                let pruned = self.applyPendingCloses(result)
                if !pruned.isEmpty || self.windows.isEmpty {
                    self.windows = pruned
                    self.reconcileOrder()
                }
                self.lastRefresh = Date()
            }
        }
    }

    /// Drop tabs the user just closed from a fresh fetch, and purge tombstones
    /// once they expire (the close has long since committed by then).
    private func applyPendingCloses(_ wins: [SafariWindow]) -> [SafariWindow] {
        let now = Date()
        pendingCloses = pendingCloses.filter { now.timeIntervalSince($0.value) < closeGrace }
        guard !pendingCloses.isEmpty else { return wins }
        let dead = Set(pendingCloses.keys)
        return wins.compactMap { w in
            let kept = w.tabs.filter { !dead.contains($0.url) }
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
    /// and re-sync once Safari confirms.
    func close(_ tab: SafariTab) {
        pendingCloses[tab.url] = Date()
        windows = windows.compactMap { window in
            let kept = window.tabs.filter { $0.id != tab.id }
            guard !kept.isEmpty else { return nil }
            return SafariWindow(id: window.id, index: window.index, tabs: kept)
        }
        reconcileOrder()
        Task.detached {
            SafariBridge.closeTab(tab)
            await MainActor.run { self.refresh() }
        }
    }

    func closeByURL(_ url: String) {
        pendingCloses[url] = Date()
        windows = windows.compactMap { window in
            let kept = window.tabs.filter { $0.url != url }
            guard !kept.isEmpty else { return nil }
            return SafariWindow(id: window.id, index: window.index, tabs: kept)
        }
        reconcileOrder()
        Task.detached {
            SafariBridge.closeTab(url: url)
            await MainActor.run { self.refresh() }
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

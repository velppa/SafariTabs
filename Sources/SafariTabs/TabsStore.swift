import Foundation
import SwiftUI

@MainActor
final class TabsStore: ObservableObject {
    @Published var windows: [SafariWindow] = []
    @Published var query: String = ""
    @Published var lastRefresh: Date = .distantPast

    private var timer: Timer?

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
                // Don't blank the UI on a transient empty fetch (Safari mid-transition).
                // Only commit when we got something, OR when we're confident Safari truly has no windows.
                if !result.isEmpty || self.windows.isEmpty {
                    self.windows = result
                }
                self.lastRefresh = Date()
            }
        }
    }

    func filtered(_ window: SafariWindow) -> [SafariTab] {
        window.tabs.filter { $0.matches(query) }
    }

    /// Optimistic local removal — drops the tab from the in-memory list so the
    /// UI updates immediately. Safari's authoritative state is reconciled on
    /// the next refresh.
    func remove(_ tabID: SafariTab.ID) {
        windows = windows.compactMap { window in
            let kept = window.tabs.filter { $0.id != tabID }
            guard !kept.isEmpty else { return nil }
            return SafariWindow(id: window.id, index: window.index, tabs: kept)
        }
    }

    func removeByURL(_ url: String) {
        windows = windows.compactMap { window in
            let kept = window.tabs.filter { $0.url != url }
            guard !kept.isEmpty else { return nil }
            return SafariWindow(id: window.id, index: window.index, tabs: kept)
        }
    }

    var totalCount: Int { windows.reduce(0) { $0 + $1.tabs.count } }

    var matchCount: Int {
        windows.reduce(0) { $0 + $1.tabs.filter { $0.matches(query) }.count }
    }
}

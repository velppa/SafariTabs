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
                self.windows = result
                self.lastRefresh = Date()
            }
        }
    }

    func filtered(_ window: SafariWindow) -> [SafariTab] {
        window.tabs.filter { $0.matches(query) }
    }

    var totalCount: Int { windows.reduce(0) { $0 + $1.tabs.count } }

    var matchCount: Int {
        windows.reduce(0) { $0 + $1.tabs.filter { $0.matches(query) }.count }
    }
}

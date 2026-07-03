import Foundation

struct SafariTab: Identifiable, Hashable {
    let windowID: Int
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String
    /// Which duplicate of this URL within its window this tab is (0-based).
    /// Part of identity so two tabs on the same page stay distinct.
    let occurrence: Int

    /// Identity must survive index shifts: closing a tab renumbers every tab
    /// below it, and index-based ids would make SwiftUI recreate those rows
    /// (visible as flicker instead of a smooth removal).
    var id: String { "\(windowID)|\(url)#\(occurrence)" }

    var domain: String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return title.lowercased().contains(q) || url.lowercased().contains(q)
    }
}

struct SafariWindow: Identifiable, Hashable {
    let id: Int
    let index: Int
    let tabs: [SafariTab]

    var title: String { "Window \(index)" }
}

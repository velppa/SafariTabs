import Foundation

struct SafariTab: Identifiable, Hashable {
    let windowID: Int
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String

    var id: String { "\(windowID):\(tabIndex)" }

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

import Foundation

struct SafariTab: Identifiable, Hashable {
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String

    var id: String { "\(windowIndex):\(tabIndex)" }

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
    let index: Int
    let tabs: [SafariTab]

    var id: Int { index }
    var title: String { "Window \(index)" }
}

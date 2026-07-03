import Foundation

/// In-binary test suite, run via the `self-test` CLI subcommand. The Command
/// Line Tools toolchain ships without XCTest/Testing, so assertions live in
/// the executable itself.
enum SelfTest {
    private static var failures: [String] = []

    private static func expect(
        _ ok: Bool, _ label: String,
        file: String = #fileID, line: Int = #line
    ) {
        if !ok { failures.append("\(file):\(line): \(label)") }
    }

    private static func tab(
        _ win: Int, _ idx: Int, _ url: String, occurrence: Int = 0
    ) -> SafariTab {
        SafariTab(windowID: win, windowIndex: win, tabIndex: idx,
                  title: "t\(idx)", url: url, occurrence: occurrence)
    }

    private static func window(_ id: Int, _ tabs: [SafariTab]) -> SafariWindow {
        SafariWindow(id: id, index: id, tabs: tabs)
    }

    static func run() -> Never {
        // Closing one of two same-URL tabs in a window must hide exactly
        // one, not both.
        do {
            let wins = [window(1, [
                tab(1, 1, "https://a.com", occurrence: 0),
                tab(1, 2, "https://a.com", occurrence: 1),
                tab(1, 3, "https://b.com"),
            ])]
            let pruned = TabsStore.prune(
                wins, pending: [.init(windowID: 1, url: "https://a.com", at: Date())])
            expect(pruned[0].tabs.count == 2, "prune removes single occurrence")
            expect(pruned[0].tabs.filter { $0.url == "https://a.com" }.count == 1,
                   "one duplicate survives")
        }

        // A tombstone in window 1 must not hide the same URL open in window 2.
        do {
            let wins = [
                window(1, [tab(1, 1, "https://a.com")]),
                window(2, [tab(2, 1, "https://a.com"), tab(2, 2, "https://b.com")]),
            ]
            let pruned = TabsStore.prune(
                wins, pending: [.init(windowID: 1, url: "https://a.com", at: Date())])
            expect(pruned.count == 1, "emptied window dropped")
            expect(pruned.first?.id == 2, "other window kept")
            expect(pruned.first?.tabs.count == 2, "twin URL in other window kept")
        }

        // Two tombstones for the same URL hide two occurrences.
        do {
            let wins = [window(1, [
                tab(1, 1, "https://a.com", occurrence: 0),
                tab(1, 2, "https://a.com", occurrence: 1),
                tab(1, 3, "https://b.com"),
            ])]
            let pending: [TabsStore.PendingClose] = [
                .init(windowID: 1, url: "https://a.com", at: Date()),
                .init(windowID: 1, url: "https://a.com", at: Date()),
            ]
            let pruned = TabsStore.prune(wins, pending: pending)
            expect(pruned.first?.tabs.map(\.url) == ["https://b.com"],
                   "two tombstones hide two occurrences")
        }

        // Tab identity must not depend on tabIndex: closing a tab above
        // shifts indexes of the tabs below, and their rows must not be
        // recreated.
        do {
            let before = tab(1, 5, "https://a.com")
            let after = tab(1, 4, "https://a.com")
            expect(before.id == after.id, "id stable across index shift")
        }

        // Same URL twice in one window must still yield distinct IDs.
        do {
            let first = tab(1, 1, "https://a.com", occurrence: 0)
            let second = tab(1, 2, "https://a.com", occurrence: 1)
            expect(first.id != second.id, "duplicate URLs have distinct ids")
        }

        if failures.isEmpty {
            print("self-test: all checks passed")
            exit(0)
        }
        for f in failures { FileHandle.standardError.write(Data("FAIL \(f)\n".utf8)) }
        exit(1)
    }
}

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
        // A fetch that still shows both twins is corrected down to the
        // expected count: exactly one hidden, the earlier twin survives.
        do {
            let wins = [window(1, [
                tab(1, 1, "https://a.com", occurrence: 0),
                tab(1, 2, "https://a.com", occurrence: 1),
                tab(1, 3, "https://b.com"),
            ])]
            let (pruned, still) = TabsStore.prune(
                wins,
                pending: [.init(windowID: 1, url: "https://a.com",
                                expectedRemaining: 1, at: Date())])
            expect(pruned[0].tabs.count == 2, "prune hides single surplus tab")
            expect(pruned[0].tabs.filter { $0.url == "https://a.com" }.count == 1,
                   "one duplicate survives")
            expect(pruned[0].tabs.first?.occurrence == 0, "earlier twin kept")
            expect(still.count == 1, "unconfirmed tombstone kept")
        }

        // A fetch that already reflects the close must not eat the surviving
        // twin, and the confirmed tombstone retires.
        do {
            let wins = [window(1, [
                tab(1, 1, "https://a.com", occurrence: 0),
                tab(1, 2, "https://b.com"),
            ])]
            let (pruned, still) = TabsStore.prune(
                wins,
                pending: [.init(windowID: 1, url: "https://a.com",
                                expectedRemaining: 1, at: Date())])
            expect(pruned[0].tabs.count == 2, "confirmed close hides nothing")
            expect(still.isEmpty, "confirmed tombstone retired")
        }

        // A tombstone in window 1 must not hide the same URL open in window 2.
        do {
            let wins = [
                window(1, [tab(1, 1, "https://a.com")]),
                window(2, [tab(2, 1, "https://a.com"), tab(2, 2, "https://b.com")]),
            ]
            let (pruned, _) = TabsStore.prune(
                wins,
                pending: [.init(windowID: 1, url: "https://a.com",
                                expectedRemaining: 0, at: Date())])
            expect(pruned.count == 1, "emptied window dropped")
            expect(pruned.first?.id == 2, "other window kept")
            expect(pruned.first?.tabs.count == 2, "twin URL in other window kept")
        }

        // Two quick closes of the same URL: the lower expectation wins and
        // the fetch is corrected down to it.
        do {
            let wins = [window(1, [
                tab(1, 1, "https://a.com", occurrence: 0),
                tab(1, 2, "https://a.com", occurrence: 1),
                tab(1, 3, "https://b.com"),
            ])]
            let pending: [TabsStore.PendingClose] = [
                .init(windowID: 1, url: "https://a.com", expectedRemaining: 1, at: Date()),
                .init(windowID: 1, url: "https://a.com", expectedRemaining: 0, at: Date()),
            ]
            let (pruned, _) = TabsStore.prune(wins, pending: pending)
            expect(pruned.first?.tabs.map(\.url) == ["https://b.com"],
                   "two closes hide both twins")
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

        // Startup order: windows sort by display name — custom name when set,
        // "Window N" fallback otherwise — with numeric-aware comparison.
        do {
            let wins = [
                window(3, [tab(3, 1, "https://c.com")]),
                window(1, [tab(1, 1, "https://a.com")]),
                window(2, [tab(2, 1, "https://b.com")]),
                window(10, [tab(10, 1, "https://d.com")]),
            ]
            let ids = TabsStore.nameSortedIDs(wins, customNames: [3: "Alpha", 2: "beta"])
            // Alpha(3), beta(2), Window 1(1), Window 10(10)
            expect(ids == [3, 2, 1, 10], "startup sort by name, case-insensitive, numeric-aware")
        }

        // URLs are embedded in AppleScript string literals; quotes and
        // backslashes must survive the trip.
        do {
            expect(SafariBridge.escape(#"a"b\c"#) == #"a\"b\\c"#,
                   "escape quotes and backslashes for AppleScript")
            expect(SafariBridge.escape("https://a.com/?q=1") == "https://a.com/?q=1",
                   "plain URL unchanged")
        }

        if failures.isEmpty {
            print("self-test: all checks passed")
            exit(0)
        }
        for f in failures { FileHandle.standardError.write(Data("FAIL \(f)\n".utf8)) }
        exit(1)
    }
}

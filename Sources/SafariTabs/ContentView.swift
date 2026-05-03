import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: TabsStore
    @State private var selection: SafariTab.ID?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if store.windows.isEmpty {
                emptyState
            } else {
                columns
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search tabs", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
            if !store.query.isEmpty {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var columns: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(store.windows.enumerated()), id: \.element.id) { idx, window in
                    WindowColumn(window: window, columnNumber: idx + 1, selection: $selection)
                        .frame(width: 320)
                    Divider()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Safari windows open")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Open Safari, then press ⌘R to refresh.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if store.query.isEmpty {
                Text("\(store.totalCount) tabs in \(store.windows.count) windows")
            } else {
                Text("\(store.matchCount) of \(store.totalCount) match")
            }
            Spacer()
            Text("Updated \(store.lastRefresh, style: .time)")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct WindowColumn: View {
    let window: SafariWindow
    let columnNumber: Int
    @Binding var selection: SafariTab.ID?
    @EnvironmentObject var store: TabsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("⌘\(columnNumber)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(window.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(filtered.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(filtered) { tab in
                        TabRow(tab: tab)
                            .tag(tab.id as SafariTab.ID?)
                            .id(tab.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                SafariBridge.activate(tab)
                            }
                            .contextMenu {
                                Button("Activate") { SafariBridge.activate(tab) }
                                Button("Copy URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(tab.url, forType: .string)
                                }
                                Divider()
                                Button("Close Tab", role: .destructive) {
                                    SafariBridge.closeTab(tab)
                                    store.refresh()
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .onChange(of: store.query) { _ in
                    if let first = filtered.first {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
        }
    }

    private var filtered: [SafariTab] { store.filtered(window) }
}

private struct TabRow: View {
    let tab: SafariTab

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title.isEmpty ? "Untitled" : tab.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(tab.domain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

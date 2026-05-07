import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: TabsStore
    @State private var selection: SafariTab.ID?
    @State private var renamingWindowID: Int?
    @State private var draggingWindowID: Int?

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
        GeometryReader { geo in
            // Each swimlane is 1/3 of the active window width, capped at
            // 1/6 of the current display so a maximized window fits 6
            // swimlanes and a half-screen window fits 3 — on any resolution.
            let screenW = NSScreen.main?.frame.width ?? 1920
            let columnWidth = max(220, min(geo.size.width / 3, screenW / 6))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(store.displayWindows.enumerated()), id: \.element.id) { idx, window in
                            WindowColumn(
                                window: window,
                                columnNumber: idx + 1,
                                selection: $selection,
                                renamingWindowID: $renamingWindowID,
                                draggingWindowID: $draggingWindowID
                            )
                            .frame(width: columnWidth)
                            .id(window.id)
                            Divider()
                        }
                    }
                }
                .background(shortcuts(proxy: proxy))
            }
        }
    }

    @ViewBuilder
    private func shortcuts(proxy: ScrollViewProxy) -> some View {
        Group {
            ForEach(1...9, id: \.self) { n in
                Button("") { focusWindow(n, proxy: proxy) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Button("") { moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { moveSelection(by: +1) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("") { moveColumn(by: -1, proxy: proxy) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { moveColumn(by: +1, proxy: proxy) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { activateSelected() }
                .keyboardShortcut(.return, modifiers: [])
            Button("") { closeSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func moveSelection(by delta: Int) {
        guard !store.windows.isEmpty else { return }
        let windowAndTabs: (SafariWindow, [SafariTab])? = {
            if let sel = selection,
               let win = store.windows.first(where: { $0.tabs.contains(where: { $0.id == sel }) }) {
                return (win, store.filtered(win))
            }
            let first = store.displayWindows[0]
            return (first, store.filtered(first))
        }()
        guard let (_, tabs) = windowAndTabs, !tabs.isEmpty else { return }
        let currentIdx = tabs.firstIndex(where: { $0.id == selection }) ?? -1
        let nextIdx = max(0, min(tabs.count - 1, currentIdx + delta))
        selection = tabs[nextIdx].id
    }

    private func moveColumn(by delta: Int, proxy: ScrollViewProxy) {
        let display = store.displayWindows
        guard !display.isEmpty else { return }
        let currentIdx: Int = {
            if let sel = selection,
               let i = display.firstIndex(where: { $0.tabs.contains(where: { $0.id == sel }) }) {
                return i
            }
            return 0
        }()
        let nextIdx = max(0, min(display.count - 1, currentIdx + delta))
        focusWindow(nextIdx + 1, proxy: proxy)
    }

    private func activateSelected() {
        guard let sel = selection,
              let tab = store.windows.flatMap({ $0.tabs }).first(where: { $0.id == sel })
        else { return }
        SafariBridge.activate(tab)
    }

    private func closeSelected() {
        guard let sel = selection,
              let win = store.windows.first(where: { $0.tabs.contains(where: { $0.id == sel }) }),
              let tab = win.tabs.first(where: { $0.id == sel })
        else { return }
        let visible = store.filtered(win)
        let nextID: SafariTab.ID? = {
            guard let i = visible.firstIndex(where: { $0.id == sel }) else { return nil }
            if i + 1 < visible.count { return visible[i + 1].id }
            if i - 1 >= 0 { return visible[i - 1].id }
            return nil
        }()
        store.remove(tab.id)
        selection = nextID
        Task.detached { SafariBridge.closeTab(tab) }
    }

    private func focusWindow(_ n: Int, proxy: ScrollViewProxy) {
        let display = store.displayWindows
        guard n >= 1, n <= display.count else { return }
        let window = display[n - 1]
        if let firstTab = store.filtered(window).first ?? window.tabs.first {
            selection = firstTab.id
        }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(window.id, anchor: nil)
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
    @Binding var renamingWindowID: Int?
    @Binding var draggingWindowID: Int?
    @EnvironmentObject var store: TabsStore
    @State private var lastClick: (id: SafariTab.ID, at: Date)?
    @State private var renameText: String = ""
    @State private var isDropTarget: Bool = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            tabList
        }
        .opacity(draggingWindowID == window.id ? 0.4 : 1.0)
        .overlay(alignment: .leading) {
            if isDropTarget {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
        }
        .onDrop(
            of: [UTType.text],
            delegate: WindowDropDelegate(
                targetID: window.id,
                store: store,
                isTargeted: $isDropTarget,
                draggingWindowID: $draggingWindowID
            )
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("⌘\(columnNumber)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            if renamingWindowID == window.id {
                TextField("", text: $renameText, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .focused($renameFocused)
                    .onAppear {
                        renameText = store.displayName(for: window)
                        renameFocused = true
                    }
                    .onExitCommand { cancelRename() }
                    .onSubmit { commitRename() }
            } else {
                Text(store.displayName(for: window))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) { beginRename() }
            }
            Spacer()
            Text("\(filtered.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename Window") { beginRename() }
            if store.displayName(for: window) != "Window \(window.index)" {
                Button("Reset Name") { store.rename(window.id, to: "") }
            }
        }
        .onDrag {
            draggingWindowID = window.id
            return NSItemProvider(object: "\(window.id)" as NSString)
        }
    }

    private var tabList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { tab in
                        TabRow(tab: tab, isSelected: selection == tab.id, onClose: {
                            closeTab(tab)
                        })
                            .id(tab.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let now = Date()
                                if let last = lastClick,
                                   last.id == tab.id,
                                   now.timeIntervalSince(last.at) < 0.4 {
                                    SafariBridge.activate(tab)
                                    lastClick = nil
                                } else {
                                    selection = tab.id
                                    lastClick = (tab.id, now)
                                }
                            }
                            .contextMenu {
                                Button("Activate") { SafariBridge.activate(tab) }
                                Button("Copy URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(tab.url, forType: .string)
                                }
                                Divider()
                                Button("Close Tab", role: .destructive) {
                                    closeTab(tab)
                                }
                            }
                    }
                }
            }
            .onChange(of: store.query) { _ in
                if let first = filtered.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
            .onChange(of: selection) { newValue in
                guard let id = newValue,
                      filtered.contains(where: { $0.id == id })
                else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var filtered: [SafariTab] { store.filtered(window) }

    private func beginRename() {
        renameText = store.displayName(for: window)
        renamingWindowID = window.id
    }

    private func commitRename() {
        guard renamingWindowID == window.id else { return }
        store.rename(window.id, to: renameText)
        renamingWindowID = nil
    }

    private func cancelRename() {
        renamingWindowID = nil
    }

    private func closeTab(_ tab: SafariTab) {
        let visible = filtered
        let nextID: SafariTab.ID? = {
            guard let i = visible.firstIndex(where: { $0.id == tab.id }) else { return nil }
            if i + 1 < visible.count { return visible[i + 1].id }
            if i - 1 >= 0 { return visible[i - 1].id }
            return nil
        }()
        store.remove(tab.id)
        if selection == tab.id { selection = nextID }
        Task.detached { SafariBridge.closeTab(tab) }
    }
}

private struct WindowDropDelegate: DropDelegate {
    let targetID: Int
    let store: TabsStore
    @Binding var isTargeted: Bool
    @Binding var draggingWindowID: Int?

    func dropEntered(info: DropInfo) {
        guard let src = draggingWindowID, src != targetID else { return }
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let src = Int(s) else { return }
            Task { @MainActor in
                store.moveWindow(sourceID: src, before: targetID)
                draggingWindowID = nil
            }
        }
        return true
    }
}

private struct TabRow: View {
    let tab: SafariTab
    let isSelected: Bool
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title.isEmpty ? "Untitled" : tab.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(tab.domain)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if isHovered || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(4)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .onHover { isHovered = $0 }
    }
}

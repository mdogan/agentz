import Foundation
import SwiftUI

enum RepositoryPathSelection {
    static func normalized(_ input: String) -> String? {
        normalizedSelection(
            input.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func normalizedSelection(_ input: String) -> String? {
        guard !input.isEmpty,
              !input.hasPrefix("/"),
              !input.contains("\0") else {
            return nil
        }

        var normalizedComponents: [Substring] = []
        for component in input.split(
            separator: "/",
            omittingEmptySubsequences: false
        ) {
            if component.isEmpty || component == "." {
                continue
            }
            guard component != ".." else { return nil }
            normalizedComponents.append(component)
        }

        guard !normalizedComponents.isEmpty else { return nil }
        return normalizedComponents.joined(separator: "/")
    }
}

enum RepositoryPathPickerSearch {
    static func filter(
        _ items: [RepositoryPathItem],
        query: String
    ) -> [RepositoryPathItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.path.localizedCaseInsensitiveContains(query)
        }
    }
}

enum RepositoryPathPickerNavigation {
    static func reconcile(
        selection: RepositoryPathItem?,
        items: [RepositoryPathItem]
    ) -> RepositoryPathItem? {
        if let selection, items.contains(selection) {
            return selection
        }
        return items.first
    }

    static func move(
        selection: RepositoryPathItem?,
        offset: Int,
        items: [RepositoryPathItem]
    ) -> RepositoryPathItem? {
        guard !items.isEmpty else { return nil }
        guard let selection,
              let index = items.firstIndex(of: selection) else {
            return offset < 0 ? items.last : items.first
        }

        let count = items.count
        let nextIndex = (index + offset % count + count) % count
        return items[nextIndex]
    }
}

struct PathHistoryPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RepositoryStore
    @FocusState private var isSearchFocused: Bool
    @State private var searchText = ""
    @State private var selectedItem: RepositoryPathItem?

    private var items: [RepositoryPathItem] {
        RepositoryPathPickerSearch.filter(
            store.repositoryPathItems,
            query: searchText
        )
    }

    private var typedPath: String? {
        RepositoryPathSelection.normalized(searchText)
    }

    private var hasExactItemForTypedPath: Bool {
        guard let typedPath else { return false }
        return store.repositoryPathItems.contains {
            $0.path == typedPath
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(GitForkTheme.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("File or Directory History")
                            .font(.title2.weight(.semibold))
                        Text(
                            "Choose a tracked path or type a repository-relative "
                                + "path. Commits come from \(store.pathHistoryReferenceName)."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }

                TextField("Search or enter a path", text: $searchText)
                    .focused($isSearchFocused)
                    .onSubmit {
                        showSelectedHistory()
                    }
                    .onKeyPress(
                        keys: [.escape, .upArrow, .downArrow]
                    ) { press in
                        if press.key == .escape {
                            dismiss()
                        } else if press.key == .upArrow {
                            moveSelection(by: -1)
                        } else {
                            moveSelection(by: 1)
                        }
                        return .handled
                    }
                    .lookField(isFocused: isSearchFocused, systemImage: "magnifyingglass")
            }
            .padding(20)

            Divider()

            Group {
                if store.isLoadingRepositoryPaths
                    && store.repositoryPathItems.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading repository paths…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if items.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Tracked Paths" : "No Matching Paths",
                        systemImage: searchText.isEmpty ? "doc" : "magnifyingglass",
                        description: Text(emptyDescription)
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(items) { item in
                                    let isSelected = selectedItem == item

                                    Button {
                                        showHistory(for: item.path)
                                    } label: {
                                        RepositoryPathPickerRow(
                                            item: item,
                                            isSelected: isSelected
                                        )
                                    }
                                    .buttonStyle(
                                        GitForkHoverButtonStyle(
                                            .row(isSelected: isSelected)
                                        )
                                    )
                                    .help("Show commit history for \(item.path)")
                                    .accessibilityAddTraits(
                                        isSelected ? .isSelected : []
                                    )
                                    .id(item.id)
                                }
                            }
                            .padding(12)
                        }
                        .onChange(of: selectedItem) { _, item in
                            guard let item else { return }
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(item.id)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                if let typedPath, !hasExactItemForTypedPath {
                    Button {
                        showHistory(for: typedPath)
                    } label: {
                        Label("Use “\(typedPath)”", systemImage: "text.cursor")
                            .lineLimit(1)
                    }
                    .help("Show history for the typed repository-relative path")
                }

                Spacer()

                HStack(spacing: 12) {
                    Text("↑↓ Navigate")
                    Text("↩ Open")
                    Text("esc Close")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Show History") {
                    showSelectedHistory()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedItem == nil && typedPath == nil)
            }
            .padding(16)
        }
        .frame(width: 620, height: 500)
        .onAppear {
            reconcileSelection()
            isSearchFocused = true
        }
        .onChange(of: searchText) {
            reconcileSelection()
        }
        .onChange(of: store.repositoryPathItems) {
            reconcileSelection()
        }
    }

    private var emptyDescription: String {
        if let typedPath {
            return "Press Return or choose Use “\(typedPath)” to search its history."
        }
        if searchText.isEmpty {
            return "This repository has no paths tracked in its index."
        }
        return "Enter a repository-relative path without “..”."
    }

    private func reconcileSelection() {
        selectedItem = RepositoryPathPickerNavigation.reconcile(
            selection: selectedItem,
            items: items
        )
    }

    private func moveSelection(by offset: Int) {
        selectedItem = RepositoryPathPickerNavigation.move(
            selection: selectedItem,
            offset: offset,
            items: items
        )
    }

    private func showSelectedHistory() {
        if let selectedItem {
            showHistory(for: selectedItem.path)
        } else if let typedPath {
            showHistory(for: typedPath)
        }
    }

    private func showHistory(for path: String) {
        dismiss()
        store.selectPathHistory(path)
    }
}

private struct RepositoryPathPickerRow: View {
    let item: RepositoryPathItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .directory ? "folder.fill" : "doc")
                .font(.title3)
                .foregroundStyle(
                    item.kind == .directory
                        ? GitForkTheme.accent
                        : .secondary
                )
                .frame(width: 24)

            Text(item.path)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(item.kind == .directory ? "Folder" : "File")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isSelected {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(GitForkTheme.accent)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

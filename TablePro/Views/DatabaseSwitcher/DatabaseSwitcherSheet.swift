//
//  DatabaseSwitcherSheet.swift
//  TablePro
//
//  Modal sheet to display and switch between databases.
//  Similar to TablePlus's "Open database" feature (Cmd+K).
//

import SwiftUI

/// Modal sheet to display available databases and switch between them
struct DatabaseSwitcherSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss
    let currentDatabase: String?
    let databaseType: DatabaseType
    let onSelect: (String) -> Void

    @State private var databases: [String] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedItem: String?
    @State private var shouldScrollToSelection = false

    var filteredDatabases: [String] {
        if searchText.isEmpty {
            return databases
        }
        return databases.filter {
            $0.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("Open database")
                .font(.system(size: DesignConstants.FontSize.body, weight: .semibold))
                .padding(.vertical, 12)

            Divider()

            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: DesignConstants.FontSize.body))

                TextField("Search for database...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: DesignConstants.FontSize.body))
                    .onSubmit {
                        openSelectedDatabase()
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, DesignConstants.Spacing.sm)

            Divider()

            // Database list or empty state
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if databaseType == .sqlite {
                sqliteEmptyState
            } else if filteredDatabases.isEmpty {
                emptyState
            } else {
                databaseListView
            }

            Divider()

            // Footer buttons
            footerView
        }
        .frame(width: 360, height: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadDatabases()
        }
        .onChange(of: searchText) { _, _ in
            // Reset selection when search changes
            selectedItem = filteredDatabases.first
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(up: true)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(up: false)
            return .handled
        }
        .onKeyPress(.return) {
            openSelectedDatabase()
            return .handled
        }
    }

    // MARK: - Database List

    private var databaseListView: some View {
        ScrollViewReader { proxy in
            List(filteredDatabases, id: \.self) { database in
                databaseRow(database)
                    .id(database)
                    .listRowSeparator(.hidden)
                    .listRowInsets(DesignConstants.swiftUIListRowInsets)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(database == selectedItem ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
                            .padding(.horizontal, 4)
                    )
                    .onTapGesture {
                        selectedItem = database
                    }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .environment(\.defaultMinListRowHeight, DesignConstants.RowHeight.compact)
            .onChange(of: filteredDatabases) { _, newList in
                // Reset selection when list changes
                if let selected = selectedItem, !newList.contains(selected) {
                    selectedItem = newList.first
                }
            }
            .onChange(of: selectedItem) { _, newValue in
                // Scroll to selected item when navigating with keyboard
                if let item = newValue {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(item, anchor: .center)
                    }
                }
            }
            .onChange(of: shouldScrollToSelection) { _, shouldScroll in
                // Scroll to selection after databases load
                if shouldScroll, let item = selectedItem {
                    shouldScrollToSelection = false

                    // Delay scroll to ensure List is fully rendered
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(item, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func databaseRow(_ database: String) -> some View {
        let isSelected = database == selectedItem
        let isCurrent = database == currentDatabase

        return HStack(spacing: 10) {
            Image(systemName: "cylinder")
                .font(.system(size: DesignConstants.FontSize.body))
                .foregroundStyle(isSelected ? .white : (isCurrent ? .blue : .secondary))

            Text(database)
                .font(.system(size: DesignConstants.FontSize.body))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)

            Spacer()

            if isCurrent {
                Text("current")
                    .font(.system(size: DesignConstants.FontSize.caption))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .contentShape(Rectangle())
        .overlay(
            DoubleClickView {
                selectedItem = database
                openSelectedDatabase()
            }
        )
    }

    // MARK: - Empty States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading databases...")
                .font(.system(size: DesignConstants.FontSize.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: DesignConstants.IconSize.extraLarge))
                .foregroundStyle(.orange)

            Text("Failed to load databases")
                .font(.system(size: DesignConstants.FontSize.body, weight: .medium))

            Text(message)
                .font(.system(size: DesignConstants.FontSize.small))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                loadDatabases()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sqliteEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: DesignConstants.IconSize.extraLarge))
                .foregroundStyle(.secondary)

            Text("SQLite is file-based")
                .font(.system(size: DesignConstants.FontSize.body, weight: .medium))

            Text("Each SQLite file is a separate database.\nTo open a different database, create a new connection.")
                .font(.system(size: DesignConstants.FontSize.small))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DesignConstants.IconSize.extraLarge))
                .foregroundStyle(.secondary)

            if searchText.isEmpty {
                Text("No databases found")
                    .font(.system(size: DesignConstants.FontSize.body, weight: .medium))
            } else {
                Text("No matching databases")
                    .font(.system(size: DesignConstants.FontSize.body, weight: .medium))

                Text("No databases match \"\(searchText)\"")
                    .font(.system(size: DesignConstants.FontSize.small))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }

            Spacer()

            Button("Open") {
                openSelectedDatabase()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedItem == nil || selectedItem == currentDatabase)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func moveSelection(up: Bool) {
        guard !filteredDatabases.isEmpty else { return }

        // Determine the current index only if the selected item exists in the filtered list
        if let selected = selectedItem,
           let currentIndex = filteredDatabases.firstIndex(of: selected) {
            if up {
                let newIndex = max(0, currentIndex - 1)
                selectedItem = filteredDatabases[newIndex]
            } else {
                let newIndex = min(filteredDatabases.count - 1, currentIndex + 1)
                selectedItem = filteredDatabases[newIndex]
            }
        } else {
            // No valid current selection; choose a sensible starting point
            selectedItem = up ? filteredDatabases.last : filteredDatabases.first
        }
    }

    private func loadDatabases() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                guard let driver = DatabaseManager.shared.activeDriver else {
                    await MainActor.run {
                        errorMessage = "No active connection"
                        isLoading = false
                    }
                    return
                }

                let result = try await driver.fetchDatabases()

                await MainActor.run {
                    databases = result
                    isLoading = false

                    // Pre-select current database if available
                    if let current = currentDatabase, result.contains(current) {
                        selectedItem = current
                    } else {
                        selectedItem = result.first
                    }

                    // Trigger scroll to selection and focus
                    shouldScrollToSelection = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func openSelectedDatabase() {
        guard let database = selectedItem else { return }

        // Don't reopen current database
        if database == currentDatabase {
            dismiss()
            return
        }

        onSelect(database)
        dismiss()
    }
}


// MARK: - DoubleClickView

/// NSViewRepresentable that detects double-clicks without interfering with native List selection
private struct DoubleClickView: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughDoubleClickView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PassThroughDoubleClickView)?.onDoubleClick = onDoubleClick
    }
}

private class PassThroughDoubleClickView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        }
        // Always forward to next responder for List selection
        super.mouseDown(with: event)
    }
}

// MARK: - Preview

#Preview("MySQL Databases") {
    DatabaseSwitcherSheet(
        isPresented: .constant(true),
        currentDatabase: "laravel",
        databaseType: .mysql
    )           { db in print("Selected: \(db)") }
}

#Preview("SQLite Empty") {
    DatabaseSwitcherSheet(
        isPresented: .constant(true),
        currentDatabase: nil,
        databaseType: .sqlite
    )           { db in print("Selected: \(db)") }
}

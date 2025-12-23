//
//  SidebarView.swift
//  OpenTable
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import SwiftUI

// MARK: - SidebarView

/// Sidebar view displaying list of database tables
struct SidebarView: View {
    @Binding var tables: [TableInfo]
    @Binding var selectedTables: Set<TableInfo>
    var activeTableName: String?
    var onOpenTable: ((String) -> Void)?
    var onShowAllTables: (() -> Void)?

    // Pending table operations
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    /// Prevents selection callback during programmatic updates (e.g., refresh)
    @State private var isRestoringSelection = false

    /// Whether the tables section is expanded
    @State private var isTablesExpanded = true

    /// Filtered tables based on search text
    private var filteredTables: [TableInfo] {
        guard !searchText.isEmpty else { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            content
        }
        .frame(minWidth: 280)
        .onChange(of: selectedTables) { oldTables, newTables in
            guard !isRestoringSelection else { return }
            let added = newTables.subtracting(oldTables)
            if let table = added.first {
                Task { @MainActor in
                    onOpenTable?(table.name)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .databaseDidConnect)) { _ in
            Task { @MainActor in
                loadTables()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshAll)) { _ in
            Task { @MainActor in
                loadTables()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .copyTableNames)) { _ in
            guard !selectedTables.isEmpty else { return }
            let names = selectedTables.map { $0.name }.sorted()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names.joined(separator: ","), forType: .string)
        }
        .onReceive(NotificationCenter.default.publisher(for: .truncateTables)) { _ in
            guard !selectedTables.isEmpty else { return }
            batchToggleTruncate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearSelection)) { _ in
            selectedTables.removeAll()
        }
        .onChange(of: tables) { _, newTables in
            // When tables become empty (disconnected), reset to loading state
            if newTables.isEmpty {
                // Defer state change to avoid publishing during view update
                Task { @MainActor in
                    isLoading = true
                }
            }
        }
        .onAppear {
            guard tables.isEmpty else { return }
            // Defer state changes to avoid publishing during view update
            Task { @MainActor in
                isLoading = true
                if DatabaseManager.shared.activeDriver != nil {
                    loadTables()
                }
            }
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            TextField("Filter", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Content States

    @ViewBuilder
    private var content: some View {
        if let error = errorMessage {
            errorState(message: error)
        } else if tables.isEmpty && isLoading {
            loadingState
        } else if tables.isEmpty {
            emptyState
        } else if filteredTables.isEmpty {
            noMatchState
        } else {
            tableList
        }
    }

    private var loadingState: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tablecells")
                .font(.title)
                .foregroundStyle(.tertiary)

            Text("No Tables")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Refresh") {
                loadTables()
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 20)
    }

    private var noMatchState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No matching tables")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Table List

    private var tableList: some View {
        List(selection: $selectedTables) {
            Section(isExpanded: $isTablesExpanded) {
                ForEach(filteredTables) { table in
                    TableRow(
                        table: table,
                        isActive: activeTableName == table.name,
                        isPendingTruncate: pendingTruncates.contains(table.name),
                        isPendingDelete: pendingDeletes.contains(table.name)
                    )
                    .tag(table)
                    .contextMenu {
                        tableContextMenu(for: table)
                    }
                }
            } header: {
                Button(action: {
                    onShowAllTables?()
                }) {
                    Text("Tables")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to show all tables with metadata")
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            batchToggleDelete()
        }
        .onExitCommand {
            selectedTables.removeAll()
        }
    }

    @ViewBuilder
    private func tableContextMenu(for table: TableInfo) -> some View {
        Button("Copy Name") {
            let names = selectedTables.isEmpty ? [table.name] : selectedTables.map { $0.name }.sorted()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names.joined(separator: ","), forType: .string)
        }
        .keyboardShortcut(KeyboardShortcuts.copy)

        Divider()

        Button("Truncate") {
            batchToggleTruncate()
        }
        .keyboardShortcut(KeyboardShortcuts.truncateTable)

        Button("Delete", role: .destructive) {
            batchToggleDelete()
        }
        .keyboardShortcut(KeyboardShortcuts.delete)
    }
    
    /// Batch toggle truncate for all selected tables
    private func batchToggleTruncate() {
        var updatedDeletes = pendingDeletes
        var updatedTruncates = pendingTruncates
        
        let tablesToToggle = selectedTables.isEmpty ? [] : selectedTables
        for table in tablesToToggle {
            updatedDeletes.remove(table.name)
            if updatedTruncates.contains(table.name) {
                updatedTruncates.remove(table.name)
            } else {
                updatedTruncates.insert(table.name)
            }
        }
        
        pendingDeletes = updatedDeletes
        pendingTruncates = updatedTruncates
    }
    
    /// Batch toggle delete for all selected tables
    private func batchToggleDelete() {
        var updatedDeletes = pendingDeletes
        var updatedTruncates = pendingTruncates
        
        let tablesToToggle = selectedTables.isEmpty ? [] : selectedTables
        for table in tablesToToggle {
            updatedTruncates.remove(table.name)
            if updatedDeletes.contains(table.name) {
                updatedDeletes.remove(table.name)
            } else {
                updatedDeletes.insert(table.name)
            }
        }
        
        pendingTruncates = updatedTruncates
        pendingDeletes = updatedDeletes
    }

    // MARK: - Actions

    private func loadTables() {
        isLoading = true
        errorMessage = nil
        Task {
            await loadTablesAsync()
        }
    }

    private func loadTablesAsync() async {
        let previousSelectedName = selectedTables.first?.name

        guard let driver = DatabaseManager.shared.activeDriver else {
            await MainActor.run { isLoading = false }
            return
        }

        do {
            let fetchedTables = try await driver.fetchTables()
            await MainActor.run {
                tables = fetchedTables
                // Only restore selection if it was cleared (prevent reopening tabs)
                if let name = previousSelectedName {
                    let currentNames = Set(selectedTables.map { $0.name })
                    if !currentNames.contains(name) {
                        // Selection was cleared, restore it without triggering callback
                        isRestoringSelection = true
                        if let restored = fetchedTables.first(where: { $0.name == name }) {
                            selectedTables = [restored]
                        }
                        isRestoringSelection = false
                    }
                }
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func toggleTruncate(_ tableName: String) {
        pendingDeletes.remove(tableName)
        if pendingTruncates.contains(tableName) {
            pendingTruncates.remove(tableName)
        } else {
            pendingTruncates.insert(tableName)
        }
    }

    private func toggleDelete(_ tableName: String) {
        pendingTruncates.remove(tableName)
        if pendingDeletes.contains(tableName) {
            pendingDeletes.remove(tableName)
            print("DEBUG: Removed \(tableName) from pendingDeletes")
        } else {
            pendingDeletes.insert(tableName)
            print("DEBUG: Inserted \(tableName) into pendingDeletes, count: \(pendingDeletes.count)")
        }
    }
}

// MARK: - TableRow

/// Row view for a single table
struct TableRow: View {
    let table: TableInfo
    let isActive: Bool
    let isPendingTruncate: Bool
    let isPendingDelete: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Icon with status indicator
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: table.type == .view ? "eye" : "tablecells")
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                // Pending operation indicator
                if isPendingDelete {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .offset(x: 4, y: 4)
                } else if isPendingTruncate {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .offset(x: 4, y: 4)
                }
            }

            Text(table.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(textColor)
        }
        .padding(.vertical, 2)
    }

    private var iconColor: Color {
        if isPendingDelete { return .red }
        if isPendingTruncate { return .orange }
        return table.type == .view ? .purple : .blue
    }

    private var textColor: Color {
        if isPendingDelete { return .red }
        if isPendingTruncate { return .orange }
        return .primary
    }
}

// MARK: - Preview

#Preview {
    SidebarView(
        tables: .constant([]),
        selectedTables: .constant([]),
        pendingTruncates: .constant([]),
        pendingDeletes: .constant([])
    )
    .frame(width: 250, height: 400)
}

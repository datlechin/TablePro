//
//  SidebarView.swift
//  TablePro
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
    var onTablePro: ((String) -> Void)?
    var onShowAllTables: (() -> Void)?

    // Pending table operations
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>
    @Binding var tableOperationOptions: [String: TableOperationOptions]
    let databaseType: DatabaseType

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    /// Prevents selection callback during programmatic updates (e.g., refresh)
    @State private var isRestoringSelection = false

    /// Whether the tables section is expanded
    @State private var isTablesExpanded = true

    /// State for table operation confirmation dialog
    @State private var showOperationDialog = false
    @State private var pendingOperationType: TableOperationType?
    @State private var pendingOperationTables: [String] = []

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
                    onTablePro?(table.name)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .databaseDidConnect)) { _ in
            Task { @MainActor in
                loadTables()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshData)) { _ in
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
        .sheet(isPresented: $showOperationDialog) {
            if let operationType = pendingOperationType {
                let tables = pendingOperationTables
                if let firstTable = tables.first {
                    let tableName = tables.count > 1
                        ? "\(tables.count) tables"
                        : firstTable
                    TableOperationDialog(
                        isPresented: $showOperationDialog,
                        tableName: tableName,
                        operationType: operationType,
                        databaseType: databaseType
                    )                        { options in
                        confirmOperation(options: options)
                    }
                }
            }
        }
        .onChange(of: showOperationDialog) { _, isPresented in
            AppState.shared.isSheetPresented = isPresented
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: DesignConstants.FontSize.medium))

            TextField("Filter", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: DesignConstants.FontSize.body))

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: DesignConstants.FontSize.medium))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, DesignConstants.Spacing.xxs)
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
                        tableContextMenu(clickedTable: table)
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
        .contextMenu {
            tableContextMenu()
        }
        .onDeleteCommand {
            batchToggleDelete()
        }
        .onExitCommand {
            selectedTables.removeAll()
        }
    }

    /// Unified context menu for sidebar - used for both table rows and empty space
    /// - Parameter clickedTable: The table that was right-clicked, nil if clicking empty space
    @ViewBuilder
    private func tableContextMenu(clickedTable: TableInfo? = nil) -> some View {
        let hasSelection = !selectedTables.isEmpty || clickedTable != nil

        Button("Create New Table...") {
            NotificationCenter.default.post(name: .createTable, object: nil)
        }
        .keyboardShortcut("n", modifiers: .command)

        Divider()

        Button("Copy Name") {
            let names: [String]
            if selectedTables.isEmpty, let table = clickedTable {
                names = [table.name]
            } else {
                names = selectedTables.map { $0.name }.sorted()
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names.joined(separator: ","), forType: .string)
        }
        .keyboardShortcut("c", modifiers: .command)
        .disabled(!hasSelection)

        Button("Export...") {
            if selectedTables.isEmpty, let table = clickedTable {
                selectedTables.insert(table)
            }
            NotificationCenter.default.post(name: .exportTables, object: nil)
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(!hasSelection)

        Button("Import...") {
            NotificationCenter.default.post(name: .importTables, object: nil)
        }
        .keyboardShortcut("i", modifiers: .command)

        Divider()

        Button("Truncate") {
            if selectedTables.isEmpty, let table = clickedTable {
                selectedTables.insert(table)
            }
            batchToggleTruncate()
        }
        .disabled(!hasSelection)

        Button("Delete", role: .destructive) {
            if selectedTables.isEmpty, let table = clickedTable {
                selectedTables.insert(table)
            }
            batchToggleDelete()
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(!hasSelection)
    }

    /// Batch toggle truncate for all selected tables
    private func batchToggleTruncate() {
        let tablesToToggle = selectedTables.isEmpty ? [] : Array(selectedTables.map { $0.name })
        guard !tablesToToggle.isEmpty else { return }

        // Check if all tables are already pending truncate - if so, remove them
        // Cancellation doesn't require confirmation since it's a safe operation that
        // simply removes the pending state. The stored options are intentionally discarded.
        let allAlreadyPending = tablesToToggle.allSatisfy { pendingTruncates.contains($0) }
        if allAlreadyPending {
            var updated = pendingTruncates
            for name in tablesToToggle {
                updated.remove(name)
                tableOperationOptions.removeValue(forKey: name)
            }
            pendingTruncates = updated
        } else {
            // Show dialog to confirm operation
            pendingOperationType = .truncate
            pendingOperationTables = tablesToToggle
            showOperationDialog = true
        }
    }

    /// Batch toggle delete for all selected tables
    private func batchToggleDelete() {
        let tablesToToggle = selectedTables.isEmpty ? [] : Array(selectedTables.map { $0.name })
        guard !tablesToToggle.isEmpty else { return }

        // Check if all tables are already pending delete - if so, remove them
        // Cancellation doesn't require confirmation since it's a safe operation that
        // simply removes the pending state. The stored options are intentionally discarded.
        let allAlreadyPending = tablesToToggle.allSatisfy { pendingDeletes.contains($0) }
        if allAlreadyPending {
            var updated = pendingDeletes
            for name in tablesToToggle {
                updated.remove(name)
                tableOperationOptions.removeValue(forKey: name)
            }
            pendingDeletes = updated
        } else {
            // Show dialog to confirm operation
            pendingOperationType = .drop
            pendingOperationTables = tablesToToggle
            showOperationDialog = true
        }
    }

    /// Confirm the pending operation with the given options
    private func confirmOperation(options: TableOperationOptions) {
        guard let operationType = pendingOperationType else { return }

        var updatedTruncates = pendingTruncates
        var updatedDeletes = pendingDeletes
        var updatedOptions = tableOperationOptions

        for tableName in pendingOperationTables {
            // Remove from opposite set if present
            if operationType == .truncate {
                updatedDeletes.remove(tableName)
                updatedTruncates.insert(tableName)
            } else {
                updatedTruncates.remove(tableName)
                updatedDeletes.insert(tableName)
            }

            // Store options for this table
            updatedOptions[tableName] = options
        }

        pendingTruncates = updatedTruncates
        pendingDeletes = updatedDeletes
        tableOperationOptions = updatedOptions

        // Reset dialog state
        pendingOperationType = nil
        pendingOperationTables = []
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
        } else {
            pendingDeletes.insert(tableName)
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
                    .frame(width: DesignConstants.IconSize.default)

                // Pending operation indicator
                if isPendingDelete {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: DesignConstants.FontSize.caption))
                        .foregroundStyle(.red)
                        .offset(x: 4, y: 4)
                } else if isPendingTruncate {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: DesignConstants.FontSize.caption))
                        .foregroundStyle(.orange)
                        .offset(x: 4, y: 4)
                }
            }

            Text(table.name)
                .font(.system(size: DesignConstants.FontSize.medium, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(textColor)
        }
        .padding(.vertical, DesignConstants.Spacing.xxs)
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
        pendingDeletes: .constant([]),
        tableOperationOptions: .constant([:]),
        databaseType: .mysql
    )
    .frame(width: 250, height: 400)
}

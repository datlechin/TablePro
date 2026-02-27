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
    @StateObject private var viewModel: SidebarViewModel

    // Keep @Binding on the view for SwiftUI change tracking.
    // The ViewModel stores the same bindings for write access.
    @Binding var tables: [TableInfo]
    @Binding var selectedTables: Set<TableInfo>
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>

    var activeTableName: String?
    var onShowAllTables: (() -> Void)?

    /// Computed on the view (not ViewModel) so SwiftUI tracks both
    /// `@Binding var tables` and `@Published var searchText` as dependencies.
    private var filteredTables: [TableInfo] {
        guard !viewModel.searchText.isEmpty else { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(viewModel.searchText) }
    }

    init(
        tables: Binding<[TableInfo]>,
        selectedTables: Binding<Set<TableInfo>>,
        activeTableName: String? = nil,
        onShowAllTables: (() -> Void)? = nil,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        databaseType: DatabaseType
    ) {
        _tables = tables
        _selectedTables = selectedTables
        _pendingTruncates = pendingTruncates
        _pendingDeletes = pendingDeletes
        _viewModel = StateObject(wrappedValue: SidebarViewModel(
            tables: tables,
            selectedTables: selectedTables,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            tableOperationOptions: tableOperationOptions,
            databaseType: databaseType
        ))
        self.activeTableName = activeTableName
        self.onShowAllTables = onShowAllTables
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !tables.isEmpty {
                searchField
            }
            content
        }
        .frame(minWidth: 280)
        .onChange(of: tables) { _, newTables in
            if newTables.isEmpty && DatabaseManager.shared.status != .disconnected && !viewModel.isLoading {
                viewModel.loadTables()
            }
        }
        .onAppear {
            viewModel.setupNotifications()
            viewModel.onAppear()
        }
        .sheet(isPresented: $viewModel.showOperationDialog) {
            if let operationType = viewModel.pendingOperationType {
                let dialogTables = viewModel.pendingOperationTables
                if let firstTable = dialogTables.first {
                    let tableName =
                        dialogTables.count > 1
                        ? String(localized: "\(dialogTables.count) tables")
                        : firstTable
                    TableOperationDialog(
                        isPresented: $viewModel.showOperationDialog,
                        tableName: tableName,
                        operationType: operationType,
                        databaseType: viewModel.databaseType
                    ) { options in
                        viewModel.confirmOperation(options: options)
                    }
                }
            }
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: DesignConstants.FontSize.medium))

            TextField("Filter", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: DesignConstants.FontSize.body))

            if !viewModel.searchText.isEmpty {
                Button(action: { viewModel.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: DesignConstants.FontSize.medium))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear table filter"))
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
        if let error = viewModel.errorMessage {
            errorState(message: error)
        } else if tables.isEmpty && viewModel.isLoading {
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
        VStack(spacing: 6) {
            Image(systemName: "tablecells")
                .font(.system(size: 28, weight: .thin))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text("No Tables")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            Text("This database has no tables yet.")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Section(isExpanded: $viewModel.isTablesExpanded) {
                ForEach(filteredTables) { table in
                    TableRow(
                        table: table,
                        isActive: activeTableName == table.name,
                        isPendingTruncate: pendingTruncates.contains(table.name),
                        isPendingDelete: pendingDeletes.contains(table.name)
                    )
                    .tag(table)
                    .contextMenu {
                        SidebarContextMenu(
                            clickedTable: table,
                            selectedTables: $selectedTables,
                            isReadOnly: AppState.shared.isReadOnly,
                            onBatchToggleTruncate: { viewModel.batchToggleTruncate() },
                            onBatchToggleDelete: { viewModel.batchToggleDelete() }
                        )
                    }
                }
            } header: {
                Text("Tables")
                    .help("Right-click to show all tables")
                    .contextMenu {
                        Button(String(localized: "Show All Tables")) {
                            onShowAllTables?()
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contextMenu {
            SidebarContextMenu(
                clickedTable: nil,
                selectedTables: $selectedTables,
                isReadOnly: AppState.shared.isReadOnly,
                onBatchToggleTruncate: { viewModel.batchToggleTruncate() },
                onBatchToggleDelete: { viewModel.batchToggleDelete() }
            )
        }
        .onExitCommand {
            selectedTables.removeAll()
        }
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

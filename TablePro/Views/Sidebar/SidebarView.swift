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
    @State private var viewModel: SidebarViewModel

    // Keep @Binding on the view for SwiftUI change tracking.
    // The ViewModel stores the same bindings for write access.
    @Binding var tables: [TableInfo]
    var sidebarState: SharedSidebarState
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>

    var activeTableName: String?
    var onDoubleClick: ((TableInfo) -> Void)?
    var connectionId: UUID
    private weak var coordinator: MainContentCoordinator?

    /// Computed on the view (not ViewModel) so SwiftUI tracks both
    /// `@Binding var tables` and `@Published var searchText` as dependencies.
    private var filteredTables: [TableInfo] {
        guard !viewModel.debouncedSearchText.isEmpty else { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(viewModel.debouncedSearchText) }
    }

    private var selectedTablesBinding: Binding<Set<TableInfo>> {
        Binding(
            get: { sidebarState.selectedTables },
            set: { sidebarState.selectedTables = $0 }
        )
    }

    init(
        tables: Binding<[TableInfo]>,
        sidebarState: SharedSidebarState,
        activeTableName: String? = nil,
        onDoubleClick: ((TableInfo) -> Void)? = nil,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        databaseType: DatabaseType,
        connectionId: UUID,
        schemaProvider: SQLSchemaProvider? = nil,
        coordinator: MainContentCoordinator? = nil
    ) {
        _tables = tables
        self.sidebarState = sidebarState
        self.onDoubleClick = onDoubleClick
        _pendingTruncates = pendingTruncates
        _pendingDeletes = pendingDeletes
        let selectedBinding = Binding(
            get: { sidebarState.selectedTables },
            set: { sidebarState.selectedTables = $0 }
        )
        let vm = SidebarViewModel(
            tables: tables,
            selectedTables: selectedBinding,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            tableOperationOptions: tableOperationOptions,
            databaseType: databaseType,
            connectionId: connectionId,
            schemaProvider: schemaProvider
        )
        vm.debouncedSearchText = sidebarState.searchText
        _viewModel = State(wrappedValue: vm)
        self.activeTableName = activeTableName
        self.connectionId = connectionId
        self.coordinator = coordinator
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(minWidth: 280)
        .onChange(of: sidebarState.searchText) { _, newValue in
            viewModel.debouncedSearchText = newValue
        }
        .onChange(of: tables) { _, newTables in
            let hasSession = DatabaseManager.shared.activeSessions[connectionId] != nil
            if newTables.isEmpty && hasSession && !viewModel.isLoading {
                viewModel.loadTables()
            }
        }
        .onAppear {
            viewModel.onAppear()
            coordinator?.sidebarViewModel = viewModel
        }
        .sheet(isPresented: $viewModel.showOperationDialog) {
            if let operationType = viewModel.pendingOperationType {
                let dialogTables = viewModel.pendingOperationTables
                if let firstTable = dialogTables.first {
                    TableOperationDialog(
                        isPresented: $viewModel.showOperationDialog,
                        tableName: firstTable,
                        tableCount: dialogTables.count,
                        operationType: operationType,
                        databaseType: viewModel.databaseType
                    ) { options in
                        viewModel.confirmOperation(options: options)
                    }
                }
            }
        }
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
        let entityName = PluginManager.shared.tableEntityName(for: viewModel.databaseType)
        let noItemsLabel = String(localized: "No \(entityName)")
        let noItemsDetail = String(localized: "This database has no \(entityName.lowercased()) yet.")
        return VStack(spacing: 6) {
            Image(systemName: "tablecells")
                .font(.system(size: 28, weight: .thin))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text(noItemsLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            Text(noItemsDetail)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Table List

    private var tableList: some View {
        let entityLabel = PluginManager.shared.tableEntityName(for: viewModel.databaseType)
        let noMatchLabel = String(localized: "No matching \(entityLabel.lowercased())")
        let helpLabel = String(localized: "Right-click to show all \(entityLabel.lowercased())")
        let showAllLabel = String(localized: "Show All \(entityLabel)")
        return List(selection: selectedTablesBinding) {
            if filteredTables.isEmpty {
                ContentUnavailableView(
                    noMatchLabel,
                    systemImage: "magnifyingglass"
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                Section(isExpanded: $viewModel.isTablesExpanded) {
                    ForEach(filteredTables) { table in
                        TableRow(
                            table: table,
                            isActive: activeTableName == table.name,
                            isPendingTruncate: pendingTruncates.contains(table.name),
                            isPendingDelete: pendingDeletes.contains(table.name)
                        )
                        .tag(table)
                        .overlay {
                            DoubleClickDetector {
                                onDoubleClick?(table)
                            }
                        }
                        .contextMenu {
                            SidebarContextMenu(
                                clickedTable: table,
                                selectedTables: selectedTablesBinding,
                                isReadOnly: AppState.shared.safeModeLevel.blocksAllWrites,
                                onBatchToggleTruncate: { viewModel.batchToggleTruncate() },
                                onBatchToggleDelete: { viewModel.batchToggleDelete() },
                                coordinator: coordinator
                            )
                        }
                    }
                } header: {
                    Text(entityLabel)
                        .help(helpLabel)
                        .contextMenu {
                            Button(showAllLabel) {
                                coordinator?.showAllTablesMetadata()
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contextMenu {
            SidebarContextMenu(
                clickedTable: nil,
                selectedTables: selectedTablesBinding,
                isReadOnly: AppState.shared.safeModeLevel.blocksAllWrites,
                onBatchToggleTruncate: { viewModel.batchToggleTruncate() },
                onBatchToggleDelete: { viewModel.batchToggleDelete() },
                coordinator: coordinator
            )
        }
        .onExitCommand {
            sidebarState.selectedTables.removeAll()
        }
    }
}

// MARK: - Preview

#Preview {
    SidebarView(
        tables: .constant([]),
        sidebarState: SharedSidebarState(),
        pendingTruncates: .constant([]),
        pendingDeletes: .constant([]),
        tableOperationOptions: .constant([:]),
        databaseType: .mysql,
        connectionId: UUID()
    )
    .frame(width: 250, height: 400)
}

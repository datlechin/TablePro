//
//  MainContentView.swift
//  TablePro
//
//  Main content view combining query editor and results table.
//  Refactored to use coordinator pattern for business logic separation.
//

import Combine
import SwiftUI

/// Main content view - thin presentation layer
struct MainContentView: View {
    // MARK: - Properties

    let connection: DatabaseConnection

    // Shared state from parent
    @Binding var tables: [TableInfo]
    @Binding var selectedTables: Set<TableInfo>
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>
    @Binding var tableOperationOptions: [String: TableOperationOptions]
    @Binding var isInspectorPresented: Bool

    // MARK: - State Objects

    @StateObject private var tabManager = QueryTabManager()
    @StateObject private var changeManager = DataChangeManager()
    @StateObject private var filterStateManager = FilterStateManager()
    @StateObject private var toolbarState = ConnectionToolbarState()
    @StateObject var coordinator: MainContentCoordinator

    // MARK: - Local State

    @State var selectedRowIndices: Set<Int> = []
    @State private var editingCell: CellPosition?
    @State private var notificationHandler: MainContentNotificationHandler?
    @State private var showDatabaseSwitcher = false

    // MARK: - Environment

    @EnvironmentObject private var appState: AppState

    // MARK: - Initialization

    init(
        connection: DatabaseConnection,
        tables: Binding<[TableInfo]>,
        selectedTables: Binding<Set<TableInfo>>,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        isInspectorPresented: Binding<Bool>
    ) {
        self.connection = connection
        self._tables = tables
        self._selectedTables = selectedTables
        self._pendingTruncates = pendingTruncates
        self._pendingDeletes = pendingDeletes
        self._tableOperationOptions = tableOperationOptions
        self._isInspectorPresented = isInspectorPresented

        // Create state objects
        let tabMgr = QueryTabManager()
        let changeMgr = DataChangeManager()
        let filterMgr = FilterStateManager()
        let toolbarSt = ConnectionToolbarState()

        _tabManager = StateObject(wrappedValue: tabMgr)
        _changeManager = StateObject(wrappedValue: changeMgr)
        _filterStateManager = StateObject(wrappedValue: filterMgr)
        _toolbarState = StateObject(wrappedValue: toolbarSt)

        // Create coordinator with all dependencies
        _coordinator = StateObject(wrappedValue: MainContentCoordinator(
            connection: connection,
            tabManager: tabMgr,
            changeManager: changeMgr,
            filterStateManager: filterMgr,
            toolbarState: toolbarSt
        ))
    }

    // MARK: - Body

    var body: some View {
        mainContentView
            .tableProToolbar(state: toolbarState)
            .mainContentAlerts(
                coordinator: coordinator,
                connection: connection,
                pendingTruncates: $pendingTruncates,
                pendingDeletes: $pendingDeletes,
                tables: tables,
                selectedTables: selectedTables
            )
            .task { await initializeAndRestoreTabs() }
            .onChange(of: tabManager.selectedTabId) { oldTabId, newTabId in
                handleTabSelectionChange(from: oldTabId, to: newTabId)
            }
            .onChange(of: tabManager.tabs) { _, newTabs in
                handleTabsChange(newTabs)
            }
            .onChange(of: currentTab?.resultColumns) { _, newColumns in
                handleColumnsChange(newColumns: newColumns)
            }
            .onChange(of: DatabaseManager.shared.currentSession?.isConnected) { _, isConnected in
                handleConnectionChange(isConnected)
            }
            .onChange(of: DatabaseManager.shared.currentSession?.status) { _, newStatus in
                handleSessionStatusChange(newStatus)
            }
            .onChange(of: currentTab?.isExecuting) { _, isExecuting in
                toolbarState.isExecuting = isExecuting ?? false
            }
            .onChange(of: currentTab?.executionTime) { _, executionTime in
                if let time = executionTime {
                    toolbarState.lastQueryDuration = time
                }
            }
            .onChange(of: selectedTables) { oldTables, newTables in
                handleTableSelectionChange(from: oldTables, to: newTables)
            }
            .onChange(of: selectedRowIndices) { _, newIndices in
                AppState.shared.hasRowSelection = !newIndices.isEmpty
            }
            .onAppear { setupNotificationHandler() }
            .sheet(isPresented: $showDatabaseSwitcher) {
                DatabaseSwitcherSheet(
                    isPresented: $showDatabaseSwitcher,
                    currentDatabase: DatabaseManager.shared.currentSession?.connection.database,
                    databaseType: connection.type
                )                    { database in
                    switchDatabase(to: database)
                }
            }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContentView: some View {
        HStack(spacing: 0) {
            MainEditorContentView(
                tabManager: tabManager,
                coordinator: coordinator,
                changeManager: changeManager,
                filterStateManager: filterStateManager,
                connection: connection,
                selectedRowIndices: $selectedRowIndices,
                editingCell: $editingCell,
                onCellEdit: { rowIndex, colIndex, value in
                    coordinator.updateCellInTab(rowIndex: rowIndex, columnIndex: colIndex, value: value)
                },
                onSort: { columnIndex, ascending in
                    coordinator.handleSort(columnIndex: columnIndex, ascending: ascending, selectedRowIndices: &selectedRowIndices)
                },
                onAddRow: {
                    coordinator.addNewRow(selectedRowIndices: &selectedRowIndices, editingCell: &editingCell)
                },
                onUndoInsert: { rowIndex in
                    coordinator.undoInsertRow(at: rowIndex, selectedRowIndices: &selectedRowIndices)
                },
                onFilterColumn: { columnName in
                    filterStateManager.addFilterForColumn(columnName)
                },
                onApplyFilters: { filters in
                    coordinator.applyFilters(filters)
                },
                onClearFilters: {
                    coordinator.clearFiltersAndReload()
                },
                onQuickSearch: { searchText in
                    coordinator.applyQuickSearch(searchText)
                },
                onCommit: { sql in
                    executeCommitSQL(sql)
                },
                onRefresh: {
                    coordinator.runQuery()
                },
                onFirstPage: {
                    coordinator.goToFirstPage()
                },
                onPreviousPage: {
                    coordinator.goToPreviousPage()
                },
                onNextPage: {
                    coordinator.goToNextPage()
                },
                onLastPage: {
                    coordinator.goToLastPage()
                },
                onLimitChange: { newLimit in
                    coordinator.updatePageSize(newLimit)
                },
                onOffsetChange: { newOffset in
                    coordinator.updateOffset(newOffset)
                },
                onPaginationGo: {
                    coordinator.applyPaginationSettings()
                }
            )

            // Right sidebar
            if isInspectorPresented {
                Divider()
                RightSidebarView(
                    tableName: currentTab?.tableName,
                    tableMetadata: coordinator.tableMetadata,
                    selectedRowData: selectedRowDataForSidebar
                )
                .frame(width: 280)
                .task(id: currentTab?.tableName) {
                    await loadTableMetadataIfNeeded()
                }
            }
        }
    }

    // MARK: - Initialization

    private func initializeAndRestoreTabs() async {
        await coordinator.initializeView()

        // Restore tabs from storage
        let result = coordinator.tabPersistence.restoreTabs()
        if !result.tabs.isEmpty {
            coordinator.tabPersistence.beginRestoration()
            defer { coordinator.tabPersistence.endRestoration() }

            tabManager.tabs = result.tabs
            tabManager.selectedTabId = result.selectedTabId

            // Execute query for table tabs
            if let selectedTab = tabManager.selectedTab,
               selectedTab.tabType == .table,
               !selectedTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await coordinator.tabPersistence.waitForConnectionAndExecute {
                    coordinator.runQuery()
                }
            }
        }
    }

    // MARK: - Notification Handler Setup

    private func setupNotificationHandler() {
        notificationHandler = MainContentNotificationHandler(
            coordinator: coordinator,
            filterStateManager: filterStateManager,
            connection: connection,
            selectedRowIndices: $selectedRowIndices,
            selectedTables: $selectedTables,
            pendingTruncates: $pendingTruncates,
            pendingDeletes: $pendingDeletes,
            tableOperationOptions: $tableOperationOptions,
            isInspectorPresented: $isInspectorPresented,
            editingCell: $editingCell,
            showDatabaseSwitcher: $showDatabaseSwitcher
        )
    }

    // MARK: - Database Switcher

    private func switchDatabase(to database: String) {
        Task {
            await coordinator.switchDatabase(to: database)
        }
    }

    // MARK: - Event Handlers

    private func handleTabSelectionChange(from oldTabId: UUID?, to newTabId: UUID?) {
        coordinator.handleTabChange(
            from: oldTabId,
            to: newTabId,
            selectedRowIndices: &selectedRowIndices,
            tabs: tabManager.tabs
        )

        // Dismiss autocomplete windows
        NotificationCenter.default.post(name: NSNotification.Name("QueryTabDidChange"), object: nil)

        // Persist tab selection
        guard !coordinator.tabPersistence.isRestoringTabs,
              !coordinator.tabPersistence.isDismissing else { return }

        if let sessionId = DatabaseManager.shared.currentSessionId {
            DatabaseManager.shared.updateSession(sessionId) { session in
                session.selectedTabId = newTabId
            }
            coordinator.tabPersistence.saveTabsImmediately(
                tabs: tabManager.tabs,
                selectedTabId: newTabId
            )
        }
    }

    private func handleTabsChange(_ newTabs: [QueryTab]) {
        guard !coordinator.tabPersistence.isRestoringTabs,
              !coordinator.tabPersistence.isDismissing else { return }

        if let sessionId = DatabaseManager.shared.currentSessionId {
            DatabaseManager.shared.updateSession(sessionId) { session in
                session.tabs = newTabs
            }
            coordinator.tabPersistence.saveTabsImmediately(
                tabs: newTabs,
                selectedTabId: tabManager.selectedTabId
            )

            if newTabs.isEmpty {
                coordinator.tabPersistence.clearSavedState()
            }
        }
    }

    private func handleColumnsChange(newColumns: [String]?) {
        guard let newColumns = newColumns, !newColumns.isEmpty,
              let tab = tabManager.selectedTab,
              !tab.pendingChanges.hasChanges else { return }

        // Reconfigure if columns changed OR table name changed (switching tables)
        let columnsChanged = changeManager.columns != newColumns
        let tableChanged = changeManager.tableName != (tab.tableName ?? "")

        guard columnsChanged || tableChanged else { return }

        changeManager.configureForTable(
            tableName: tab.tableName ?? "",
            columns: newColumns,
            primaryKeyColumn: newColumns.first,
            databaseType: connection.type
        )
    }


    private func handleConnectionChange(_ isConnected: Bool?) {
        if isConnected == true && coordinator.needsLazyLoad {
            coordinator.needsLazyLoad = false
            coordinator.runQuery()
        }
    }

    private func handleSessionStatusChange(_ newStatus: ConnectionStatus?) {
        if let status = newStatus {
            toolbarState.connectionState = mapSessionStatus(status)
        }
    }

    private func handleTableSelectionChange(from oldTables: Set<TableInfo>, to newTables: Set<TableInfo>) {
        let added = newTables.subtracting(oldTables)
        if let table = added.first {
            selectedRowIndices = []
            coordinator.openTableTab(table.name)
        }
        AppState.shared.hasTableSelection = !newTables.isEmpty
    }

    // MARK: - Helper Methods

    private func loadTableMetadataIfNeeded() async {
        guard let tableName = currentTab?.tableName,
              coordinator.tableMetadata?.tableName != tableName else { return }
        await coordinator.loadTableMetadata(tableName: tableName)
    }

    private func executeCommitSQL(_ sql: String) {
        guard !sql.isEmpty else { return }

        Task {
            do {
                guard let driver = DatabaseManager.shared.activeDriver else {
                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].errorMessage = "Not connected to database"
                    }
                    return
                }

                let statements = sql.components(separatedBy: ";").filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }

                for statement in statements {
                    let startTime = Date()
                    _ = try await driver.execute(query: statement)
                    let executionTime = Date().timeIntervalSince(startTime)

                    QueryHistoryManager.shared.recordQuery(
                        query: statement.trimmingCharacters(in: .whitespacesAndNewlines),
                        connectionId: connection.id,
                        databaseName: connection.database ?? "",
                        executionTime: executionTime,
                        rowCount: 0,
                        wasSuccessful: true,
                        errorMessage: nil
                    )
                }

                changeManager.clearChanges()
                if let index = tabManager.selectedTabIndex {
                    tabManager.tabs[index].pendingChanges = TabPendingChanges()
                    tabManager.tabs[index].errorMessage = nil
                }

                coordinator.runQuery()
            } catch {
                if let index = tabManager.selectedTabIndex {
                    tabManager.tabs[index].errorMessage = "Save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func mapSessionStatus(_ status: ConnectionStatus) -> ToolbarConnectionState {
        switch status {
        case .connected: return .connected
        case .connecting: return .executing
        case .disconnected: return .disconnected
        case .error: return .error("")
        }
    }
}

// MARK: - Preview

#Preview("With Connection") {
    MainContentView(
        connection: DatabaseConnection.sampleConnections[0],
        tables: .constant([]),
        selectedTables: .constant([]),
        pendingTruncates: .constant([]),
        pendingDeletes: .constant([]),
        tableOperationOptions: .constant([:]),
        isInspectorPresented: .constant(false)
    )
    .frame(width: 1_000, height: 600)
}

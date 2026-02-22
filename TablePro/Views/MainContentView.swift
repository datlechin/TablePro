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
    @Binding var inspectorContext: InspectorContext
    var rightPanelState: RightPanelState

    // MARK: - State Objects

    @StateObject private var tabManager: QueryTabManager
    @StateObject private var changeManager: DataChangeManager
    @StateObject private var filterStateManager: FilterStateManager
    @StateObject private var toolbarState: ConnectionToolbarState
    @StateObject var coordinator: MainContentCoordinator

    // MARK: - Local State

    @State var selectedRowIndices: Set<Int> = []
    @State private var previousSelectedTabId: UUID?
    @State private var previousSelectedTables: Set<TableInfo> = []
    @State private var editingCell: CellPosition?
    @State private var commandActions: MainContentCommandActions?
    @State private var queryResultsSummaryCache: (tabId: UUID, version: Int, summary: String?)?
    @State private var inspectorUpdateWorkItem: DispatchWorkItem?

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
        inspectorContext: Binding<InspectorContext>,
        rightPanelState: RightPanelState
    ) {
        self.connection = connection
        self._tables = tables
        self._selectedTables = selectedTables
        self._pendingTruncates = pendingTruncates
        self._pendingDeletes = pendingDeletes
        self._tableOperationOptions = tableOperationOptions
        self._inspectorContext = inspectorContext
        self.rightPanelState = rightPanelState

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
        _coordinator = StateObject(
            wrappedValue: MainContentCoordinator(
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
            .openTableToolbar(state: toolbarState)
            .task { await initializeAndRestoreTabs() }
            .onChange(of: tabManager.selectedTabId) { _, newTabId in
                if coordinator.skipNextTabChangeOnChange {
                    // Work already done by direct caller (keyboard/tab bar/sidebar)
                    coordinator.skipNextTabChangeOnChange = false
                    previousSelectedTabId = newTabId
                    return
                }
                handleTabSelectionChange(from: previousSelectedTabId, to: newTabId)
                previousSelectedTabId = newTabId
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
            .onChange(of: selectedTables) { _, newTables in
                handleTableSelectionChange(from: previousSelectedTables, to: newTables)
                previousSelectedTables = newTables
            }
            .onChange(of: selectedRowIndices) { _, newIndices in
                AppState.shared.hasRowSelection = !newIndices.isEmpty
                // Defer sidebar/inspector updates so SwiftUI can render the tab switch first
                scheduleInspectorUpdate()
            }
            .onChange(of: currentTab?.resultRows) {
                scheduleInspectorUpdate()
            }
            .onChange(of: currentTab?.tableName) {
                scheduleInspectorUpdate()
                Task { await loadTableMetadataIfNeeded() }
            }
            .onChange(of: coordinator.tableMetadata?.tableName) {
                scheduleInspectorUpdate()
            }
            .onAppear {
                setupCommandActions()
                updateToolbarPendingState()
                updateInspectorContext()
            }
            .onChange(of: changeManager.hasChanges) {
                updateToolbarPendingState()
            }
            .onChange(of: pendingTruncates) {
                updateToolbarPendingState()
            }
            .onChange(of: pendingDeletes) {
                updateToolbarPendingState()
            }
            .onChange(of: appState.hasStructureChanges) {
                updateToolbarPendingState()
            }
            .sheet(isPresented: $coordinator.showDatabaseSwitcher) {
                DatabaseSwitcherSheet(
                    isPresented: $coordinator.showDatabaseSwitcher,
                    currentDatabase: connection.database,
                    databaseType: connection.type,
                    connectionId: connection.id,
                    onSelect: switchDatabase
                )
            }
            .sheet(isPresented: $coordinator.showExportDialog) {
                ExportDialog(
                    isPresented: $coordinator.showExportDialog,
                    connection: connection,
                    preselectedTables: Set(selectedTables.map(\.name))
                )
            }
            .sheet(isPresented: $coordinator.showImportDialog) {
                ImportDialog(
                    isPresented: $coordinator.showImportDialog,
                    connection: connection,
                    initialFileURL: coordinator.importFileURL
                )
            }
            .modifier(FocusedCommandActionsModifier(actions: commandActions))
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContentView: some View {
        MainEditorContentView(
            tabManager: tabManager,
            coordinator: coordinator,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            connection: connection,
            selectedRowIndices: $selectedRowIndices,
            editingCell: $editingCell,
            onCellEdit: { rowIndex, colIndex, value in
                coordinator.updateCellInTab(
                    rowIndex: rowIndex, columnIndex: colIndex, value: value)
            },
            onSort: { columnIndex, ascending, isMultiSort in
                coordinator.handleSort(
                    columnIndex: columnIndex, ascending: ascending,
                    isMultiSort: isMultiSort,
                    selectedRowIndices: &selectedRowIndices)
            },
            onAddRow: {
                coordinator.addNewRow(
                    selectedRowIndices: &selectedRowIndices, editingCell: &editingCell)
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
               !selectedTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                await coordinator.tabPersistence.waitForConnectionAndExecute {
                    // Switch to the tab's database if it differs from the connection's default
                    if !selectedTab.databaseName.isEmpty,
                       selectedTab.databaseName != coordinator.connection.database
                    {
                        Task {
                            await coordinator.switchDatabase(to: selectedTab.databaseName)
                        }
                    } else {
                        coordinator.runQuery()
                    }
                }
            }
        }
    }

    // MARK: - Command Actions Setup

    private func updateToolbarPendingState() {
        toolbarState.hasPendingChanges = changeManager.hasChanges
            || !pendingTruncates.isEmpty
            || !pendingDeletes.isEmpty
            || AppState.shared.hasStructureChanges
    }

    private func setupCommandActions() {
        commandActions = MainContentCommandActions(
            coordinator: coordinator,
            filterStateManager: filterStateManager,
            connection: connection,
            selectedRowIndices: $selectedRowIndices,
            selectedTables: $selectedTables,
            pendingTruncates: $pendingTruncates,
            pendingDeletes: $pendingDeletes,
            tableOperationOptions: $tableOperationOptions,
            rightPanelState: rightPanelState,
            editingCell: $editingCell
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
              !coordinator.tabPersistence.isDismissing
        else { return }

        if let sessionId = DatabaseManager.shared.currentSessionId {
            DatabaseManager.shared.updateSession(sessionId) { session in
                session.selectedTabId = newTabId
            }
            coordinator.tabPersistence.saveTabsAsync(
                tabs: tabManager.tabs,
                selectedTabId: newTabId
            )
        }
    }

    private func handleTabsChange(_ newTabs: [QueryTab]) {
        guard !coordinator.tabPersistence.isRestoringTabs,
              !coordinator.tabPersistence.isDismissing
        else { return }

        if let sessionId = DatabaseManager.shared.currentSessionId {
            DatabaseManager.shared.updateSession(sessionId) { session in
                session.tabs = newTabs
            }
            coordinator.tabPersistence.saveTabsAsync(
                tabs: newTabs,
                selectedTabId: tabManager.selectedTabId
            )

            if newTabs.isEmpty {
                coordinator.tabPersistence.clearSavedState()
            }
        }
    }

    private func handleColumnsChange(newColumns: [String]?) {
        // Skip during tab switch — handleTabChange already configures the change manager
        guard !coordinator.isHandlingTabSwitch else { return }

        guard let newColumns = newColumns, !newColumns.isEmpty,
              let tab = tabManager.selectedTab,
              !tab.pendingChanges.hasChanges
        else { return }

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

    private func handleTableSelectionChange(
        from oldTables: Set<TableInfo>, to newTables: Set<TableInfo>
    ) {
        let added = newTables.subtracting(oldTables)
        if let table = added.first {
            selectedRowIndices = []
            TabOpenTimingLogger.shared.markTrigger(source: "sidebar:\(table.name)")
            coordinator.openTableTab(table.name, isView: table.type == .view)
        }
        AppState.shared.hasTableSelection = !newTables.isEmpty
    }

    // MARK: - Helper Methods

    private func loadTableMetadataIfNeeded() async {
        guard let tableName = currentTab?.tableName,
              coordinator.tableMetadata?.tableName != tableName
        else { return }
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
                        databaseName: connection.database,
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
                    tabManager.tabs[index].errorMessage =
                        "Save failed: \(error.localizedDescription)"
                }

                // Show error alert to user
                AlertHelper.showErrorSheet(
                    title: String(localized: "Save Failed"),
                    message: error.localizedDescription,
                    window: NSApplication.shared.keyWindow
                )
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

    // MARK: - Sidebar Edit Handling

    private func updateSidebarEditState() {
        guard isSidebarEditable,
              let tab = coordinator.tabManager.selectedTab,
              !selectedRowIndices.isEmpty
        else {
            rightPanelState.editState.fields = []
            return
        }

        var allRows: [[String?]] = []
        for index in selectedRowIndices.sorted() {
            if index < tab.resultRows.count {
                allRows.append(tab.resultRows[index].values)
            }
        }

        rightPanelState.editState.configure(
            selectedRowIndices: selectedRowIndices,
            allRows: allRows,
            columns: tab.resultColumns,
            columnTypes: tab.columnTypes
        )
    }

    // MARK: - Inspector Context

    /// Coalesces multiple onChange-triggered updates into a single deferred call.
    /// During tab switch, onChange handlers fire 3-4× — this ensures we only rebuild once,
    /// and defers the work so SwiftUI can render the tab switch first.
    private func scheduleInspectorUpdate() {
        inspectorUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [self] in
            updateSidebarEditState()
            updateInspectorContext()
        }
        inspectorUpdateWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateInspectorContext() {
        inspectorContext = InspectorContext(
            tableName: currentTab?.tableName,
            tableMetadata: coordinator.tableMetadata,
            selectedRowData: selectedRowDataForSidebar,
            isEditable: isSidebarEditable,
            isRowDeleted: isSelectedRowDeleted,
            currentQuery: coordinator.tabManager.selectedTab?.query,
            queryResults: cachedQueryResultsSummary()
        )
    }

    private func cachedQueryResultsSummary() -> String? {
        guard let tab = currentTab else { return nil }
        if let cache = queryResultsSummaryCache,
           cache.tabId == tab.id, cache.version == tab.resultVersion {
            return cache.summary
        }
        let summary = buildQueryResultsSummary()
        queryResultsSummaryCache = (tabId: tab.id, version: tab.resultVersion, summary: summary)
        return summary
    }

    private func buildQueryResultsSummary() -> String? {
        guard let tab = currentTab,
              !tab.resultColumns.isEmpty,
              !tab.resultRows.isEmpty
        else { return nil }

        let columns = tab.resultColumns
        let rows = tab.resultRows
        let maxRows = 10
        let displayRows = Array(rows.prefix(maxRows))

        var lines: [String] = []
        lines.append(columns.joined(separator: " | "))

        for row in displayRows {
            let values = columns.indices.map { i in
                i < row.values.count ? (row.values[i] ?? "NULL") : "NULL"
            }
            lines.append(values.joined(separator: " | "))
        }

        if rows.count > maxRows {
            lines.append("(showing \(maxRows) of \(rows.count) rows)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Focused Command Actions Modifier

/// Conditionally publishes `MainContentCommandActions` as a focused scene object.
/// `focusedSceneObject` requires a non-optional value, so this modifier
/// only applies it when the actions object has been created.
private struct FocusedCommandActionsModifier: ViewModifier {
    let actions: MainContentCommandActions?

    func body(content: Content) -> some View {
        if let actions {
            content.focusedSceneObject(actions)
        } else {
            content
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
        inspectorContext: .constant(.empty),
        rightPanelState: RightPanelState()
    )
    .frame(width: 1_000, height: 600)
}

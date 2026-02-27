//
//  MainContentView.swift
//  TablePro
//
//  Main content view combining query editor and results table.
//  Refactored to use coordinator pattern for business logic separation.
//

import Combine
import os
import SwiftUI

/// Main content view - thin presentation layer
struct MainContentView: View {
    // MARK: - Properties

    let connection: DatabaseConnection
    /// Payload identifying what this window-tab should display (nil = default query tab)
    let payload: EditorTabPayload?

    // Shared state from parent
    @Binding var windowTitle: String
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
    /// Stable identifier for this window in NativeTabRegistry
    @State private var windowId = UUID()
    @State private var hasInitialized = false

    // MARK: - Environment

    @EnvironmentObject private var appState: AppState

    // MARK: - Initialization

    private static let initLogger = Logger(subsystem: "com.TablePro", category: "MainContentView")

    init(
        connection: DatabaseConnection,
        payload: EditorTabPayload?,
        windowTitle: Binding<String>,
        tables: Binding<[TableInfo]>,
        selectedTables: Binding<Set<TableInfo>>,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        inspectorContext: Binding<InspectorContext>,
        rightPanelState: RightPanelState
    ) {
        self.connection = connection
        self.payload = payload
        self._windowTitle = windowTitle
        self._tables = tables
        self._selectedTables = selectedTables
        self._pendingTruncates = pendingTruncates
        self._pendingDeletes = pendingDeletes
        self._tableOperationOptions = tableOperationOptions
        self._inspectorContext = inspectorContext
        self.rightPanelState = rightPanelState

        // Create state objects — each native window-tab gets its own instances
        let tabMgr = QueryTabManager()
        let changeMgr = DataChangeManager()
        let filterMgr = FilterStateManager()
        let toolbarSt = ConnectionToolbarState()

        // Initialize single tab based on payload
        if let payload {
            switch payload.tabType {
            case .table:
                if let tableName = payload.tableName {
                    tabMgr.addTableTab(
                        tableName: tableName,
                        databaseType: connection.type,
                        databaseName: payload.databaseName ?? connection.database
                    )
                    if let index = tabMgr.selectedTabIndex {
                        tabMgr.tabs[index].isView = payload.isView
                        tabMgr.tabs[index].isEditable = !payload.isView
                        if payload.showStructure {
                            tabMgr.tabs[index].showStructure = true
                        }
                    }
                } else {
                    tabMgr.addTab(databaseName: payload.databaseName ?? connection.database)
                }
            case .query:
                tabMgr.addTab(
                    initialQuery: payload.initialQuery,
                    databaseName: payload.databaseName ?? connection.database
                )
            case .createTable:
                tabMgr.addCreateTableTab(
                    databaseName: payload.databaseName ?? connection.database,
                    databaseType: connection.type
                )
            }
        }
        // If payload is nil, tab restoration will add tabs in initializeAndRestoreTabs()

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
        bodyContent
            .sheet(item: $coordinator.activeSheet) { sheet in
                sheetContent(for: sheet)
            }
            .modifier(FocusedCommandActionsModifier(actions: commandActions))
    }

    // MARK: - Sheet Content

    /// Returns the appropriate sheet view for the given `ActiveSheet` case.
    /// Uses a dismissal binding that sets `coordinator.activeSheet = nil` when the
    /// child view sets `isPresented = false`.
    @ViewBuilder
    private func sheetContent(for sheet: ActiveSheet) -> some View {
        let dismissBinding = Binding<Bool>(
            get: { coordinator.activeSheet != nil },
            set: { if !$0 { coordinator.activeSheet = nil } }
        )

        switch sheet {
        case .databaseSwitcher:
            DatabaseSwitcherSheet(
                isPresented: dismissBinding,
                currentDatabase: connection.database,
                databaseType: connection.type,
                connectionId: connection.id,
                onSelect: switchDatabase
            )
        case .exportDialog:
            ExportDialog(
                isPresented: dismissBinding,
                connection: connection,
                preselectedTables: Set(selectedTables.map(\.name))
            )
        case .importDialog:
            ImportDialog(
                isPresented: dismissBinding,
                connection: connection,
                initialFileURL: coordinator.importFileURL
            )
        }
    }

    /// Trigger for toolbar pending-changes badge — combines all four sources that
    /// contribute to `hasPendingChanges`. Replaces four separate handlers that each
    /// called `updateToolbarPendingState()`.
    private var pendingChangeTrigger: PendingChangeTrigger {
        PendingChangeTrigger(
            hasDataChanges: changeManager.hasChanges,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            hasStructureChanges: appState.hasStructureChanges
        )
    }

    /// Split into two halves to help the Swift type checker with the long modifier chain.
    private var bodyContent: some View {
        bodyContentCore
            .onChange(of: currentTab?.tableName) {
                scheduleInspectorUpdate()
                // Only load metadata after the tab has executed at least once —
                // avoids a redundant DB query racing with the initial data query
                if currentTab?.lastExecutedAt != nil {
                    Task { await loadTableMetadataIfNeeded() }
                }
            }
            .onChange(of: inspectorTrigger) {
                scheduleInspectorUpdate()
            }
            .onAppear {
                // Set window title for empty state (no tabs restored)
                if tabManager.tabs.isEmpty {
                    windowTitle = connection.name
                }
                setupCommandActions()
                updateToolbarPendingState()
                updateInspectorContext()
                rightPanelState.aiViewModel.schemaProvider = coordinator.schemaProvider

                // Register this window's tabs in the native tab registry
                NativeTabRegistry.shared.register(
                    windowId: windowId,
                    connectionId: connection.id,
                    tabs: tabManager.tabs.map { $0.toSnapshot() },
                    selectedTabId: tabManager.selectedTabId
                )
            }
            .onDisappear {
                NativeTabRegistry.shared.unregister(windowId: windowId)
                coordinator.teardown()
            }
            .onChange(of: pendingChangeTrigger) {
                updateToolbarPendingState()
            }
    }

    private var bodyContentCore: some View {
        mainContentView
            .openTableToolbar(state: toolbarState)
            .task { await initializeAndRestoreTabs() }
            .onChange(of: tabManager.selectedTabId) { _, newTabId in
                handleTabSelectionChange(from: previousSelectedTabId, to: newTabId)
                previousSelectedTabId = newTabId
            }
            .onChange(of: tabManager.tabs) { _, newTabs in
                handleTabsChange(newTabs)
            }
            .onChange(of: currentTab?.resultColumns) { _, newColumns in
                handleColumnsChange(newColumns: newColumns)
            }
            .onReceive(DatabaseManager.shared.$activeSessions) { sessions in
                guard let session = sessions[connection.id] else { return }
                if session.isConnected && coordinator.needsLazyLoad {
                    coordinator.needsLazyLoad = false
                    coordinator.tabPersistence.markJustRestored()
                    if let selectedTab = tabManager.selectedTab,
                       !selectedTab.databaseName.isEmpty,
                       selectedTab.databaseName != session.connection.database
                    {
                        Task { await coordinator.switchDatabase(to: selectedTab.databaseName) }
                    } else {
                        coordinator.runQuery()
                    }
                }
                toolbarState.connectionState = mapSessionStatus(session.status)
            }

            .onChange(of: selectedTables) { _, newTables in
                handleTableSelectionChange(from: previousSelectedTables, to: newTables)
                previousSelectedTables = newTables
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                DispatchQueue.main.async {
                    syncSidebarToCurrentTab()
                }
            }
            .onChange(of: selectedRowIndices) { _, newIndices in
                AppState.shared.hasRowSelection = !newIndices.isEmpty
                scheduleInspectorUpdate()
            }
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
            windowId: windowId,
            connectionId: connection.id,
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
        guard !hasInitialized else { return }
        hasInitialized = true
        // Sync toolbar setup (fast, no I/O)
        coordinator.initializeToolbar()
        // Schema load runs in background — doesn't block data query
        Task { await coordinator.loadSchemaIfNeeded() }

        // If payload provided a tab, execute its query immediately
        if payload != nil {
            if let selectedTab = tabManager.selectedTab,
               selectedTab.tabType == .table,
               !selectedTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                // Fast path: connection already ready
                if let session = DatabaseManager.shared.activeSessions[connection.id],
                   session.isConnected
                {
                    coordinator.tabPersistence.markJustRestored()
                    if !selectedTab.databaseName.isEmpty,
                       selectedTab.databaseName != session.connection.database
                    {
                        Task { await coordinator.switchDatabase(to: selectedTab.databaseName) }
                    } else {
                        coordinator.executeTableTabQueryDirectly()
                    }
                } else {
                    // Reactive path: fires via .onReceive($activeSessions) when connection is ready
                    coordinator.needsLazyLoad = true
                }
            }
            return
        }

        // No payload — restore tabs from storage (first window on connection)
        let result = await coordinator.tabPersistence.restoreTabs()
        if !result.tabs.isEmpty {
            coordinator.tabPersistence.beginRestoration()
            defer { coordinator.tabPersistence.endRestoration() }

            // Find the selected tab, or use the first one
            let selectedId = result.selectedTabId
            let selectedIndex = result.tabs.firstIndex(where: { $0.id == selectedId }) ?? 0

            // Keep only the selected tab for this window
            let selectedTab = result.tabs[selectedIndex]
            tabManager.tabs = [selectedTab]
            tabManager.selectedTabId = selectedTab.id

            // Update registry with this window's single tab
            NativeTabRegistry.shared.update(
                windowId: windowId,
                connectionId: connection.id,
                tabs: tabManager.tabs.map { $0.toSnapshot() },
                selectedTabId: selectedTab.id
            )

            // Open remaining tabs as new native window-tabs
            let remainingTabs = result.tabs.enumerated()
                .filter { $0.offset != selectedIndex }
                .map(\.element)

            if !remainingTabs.isEmpty {
                // Delay to let the first window finish setup
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    for tab in remainingTabs {
                        let payload = EditorTabPayload(from: tab, connectionId: connection.id)
                        WindowOpener.shared.openNativeTab(payload)
                        // Small delay between opens to avoid overwhelming AppKit
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
            }

            // Execute query for the selected tab if it's a table tab
            if selectedTab.tabType == .table,
               !selectedTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                // Fast path: connection already ready
                if let session = DatabaseManager.shared.activeSessions[connection.id],
                   session.isConnected
                {
                    coordinator.tabPersistence.markJustRestored()
                    if !selectedTab.databaseName.isEmpty,
                       selectedTab.databaseName != session.connection.database
                    {
                        Task { await coordinator.switchDatabase(to: selectedTab.databaseName) }
                    } else {
                        coordinator.executeTableTabQueryDirectly()
                    }
                } else {
                    // Reactive path: fires via .onReceive($activeSessions) when connection is ready
                    coordinator.needsLazyLoad = true
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
        let actions = MainContentCommandActions(
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
        actions.window = NSApp.keyWindow
        commandActions = actions

        // Safety fallback: if window wasn't key yet at onAppear time,
        // retry on next run loop when the window is guaranteed to be visible
        if actions.window == nil {
            DispatchQueue.main.async { [weak actions] in
                actions?.window = NSApp.keyWindow
            }
        }
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

        // Update window title to reflect selected tab
        windowTitle = tabManager.selectedTab?.tableName
            ?? (tabManager.tabs.isEmpty ? connection.name : "SQL Query")

        // Sync sidebar selection to match the newly selected tab.
        // Critical for new native windows: localSelectedTables starts empty,
        // and this is the only place that can seed it from the restored tab.
        syncSidebarToCurrentTab()

        // Persist tab selection
        guard !coordinator.tabPersistence.isRestoringTabs,
              !coordinator.tabPersistence.isDismissing
        else { return }

        // Update registry (non-observable, safe inside onChange)
        NativeTabRegistry.shared.update(
            windowId: windowId,
            connectionId: connection.id,
            tabs: tabManager.tabs.map { $0.toSnapshot() },
            selectedTabId: newTabId
        )

        // Defer session sync + persistence to next run loop to avoid
        // "tried to update multiple times per frame" warning
        let connId = connection.id
        DispatchQueue.main.async { [coordinator] in
            guard !coordinator.tabPersistence.isDismissing else { return }
            let combinedTabs = NativeTabRegistry.shared.allTabs(for: connId)
            coordinator.tabPersistence.saveTabsAsync(
                tabs: combinedTabs,
                selectedTabId: newTabId
            )
        }
    }

    private func handleTabsChange(_ newTabs: [QueryTab]) {
        guard !coordinator.tabPersistence.isRestoringTabs,
              !coordinator.tabPersistence.isDismissing
        else { return }

        // Update window title to reflect current state
        windowTitle = tabManager.selectedTab?.tableName
            ?? (tabManager.tabs.isEmpty ? connection.name : "SQL Query")

        // Update registry (non-observable, safe inside onChange)
        NativeTabRegistry.shared.update(
            windowId: windowId,
            connectionId: connection.id,
            tabs: newTabs.map { $0.toSnapshot() },
            selectedTabId: tabManager.selectedTabId
        )

        // Defer session sync + persistence to next run loop to avoid
        // "tried to update multiple times per frame" warning
        let connId = connection.id
        let selectedTabId = tabManager.selectedTabId
        DispatchQueue.main.async { [coordinator] in
            guard !coordinator.tabPersistence.isDismissing else { return }
            let combinedTabs = NativeTabRegistry.shared.allTabs(for: connId)
            coordinator.tabPersistence.saveTabsAsync(
                tabs: combinedTabs,
                selectedTabId: selectedTabId
            )

            if combinedTabs.isEmpty {
                coordinator.tabPersistence.clearSavedState()
            }
        }
    }

    private func handleColumnsChange(newColumns: [String]?) {
        // Skip during tab switch — handleTabChange already configures the change manager
        guard !coordinator.isHandlingTabSwitch else { return }

        guard let newColumns = newColumns, !newColumns.isEmpty,
              let tab = tabManager.selectedTab,
              !changeManager.hasChanges
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

    private func handleTableSelectionChange(
        from oldTables: Set<TableInfo>, to newTables: Set<TableInfo>
    ) {
        guard let table = newTables.subtracting(oldTables).first else {
            AppState.shared.hasTableSelection = !newTables.isEmpty
            return
        }

        switch SidebarNavigationResult.resolve(
            clickedTableName: table.name,
            currentTabTableName: tabManager.selectedTab?.tableName,
            hasExistingTabs: !tabManager.tabs.isEmpty
        ) {
        case .skip:
            // Programmatic sync — selection already reflects the active tab.
            AppState.shared.hasTableSelection = !newTables.isEmpty
            return
        case .openInPlace:
            selectedRowIndices = []
            coordinator.openTableTab(table.name, isView: table.type == .view)
        case .revertAndOpenNewWindow:
            // Revert sidebar SYNCHRONOUSLY so SwiftUI coalesces [B]→[A] into one
            // render pass — the source window never visually flashes the new table.
            syncSidebarToCurrentTab()
            coordinator.openTableTab(table.name, isView: table.type == .view)
        }

        AppState.shared.hasTableSelection = !newTables.isEmpty
    }

    /// Keep sidebar selection in sync with the current window's tab
    private func syncSidebarToCurrentTab() {
        if let currentTableName = tabManager.selectedTab?.tableName,
           let match = tables.first(where: { $0.name == currentTableName }) {
            selectedTables = [match]
        } else {
            selectedTables = []
        }
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
        payload: nil,
        windowTitle: .constant("SQL Query"),
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

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
    /// Payload identifying what this window-tab should display (nil = default query tab)
    let payload: EditorTabPayload?

    // Shared state from parent
    @Binding var windowTitle: String
    @Binding var tables: [TableInfo]
    var sidebarState: SharedSidebarState
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>
    @Binding var tableOperationOptions: [String: TableOperationOptions]
    @Binding var inspectorContext: InspectorContext
    var rightPanelState: RightPanelState

    // MARK: - State Objects

    @State private var tabManager: QueryTabManager
    @State private var changeManager: DataChangeManager
    @State private var filterStateManager: FilterStateManager
    @State private var toolbarState: ConnectionToolbarState
    @State var coordinator: MainContentCoordinator

    // MARK: - Local State

    @State var selectedRowIndices: Set<Int> = []
    @State private var previousSelectedTabId: UUID?
    @State private var previousSelectedTables: Set<TableInfo> = []
    @State private var editingCell: CellPosition?
    @State private var commandActions: MainContentCommandActions?
    @State private var queryResultsSummaryCache: (tabId: UUID, version: Int, summary: String?)?
    @State private var inspectorUpdateTask: Task<Void, Never>?
    /// Stable identifier for this window in WindowLifecycleMonitor
    @State private var windowId = UUID()
    @State private var hasInitialized = false
    /// Tracks whether this view's window is the key (focused) window
    @State private var isKeyWindow = false
    /// Reference to this view's NSWindow for filtering notifications
    @State private var viewWindow: NSWindow?

    // MARK: - Environment

    @Environment(AppState.self) private var appState

    // MARK: - Initialization

    init(
        connection: DatabaseConnection,
        payload: EditorTabPayload?,
        windowTitle: Binding<String>,
        tables: Binding<[TableInfo]>,
        sidebarState: SharedSidebarState,
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
        self.sidebarState = sidebarState
        self._pendingTruncates = pendingTruncates
        self._pendingDeletes = pendingDeletes
        self._tableOperationOptions = tableOperationOptions
        self._inspectorContext = inspectorContext
        self.rightPanelState = rightPanelState

        // Create state objects — each native window-tab gets its own instances
        let tabMgr = QueryTabManager()
        let changeMgr = DataChangeManager()
        let filterMgr = FilterStateManager()
        let toolbarSt = ConnectionToolbarState(connection: connection)

        // Eagerly populate version + state from existing session to avoid flash
        if let session = DatabaseManager.shared.session(for: connection.id) {
            toolbarSt.updateConnectionState(from: session.status)
            if let driver = session.driver {
                toolbarSt.databaseVersion = driver.serverVersion
            }
        } else if let driver = DatabaseManager.shared.driver(for: connection.id) {
            toolbarSt.connectionState = .connected
            toolbarSt.databaseVersion = driver.serverVersion
        }
        toolbarSt.hasCompletedSetup = true

        // Redis: set initial database name eagerly to avoid toolbar flash
        if connection.type == .redis {
            let dbIndex = connection.redisDatabase ?? Int(connection.database) ?? 0
            toolbarSt.databaseName = String(dbIndex)
        }

        // Initialize single tab based on payload
        if let payload, !payload.isConnectionOnly {
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
            }
        }
        // If payload is nil or connection-only, tab restoration handles it in initializeAndRestoreTabs()

        _tabManager = State(wrappedValue: tabMgr)
        _changeManager = State(wrappedValue: changeMgr)
        _filterStateManager = State(wrappedValue: filterMgr)
        _toolbarState = State(wrappedValue: toolbarSt)

        // Create coordinator with all dependencies
        _coordinator = State(
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
            let session = DatabaseManager.shared.session(for: connection.id)
            let activeDatabase = session?.currentDatabase ?? connection.database
            let activeSchema = session?.currentSchema
            let currentSelection = connection.type == .redshift
                ? (activeSchema ?? activeDatabase)
                : activeDatabase
            DatabaseSwitcherSheet(
                isPresented: dismissBinding,
                currentDatabase: currentSelection,
                currentSchema: activeSchema,
                databaseType: connection.type,
                connectionId: connection.id,
                onSelect: switchDatabase,
                onSelectSchema: { schema in
                    Task { await coordinator.switchSchema(to: schema) }
                }
            )
        case .exportDialog:
            ExportDialog(
                isPresented: dismissBinding,
                connection: connection,
                preselectedTables: Set(sidebarState.selectedTables.map(\.name))
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
            .task(id: currentTab?.tableName) {
                // Only load metadata after the tab has executed at least once —
                // avoids a redundant DB query racing with the initial data query
                guard currentTab?.lastExecutedAt != nil else { return }
                await loadTableMetadataIfNeeded()
            }
            .onChange(of: inspectorTrigger) {
                scheduleInspectorUpdate()
            }
            .onAppear {
                coordinator.markActivated()

                // Set window title for empty state (no tabs restored)
                if tabManager.tabs.isEmpty {
                    windowTitle = connection.name
                }
                setupCommandActions()
                updateToolbarPendingState()
                updateInspectorContext()
                rightPanelState.aiViewModel.schemaProvider = coordinator.schemaProvider

                // Register NSWindow reference and set per-connection tab grouping
                DispatchQueue.main.async {
                    // Find our window by title rather than keyWindow to avoid races
                    // when multiple windows open simultaneously
                    let targetTitle = windowTitle
                    let window = NSApp.keyWindow
                        ?? NSApp.windows.first { $0.isVisible && $0.title == targetTitle }
                    guard let window else { return }
                    window.subtitle = connection.name
                    window.tabbingIdentifier = "com.TablePro.main.\(connection.id.uuidString)"
                    window.tabbingMode = .preferred

                    WindowLifecycleMonitor.shared.register(
                        window: window,
                        connectionId: connection.id,
                        windowId: windowId
                    )
                    viewWindow = window
                    isKeyWindow = window.isKeyWindow
                }
            }
            .onDisappear {
                // Mark teardown intent synchronously so deinit doesn't warn
                // if SwiftUI deallocates the coordinator before the delayed Task fires
                coordinator.markTeardownScheduled()

                let capturedWindowId = windowId
                let connectionId = connection.id
                let connectionName = connection.name
                Task { @MainActor in
                    // 200ms grace period: SwiftUI fires onDisappear transiently during
                    // tab group merges/splits, then re-fires onAppear shortly after.
                    // The onAppear handler re-registers via WindowLifecycleMonitor on
                    // DispatchQueue.main.async, so this delay must exceed that dispatch
                    // latency to avoid tearing down a window that's about to reappear.
                    try? await Task.sleep(for: .milliseconds(200))

                    // If this window re-registered (temporary disappear during tab group merge), skip cleanup
                    if WindowLifecycleMonitor.shared.isRegistered(windowId: capturedWindowId) {
                        coordinator.clearTeardownScheduled()
                        return
                    }

                    // Window truly closed — teardown coordinator
                    coordinator.teardown()

                    // If no more windows for this connection, disconnect.
                    // Tab state is NOT cleared here — it's preserved for next reconnect.
                    // Only handleTabsChange(count=0) clears state (user explicitly closed all tabs).
                    guard !WindowLifecycleMonitor.shared.hasWindows(for: connectionId) else { return }

                    let hasVisibleWindow = NSApp.windows.contains { window in
                        window.isVisible && window.subtitle == connectionName
                    }
                    if !hasVisibleWindow {
                        await DatabaseManager.shared.disconnectSession(connectionId)
                    }
                }
            }
            .onChange(of: pendingChangeTrigger) {
                updateToolbarPendingState()
            }
    }

    private var bodyContentCore: some View {
        mainContentView
            .openTableToolbar(state: toolbarState)
            .modifier(ToolbarTintModifier(connectionColor: connection.color))
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
            .onChange(of: DatabaseManager.shared.sessionVersion, initial: true) { _, _ in
                let sessions = DatabaseManager.shared.activeSessions
                guard let session = sessions[connection.id] else { return }
                if session.isConnected && coordinator.needsLazyLoad {
                    coordinator.needsLazyLoad = false
                    if let selectedTab = tabManager.selectedTab,
                       !selectedTab.databaseName.isEmpty,
                       selectedTab.databaseName != session.activeDatabase
                    {
                        Task { await coordinator.switchDatabase(to: selectedTab.databaseName) }
                    } else {
                        coordinator.runQuery()
                    }
                }
                let mappedState = mapSessionStatus(session.status)
                if mappedState != toolbarState.connectionState {
                    toolbarState.connectionState = mappedState
                }
            }

            .onChange(of: sidebarState.selectedTables) { _, newTables in
                handleTableSelectionChange(from: previousSelectedTables, to: newTables)
                previousSelectedTables = newTables
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard let notificationWindow = notification.object as? NSWindow,
                      notificationWindow === viewWindow else { return }
                isKeyWindow = true
                DispatchQueue.main.async {
                    syncSidebarToCurrentTab()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
                guard let notificationWindow = notification.object as? NSWindow,
                      notificationWindow === viewWindow else { return }
                isKeyWindow = false
            }
            .onChange(of: tables) { _, newTables in
                let syncAction = SidebarSyncAction.resolveOnTablesLoad(
                    newTables: newTables,
                    selectedTables: sidebarState.selectedTables,
                    currentTabTableName: tabManager.selectedTab?.tableName
                )
                if case let .select(tableName) = syncAction,
                   let match = newTables.first(where: { $0.name == tableName }) {
                    sidebarState.selectedTables = [match]
                }
            }
            .onChange(of: selectedRowIndices) { _, newIndices in
                AppState.shared.hasRowSelection = !newIndices.isEmpty
                if !newIndices.isEmpty,
                   AppSettingsManager.shared.dataGrid.autoShowInspector,
                   tabManager.selectedTab?.tabType == .table
                {
                    rightPanelState.isPresented = true
                }
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
                scheduleInspectorUpdate()
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
        Task { await coordinator.loadSchemaIfNeeded() }

        // If payload provided a specific tab (not connection-only), execute its query immediately
        if let payload, !payload.isConnectionOnly {
            if let selectedTab = tabManager.selectedTab,
               selectedTab.tabType == .table,
               !selectedTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                // Fast path: connection already ready
                if let session = DatabaseManager.shared.activeSessions[connection.id],
                   session.isConnected
                {
                    if !selectedTab.databaseName.isEmpty,
                       selectedTab.databaseName != session.activeDatabase
                    {
                        Task { await coordinator.switchDatabase(to: selectedTab.databaseName) }
                    } else {
                        coordinator.executeTableTabQueryDirectly()
                    }
                } else {
                    // Reactive path: fires via onChange(of: sessionVersion) when connection is ready
                    coordinator.needsLazyLoad = true
                }
            }
            return
        }

        // Connection-only payload or nil payload -- restore tabs from storage
        // If other windows already exist for this connection, this is a "new tab"
        // from the native macOS "+" button -- just add a single empty query tab.
        if WindowLifecycleMonitor.shared.hasOtherWindows(for: connection.id, excluding: windowId) {
            tabManager.addTab(databaseName: connection.database)
            return
        }

        // No existing windows -- restore tabs from storage (first window on connection)
        let result = await coordinator.persistence.restoreFromDisk()
        if !result.tabs.isEmpty {
            // Find the selected tab, or use the first one
            let selectedId = result.selectedTabId
            let selectedIndex = result.tabs.firstIndex(where: { $0.id == selectedId }) ?? 0

            // Keep only the selected tab for this window
            let selectedTab = result.tabs[selectedIndex]
            tabManager.tabs = [selectedTab]
            tabManager.selectedTabId = selectedTab.id

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
                    if !selectedTab.databaseName.isEmpty,
                       selectedTab.databaseName != session.activeDatabase
                    {
                        Task { await coordinator.switchDatabase(to: selectedTab.databaseName) }
                    } else {
                        coordinator.executeTableTabQueryDirectly()
                    }
                } else {
                    // Reactive path: fires via onChange(of: sessionVersion) when connection is ready
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
            selectedTables: Binding(
                get: { sidebarState.selectedTables },
                set: { sidebarState.selectedTables = $0 }
            ),
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
        let queryLabel = connection.type == .mongodb ? "MQL Query" : connection.type == .redis ? "Redis Query" : "SQL Query"
        windowTitle = tabManager.selectedTab?.tableName
            ?? (tabManager.tabs.isEmpty ? connection.name : queryLabel)

        // Sync sidebar selection to match the newly selected tab.
        // Critical for new native windows: localSelectedTables starts empty,
        // and this is the only place that can seed it from the restored tab.
        syncSidebarToCurrentTab()

        // Persist tab selection explicitly (skip during teardown)
        guard !coordinator.isTearingDown else { return }
        coordinator.persistence.saveNow(
            tabs: tabManager.tabs,
            selectedTabId: newTabId
        )
    }

    private func handleTabsChange(_ newTabs: [QueryTab]) {
        // Always update window title to reflect current tab, even during restoration
        let queryLabel = connection.type == .mongodb ? "MQL Query" : connection.type == .redis ? "Redis Query" : "SQL Query"
        windowTitle = tabManager.selectedTab?.tableName
            ?? (tabManager.tabs.isEmpty ? connection.name : queryLabel)

        // Don't persist during teardown — SwiftUI may fire onChange with empty tabs
        // as the view is being deallocated
        guard !coordinator.isTearingDown else { return }

        // Persist tab changes explicitly
        if newTabs.isEmpty {
            coordinator.persistence.clearSavedState()
        } else {
            coordinator.persistence.saveNow(
                tabs: newTabs,
                selectedTabId: tabManager.selectedTabId
            )
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
        let action = TableSelectionAction.resolve(oldTables: oldTables, newTables: newTables)

        guard case let .navigate(tableName, isView) = action else {
            AppState.shared.hasTableSelection = !newTables.isEmpty
            return
        }

        // Only navigate when this is the focused window.
        // Prevents feedback loops when shared sidebar state syncs across native tabs.
        guard isKeyWindow else {
            AppState.shared.hasTableSelection = !newTables.isEmpty
            return
        }

        let result = SidebarNavigationResult.resolve(
            clickedTableName: tableName,
            currentTabTableName: tabManager.selectedTab?.tableName,
            hasExistingTabs: !tabManager.tabs.isEmpty
        )

        switch result {
        case .skip:
            AppState.shared.hasTableSelection = !newTables.isEmpty
            return
        case .openInPlace:
            selectedRowIndices = []
            coordinator.openTableTab(tableName, isView: isView)
        case .revertAndOpenNewWindow:
            coordinator.openTableTab(tableName, isView: isView)
        }

        AppState.shared.hasTableSelection = !newTables.isEmpty
    }

    /// Keep sidebar selection in sync with the current window's tab.
    /// Only writes when the value actually changes, preventing spurious onChange triggers.
    /// Navigation safety is guaranteed by `SidebarNavigationResult.resolve` returning `.skip`
    /// when the selected table matches the current tab.
    private func syncSidebarToCurrentTab() {
        let target: Set<TableInfo>
        if let currentTableName = tabManager.selectedTab?.tableName,
           let match = tables.first(where: { $0.name == currentTableName }) {
            target = [match]
        } else {
            target = []
        }
        if sidebarState.selectedTables != target {
            sidebarState.selectedTables = target
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
                guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
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
        guard let tab = coordinator.tabManager.selectedTab,
              !selectedRowIndices.isEmpty
        else {
            rightPanelState.editState.fields = []
            rightPanelState.editState.onFieldChanged = nil
            return
        }

        var allRows: [[String?]] = []
        for index in selectedRowIndices.sorted() {
            if index < tab.resultRows.count {
                allRows.append(tab.resultRows[index].values)
            }
        }

        // Enrich column types with loaded enum values from Phase 2b
        var columnTypes = tab.columnTypes
        for (i, col) in tab.resultColumns.enumerated() where i < columnTypes.count {
            if let values = tab.columnEnumValues[col], !values.isEmpty {
                let ct = columnTypes[i]
                if ct.isEnumType {
                    columnTypes[i] = .enumType(rawType: ct.rawType, values: values)
                } else if ct.isSetType {
                    columnTypes[i] = .set(rawType: ct.rawType, values: values)
                }
            }
        }

        // Clear stale sidebar edits after refresh/discard
        if !changeManager.hasChanges {
            rightPanelState.editState.clearEdits()
        }

        // Collect columns modified in data grid so sidebar shows green dots
        var modifiedColumns = Set<Int>()
        for rowIndex in selectedRowIndices {
            modifiedColumns.formUnion(changeManager.getModifiedColumnsForRow(rowIndex))
        }

        rightPanelState.editState.configure(
            selectedRowIndices: selectedRowIndices,
            allRows: allRows,
            columns: tab.resultColumns,
            columnTypes: columnTypes,
            externallyModifiedColumns: modifiedColumns
        )

        guard isSidebarEditable else {
            rightPanelState.editState.onFieldChanged = nil
            return
        }

        let capturedCoordinator = coordinator
        let capturedEditState = rightPanelState.editState
        rightPanelState.editState.onFieldChanged = { columnIndex, newValue in
            guard let tab = capturedCoordinator.tabManager.selectedTab else { return }
            let columnName = columnIndex < tab.resultColumns.count ? tab.resultColumns[columnIndex] : ""

            for rowIndex in capturedEditState.selectedRowIndices {
                guard rowIndex < tab.resultRows.count else { continue }
                let originalRow = tab.resultRows[rowIndex].values
                let oldValue = columnIndex < originalRow.count ? originalRow[columnIndex] : nil

                capturedCoordinator.changeManager.recordCellChange(
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    columnName: columnName,
                    oldValue: oldValue,
                    newValue: newValue,
                    originalRow: originalRow
                )
            }
        }
    }

    // MARK: - Inspector Context

    /// Coalesces multiple onChange-triggered updates into a single deferred call.
    /// During tab switch, onChange handlers fire 3-4x — this ensures we only rebuild once,
    /// and defers the work so SwiftUI can render the tab switch first.
    private func scheduleInspectorUpdate() {
        inspectorUpdateTask?.cancel()
        inspectorUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            updateSidebarEditState()
            updateInspectorContext()
        }
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

// MARK: - Toolbar Tint Modifier

/// Applies a subtle color tint to the window toolbar when a connection color is set.
private struct ToolbarTintModifier: ViewModifier {
    let connectionColor: ConnectionColor

    @ViewBuilder
    func body(content: Content) -> some View {
        if connectionColor.isDefault {
            content
                .toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content
                .toolbarBackground(connectionColor.color.opacity(0.12), for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        }
    }
}

// MARK: - Focused Command Actions Modifier

/// Conditionally publishes `MainContentCommandActions` as a focused scene value.
/// `focusedSceneValue` requires a non-optional value, so this modifier
/// only applies it when the actions object has been created.
private struct FocusedCommandActionsModifier: ViewModifier {
    let actions: MainContentCommandActions?

    func body(content: Content) -> some View {
        if let actions {
            content.focusedSceneValue(\.commandActions, actions)
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
        sidebarState: SharedSidebarState(),
        pendingTruncates: .constant([]),
        pendingDeletes: .constant([]),
        tableOperationOptions: .constant([:]),
        inspectorContext: .constant(.empty),
        rightPanelState: RightPanelState()
    )
    .frame(width: 1_000, height: 600)
}

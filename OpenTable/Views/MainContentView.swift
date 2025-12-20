//
//  MainContentView.swift
//  OpenTable
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Combine
import SwiftUI

/// Main content view combining query editor and results table
struct MainContentView: View {
    let connection: DatabaseConnection

    // Shared table state from parent
    @Binding var tables: [TableInfo]
    @Binding var selectedTable: TableInfo?
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>

    @StateObject private var tabManager = QueryTabManager()
    @StateObject private var changeManager = DataChangeManager()

    @State private var selectedRowIndices: Set<Int> = []

    // Unified alert for all discard scenarios
    enum DiscardAction {
        case refresh
        case closeTab
        case refreshAll
    }
    @State private var pendingDiscardAction: DiscardAction?

    @State private var schemaProvider: SQLSchemaProvider = SQLSchemaProvider()
    @State private var cursorPosition: Int = 0
    @State private var currentQueryTask: Task<Void, Never>?
    @State private var queryGeneration: Int = 0
    @State private var changeManagerUpdateTask: Task<Void, Never>?

    // Error alert state
    @State private var showErrorAlert = false
    @State private var errorAlertMessage = ""

    // MARK: - Toolbar State

    /// Observable state for the production-quality toolbar
    @StateObject private var toolbarState = ConnectionToolbarState()

    private var currentTab: QueryTab? {
        tabManager.selectedTab
    }

    @ViewBuilder
    var body: some View {
        Group {
            bodyContent
        }
    }

    // MARK: - Main Content View

    @ViewBuilder
    private var mainContentView: some View {
        // Main content area (no right sidebar - not implemented)
        mainEditorContent
    }

    // MARK: - Main Editor Content

    @ViewBuilder
    private var mainEditorContent: some View {
        VStack(spacing: 0) {
            // Tab bar - only show when there are tabs
            if !tabManager.tabs.isEmpty {
                QueryTabBar(tabManager: tabManager)
                Divider()
            }

            // Content for selected tab
            if let tab = currentTab {
                if tab.tabType == .query {
                    // Query Tab: Editor + Results
                    queryTabContent(tab: tab)
                } else {
                    // Table Tab: Results only
                    tableTabContent(tab: tab)
                }
            } else {
                // Empty state when no tabs are open
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.system(size: 64))
                        .foregroundStyle(.tertiary)

                    Text("No tabs open")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Text("Select a table from the sidebar")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - View with Toolbar

    @ViewBuilder
    private var viewWithToolbar: some View {
        mainContentView
            .openTableToolbar(state: toolbarState)
            .onChange(of: currentTab?.isExecuting) { _, isExecuting in
                // Sync execution state to toolbar
                Task { @MainActor in
                    toolbarState.isExecuting = isExecuting ?? false
                }
            }
            .onChange(of: currentTab?.executionTime) { _, executionTime in
                // Update last query duration in toolbar (only when there's a value - preserve last time)
                if let time = executionTime {
                    Task { @MainActor in
                        toolbarState.lastQueryDuration = time
                    }
                }
            }
            .onChange(of: DatabaseManager.shared.currentSession?.status) { _, newStatus in
                // Update toolbar connection state when session status changes
                if let status = newStatus {
                    Task { @MainActor in
                        toolbarState.connectionState = mapSessionStatus(status)
                    }
                }
            }
    }

    // MARK: - Discard Alert Binding
    
    /// Extracted binding to reduce type-checker complexity
    private var showDiscardAlert: Binding<Bool> {
        Binding(
            get: { pendingDiscardAction != nil },
            set: { if !$0 { pendingDiscardAction = nil } }
        )
    }
    
    /// Message for discard alert based on pending action
    private var discardAlertMessage: String {
        guard let action = pendingDiscardAction else { return "" }
        switch action {
        case .refresh, .refreshAll:
            return "Refreshing will discard all unsaved changes."
        case .closeTab:
            return "Closing this tab will discard all unsaved changes."
        }
    }

    // MARK: - Body Content

    @ViewBuilder
    private var bodyContent: some View {
        bodyContentWithNotifications
            .alert("Discard Unsaved Changes?", isPresented: showDiscardAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) {
                    handleDiscard()
                }
            } message: {
                Text(discardAlertMessage)
            }
            .alert("Query Error", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {
                    // Clear the error message from the tab
                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].errorMessage = nil
                    }
                }
            } message: {
                Text(errorAlertMessage)
            }
            .onChange(of: tabManager.selectedTabId) { oldTabId, newTabId in
                Task { @MainActor in
                    handleTabChange(oldTabId: oldTabId, newTabId: newTabId)
                }
            }
            .onChange(of: currentTab?.resultColumns) { _, newColumns in
                Task { @MainActor in
                    handleColumnsChange(newColumns: newColumns)
                }
            }
            .onChange(of: currentTab?.errorMessage) { _, newError in
                // Show error alert when errorMessage is set
                if let error = newError, !error.isEmpty {
                    errorAlertMessage = error
                    showErrorAlert = true
                }
            }
    }
    
    /// Separated to reduce type-checker complexity
    @ViewBuilder
    private var bodyContentWithNotifications: some View {
        viewWithToolbar
            .task {
                await initializeView()
            }
            .onChange(of: selectedTable) { _, newTable in
                if let table = newTable {
                    // Defer state changes to avoid "Publishing changes from within view updates" error
                    Task { @MainActor in
                        openTableData(table.name)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshAll)) { _ in
                Task { @MainActor in
                    handleRefreshAll()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newTab)) { _ in
                // Cmd+T to create new query tab
                Task { @MainActor in
                    tabManager.addTab()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeCurrentTab)) { _ in
                Task { @MainActor in
                    handleCloseAction()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .saveChanges)) { _ in
                // Cmd+S to save changes
                Task { @MainActor in
                    saveChanges()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshData)) { _ in
                Task { @MainActor in
                    // Cmd+R to refresh data - warn if pending changes
                    let hasEditedCells = changeManager.hasChanges
                    let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

                    if hasEditedCells || hasPendingTableOps {
                        pendingDiscardAction = .refresh
                    } else {
                        // No changes - refresh table browser and run current query
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .refreshAll, object: nil)
                        }
                        runQuery()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedRows)) { _ in
                // Delete key to mark selected rows for deletion
                Task { @MainActor in
                    deleteSelectedRows()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .databaseDidConnect)) { _ in
                // Load schema and update toolbar when connection is established (fixes race condition)
                Task { @MainActor in
                    await loadSchema()
                    // Update version after connection is fully established
                    if let driver = DatabaseManager.shared.activeDriver {
                        toolbarState.databaseVersion = driver.serverVersion
                    }
                }
            }
    }

    // MARK: - Query Tab Content

    private func queryTabContent(tab: QueryTab) -> some View {
        VSplitView {
            // Query Editor (top)
            VStack(spacing: 0) {
                QueryEditorView(
                    queryText: Binding(
                        get: { tab.query },
                        set: { newValue in
                            if let index = tabManager.selectedTabIndex {
                                tabManager.tabs[index].query = newValue
                            }
                        }
                    ),
                    cursorPosition: $cursorPosition,
                    onExecute: runQuery,
                    schemaProvider: schemaProvider
                )
            }
            .frame(minHeight: 100, idealHeight: 200)

            // Results Table (bottom)
            resultsSection(tab: tab)
        }
    }

    // MARK: - Table Tab Content

    private func tableTabContent(tab: QueryTab) -> some View {
        resultsSection(tab: tab)
    }

    // MARK: - Results Section (shared)

    private func resultsSection(tab: QueryTab) -> some View {
        VStack(spacing: 0) {
            // Show structure view or data view based on toggle
            if tab.showStructure, let tableName = tab.tableName {
                TableStructureView(tableName: tableName, connection: connection)
                    .frame(maxHeight: .infinity)
            } else {
                DataGridView(
                    rowProvider: InMemoryRowProvider(
                        rows: sortedRows(for: tab),
                        columns: tab.resultColumns,
                        columnDefaults: tab.columnDefaults
                    ),
                    changeManager: changeManager,
                    isEditable: tab.isEditable,
                    onCommit: { sql in
                        executeCommitSQL(sql)
                    },
                    onRefresh: { runQuery() },
                    onCellEdit: { rowIndex, colIndex, newValue in
                        updateCellInTab(rowIndex: rowIndex, columnIndex: colIndex, value: newValue)
                    },
                    onSort: { columnIndex, ascending in
                        handleSort(columnIndex: columnIndex, ascending: ascending)
                    },
                    selectedRowIndices: $selectedRowIndices,
                    sortState: sortStateBinding
                )
                .frame(maxHeight: .infinity, alignment: .top)
            }

            statusBar
        }
        .frame(minHeight: 150)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            // Data/Structure toggle for table tabs (TablePlus style - bottom left)
            if let tab = currentTab, tab.tabType == .table, tab.tableName != nil {
                Picker(
                    "",
                    selection: Binding(
                        get: { tab.showStructure ? "structure" : "data" },
                        set: { newValue in
                            DispatchQueue.main.async {
                                if let index = tabManager.selectedTabIndex {
                                    tabManager.tabs[index].showStructure = (newValue == "structure")
                                }
                            }
                        }
                    )
                ) {
                    Label("Data", systemImage: "tablecells").tag("data")
                    Label("Structure", systemImage: "list.bullet.rectangle").tag("structure")
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .controlSize(.small)
                .offset(x: -20)
            }

            Spacer()

            if let tab = currentTab, !tab.resultRows.isEmpty {
                Text("\(tab.resultRows.count) rows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Actions

    /// Initialize view with connection info
    private func initializeView() async {
        // Initialize toolbar with connection info
        await MainActor.run {
            toolbarState.update(from: connection)

            // Get actual connection state from session
            if let session = DatabaseManager.shared.currentSession {
                toolbarState.connectionState = mapSessionStatus(session.status)
                if let driver = session.driver {
                    toolbarState.databaseVersion = driver.serverVersion
                }
            } else if let driver = DatabaseManager.shared.activeDriver {
                // Fallback for backward compatibility
                toolbarState.connectionState = .connected
                toolbarState.databaseVersion = driver.serverVersion
            }
        }

        // Load schema for autocomplete
        await loadSchema()
    }

    /// Map ConnectionStatus to ToolbarConnectionState
    private func mapSessionStatus(_ status: ConnectionStatus) -> ToolbarConnectionState {
        switch status {
        case .connected:
            return .connected
        case .connecting:
            return .executing  // Show as executing during connection
        case .disconnected:
            return .disconnected
        case .error:
            return .error("")
        }
    }

    private func loadSchema() async {
        // Use activeDriver from DatabaseManager (already connected with SSH tunnel if enabled)
        guard let driver = DatabaseManager.shared.activeDriver else {
            // Driver not ready yet (e.g., SSH tunnel still connecting) - this is normal
            return
        }
        await schemaProvider.loadSchema(using: driver, connection: connection)
    }

    private func runQuery() {
        guard let index = tabManager.selectedTabIndex else { return }

        // Cancel any previous running query to prevent race conditions
        // This is critical for SSH connections where rapid sorting can cause
        // multiple queries to return out of order, leading to EXC_BAD_ACCESS
        currentQueryTask?.cancel()

        // Increment generation - any query with a different generation will be ignored
        queryGeneration += 1
        let capturedGeneration = queryGeneration

        guard !tabManager.tabs[index].isExecuting else { return }

        tabManager.tabs[index].isExecuting = true
        tabManager.tabs[index].executionTime = nil
        tabManager.tabs[index].errorMessage = nil

        // Update toolbar to show spinner
        toolbarState.isExecuting = true

        // Note: We don't discard changes here anymore - changes persist until:
        // 1. User saves (Cmd+S)
        // 2. User explicitly discards (via alert)
        // 3. Tab is closed

        let fullQuery = tabManager.tabs[index].query

        // Extract query at cursor position (like TablePlus)
        let sql = extractQueryAtCursor(from: fullQuery, at: cursorPosition)

        // Don't execute empty queries (avoids MySQL Error 1065: Query was empty)
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            tabManager.tabs[index].isExecuting = false
            toolbarState.isExecuting = false
            return
        }

        let conn = connection
        let tabId = tabManager.tabs[index].id

        // Detect table name from simple SELECT queries
        let tableName = extractTableName(from: sql)
        let isEditable = tableName != nil

        currentQueryTask = Task {
            do {
                let result = try await executeQueryAsync(sql: sql, connection: conn)

                // Fetch column defaults if editable table
                var columnDefaults: [String: String?] = [:]
                if isEditable, let tableName = tableName {
                    // Use activeDriver from DatabaseManager (already connected with SSH tunnel)
                    if let driver = DatabaseManager.shared.activeDriver {
                        let columnInfo = try await driver.fetchColumns(table: tableName)
                        for col in columnInfo {
                            columnDefaults[col.name] = col.defaultValue
                        }
                    }
                }

                // ===== CRITICAL: Deep copy ALL data BEFORE leaving this async context =====
                // Create NEW String objects to avoid any reference to underlying C buffers
                var safeColumns: [String] = []
                for col in result.columns {
                    safeColumns.append(String(col))
                }

                var safeRows: [QueryResultRow] = []
                for row in result.rows {
                    var safeValues: [String?] = []
                    for val in row {
                        if let v = val {
                            safeValues.append(String(v))
                        } else {
                            safeValues.append(nil)
                        }
                    }
                    safeRows.append(QueryResultRow(values: safeValues))
                }

                let safeExecutionTime = result.executionTime

                // Copy columnDefaults too
                var safeColumnDefaults: [String: String?] = [:]
                for (key, value) in columnDefaults {
                    safeColumnDefaults[String(key)] = value.map { String($0) }
                }

                let safeTableName = tableName.map { String($0) }

                // Check if task was cancelled (e.g., user triggered another sort)
                // This prevents race conditions where cancelled queries still try to update UI
                guard !Task.isCancelled else {
                    await MainActor.run {
                        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                            tabManager.tabs[idx].isExecuting = false
                        }
                        // Also update toolbar state with execution time (even for cancelled tasks)
                        toolbarState.isExecuting = false
                        toolbarState.lastQueryDuration = safeExecutionTime
                    }
                    return
                }

                // Find tab by ID (index may have changed) - must update on main thread
                await MainActor.run {
                    // ALWAYS update toolbar state first - user should see query completion
                    toolbarState.isExecuting = false
                    toolbarState.lastQueryDuration = safeExecutionTime

                    // Only update tab if this is still the most recent query
                    // This prevents race conditions when navigating quickly between tables
                    guard capturedGeneration == queryGeneration else { return }
                    guard !Task.isCancelled else { return }

                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        // CRITICAL: Update tab atomically to prevent objc_retain crashes
                        // with large result sets (25+ columns). Working with a copy first
                        // prevents partial updates that can crash during deallocation.
                        var updatedTab = tabManager.tabs[idx]
                        updatedTab.resultColumns = safeColumns
                        updatedTab.columnDefaults = safeColumnDefaults
                        updatedTab.resultRows = safeRows
                        updatedTab.executionTime = safeExecutionTime
                        updatedTab.isExecuting = false
                        updatedTab.lastExecutedAt = Date()
                        updatedTab.tableName = safeTableName
                        updatedTab.isEditable = isEditable

                        // Atomically replace the tab
                        tabManager.tabs[idx] = updatedTab

                        // IMPORTANT: We do NOT update changeManager here.
                        // After extensive debugging, updating changeManager from async
                        // Task completion causes EXC_BAD_ACCESS crashes during rapid navigation.
                        // The onChange(selectedTabId) handler updates changeManager synchronously
                        // when this tab becomes selected, which is safe and reliable.
                    }
                }

            } catch {
                // Only update if this is still the current query
                guard capturedGeneration == queryGeneration else { return }

                // MUST run on MainActor for SwiftUI onChange to fire
                await MainActor.run {
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.tabs[idx].errorMessage = error.localizedDescription
                        tabManager.tabs[idx].isExecuting = false
                    }
                    toolbarState.isExecuting = false
                }
            }
        }
    }

    private func executeQueryAsync(sql: String, connection: DatabaseConnection) async throws
        -> QueryResult
    {
        // Use DatabaseManager to execute query - this ensures proper thread safety
        return try await DatabaseManager.shared.execute(query: sql)
    }

    /// Extract table name from a simple SELECT query
    private func extractTableName(from sql: String) -> String? {
        let pattern =
            #"(?i)^\s*SELECT\s+.+?\s+FROM\s+[`"]?(\w+)[`"]?\s*(?:WHERE|ORDER|LIMIT|GROUP|HAVING|$|;)"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
            let match = regex.firstMatch(
                in: sql, options: [], range: NSRange(sql.startIndex..., in: sql)),
            let range = Range(match.range(at: 1), in: sql)
        else {
            return nil
        }

        return String(sql[range])
    }

    /// Extract the SQL statement at the cursor position (semicolon-delimited)
    /// This enables TablePlus-like behavior: execute only the current query, not all queries
    private func extractQueryAtCursor(from fullQuery: String, at position: Int) -> String {
        let trimmed = fullQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // If no semicolons, return the entire query
        guard trimmed.contains(";") else { return trimmed }

        // Split by semicolon but keep track of positions
        var statements: [(text: String, range: Range<Int>)] = []
        var currentStart = 0
        var inString = false
        var stringChar: Character = "\""

        for (i, char) in fullQuery.enumerated() {
            // Track string literals to avoid splitting on semicolons inside strings
            if char == "'" || char == "\"" {
                if !inString {
                    inString = true
                    stringChar = char
                } else if char == stringChar {
                    inString = false
                }
            }

            // Found a statement delimiter
            if char == ";" && !inString {
                let statement = String(
                    fullQuery[
                        fullQuery.index(
                            fullQuery.startIndex, offsetBy: currentStart)..<fullQuery.index(
                                fullQuery.startIndex, offsetBy: i)]
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                if !statement.isEmpty {
                    statements.append((text: statement, range: currentStart..<(i + 1)))
                }
                currentStart = i + 1
            }
        }

        // Don't forget the last statement (may not end with ;)
        if currentStart < fullQuery.count {
            let remaining = String(
                fullQuery[fullQuery.index(fullQuery.startIndex, offsetBy: currentStart)...]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                statements.append((text: remaining, range: currentStart..<fullQuery.count))
            }
        }

        // Find the statement containing the cursor position
        let safePosition = min(max(0, position), fullQuery.count)
        for statement in statements {
            if statement.range.contains(safePosition) || statement.range.upperBound == safePosition
            {
                return statement.text
            }
        }

        // If cursor is at end or no match, return last statement
        return statements.last?.text ?? trimmed
    }

    /// Update cell value in the current tab's resultRows
    private func updateCellInTab(rowIndex: Int, columnIndex: Int, value: String?) {
        guard let index = tabManager.selectedTabIndex,
            rowIndex < tabManager.tabs[index].resultRows.count
        else { return }

        // Update the underlying data so it persists across UI refreshes
        tabManager.tabs[index].resultRows[rowIndex].values[columnIndex] = value

        // Mark tab as having user interaction (prevents auto-replacement)
        tabManager.tabs[index].hasUserInteraction = true
    }

    /// Delete selected rows (Delete key)
    private func deleteSelectedRows() {
        guard let index = tabManager.selectedTabIndex,
            !selectedRowIndices.isEmpty
        else { return }

        // Mark each selected row for deletion
        for rowIndex in selectedRowIndices.sorted(by: >) {
            if rowIndex < tabManager.tabs[index].resultRows.count {
                let originalRow = tabManager.tabs[index].resultRows[rowIndex].values
                changeManager.recordRowDeletion(rowIndex: rowIndex, originalRow: originalRow)
            }
        }

        // Clear selection after marking for deletion
        selectedRowIndices.removeAll()

        // Mark tab as having user interaction (prevents auto-replacement)
        tabManager.tabs[index].hasUserInteraction = true
    }

    // MARK: - Column Sorting

    /// Binding for the current tab's sort state
    private var sortStateBinding: Binding<SortState> {
        Binding(
            get: {
                guard let index = tabManager.selectedTabIndex else {
                    return SortState()
                }
                return tabManager.tabs[index].sortState
            },
            set: { newValue in
                if let index = tabManager.selectedTabIndex {
                    tabManager.tabs[index].sortState = newValue
                }
            }
        )
    }

    /// Binding for column widths - persists widths across tab switches

    /// Get rows for a tab with sorting applied
    /// - Query tabs: Sort in-memory (client-side) without modifying SQL
    /// - Table tabs: Return as-is (sorting handled via SQL ORDER BY in handleSort)
    private func sortedRows(for tab: QueryTab) -> [QueryResultRow] {
        // Table tabs: Don't apply client-side sorting
        // Sorting is handled via SQL ORDER BY - if that fails, data stays unsorted
        // This ensures SQL errors (like JSON columns) are properly visible
        if tab.tabType == .table {
            return tab.resultRows
        }

        // Query tabs: Apply client-side sorting
        guard let columnIndex = tab.sortState.columnIndex,
            columnIndex < tab.resultColumns.count
        else {
            return tab.resultRows
        }

        // Sort in memory (used for query tabs where we don't modify the SQL)
        return tab.resultRows.sorted { row1, row2 in
            let val1 = row1.values[columnIndex] ?? ""
            let val2 = row2.values[columnIndex] ?? ""

            if tab.sortState.direction == .ascending {
                return val1.localizedStandardCompare(val2) == .orderedAscending
            } else {
                return val1.localizedStandardCompare(val2) == .orderedDescending
            }
        }
    }

    /// Handle column header click for sorting
    /// - Query tabs: Update sortState only (in-memory sorting via sortedRows)
    /// - Table tabs: Update sortState + modify SQL with ORDER BY
    /// - ascending: Sort direction determined by native NSTableView
    private func handleSort(columnIndex: Int, ascending: Bool) {
        guard let tabIndex = tabManager.selectedTabIndex else { return }

        // Capture all values early to prevent deallocation issues
        guard tabIndex < tabManager.tabs.count else { return }
        let tab = tabManager.tabs[tabIndex]

        // CRITICAL: Validate column index for large tables
        guard columnIndex >= 0 && columnIndex < tab.resultColumns.count else {
            return
        }

        // Capture column name to avoid string retention issues
        let columnName = String(tab.resultColumns[columnIndex])
        
        // Use direction directly from AppKit (no guessing/toggling)
        var currentSort = SortState()
        currentSort.columnIndex = columnIndex
        currentSort.direction = ascending ? .ascending : .descending

        // Verify tab still exists before updating
        guard tabIndex < tabManager.tabs.count else { return }

        // Update sort state (used by both query and table tabs)
        tabManager.tabs[tabIndex].sortState = currentSort

        // Mark tab as having user interaction (prevents auto-replacement)
        tabManager.tabs[tabIndex].hasUserInteraction = true

        // For QUERY tabs: Show loading state during client-side sort
        if tab.tabType == .query {
            Task { @MainActor in
                tabManager.tabs[tabIndex].isExecuting = true

                // Small delay to ensure spinner shows and allow UI to update
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms

                // Sorting happens automatically via sortedRows() on next render
                tabManager.tabs[tabIndex].isExecuting = false
            }
            return
        }

        // For TABLE tabs: Modify SQL with ORDER BY and re-execute

        // Build ORDER BY clause with explicit string copies to avoid retention issues
        let orderDirection = currentSort.direction == .ascending ? "ASC" : "DESC"

        // Get base query (remove any existing ORDER BY) - work with copy
        var baseQuery = String(tab.query)
        if let orderByRange = baseQuery.range(
            of: "ORDER BY", options: [.caseInsensitive, .backwards])
        {
            // Find the end of ORDER BY clause (before LIMIT or end of query)
            let afterOrderBy = baseQuery[orderByRange.upperBound...]
            if let limitRange = afterOrderBy.range(of: "LIMIT", options: .caseInsensitive) {
                // Keep LIMIT, remove ORDER BY clause
                let beforeOrderBy = baseQuery[..<orderByRange.lowerBound]
                let limitClause = baseQuery[limitRange.lowerBound...]
                baseQuery = String(beforeOrderBy) + String(limitClause)
            } else if afterOrderBy.range(of: ";") != nil {
                // Remove ORDER BY until semicolon
                baseQuery = String(baseQuery[..<orderByRange.lowerBound]) + ";"
            } else {
                // Remove ORDER BY until end
                baseQuery = String(baseQuery[..<orderByRange.lowerBound])
            }
        }

        // Insert ORDER BY before LIMIT (if exists) or at end
        // Use database-specific identifier quoting
        let quote = connection.type.identifierQuote
        let orderByClause = "ORDER BY \(quote)\(columnName)\(quote) \(orderDirection)"

        let newQuery: String
        if let limitRange = baseQuery.range(of: "LIMIT", options: .caseInsensitive) {
            let beforeLimit = baseQuery[..<limitRange.lowerBound].trimmingCharacters(
                in: .whitespaces)
            let limitClause = baseQuery[limitRange.lowerBound...]
            newQuery = "\(beforeLimit) \(orderByClause) \(limitClause)"
        } else {
            // Remove trailing semicolon and add ORDER BY
            let trimmed = baseQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix(";") {
                newQuery = String(trimmed.dropLast()) + " \(orderByClause);"
            } else {
                newQuery = "\(trimmed) \(orderByClause)"
            }
        }

        // Final validation before updating tab
        guard tabIndex < tabManager.tabs.count else { return }
        tabManager.tabs[tabIndex].query = newQuery

        // Re-execute query to fetch sorted data
        runQuery()
    }

    // MARK: - Event Handlers

    /// Handle tab selection changes
    private func handleTabChange(oldTabId: UUID?, newTabId: UUID?) {
        // Save state to the old tab before switching
        if let oldId = oldTabId,
            let oldIndex = tabManager.tabs.firstIndex(where: { $0.id == oldId })
        {
            // Save pending changes
            tabManager.tabs[oldIndex].pendingChanges = changeManager.saveState()
            // Save row selection
            tabManager.tabs[oldIndex].selectedRowIndices = selectedRowIndices
            // sortState is already in tab, no need to save from local state
        }

        // Restore state from the new tab
        if let newId = newTabId,
            let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId })
        {
            let newTab = tabManager.tabs[newIndex]

            // Restore pending changes
            if newTab.pendingChanges.hasChanges {
                changeManager.restoreState(
                    from: newTab.pendingChanges, tableName: newTab.tableName ?? "")
            } else {
                // Clear changeManager for tabs without pending changes (atomically)
                changeManager.configureForTable(
                    tableName: newTab.tableName ?? "",
                    columns: newTab.resultColumns,
                    primaryKeyColumn: newTab.resultColumns.first,
                    databaseType: connection.type
                )
            }

            // Restore row selection
            selectedRowIndices = newTab.selectedRowIndices
            // sortState is accessed via binding, no need to restore to local state
        }
    }

    /// Handle result columns changes
    private func handleColumnsChange(newColumns: [String]?) {
        // Sync changeManager when data loads on the current tab
        guard let newColumns = newColumns, !newColumns.isEmpty else { return }
        guard let tab = tabManager.selectedTab else { return }
        guard !tab.pendingChanges.hasChanges else { return }

        // Only update if columns have actually changed
        guard changeManager.columns != newColumns else { return }

        changeManager.configureForTable(
            tableName: tab.tableName ?? "",
            columns: newColumns,
            primaryKeyColumn: newColumns.first,
            databaseType: connection.type
        )
    }

    /// Handle refresh all action
    private func handleRefreshAll() {
        // Check for unsaved changes
        let hasEditedCells = changeManager.hasChanges
        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

        if hasEditedCells || hasPendingTableOps {
            // Show unified alert
            pendingDiscardAction = .refreshAll
        } else {
            // No changes, just refresh
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .databaseDidConnect, object: nil)
            }
            runQuery()
        }
    }

    /// Unified handler for all discard actions
    private func handleDiscard() {
        guard let action = pendingDiscardAction else { return }

        // CRITICAL: Restore original values BEFORE clearing changes
        let originalValues = changeManager.getOriginalValues()
        if let index = tabManager.selectedTabIndex {
            for (rowIndex, columnIndex, originalValue) in originalValues {
                if rowIndex < tabManager.tabs[index].resultRows.count {
                    tabManager.tabs[index].resultRows[rowIndex].values[columnIndex] = originalValue
                }
            }
        }

        // Clear pending table operations (for all actions)
        pendingTruncates.removeAll()
        pendingDeletes.removeAll()

        // Clear changes
        changeManager.clearChanges()
        if let index = tabManager.selectedTabIndex {
            tabManager.tabs[index].pendingChanges = TabPendingChanges()
        }

        // Force reload to show restored values
        changeManager.reloadVersion += 1

        // Refresh table browser to clear delete/truncate visual indicators
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .databaseDidConnect, object: nil)
        }

        // Execute the specific action
        switch action {
        case .refresh, .refreshAll:
            runQuery()
        case .closeTab:
            closeCurrentTab()
        }

        // Clear the pending action
        pendingDiscardAction = nil
    }

    /// Handle close action with progressive behavior:
    /// 1. Has tabs → close current tab
    /// 2. No tabs → go to welcome screen
    private func handleCloseAction() {
        if currentTab != nil {
            // Check for unsaved changes before closing
            let hasEditedCells = changeManager.hasChanges
            let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

            if hasEditedCells || hasPendingTableOps {
                pendingDiscardAction = .closeTab
            } else {
                closeCurrentTab()
            }
        } else {
            // No tabs - go to welcome screen
            NotificationCenter.default.post(name: .deselectConnection, object: nil)
        }
    }

    /// Close the current tab
    private func closeCurrentTab() {
        guard let tab = currentTab else { return }
        tabManager.closeTab(tab)
    }

    /// Save pending changes (Cmd+S)
    private func saveChanges() {
        print("DEBUG: saveChanges() called")

        let hasEditedCells = changeManager.hasChanges
        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

        print("DEBUG: hasEditedCells = \(hasEditedCells)")
        print("DEBUG: hasPendingTableOps = \(hasPendingTableOps)")

        guard hasEditedCells || hasPendingTableOps else {
            print("DEBUG: No changes to save")
            return
        }

        var allStatements: [String] = []

        // 1. Generate SQL for cell edits
        if hasEditedCells {
            let cellStatements = changeManager.generateSQL()
            print("DEBUG: Generated \(cellStatements.count) cell edit SQL statements")
            for (index, stmt) in cellStatements.enumerated() {
                print("DEBUG: Cell statement \(index + 1): \(stmt)")
            }
            allStatements.append(contentsOf: cellStatements)
        }

        // 2. Generate SQL for table operations
        if hasPendingTableOps {
            // Truncate tables first
            for tableName in pendingTruncates {
                let quotedName = connection.type.quoteIdentifier(tableName)
                let stmt = "TRUNCATE TABLE \(quotedName)"
                print("DEBUG: Table operation: \(stmt)")
                allStatements.append(stmt)
            }

            // Then delete tables
            for tableName in pendingDeletes {
                let quotedName = connection.type.quoteIdentifier(tableName)
                let stmt = "DROP TABLE \(quotedName)"
                print("DEBUG: Table operation: \(stmt)")
                allStatements.append(stmt)
            }
        }

        guard !allStatements.isEmpty else {
            print("DEBUG: No SQL statements generated")
            if let index = tabManager.selectedTabIndex {
                tabManager.tabs[index].errorMessage = "Could not generate SQL for changes."
            }
            return
        }

        let sql = allStatements.joined(separator: ";\n")
        executeCommitSQL(sql, clearTableOps: hasPendingTableOps)
    }

    /// Execute commit SQL and refresh data
    private func executeCommitSQL(_ sql: String, clearTableOps: Bool = false) {
        guard !sql.isEmpty else { return }

        print("DEBUG: Executing SQL:\n\(sql)")

        Task {
            do {
                // Use activeDriver from DatabaseManager (already connected with SSH tunnel)
                guard let driver = DatabaseManager.shared.activeDriver else {
                    await MainActor.run {
                        if let index = tabManager.selectedTabIndex {
                            tabManager.tabs[index].errorMessage = "Not connected to database"
                        }
                    }
                    throw DatabaseError.notConnected
                }

                // Execute each statement
                let statements = sql.components(separatedBy: ";").filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }

                for statement in statements {
                    print("DEBUG: Executing: \(statement)")
                    _ = try await driver.execute(query: statement)
                }

                print("DEBUG: All statements executed successfully")

                // Clear pending changes since they're now saved
                await MainActor.run {
                    changeManager.clearChanges()
                    // Also clear the tab's stored pending changes
                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].pendingChanges = TabPendingChanges()
                        tabManager.tabs[index].errorMessage = nil  // Clear any previous errors
                    }

                    // Clear table operations if any were executed
                    if clearTableOps {
                        // Before clearing, capture which tables were deleted
                        let deletedTables = Set(pendingDeletes)

                        pendingTruncates.removeAll()
                        pendingDeletes.removeAll()

                        // Close tabs for deleted tables to prevent errors
                        if !deletedTables.isEmpty {
                            // Note: We don't need to preserve selection - tabManager handles it
                            _ = tabManager.selectedTabId

                            // Collect tabs to close
                            var tabsToClose: [QueryTab] = []
                            for tab in tabManager.tabs {
                                if let tableName = tab.tableName, deletedTables.contains(tableName)
                                {
                                    tabsToClose.append(tab)
                                }
                            }

                            // Close tabs using the manager's method
                            for tab in tabsToClose {
                                tabManager.closeTab(tab)
                            }
                        }

                        // Refresh table browser to show updated table list
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .databaseDidConnect, object: nil)
                        }
                    }

                    print("DEBUG: Changes cleared, refreshing query")
                }

                // Refresh the current query to show updated data (if tab still exists)
                if tabManager.selectedTabIndex != nil && !tabManager.tabs.isEmpty {
                    runQuery()
                }

            } catch {
                print("DEBUG: Error during save: \(error)")
                await MainActor.run {
                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].errorMessage =
                            "Save failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Debounced update of changeManager to prevent crashes during rapid navigation
    /// Only updates if tab remains selected for 100ms
    private func debouncedUpdateChangeManager(for tabId: UUID) {
        // Cancel any pending update
        changeManagerUpdateTask?.cancel()

        // Schedule new update after delay
        changeManagerUpdateTask = Task { @MainActor in
            // Wait 100ms to allow rapid navigation to settle
            try? await Task.sleep(nanoseconds: 100_000_000)

            guard !Task.isCancelled else { return }
            guard tabManager.selectedTabId == tabId else { return }
            guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }

            let tab = tabManager.tabs[idx]
            changeManager.configureForTable(
                tableName: tab.tableName ?? "",
                columns: tab.resultColumns,
                primaryKeyColumn: tab.resultColumns.first,
                databaseType: connection.type
            )
        }
    }

    /// Open table data (TablePlus-style smart tab behavior)
    /// - Reuses clean table tabs instead of creating new ones
    /// - Creates new tab if current tab has unsaved changes or is a query tab
    /// - Preserves pending changes per-tab when switching
    private func openTableData(_ tableName: String) {
        // Note: Save/restore of pending changes is handled by onChange(of: selectedTabId)
        // which fires whenever the selected tab changes

        // Use smart tab opening - reuse clean table tabs
        // Returns true if we need to run query (new/replaced tab), false if just switching to existing
        let needsQuery = tabManager.openTableTabSmart(
            tableName: tableName, hasUnsavedChanges: changeManager.hasChanges,
            databaseType: connection.type)

        // Clear selection for new/replaced tabs (prevents old selection from leaking)
        // For existing tabs, onChange will restore their saved selection
        if needsQuery {
            selectedRowIndices = []
            runQuery()
        }
    }
}

#Preview("With Connection") {
    MainContentView(
        connection: DatabaseConnection.sampleConnections[0],
        tables: .constant([]),
        selectedTable: .constant(nil),
        pendingTruncates: .constant([]),
        pendingDeletes: .constant([])
    )
    .frame(width: 1000, height: 600)
}

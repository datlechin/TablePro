//
//  MainContentCoordinator.swift
//  TablePro
//
//  Coordinator managing business logic for MainContentView.
//  Separates view logic from presentation for better maintainability.
//

import Combine
import Foundation
import SwiftUI

/// Discard action types for unified alert handling
enum DiscardAction {
    case refresh
    case closeTab
    case refreshAll
}

/// Coordinator managing MainContentView business logic
@MainActor
final class MainContentCoordinator: ObservableObject {
    // MARK: - Dependencies

    let connection: DatabaseConnection
    let tabManager: QueryTabManager
    let changeManager: DataChangeManager
    let filterStateManager: FilterStateManager
    let toolbarState: ConnectionToolbarState

    // MARK: - Services

    private let queryBuilder: TableQueryBuilder
    let tabPersistence: TabPersistenceService
    private lazy var rowOperationsManager: RowOperationsManager = {
        RowOperationsManager(changeManager: changeManager)
    }()

    // MARK: - Published State

    @Published var schemaProvider = SQLSchemaProvider()
    @Published var cursorPosition: Int = 0
    @Published var tableMetadata: TableMetadata?
    @Published var pendingDiscardAction: DiscardAction?
    // Removed: showErrorAlert and errorAlertMessage - errors now display inline
    @Published var showDatabaseSwitcher = false
    @Published var showExportDialog = false
    @Published var showImportDialog = false
    @Published var importFileURL: URL?
    @Published var needsLazyLoad = false

    // MARK: - Internal State

    private var queryGeneration: Int = 0
    private var currentQueryTask: Task<Void, Never>?
    private var changeManagerUpdateTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        connection: DatabaseConnection,
        tabManager: QueryTabManager,
        changeManager: DataChangeManager,
        filterStateManager: FilterStateManager,
        toolbarState: ConnectionToolbarState
    ) {
        self.connection = connection
        self.tabManager = tabManager
        self.changeManager = changeManager
        self.filterStateManager = filterStateManager
        self.toolbarState = toolbarState
        self.queryBuilder = TableQueryBuilder(databaseType: connection.type)
        self.tabPersistence = TabPersistenceService(connectionId: connection.id)
    }

    // MARK: - Initialization Actions

    /// Initialize view with connection info and load schema
    func initializeView() async {
        // Initialize toolbar with connection info
        toolbarState.update(from: connection)

        // Get actual connection state from session
        if let session = DatabaseManager.shared.currentSession {
            toolbarState.connectionState = mapSessionStatus(session.status)
            if let driver = session.driver {
                toolbarState.databaseVersion = driver.serverVersion
            }
        } else if let driver = DatabaseManager.shared.activeDriver {
            toolbarState.connectionState = .connected
            toolbarState.databaseVersion = driver.serverVersion
        }

        // Load schema for autocomplete
        await loadSchema()
    }

    /// Map ConnectionStatus to ToolbarConnectionState
    private func mapSessionStatus(_ status: ConnectionStatus) -> ToolbarConnectionState {
        switch status {
        case .connected: return .connected
        case .connecting: return .executing
        case .disconnected: return .disconnected
        case .error: return .error("")
        }
    }

    // MARK: - Schema Loading

    func loadSchema() async {
        guard let driver = DatabaseManager.shared.activeDriver else { return }
        await schemaProvider.loadSchema(using: driver, connection: connection)
    }

    func loadTableMetadata(tableName: String) async {
        guard let driver = DatabaseManager.shared.activeDriver else { return }

        do {
            let metadata = try await driver.fetchTableMetadata(tableName: tableName)
            self.tableMetadata = metadata
        } catch {
            print("[MainContentCoordinator] Failed to load table metadata: \(error)")
        }
    }

    // MARK: - Query Execution

    func runQuery() {
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].isExecuting else { return }

        currentQueryTask?.cancel()
        queryGeneration += 1
        let capturedGeneration = queryGeneration

        tabManager.tabs[index].isExecuting = true
        tabManager.tabs[index].executionTime = nil
        tabManager.tabs[index].errorMessage = nil
        toolbarState.isExecuting = true

        let fullQuery = tabManager.tabs[index].query

        // For table tabs, use the full query. For query tabs, extract at cursor
        let sql: String
        if tabManager.tabs[index].tabType == .table {
            sql = fullQuery
        } else {
            sql = extractQueryAtCursor(from: fullQuery, at: cursorPosition)
        }

        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            tabManager.tabs[index].isExecuting = false
            toolbarState.isExecuting = false
            return
        }

        let conn = connection
        let tabId = tabManager.tabs[index].id
        let tableName = extractTableName(from: sql)
        let isEditable = tableName != nil

        currentQueryTask = Task {
            do {
                let result = try await DatabaseManager.shared.execute(query: sql)

                var columnDefaults: [String: String?] = [:]
                var totalRowCount: Int?

                if isEditable, let tableName = tableName {
                    if let driver = DatabaseManager.shared.activeDriver {
                        async let columnInfoTask = driver.fetchColumns(table: tableName)
                        async let countTask: QueryResult = {
                            let quotedTable = conn.type.quoteIdentifier(tableName)
                            return try await DatabaseManager.shared.execute(query: "SELECT COUNT(*) FROM \(quotedTable)")
                        }()

                        let (columnInfo, countResult) = try await (columnInfoTask, countTask)

                        for col in columnInfo {
                            columnDefaults[col.name] = col.defaultValue
                        }

                        if let firstRow = countResult.rows.first,
                           let countStr = firstRow.first as? String,
                           let count = Int(countStr) {
                            totalRowCount = count
                        }
                    }
                }

                // Deep copy to prevent C buffer retention issues
                let safeColumns = result.columns.map { String($0) }
                let safeRows = result.rows.map { row in
                    QueryResultRow(values: row.map { $0.map { String($0) } })
                }
                let safeExecutionTime = result.executionTime
                let safeColumnDefaults = columnDefaults.mapValues { $0.map { String($0) } }
                let safeTableName = tableName.map { String($0) }
                let safeTotalRowCount = totalRowCount

                guard !Task.isCancelled else {
                    await MainActor.run {
                        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                            tabManager.tabs[idx].isExecuting = false
                        }
                        toolbarState.isExecuting = false
                        toolbarState.lastQueryDuration = safeExecutionTime
                    }
                    return
                }

                await MainActor.run {
                    currentQueryTask = nil
                    toolbarState.isExecuting = false
                    toolbarState.lastQueryDuration = safeExecutionTime

                    guard capturedGeneration == queryGeneration else { return }
                    guard !Task.isCancelled else { return }

                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        var updatedTab = tabManager.tabs[idx]
                        updatedTab.resultColumns = safeColumns
                        updatedTab.columnDefaults = safeColumnDefaults
                        updatedTab.resultRows = safeRows
                        updatedTab.executionTime = safeExecutionTime
                        updatedTab.rowsAffected = result.rowsAffected
                        updatedTab.isExecuting = false
                        updatedTab.lastExecutedAt = Date()
                        updatedTab.tableName = safeTableName
                        updatedTab.isEditable = isEditable
                        updatedTab.pagination.totalRowCount = safeTotalRowCount
                        tabManager.tabs[idx] = updatedTab

                        changeManager.reloadVersion += 1

                        QueryHistoryManager.shared.recordQuery(
                            query: sql,
                            connectionId: conn.id,
                            databaseName: conn.database ?? "",
                            executionTime: safeExecutionTime,
                            rowCount: safeRows.count,
                            wasSuccessful: true,
                            errorMessage: nil
                        )
                    }
                }
            } catch {
                guard capturedGeneration == queryGeneration else { return }

                await MainActor.run {
                    currentQueryTask = nil
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.tabs[idx].errorMessage = error.localizedDescription
                        tabManager.tabs[idx].isExecuting = false
                    }
                    toolbarState.isExecuting = false

                    QueryHistoryManager.shared.recordQuery(
                        query: sql,
                        connectionId: conn.id,
                        databaseName: conn.database ?? "",
                        executionTime: 0,
                        rowCount: 0,
                        wasSuccessful: false,
                        errorMessage: error.localizedDescription
                    )
                }
            }
        }
    }

    // MARK: - SQL Parsing

    private func extractTableName(from sql: String) -> String? {
        let pattern = #"(?i)^\s*SELECT\s+.+?\s+FROM\s+[`"]?(\w+)[`"]?\s*(?:WHERE|ORDER|LIMIT|GROUP|HAVING|$|;)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: sql, options: [], range: NSRange(sql.startIndex..., in: sql)),
              let range = Range(match.range(at: 1), in: sql) else {
            return nil
        }
        return String(sql[range])
    }

    private func extractQueryAtCursor(from fullQuery: String, at position: Int) -> String {
        let trimmed = fullQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains(";") else { return trimmed }

        var statements: [(text: String, range: Range<Int>)] = []
        var currentStart = 0
        var inString = false
        var stringChar: Character = "\""

        for (i, char) in fullQuery.enumerated() {
            if char == "'" || char == "\"" {
                if !inString {
                    inString = true
                    stringChar = char
                } else if char == stringChar {
                    inString = false
                }
            }

            if char == ";" && !inString {
                let statement = String(
                    fullQuery[fullQuery.index(fullQuery.startIndex, offsetBy: currentStart)..<fullQuery.index(fullQuery.startIndex, offsetBy: i)]
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !statement.isEmpty {
                    statements.append((text: statement, range: currentStart..<(i + 1)))
                }
                currentStart = i + 1
            }
        }

        if currentStart < fullQuery.count {
            let remaining = String(fullQuery[fullQuery.index(fullQuery.startIndex, offsetBy: currentStart)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                statements.append((text: remaining, range: currentStart..<fullQuery.count))
            }
        }

        let safePosition = min(max(0, position), fullQuery.count)
        for statement in statements {
            if statement.range.contains(safePosition) || statement.range.upperBound == safePosition {
                return statement.text
            }
        }

        return statements.last?.text ?? trimmed
    }

    // MARK: - Sorting

    func handleSort(columnIndex: Int, ascending: Bool, selectedRowIndices: inout Set<Int>) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tab = tabManager.tabs[tabIndex]
        guard columnIndex >= 0 && columnIndex < tab.resultColumns.count else { return }

        let columnName = String(tab.resultColumns[columnIndex])
        var currentSort = SortState()
        currentSort.columnIndex = columnIndex
        currentSort.direction = ascending ? .ascending : .descending

        tabManager.tabs[tabIndex].sortState = currentSort
        tabManager.tabs[tabIndex].hasUserInteraction = true

        // Reset pagination to page 1 when sorting changes
        tabManager.tabs[tabIndex].pagination.reset()

        if tab.tabType == .query {
            Task { @MainActor in
                tabManager.tabs[tabIndex].isExecuting = true
                try? await Task.sleep(nanoseconds: 10_000_000)
                changeManager.reloadVersion += 1
                tabManager.tabs[tabIndex].isExecuting = false
            }
            return
        }

        let newQuery = queryBuilder.buildSortedQuery(
            baseQuery: tab.query,
            columnName: columnName,
            ascending: ascending
        )
        tabManager.tabs[tabIndex].query = newQuery
        runQuery()
    }

    // MARK: - Pagination

    /// Navigate to next page
    func goToNextPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        var tab = tabManager.tabs[tabIndex]
        guard tab.pagination.hasNextPage else { return }

        tab.pagination.goToNextPage()
        tabManager.tabs[tabIndex] = tab
        reloadCurrentPage()
    }

    /// Navigate to previous page
    func goToPreviousPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        var tab = tabManager.tabs[tabIndex]
        guard tab.pagination.hasPreviousPage else { return }

        tab.pagination.goToPreviousPage()
        tabManager.tabs[tabIndex] = tab
        reloadCurrentPage()
    }

    /// Navigate to first page
    func goToFirstPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        var tab = tabManager.tabs[tabIndex]
        guard tab.pagination.currentPage != 1 else { return }

        tab.pagination.goToFirstPage()
        tabManager.tabs[tabIndex] = tab
        reloadCurrentPage()
    }

    /// Navigate to last page
    func goToLastPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        var tab = tabManager.tabs[tabIndex]
        guard tab.pagination.currentPage != tab.pagination.totalPages else { return }

        tab.pagination.goToLastPage()
        tabManager.tabs[tabIndex] = tab
        reloadCurrentPage()
    }

    /// Update page size (limit) and reload
    func updatePageSize(_ newSize: Int) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              newSize > 0 else { return }

        tabManager.tabs[tabIndex].pagination.updatePageSize(newSize)
        reloadCurrentPage()
    }

    /// Update offset and reload
    func updateOffset(_ newOffset: Int) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              newOffset >= 0 else { return }

        tabManager.tabs[tabIndex].pagination.updateOffset(newOffset)
        reloadCurrentPage()
    }

    /// Apply both limit and offset changes and reload
    func applyPaginationSettings() {
        reloadCurrentPage()
    }

    /// Reload current page data
    private func reloadCurrentPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              let tableName = tabManager.tabs[tabIndex].tableName else { return }

        let tab = tabManager.tabs[tabIndex]
        let pagination = tab.pagination

        let newQuery = queryBuilder.buildBaseQuery(
            tableName: tableName,
            sortState: tab.sortState,
            columns: tab.resultColumns,
            limit: pagination.pageSize,
            offset: pagination.currentOffset
        )

        tabManager.tabs[tabIndex].query = newQuery
        runQuery()
    }

    // MARK: - Filtering

    func applyFilters(_ filters: [TableFilter]) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              let tableName = tabManager.tabs[tabIndex].tableName else { return }

        // Reset pagination when filters change
        tabManager.tabs[tabIndex].pagination.reset()

        let newQuery = queryBuilder.buildFilteredQuery(
            tableName: tableName,
            filters: filters,
            sortState: tabManager.tabs[tabIndex].sortState,
            columns: tabManager.tabs[tabIndex].resultColumns,
            limit: tabManager.tabs[tabIndex].pagination.pageSize,
            offset: tabManager.tabs[tabIndex].pagination.currentOffset
        )

        tabManager.tabs[tabIndex].query = newQuery

        if !filters.isEmpty {
            filterStateManager.saveLastFilters(for: tableName)
        }

        runQuery()
    }

    func applyQuickSearch(_ searchText: String) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              let tableName = tabManager.tabs[tabIndex].tableName,
              !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        // Reset pagination when search changes
        tabManager.tabs[tabIndex].pagination.reset()

        let tab = tabManager.tabs[tabIndex]
        let newQuery = queryBuilder.buildQuickSearchQuery(
            tableName: tableName,
            searchText: searchText,
            columns: tab.resultColumns,
            sortState: tab.sortState,
            limit: tab.pagination.pageSize,
            offset: tab.pagination.currentOffset
        )

        tabManager.tabs[tabIndex].query = newQuery
        runQuery()
    }

    func clearFiltersAndReload() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              let tableName = tabManager.tabs[tabIndex].tableName else { return }

        let newQuery = queryBuilder.buildBaseQuery(
            tableName: tableName,
            sortState: tabManager.tabs[tabIndex].sortState,
            columns: tabManager.tabs[tabIndex].resultColumns
        )

        tabManager.tabs[tabIndex].query = newQuery
        runQuery()
    }

    func rebuildTableQuery(at tabIndex: Int) {
        guard tabIndex < tabManager.tabs.count,
              let tableName = tabManager.tabs[tabIndex].tableName else { return }

        var newQuery = queryBuilder.buildBaseQuery(
            tableName: tableName,
            sortState: tabManager.tabs[tabIndex].sortState,
            columns: tabManager.tabs[tabIndex].resultColumns
        )

        if filterStateManager.hasAppliedFilters {
            newQuery = queryBuilder.buildFilteredQuery(
                tableName: tableName,
                filters: filterStateManager.appliedFilters,
                sortState: tabManager.tabs[tabIndex].sortState,
                columns: tabManager.tabs[tabIndex].resultColumns
            )
        }

        tabManager.tabs[tabIndex].query = newQuery
    }

    // MARK: - Row Operations

    func addNewRow(selectedRowIndices: inout Set<Int>, editingCell: inout CellPosition?) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tab = tabManager.tabs[tabIndex]
        guard tab.isEditable, tab.tableName != nil else { return }

        guard let result = rowOperationsManager.addNewRow(
            columns: tab.resultColumns,
            columnDefaults: tab.columnDefaults,
            resultRows: &tabManager.tabs[tabIndex].resultRows
        ) else { return }

        selectedRowIndices = [result.rowIndex]
        editingCell = CellPosition(row: result.rowIndex, column: 0)
        tabManager.tabs[tabIndex].hasUserInteraction = true
    }

    func deleteSelectedRows(indices: Set<Int>, selectedRowIndices: inout Set<Int>) {
        guard let tabIndex = tabManager.selectedTabIndex,
              !indices.isEmpty else { return }

        let nextRow = rowOperationsManager.deleteSelectedRows(
            selectedIndices: indices,
            resultRows: &tabManager.tabs[tabIndex].resultRows
        )

        if nextRow >= 0 && nextRow < tabManager.tabs[tabIndex].resultRows.count {
            selectedRowIndices = [nextRow]
        } else {
            selectedRowIndices.removeAll()
        }

        tabManager.tabs[tabIndex].hasUserInteraction = true
    }

    func duplicateSelectedRow(index: Int, selectedRowIndices: inout Set<Int>, editingCell: inout CellPosition?) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tab = tabManager.tabs[tabIndex]
        guard tab.isEditable, tab.tableName != nil,
              index < tab.resultRows.count else { return }

        guard let result = rowOperationsManager.duplicateRow(
            sourceRowIndex: index,
            columns: tab.resultColumns,
            resultRows: &tabManager.tabs[tabIndex].resultRows
        ) else { return }

        selectedRowIndices = [result.rowIndex]
        editingCell = CellPosition(row: result.rowIndex, column: 0)
        tabManager.tabs[tabIndex].hasUserInteraction = true
    }

    func undoInsertRow(at rowIndex: Int, selectedRowIndices: inout Set<Int>) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        selectedRowIndices = rowOperationsManager.undoInsertRow(
            at: rowIndex,
            resultRows: &tabManager.tabs[tabIndex].resultRows,
            selectedIndices: selectedRowIndices
        )
    }

    func undoLastChange(selectedRowIndices: inout Set<Int>) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        if let adjustedSelection = rowOperationsManager.undoLastChange(
            resultRows: &tabManager.tabs[tabIndex].resultRows
        ) {
            selectedRowIndices = adjustedSelection
        }

        tabManager.tabs[tabIndex].hasUserInteraction = true
    }

    func redoLastChange() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tab = tabManager.tabs[tabIndex]
        _ = rowOperationsManager.redoLastChange(
            resultRows: &tabManager.tabs[tabIndex].resultRows,
            columns: tab.resultColumns
        )

        tabManager.tabs[tabIndex].hasUserInteraction = true
    }

    func copySelectedRowsToClipboard(indices: Set<Int>) {
        guard let index = tabManager.selectedTabIndex,
              !indices.isEmpty else { return }

        let tab = tabManager.tabs[index]
        rowOperationsManager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            resultRows: tab.resultRows
        )
    }

    // MARK: - Cell Operations

    func updateCellInTab(rowIndex: Int, columnIndex: Int, value: String?) {
        guard let index = tabManager.selectedTabIndex,
              rowIndex < tabManager.tabs[index].resultRows.count else { return }

        tabManager.tabs[index].resultRows[rowIndex].values[columnIndex] = value
        tabManager.tabs[index].hasUserInteraction = true
    }

    // MARK: - Save Changes

    func saveChanges(
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>,
        tableOperationOptions: inout [String: TableOperationOptions]
    ) {
        let hasEditedCells = changeManager.hasChanges
        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

        guard hasEditedCells || hasPendingTableOps else { return }

        var allStatements: [String] = []
        let dbType = connection.type

        // Check if any table operation needs FK disabled (must be outside transaction)
        let needsDisableFK = dbType != .postgresql && pendingTruncates.union(pendingDeletes).contains { tableName in
            tableOperationOptions[tableName]?.ignoreForeignKeys == true
        }

        // FK disable must be FIRST, before any transaction begins
        if needsDisableFK {
            allStatements.append(contentsOf: fkDisableStatements(for: dbType))
        }

        // Wrap all operations in a single transaction when we have multiple operations
        let needsTransaction = hasEditedCells && hasPendingTableOps
        if needsTransaction {
            allStatements.append("BEGIN")
        }

        if hasEditedCells {
            // changeManager.generateSQL() does NOT include transaction statements
            do {
                let editStatements = try changeManager.generateSQL()
                allStatements.append(contentsOf: editStatements)
            } catch {
                // Show error to user and abort save
                if let index = tabManager.selectedTabIndex {
                    tabManager.tabs[index].errorMessage = error.localizedDescription
                }
                return
            }
        }

        if hasPendingTableOps {
            // Generate table operation SQL WITHOUT FK handling (already done above)
            let tableOpStatements = generateTableOperationSQL(
                truncates: pendingTruncates,
                deletes: pendingDeletes,
                options: tableOperationOptions,
                wrapInTransaction: !needsTransaction,
                includeFKHandling: false  // FK handling done at this level
            )
            allStatements.append(contentsOf: tableOpStatements)
        }

        if needsTransaction {
            allStatements.append("COMMIT")
        }

        // FK re-enable must be LAST, after transaction commits
        if needsDisableFK {
            allStatements.append(contentsOf: fkEnableStatements(for: dbType))
        }

        guard !allStatements.isEmpty else {
            if let index = tabManager.selectedTabIndex {
                tabManager.tabs[index].errorMessage = "Could not generate SQL for changes."
            }
            return
        }

        // Pass statements as array to avoid SQL injection via semicolon splitting
        executeCommitStatements(
            allStatements,
            clearTableOps: hasPendingTableOps,
            pendingTruncates: &pendingTruncates,
            pendingDeletes: &pendingDeletes,
            tableOperationOptions: &tableOperationOptions
        )
    }

    /// Generates SQL statements for table truncate/drop operations.
    /// - Parameters:
    ///   - truncates: Set of table names to truncate
    ///   - deletes: Set of table names to drop
    ///   - options: Per-table options for FK and cascade handling
    ///   - wrapInTransaction: Whether to wrap statements in BEGIN/COMMIT
    ///   - includeFKHandling: Whether to include FK disable/enable statements (set false when caller handles FK)
    /// - Returns: Array of SQL statements to execute
    private func generateTableOperationSQL(
        truncates: Set<String>,
        deletes: Set<String>,
        options: [String: TableOperationOptions],
        wrapInTransaction: Bool = true,
        includeFKHandling: Bool = true
    ) -> [String] {
        var statements: [String] = []
        let dbType = connection.type

        // Sort tables for consistent execution order
        let sortedTruncates = truncates.sorted()
        let sortedDeletes = deletes.sorted()

        // Check if any operation needs FK disabled (not applicable to PostgreSQL)
        let needsDisableFK = includeFKHandling && dbType != .postgresql && truncates.union(deletes).contains { tableName in
            options[tableName]?.ignoreForeignKeys == true
        }

        // FK disable must be OUTSIDE transaction to ensure it takes effect even on rollback
        if needsDisableFK {
            statements.append(contentsOf: fkDisableStatements(for: dbType))
        }

        // Wrap in transaction for atomicity
        let needsTransaction = wrapInTransaction && (sortedTruncates.count + sortedDeletes.count) > 1
        if needsTransaction {
            statements.append("BEGIN")
        }

        for tableName in sortedTruncates {
            let quotedName = dbType.quoteIdentifier(tableName)
            let tableOptions = options[tableName] ?? TableOperationOptions()
            statements.append(contentsOf: truncateStatements(tableName: tableName, quotedName: quotedName, options: tableOptions, dbType: dbType))
        }

        for tableName in sortedDeletes {
            let quotedName = dbType.quoteIdentifier(tableName)
            let tableOptions = options[tableName] ?? TableOperationOptions()
            statements.append(dropTableStatement(quotedName: quotedName, options: tableOptions, dbType: dbType))
        }

        if needsTransaction {
            statements.append("COMMIT")
        }

        // FK re-enable must be OUTSIDE transaction to ensure it runs even on rollback
        if needsDisableFK {
            statements.append(contentsOf: fkEnableStatements(for: dbType))
        }

        return statements
    }

    /// Returns SQL statements to disable foreign key checks for the database type.
    /// - Note: PostgreSQL doesn't support globally disabling FK checks; use CASCADE instead.
    private func fkDisableStatements(for dbType: DatabaseType) -> [String] {
        switch dbType {
        case .mysql, .mariadb:
            return ["SET FOREIGN_KEY_CHECKS=0"]
        case .postgresql:
            // PostgreSQL doesn't support globally disabling non-deferrable FKs.
            // Use CASCADE option for reliable FK handling.
            return []
        case .sqlite:
            return ["PRAGMA foreign_keys = OFF"]
        }
    }

    /// Returns SQL statements to re-enable foreign key checks for the database type.
    private func fkEnableStatements(for dbType: DatabaseType) -> [String] {
        switch dbType {
        case .mysql, .mariadb:
            return ["SET FOREIGN_KEY_CHECKS=1"]
        case .postgresql:
            return []
        case .sqlite:
            return ["PRAGMA foreign_keys = ON"]
        }
    }

    /// Generates TRUNCATE/DELETE statements for a table.
    /// - Note: SQLite uses DELETE and resets auto-increment via sqlite_sequence.
    private func truncateStatements(tableName: String, quotedName: String, options: TableOperationOptions, dbType: DatabaseType) -> [String] {
        switch dbType {
        case .mysql, .mariadb:
            return ["TRUNCATE TABLE \(quotedName)"]
        case .postgresql:
            let cascade = options.cascade ? " CASCADE" : ""
            return ["TRUNCATE TABLE \(quotedName)\(cascade)"]
        case .sqlite:
            // DELETE FROM + reset auto-increment counter for true TRUNCATE semantics.
            // Note: quotedName uses backticks (via quoteIdentifier) for SQL identifiers,
            // while escapedName uses single-quote escaping for string literals in the
            // sqlite_sequence query. These are different SQL quoting mechanisms for
            // different purposes (identifier vs string literal).
            let escapedName = tableName.replacingOccurrences(of: "'", with: "''")
            return [
                "DELETE FROM \(quotedName)",
                // sqlite_sequence may not exist if no table has AUTOINCREMENT.
                // This DELETE will succeed silently if the table isn't in sqlite_sequence.
                "DELETE FROM sqlite_sequence WHERE name = '\(escapedName)'"
            ]
        }
    }

    /// Generates DROP TABLE statement with optional CASCADE.
    private func dropTableStatement(quotedName: String, options: TableOperationOptions, dbType: DatabaseType) -> String {
        switch dbType {
        case .postgresql:
            "DROP TABLE \(quotedName)\(options.cascade ? " CASCADE" : "")"
        case .mysql, .mariadb, .sqlite:
            "DROP TABLE \(quotedName)"
        }
    }

    /// Executes an array of SQL statements sequentially.
    /// This approach prevents SQL injection by avoiding semicolon-based string splitting.
    /// - Parameters:
    ///   - statements: Pre-segmented array of SQL statements to execute
    ///   - clearTableOps: Whether to clear pending table operations on success
    ///   - pendingTruncates: Inout binding to pending truncate operations (restored on failure)
    ///   - pendingDeletes: Inout binding to pending delete operations (restored on failure)
    ///   - tableOperationOptions: Inout binding to operation options (restored on failure)
    private func executeCommitStatements(
        _ statements: [String],
        clearTableOps: Bool,
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>,
        tableOperationOptions: inout [String: TableOperationOptions]
    ) {
        let validStatements = statements.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validStatements.isEmpty else { return }

        let deletedTables = Set(pendingDeletes)
        let truncatedTables = Set(pendingTruncates)
        let conn = connection
        let dbType = connection.type

        // Track if FK checks were disabled (need to re-enable on failure)
        let fkWasDisabled = dbType != .postgresql && deletedTables.union(truncatedTables).contains { tableName in
            tableOperationOptions[tableName]?.ignoreForeignKeys == true
        }

        // Capture options before clearing (for potential restore on failure)
        var capturedOptions: [String: TableOperationOptions] = [:]
        for table in deletedTables.union(truncatedTables) {
            capturedOptions[table] = tableOperationOptions[table]
        }

        // Clear operations immediately (to prevent double-execution)
        // Store references to restore synchronously on failure
        if clearTableOps {
            pendingTruncates.removeAll()
            pendingDeletes.removeAll()
            for table in deletedTables.union(truncatedTables) {
                tableOperationOptions.removeValue(forKey: table)
            }
        }

        // Capture inout references for async restoration via notification
        // This avoids the race condition of async updateSession
        let restoreNotificationName = Notification.Name("RestorePendingTableOperations_\(conn.id)")

        Task {
            let overallStartTime = Date()

            do {
                guard let driver = DatabaseManager.shared.activeDriver else {
                    await MainActor.run {
                        if let index = tabManager.selectedTabIndex {
                            tabManager.tabs[index].errorMessage = "Not connected to database"
                        }
                    }
                    throw DatabaseError.notConnected
                }

                for statement in validStatements {
                    let statementStartTime = Date()
                    _ = try await driver.execute(query: statement)
                    let executionTime = Date().timeIntervalSince(statementStartTime)

                    await MainActor.run {
                        QueryHistoryManager.shared.recordQuery(
                            query: statement.trimmingCharacters(in: .whitespacesAndNewlines),
                            connectionId: conn.id,
                            databaseName: conn.database ?? "",
                            executionTime: executionTime,
                            rowCount: 0,
                            wasSuccessful: true,
                            errorMessage: nil
                        )
                    }
                }

                await MainActor.run {
                    changeManager.clearChanges()
                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].pendingChanges = TabPendingChanges()
                        tabManager.tabs[index].errorMessage = nil
                    }

                    if clearTableOps {
                        // Close tabs for deleted tables
                        if !deletedTables.isEmpty {
                            var tabsToClose: [QueryTab] = []
                            for tab in tabManager.tabs {
                                if let tableName = tab.tableName, deletedTables.contains(tableName) {
                                    tabsToClose.append(tab)
                                }
                            }
                            for tab in tabsToClose {
                                tabManager.closeTab(tab)
                            }
                        }

                        NotificationCenter.default.post(name: .databaseDidConnect, object: nil)
                    }
                }

                if tabManager.selectedTabIndex != nil && !tabManager.tabs.isEmpty {
                    runQuery()
                }
            } catch {
                let executionTime = Date().timeIntervalSince(overallStartTime)

                // Try to re-enable FK checks if they were disabled
                if fkWasDisabled, let driver = DatabaseManager.shared.activeDriver {
                    for statement in self.fkEnableStatements(for: dbType) {
                        do {
                            try await driver.execute(query: statement)
                        } catch {
                            print("Warning: Failed to re-enable foreign key checks with statement '\(statement)': \(error)")
                        }
                    }
                }

                await MainActor.run {
                    let allSQL = validStatements.joined(separator: "; ")
                    QueryHistoryManager.shared.recordQuery(
                        query: allSQL,
                        connectionId: conn.id,
                        databaseName: conn.database ?? "",
                        executionTime: executionTime,
                        rowCount: 0,
                        wasSuccessful: false,
                        errorMessage: error.localizedDescription
                    )

                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].errorMessage = "Save failed: \(error.localizedDescription)"
                    }

                    // Restore operations on failure so user can retry.
                    // Use notification to restore via MainContentView's bindings for synchronous update.
                    if clearTableOps {
                        NotificationCenter.default.post(
                            name: restoreNotificationName,
                            object: nil,
                            userInfo: [
                                "truncates": truncatedTables,
                                "deletes": deletedTables,
                                "options": capturedOptions
                            ]
                        )

                        // Also update session for persistence
                        DatabaseManager.shared.updateSession(conn.id) { session in
                            session.pendingTruncates = truncatedTables
                            session.pendingDeletes = deletedTables
                            for (table, opts) in capturedOptions {
                                session.tableOperationOptions[table] = opts
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Table Creation

    /// Creates a new table from the provided options
    /// - Parameter options: Table creation configuration
    func createTable(_ options: TableCreationOptions) {
        let service = CreateTableService(databaseType: connection.type)

        // Generate SQL
        let sql: String
        do {
            sql = try service.generateSQL(options)
        } catch {
            // Show error in current tab
            if let index = tabManager.selectedTabIndex {
                tabManager.tabs[index].errorMessage = error.localizedDescription
            }
            return
        }

        // Execute the CREATE TABLE statement
        Task {
            let startTime = Date()

            do {
                guard let driver = DatabaseManager.shared.activeDriver else {
                    await MainActor.run {
                        if let index = tabManager.selectedTabIndex {
                            tabManager.tabs[index].errorMessage = "Not connected to database"
                        }
                    }
                    throw DatabaseError.notConnected
                }

                // Execute CREATE TABLE
                _ = try await driver.execute(query: sql)

                let duration = Date().timeIntervalSince(startTime)

                // Refresh schema to show new table (outside MainActor)
                await schemaProvider.invalidateCache()

                let needsQuery = await MainActor.run { () -> Bool in
                    // Close the create table tab
                    if let tabIndex = tabManager.selectedTabIndex,
                       tabIndex < tabManager.tabs.count {
                        let currentTab = tabManager.tabs[tabIndex]
                        tabManager.closeTab(currentTab)
                    }

                    // Open the newly created table in a new tab
                    let needs = tabManager.TableProTabSmart(
                        tableName: options.tableName,
                        hasUnsavedChanges: changeManager.hasChanges,
                        databaseType: connection.type
                    )

                    // Refresh sidebar to show new table
                    NotificationCenter.default.post(name: .refreshData, object: nil)

                    return needs
                }

                // Execute query to load table data if needed (runs async)
                if needsQuery {
                    await MainActor.run {
                        runQuery()
                    }
                }
            } catch {
                await MainActor.run {
                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].errorMessage = "Failed to create table: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    // MARK: - Discard Handling

    func handleDiscard(
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>
    ) {
        guard let action = pendingDiscardAction else { return }

        let originalValues = changeManager.getOriginalValues()
        if let index = tabManager.selectedTabIndex {
            for (rowIndex, columnIndex, originalValue) in originalValues {
                if rowIndex < tabManager.tabs[index].resultRows.count {
                    tabManager.tabs[index].resultRows[rowIndex].values[columnIndex] = originalValue
                }
            }

            let insertedIndices = changeManager.insertedRowIndices.sorted(by: >)
            for rowIndex in insertedIndices {
                if rowIndex < tabManager.tabs[index].resultRows.count {
                    tabManager.tabs[index].resultRows.remove(at: rowIndex)
                }
            }
        }

        pendingTruncates.removeAll()
        pendingDeletes.removeAll()
        changeManager.clearChanges()

        if let index = tabManager.selectedTabIndex {
            tabManager.tabs[index].pendingChanges = TabPendingChanges()
        }

        changeManager.reloadVersion += 1

        NotificationCenter.default.post(name: .databaseDidConnect, object: nil)

        switch action {
        case .refresh, .refreshAll:
            if let tabIndex = tabManager.selectedTabIndex,
               tabManager.tabs[tabIndex].tabType == .table {
                rebuildTableQuery(at: tabIndex)
            }
            runQuery()
        case .closeTab:
            closeCurrentTab()
        }

        pendingDiscardAction = nil
    }

    // MARK: - Tab Operations

    func handleCloseAction() {
        if tabManager.selectedTab != nil {
            let hasEditedCells = changeManager.hasChanges

            if hasEditedCells {
                pendingDiscardAction = .closeTab
            } else {
                closeCurrentTab()
            }
        } else {
            NotificationCenter.default.post(name: .deselectConnection, object: nil)
        }
    }

    func closeCurrentTab() {
        guard let tab = tabManager.selectedTab else { return }
        tabManager.closeTab(tab)
    }

    func handleTabChange(
        from oldTabId: UUID?,
        to newTabId: UUID?,
        selectedRowIndices: inout Set<Int>,
        tabs: [QueryTab]
    ) {
        tabPersistence.flushPendingSave(tabs: tabs, selectedTabId: tabManager.selectedTabId)

        if let oldId = oldTabId,
           let oldIndex = tabManager.tabs.firstIndex(where: { $0.id == oldId }) {
            tabManager.tabs[oldIndex].pendingChanges = changeManager.saveState()
            tabManager.tabs[oldIndex].selectedRowIndices = selectedRowIndices
        }

        if let newId = newTabId,
           let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) {
            let newTab = tabManager.tabs[newIndex]
            selectedRowIndices = newTab.selectedRowIndices
            AppState.shared.isCurrentTabEditable = newTab.isEditable && newTab.tableName != nil

            Task { @MainActor in
                if newTab.pendingChanges.hasChanges {
                    changeManager.restoreState(from: newTab.pendingChanges, tableName: newTab.tableName ?? "")
                } else {
                    changeManager.configureForTable(
                        tableName: newTab.tableName ?? "",
                        columns: newTab.resultColumns,
                        primaryKeyColumn: newTab.resultColumns.first,
                        databaseType: connection.type
                    )
                }

                let shouldSkipLazyLoad = tabPersistence.justRestoredTab
                tabPersistence.clearJustRestoredFlag()

                if !shouldSkipLazyLoad &&
                    newTab.tabType == .table &&
                    newTab.resultRows.isEmpty &&
                    newTab.lastExecutedAt == nil &&
                    !newTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let session = DatabaseManager.shared.currentSession, session.isConnected {
                        runQuery()
                    } else {
                        needsLazyLoad = true
                    }
                }
            }
        } else {
            AppState.shared.isCurrentTabEditable = false
        }
    }

    // MARK: - Table Tab Opening

    func openTableTab(_ tableName: String) {
        let needsQuery = tabManager.TableProTabSmart(
            tableName: tableName,
            hasUnsavedChanges: changeManager.hasChanges,
            databaseType: connection.type
        )

        // Initialize pagination for new table tab
        if needsQuery, let tabIndex = tabManager.selectedTabIndex {
            tabManager.tabs[tabIndex].pagination.reset()
        }

        if needsQuery {
            Task { @MainActor in
                runQuery()
            }
        }
    }

    func showAllTablesMetadata() {
        let sql: String
        switch connection.type {
        case .postgresql:
            sql = """
            SELECT
                schemaname as schema,
                tablename as name,
                'TABLE' as kind,
                n_live_tup as estimated_rows,
                pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size,
                pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) as data_size,
                pg_size_pretty(pg_indexes_size(schemaname||'.'||tablename)) as index_size,
                obj_description((schemaname||'.'||tablename)::regclass) as comment
            FROM pg_stat_user_tables
            WHERE schemaname = 'public'
            ORDER BY tablename
            """
        case .mysql, .mariadb:
            sql = """
            SELECT
                TABLE_SCHEMA as `schema`,
                TABLE_NAME as name,
                TABLE_TYPE as kind,
                IFNULL(CCSA.CHARACTER_SET_NAME, '') as charset,
                TABLE_COLLATION as collation,
                TABLE_ROWS as estimated_rows,
                CONCAT(ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2), ' MB') as total_size,
                CONCAT(ROUND(DATA_LENGTH / 1024 / 1024, 2), ' MB') as data_size,
                CONCAT(ROUND(INDEX_LENGTH / 1024 / 1024, 2), ' MB') as index_size,
                TABLE_COMMENT as comment
            FROM information_schema.TABLES
            LEFT JOIN information_schema.COLLATION_CHARACTER_SET_APPLICABILITY CCSA
                ON TABLE_COLLATION = CCSA.COLLATION_NAME
            WHERE TABLE_SCHEMA = DATABASE()
            ORDER BY TABLE_NAME
            """
        case .sqlite:
            sql = """
            SELECT
                '' as schema,
                name,
                type as kind,
                '' as charset,
                '' as collation,
                '' as estimated_rows,
                '' as total_size,
                '' as data_size,
                '' as index_size,
                '' as comment
            FROM sqlite_master
            WHERE type IN ('table', 'view')
            AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        }

        if let existingTab = tabManager.tabs.first(where: { $0.title == "Tables" }) {
            if let index = tabManager.tabs.firstIndex(where: { $0.id == existingTab.id }) {
                tabManager.tabs[index].query = sql
            }
            tabManager.selectedTabId = existingTab.id
            runQuery()
            return
        }

        let newTab = QueryTab(
            title: "Tables",
            query: sql,
            tabType: .table,
            tableName: nil
        )
        tabManager.tabs.append(newTab)
        tabManager.selectedTabId = newTab.id
        runQuery()
    }

    // MARK: - Database Switching

    /// Switch to a different database (called from database switcher)
    func switchDatabase(to database: String) async {
        guard let driver = DatabaseManager.shared.activeDriver else {
            return
        }

        do {
            // For MySQL/MariaDB, use USE command
            if connection.type == .mysql || connection.type == .mariadb {
                _ = try await driver.execute(query: "USE `\(database)`")

                // Update session with new database
                if let sessionId = DatabaseManager.shared.currentSessionId {
                    DatabaseManager.shared.updateSession(sessionId) { session in
                        var updatedConnection = session.connection
                        updatedConnection.database = database
                        session.connection = updatedConnection
                    }
                }

                // Update toolbar state
                toolbarState.databaseName = database

                // Clear tab results but keep tabs open
                tabManager.tabs = tabManager.tabs.map { tab in
                    var updatedTab = tab
                    updatedTab.resultColumns = []
                    updatedTab.resultRows = []
                    updatedTab.errorMessage = nil
                    updatedTab.executionTime = nil
                    return updatedTab
                }

                // Reload schema for autocomplete
                await loadSchema()

                // Refresh tables list in sidebar
                NotificationCenter.default.post(name: .refreshAll, object: nil)

                // Re-execute current tab's query if it's a table tab
                if let currentTab = tabManager.selectedTab, currentTab.tabType == .table {
                    runQuery()
                }
            } else {
                // For PostgreSQL and SQLite, reconnect with new database
                // (SQLite doesn't apply, but keeping for completeness)
            }
        } catch {
        }
    }

    /// Switch to a different database (legacy method - creates new connection)
    func switchToDatabase(_ database: String) {
        let newConnection = DatabaseConnection(
            id: UUID(),
            name: connection.name,
            host: connection.host,
            port: connection.port,
            database: database,
            username: connection.username,
            type: connection.type,
            sshConfig: connection.sshConfig,
            color: connection.color,
            tagId: connection.tagId
        )

        Task {
            do {
                try await DatabaseManager.shared.connectToSession(newConnection)
            } catch {
                await MainActor.run {
                }
            }
        }
    }

    // MARK: - Refresh Handling

    func handleRefreshAll(
        pendingTruncates: Set<String>,
        pendingDeletes: Set<String>
    ) {
        let hasEditedCells = changeManager.hasChanges
        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

        if hasEditedCells || hasPendingTableOps {
            pendingDiscardAction = .refreshAll
        } else {
            NotificationCenter.default.post(name: .databaseDidConnect, object: nil)
            runQuery()
        }
    }

    func handleRefresh(
        pendingTruncates: Set<String>,
        pendingDeletes: Set<String>
    ) {
        let hasEditedCells = changeManager.hasChanges
        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

        if hasEditedCells || hasPendingTableOps {
            pendingDiscardAction = .refresh
        } else {
            // Only execute query if we're in a table tab
            // Query tabs should not auto-execute on refresh (use Cmd+Enter to execute)
            if let tabIndex = tabManager.selectedTabIndex,
               tabManager.tabs[tabIndex].tabType == .table {
                currentQueryTask?.cancel()
                rebuildTableQuery(at: tabIndex)
                runQuery()
            }
        }
    }
}

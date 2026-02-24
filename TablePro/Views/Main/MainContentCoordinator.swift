//
//  MainContentCoordinator.swift
//  TablePro
//
//  Coordinator managing business logic for MainContentView.
//  Separates view logic from presentation for better maintainability.
//

import CodeEditSourceEditor
import Combine
import Foundation
import os
import SwiftUI

/// Discard action types for unified alert handling
enum DiscardAction {
    case refresh
    case closeTab
    case refreshAll
}

/// Cache entry for async-sorted query tab rows (stores index permutation, not row copies)
struct QuerySortCacheEntry {
    let sortedIndices: [Int]
    let columnIndex: Int
    let direction: SortDirection
    let resultVersion: Int
}

/// Represents which sheet is currently active in MainContentView.
/// Uses a single `.sheet(item:)` modifier instead of multiple `.sheet(isPresented:)`.
enum ActiveSheet: Identifiable {
    case databaseSwitcher
    case exportDialog
    case importDialog

    var id: Self { self }
}

/// Coordinator managing MainContentView business logic
@MainActor
final class MainContentCoordinator: ObservableObject {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator")

    // MARK: - Dependencies

    let connection: DatabaseConnection
    let tabManager: QueryTabManager
    let changeManager: DataChangeManager
    let filterStateManager: FilterStateManager
    let toolbarState: ConnectionToolbarState

    // MARK: - Services

    internal let queryBuilder: TableQueryBuilder
    let tabPersistence: TabPersistenceService
    internal lazy var rowOperationsManager: RowOperationsManager = {
        RowOperationsManager(changeManager: changeManager)
    }()

    // MARK: - Published State

    @Published var schemaProvider = SQLSchemaProvider()
    @Published var cursorPositions: [CursorPosition] = []
    @Published var tableMetadata: TableMetadata?
    // Removed: showErrorAlert and errorAlertMessage - errors now display inline
    @Published var activeSheet: ActiveSheet?
    @Published var importFileURL: URL?
    @Published var needsLazyLoad = false

    /// Cache for async-sorted query tab rows (large datasets sorted on background thread)
    @Published private(set) var querySortCache: [UUID: QuerySortCacheEntry] = [:]

    // MARK: - Internal State

    internal var queryGeneration: Int = 0
    internal var currentQueryTask: Task<Void, Never>?
    private var changeManagerUpdateTask: Task<Void, Never>?
    private var activeSortTasks: [UUID: Task<Void, Never>] = [:]

    /// Stores pending change state per tab ID, separate from QueryTab struct to avoid CoW amplification.
    /// When switching tabs, change state is saved here instead of inside the QueryTab value type.
    internal var tabPendingChanges: [UUID: TabPendingChanges] = [:]

    /// Row selection state per tab, stored separately to avoid @Published fires on tab switch
    internal var tabSelectionCache: [UUID: Set<Int>] = [:]

    /// Set during handleTabChange to suppress redundant onChange(of: resultColumns) reconfiguration
    internal var isHandlingTabSwitch = false

    /// Set when handleTabChange is called directly (keyboard/tab bar/sidebar),
    /// so .onChange(of: selectedTabId) skips the redundant call.
    internal var skipNextTabChangeOnChange = false

    /// Remove sort cache and pending change entries for tabs that no longer exist
    func cleanupSortCache(openTabIds: Set<UUID>) {
        let filteredSort = querySortCache.filter { openTabIds.contains($0.key) }
        if filteredSort.count != querySortCache.count {
            querySortCache = filteredSort
        }
        let filteredPending = tabPendingChanges.filter { openTabIds.contains($0.key) }
        if filteredPending.count != tabPendingChanges.count {
            tabPendingChanges = filteredPending
        }
        let filteredSelection = tabSelectionCache.filter { openTabIds.contains($0.key) }
        if filteredSelection.count != tabSelectionCache.count {
            tabSelectionCache = filteredSelection
        }
        for (tabId, task) in activeSortTasks where !openTabIds.contains(tabId) {
            task.cancel()
            activeSortTasks.removeValue(forKey: tabId)
        }
    }

    /// Writes cached selection state back to tab model before persistence
    private func flushSelectionCache() {
        for (tabId, selection) in tabSelectionCache {
            if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                tabManager.tabs[idx].selectedRowIndices = selection
            }
        }
        tabSelectionCache.removeAll()
    }

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
            Self.logger.error("Failed to load table metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Default row limit for query tabs to prevent unbounded result sets
    private static let defaultQueryLimit = 10_000

    /// Pre-compiled regex for detecting existing LIMIT clause in SELECT queries
    private static let limitClauseRegex = try? NSRegularExpression(
        pattern: "\\bLIMIT\\s+\\d+",
        options: .caseInsensitive
    )

    /// Pre-compiled regex for extracting table name from SELECT queries
    private static let tableNameRegex = try? NSRegularExpression(
        pattern: #"(?i)^\s*SELECT\s+.+?\s+FROM\s+[`"]?(\w+)[`"]?\s*(?:WHERE|ORDER|LIMIT|GROUP|HAVING|$|;)"#,
        options: []
    )

    // MARK: - Query Execution

    func runQuery() {
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].isExecuting else { return }

        let fullQuery = tabManager.tabs[index].query

        // For table tabs, use the full query. For query tabs, extract at cursor
        let sql: String
        if tabManager.tabs[index].tabType == .table {
            sql = fullQuery
        } else if let firstCursor = cursorPositions.first,
                  firstCursor.range.length > 0 {
            // Execute selected text only
            let nsQuery = fullQuery as NSString
            let clampedRange = NSIntersectionRange(
                firstCursor.range,
                NSRange(location: 0, length: nsQuery.length)
            )
            sql = nsQuery.substring(with: clampedRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sql = extractQueryAtCursor(
                from: fullQuery,
                at: cursorPositions.first?.range.location ?? 0
            )
        }

        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Split into individual statements for multi-statement support
        let statements = splitStatements(from: sql)
        guard !statements.isEmpty else { return }

        // Block write queries in read-only mode
        if connection.isReadOnly {
            let writeStatements = statements.filter { isWriteQuery($0) }
            if !writeStatements.isEmpty {
                tabManager.tabs[index].errorMessage =
                    "Cannot execute write queries: connection is read-only"
                return
            }
        }

        if statements.count == 1 {
            // Single statement — existing path (unchanged)
            Task { @MainActor in
                guard await confirmDangerousQueryIfNeeded(statements[0]) else {
                    return
                }
                executeQueryInternal(statements[0])
            }
        } else {
            // Multiple statements — batch-check dangerous queries, then execute sequentially
            Task { @MainActor in
                let dangerousStatements = statements.filter { isDangerousQuery($0) }
                if !dangerousStatements.isEmpty {
                    guard await confirmDangerousQueries(dangerousStatements) else { return }
                }
                executeMultipleStatements(statements)
            }
        }
    }

    /// Execute table tab query directly without the Task wrapper.
    /// Safe because table tab queries are always app-generated SELECTs.
    /// Bypasses the 15-40ms scheduling delay of `Task { @MainActor in }`.
    func executeTableTabQueryDirectly() {
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].isExecuting else { return }

        let sql = tabManager.tabs[index].query
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        executeQueryInternal(sql)
    }

    /// Run EXPLAIN on the current query (database-type-aware prefix)
    func runExplainQuery() {
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].isExecuting else { return }

        let fullQuery = tabManager.tabs[index].query

        // Extract query the same way as runQuery()
        let sql: String
        if tabManager.tabs[index].tabType == .table {
            sql = fullQuery
        } else if let firstCursor = cursorPositions.first,
                  firstCursor.range.length > 0 {
            let nsQuery = fullQuery as NSString
            let clampedRange = NSIntersectionRange(
                firstCursor.range,
                NSRange(location: 0, length: nsQuery.length)
            )
            sql = nsQuery.substring(with: clampedRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sql = extractQueryAtCursor(
                from: fullQuery,
                at: cursorPositions.first?.range.location ?? 0
            )
        }

        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Use first statement only (EXPLAIN on a single statement)
        let statements = splitStatements(from: trimmed)
        guard let stmt = statements.first else { return }

        // Build database-specific EXPLAIN prefix
        let explainSQL: String
        switch connection.type {
        case .sqlite:
            explainSQL = "EXPLAIN QUERY PLAN \(stmt)"
        case .mysql, .mariadb, .postgresql:
            explainSQL = "EXPLAIN \(stmt)"
        }

        Task { @MainActor in
            executeQueryInternal(explainSQL)
        }
    }

    /// Internal query execution (called after any confirmations)
    private func executeQueryInternal( // swiftlint:disable:this function_body_length
        _ sql: String
    ) {
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].isExecuting else { return }

        currentQueryTask?.cancel()
        queryGeneration += 1
        let capturedGeneration = queryGeneration

        // Batch mutations into a single array write to avoid multiple @Published
        // notifications — each notification triggers a full SwiftUI update cycle.
        var tab = tabManager.tabs[index]
        tab.isExecuting = true
        tab.executionTime = nil
        tab.errorMessage = nil
        tabManager.tabs[index] = tab
        toolbarState.setExecuting(true)

        let conn = connection
        let tabId = tabManager.tabs[index].id

        // DAT-1: For query tabs, auto-append LIMIT if the SQL is a SELECT without one
        let effectiveSQL: String
        if tab.tabType == .query {
            effectiveSQL = Self.addLimitIfNeeded(to: sql, limit: Self.defaultQueryLimit)
        } else {
            effectiveSQL = sql
        }

        let tableName = extractTableName(from: effectiveSQL)
        let isEditable = tableName != nil

        currentQueryTask = Task { [weak self] in
            guard let self else { return }

            do {
                let result = try await DatabaseManager.shared.execute(query: effectiveSQL)

                // Phase 1: Result data is already Swift-owned strings from the driver;
                // no need to deep copy with String($0).
                let safeColumns = result.columns
                let safeColumnTypes = result.columnTypes  // Column types are already value types (enum)
                let safeRows = result.rows.enumerated().map { index, row in
                    QueryResultRow(id: index, values: row)
                }
                let safeExecutionTime = result.executionTime
                let safeRowsAffected = result.rowsAffected
                let safeTableName = tableName

                guard !Task.isCancelled else {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                            tabManager.tabs[idx].isExecuting = false
                        }
                        toolbarState.setExecuting(false)
                        toolbarState.lastQueryDuration = safeExecutionTime
                    }
                    return
                }

                // Phase 1: Display data rows immediately without waiting for metadata
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    currentQueryTask = nil
                    toolbarState.setExecuting(false)
                    toolbarState.lastQueryDuration = safeExecutionTime

                    guard capturedGeneration == queryGeneration else { return }
                    guard !Task.isCancelled else { return }

                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        var updatedTab = tabManager.tabs[idx]
                        updatedTab.resultColumns = safeColumns
                        updatedTab.columnTypes = safeColumnTypes
                        updatedTab.resultRows = safeRows
                        updatedTab.resultVersion += 1
                        updatedTab.executionTime = safeExecutionTime
                        updatedTab.rowsAffected = safeRowsAffected
                        updatedTab.isExecuting = false
                        updatedTab.lastExecutedAt = Date()
                        updatedTab.tableName = safeTableName
                        updatedTab.isEditable = isEditable && updatedTab.isEditable
                        tabManager.tabs[idx] = updatedTab
                        AppState.shared.isCurrentTabEditable = updatedTab.isEditable
                            && !updatedTab.isView && updatedTab.tableName != nil
                        toolbarState.isTableTab = updatedTab.tabType == .table

                        QueryHistoryManager.shared.recordQuery(
                            query: sql,
                            connectionId: conn.id,
                            databaseName: conn.database,
                            executionTime: safeExecutionTime,
                            rowCount: safeRows.count,
                            wasSuccessful: true,
                            errorMessage: nil
                        )

                        // Clear stale edit state immediately so the save banner
                        // doesn't linger while Phase 2 metadata loads in background.
                        if isEditable {
                            changeManager.clearChanges()
                        }
                    }
                }

                // Phase 2: Fetch metadata in background, then update tab
                if isEditable, let tableName = tableName {
                    // NET-1: Skip Phase 2 if metadata is already cached for this table
                    let alreadyCached: Bool = await MainActor.run { [weak self] in
                        guard let self,
                              let idx = self.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                            return false
                        }
                        let tab = self.tabManager.tabs[idx]
                        return tab.tableName == tableName
                            && !tab.columnDefaults.isEmpty
                            && tab.primaryKeyColumn != nil
                    }

                    if !alreadyCached {
                        do {
                            if let driver = DatabaseManager.shared.activeDriver {
                                async let columnInfoTask = driver.fetchColumns(table: tableName)
                                async let fkInfoTask = driver.fetchForeignKeys(table: tableName)
                                let quotedTable = conn.type.quoteIdentifier(tableName)
                                async let countTask: QueryResult = try await DatabaseManager.shared.execute(
                                    query: "SELECT COUNT(*) FROM \(quotedTable)"
                                )

                                let (columnInfo, fkInfo, countResult) = try await (
                                    columnInfoTask, fkInfoTask, countTask
                                )

                                var columnDefaults: [String: String?] = [:]
                                var columnForeignKeys: [String: ForeignKeyInfo] = [:]
                                var columnNullable: [String: Bool] = [:]

                                for col in columnInfo {
                                    columnDefaults[col.name] = col.defaultValue
                                    columnNullable[col.name] = col.isNullable
                                }

                                // Build FK lookup map (column name -> FK info)
                                for fk in fkInfo {
                                    columnForeignKeys[fk.column] = fk
                                }

                                // Detect primary key column
                                let primaryKeyColumn = columnInfo.first(where: { $0.isPrimaryKey })?.name

                                var totalRowCount: Int?
                                if let firstRow = countResult.rows.first,
                                   let countStr = firstRow.first as? String,
                                   let count = Int(countStr) {
                                    totalRowCount = count
                                }

                                // Build enum/set value lookup map
                                let columnEnumValues = await self.fetchEnumValues(
                                    columnInfo: columnInfo,
                                    tableName: tableName,
                                    driver: driver,
                                    connectionType: conn.type
                                )

                                let safeColumnDefaults = columnDefaults
                                let safeColumnForeignKeys = columnForeignKeys
                                let safeColumnEnumValues = columnEnumValues
                                let safeColumnNullable = columnNullable
                                let safeTotalRowCount = totalRowCount
                                let safePrimaryKeyColumn = primaryKeyColumn

                                // Phase 2: Update tab with metadata
                                await MainActor.run { [weak self] in
                                    guard let self else { return }
                                    guard capturedGeneration == queryGeneration else { return }
                                    guard !Task.isCancelled else { return }

                                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                                        var updatedTab = tabManager.tabs[idx]
                                        updatedTab.columnDefaults = safeColumnDefaults
                                        updatedTab.columnForeignKeys = safeColumnForeignKeys
                                        updatedTab.columnEnumValues = safeColumnEnumValues
                                        updatedTab.columnNullable = safeColumnNullable
                                        updatedTab.pagination.totalRowCount = safeTotalRowCount
                                        tabManager.tabs[idx] = updatedTab

                                        // Only reconfigure changeManager if this tab is still selected;
                                        // otherwise the user switched away during Phase 2 and the
                                        // changeManager already belongs to the new active tab.
                                        if tabManager.selectedTabId == tabId {
                                            changeManager.configureForTable(
                                                tableName: tableName,
                                                columns: safeColumns,
                                                primaryKeyColumn: safePrimaryKeyColumn,
                                                databaseType: conn.type
                                            )
                                        }

                                        // Store primary key on the tab for accurate tab-switch restore
                                        tabManager.tabs[idx].primaryKeyColumn = safePrimaryKeyColumn
                                    }
                                }
                            }
                        } catch {
                            // Metadata fetch failed — data is already displayed from Phase 1,
                            // so log the error but don't disrupt the user's view.
                            // Clear stale change state so the save banner doesn't linger.
                            Logger(subsystem: "com.TablePro", category: "MainContentCoordinator")
                                .error("Phase 2 metadata fetch failed: \(error.localizedDescription)")
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                if tabManager.selectedTabId == tabId {
                                    changeManager.clearChanges()
                                }
                            }
                        }
                    }
                } else {
                    // For non-editable query results, just clear changes
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard capturedGeneration == queryGeneration else { return }
                        guard !Task.isCancelled else { return }
                        changeManager.clearChanges()
                    }
                }
            } catch {
                guard capturedGeneration == queryGeneration else { return }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    currentQueryTask = nil
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        var errTab = tabManager.tabs[idx]
                        errTab.errorMessage = error.localizedDescription
                        errTab.isExecuting = false
                        tabManager.tabs[idx] = errTab
                    }
                    toolbarState.setExecuting(false)

                    QueryHistoryManager.shared.recordQuery(
                        query: sql,
                        connectionId: conn.id,
                        databaseName: conn.database,
                        executionTime: 0,
                        rowCount: 0,
                        wasSuccessful: false,
                        errorMessage: error.localizedDescription
                    )

                    // Show error alert with AI fix option
                    let errorMessage = error.localizedDescription
                    let queryCopy = sql
                    Task { @MainActor in
                        let wantsAIFix = await AlertHelper.showQueryErrorWithAIOption(
                            title: String(localized: "Query Execution Failed"),
                            message: errorMessage,
                            window: NSApp.keyWindow
                        )
                        if wantsAIFix {
                            NotificationCenter.default.post(
                                name: .aiFixError,
                                object: nil,
                                userInfo: ["query": queryCopy, "error": errorMessage]
                            )
                        }
                    }
                }
            }
        }
    }

    /// Fetch enum/set values for columns from database-specific sources
    private func fetchEnumValues(
        columnInfo: [ColumnInfo],
        tableName: String,
        driver: DatabaseDriver,
        connectionType: DatabaseType
    ) async -> [String: [String]] {
        var result: [String: [String]] = [:]

        // Build enum/set value lookup map from column types (MySQL/MariaDB)
        for col in columnInfo {
            if let values = ColumnType.parseEnumValues(from: col.dataType) {
                result[col.name] = values
            }
        }

        // For PostgreSQL: fetch actual enum values from pg_enum catalog
        if connectionType == .postgresql {
            if let pgDriver = driver as? PostgreSQLDriver {
                for col in columnInfo where col.dataType.uppercased().hasPrefix("ENUM(") {
                    // Extract type name from "ENUM(typename)"
                    let raw = col.dataType
                    if let openParen = raw.firstIndex(of: "("),
                       let closeParen = raw.lastIndex(of: ")") {
                        let typeName = String(raw[raw.index(after: openParen)..<closeParen])
                        if let values = try? await pgDriver.fetchEnumValues(typeName: typeName) {
                            result[col.name] = values
                        }
                    }
                }
            }
        }

        // For SQLite: fetch CHECK constraint pseudo-enum values
        if connectionType == .sqlite {
            if let sqliteDriver = driver as? SQLiteDriver {
                let checkEnumValues = try? await sqliteDriver.fetchCheckConstraintEnumValues(table: tableName)
                if let checkValues = checkEnumValues {
                    for (colName, values) in checkValues {
                        result[colName] = values
                    }
                }
            }
        }

        return result
    }

    // MARK: - Query Limit Protection

    /// Appends a LIMIT clause to SELECT queries that don't already have one.
    /// Protects query tabs from unbounded result sets (e.g., SELECT * FROM million_row_table).
    private static func addLimitIfNeeded(to sql: String, limit: Int) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercased = trimmed.uppercased()

        // Only apply to SELECT statements
        guard uppercased.hasPrefix("SELECT ") else { return sql }

        // Check if query already has a LIMIT clause
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if limitClauseRegex?.firstMatch(in: trimmed, options: [], range: range) != nil {
            return sql
        }

        // Strip trailing semicolon, append LIMIT, and re-add semicolon
        let withoutSemicolon = trimmed.hasSuffix(";")
            ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
        return "\(withoutSemicolon) LIMIT \(limit)"
    }

    // MARK: - SQL Parsing

    func extractTableName(from sql: String) -> String? {
        guard let regex = Self.tableNameRegex,
              let match = regex.firstMatch(in: sql, options: [], range: NSRange(sql.startIndex..., in: sql)),
              let range = Range(match.range(at: 1), in: sql) else {
            return nil
        }
        return String(sql[range])
    }

    private func extractQueryAtCursor(from fullQuery: String, at position: Int) -> String {
        let nsQuery = fullQuery as NSString
        let length = nsQuery.length
        guard length > 0 else { return "" }

        // Fast check: if no semicolons, return the full query trimmed.
        // Uses NSString range search (C-level speed) instead of Swift String.contains.
        guard nsQuery.range(of: ";").location != NSNotFound else {
            return fullQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let singleQuote = UInt16(UnicodeScalar("'").value)
        let doubleQuote = UInt16(UnicodeScalar("\"").value)
        let backtick = UInt16(UnicodeScalar("`").value)
        let semicolonChar = UInt16(UnicodeScalar(";").value)
        let dash = UInt16(UnicodeScalar("-").value)
        let slash = UInt16(UnicodeScalar("/").value)
        let star = UInt16(UnicodeScalar("*").value)
        let newline = UInt16(UnicodeScalar("\n").value)
        let backslash = UInt16(UnicodeScalar("\\").value)

        let safePosition = min(max(0, position), length)
        var currentStart = 0
        var inString = false
        var stringCharVal: UInt16 = 0
        var inLineComment = false
        var inBlockComment = false
        var i = 0

        // Scan through characters, stopping as soon as we find the statement
        // containing the cursor. Avoids scanning the entire file.
        while i < length {
            let ch = nsQuery.character(at: i)

            // Handle line comment end
            if inLineComment {
                if ch == newline { inLineComment = false }
                i += 1
                continue
            }

            // Handle block comment end
            if inBlockComment {
                if ch == star && i + 1 < length && nsQuery.character(at: i + 1) == slash {
                    inBlockComment = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            // Detect line comment start (--)
            if !inString && ch == dash && i + 1 < length && nsQuery.character(at: i + 1) == dash {
                inLineComment = true
                i += 2
                continue
            }

            // Detect block comment start (/*)
            if !inString && ch == slash && i + 1 < length && nsQuery.character(at: i + 1) == star {
                inBlockComment = true
                i += 2
                continue
            }

            // Handle backslash escapes inside strings (e.g., \' \" \\)
            if inString && ch == backslash && i + 1 < length {
                i += 2
                continue
            }

            // Track string/identifier literals
            if ch == singleQuote || ch == doubleQuote || ch == backtick {
                if !inString {
                    inString = true
                    stringCharVal = ch
                } else if ch == stringCharVal {
                    // Handle doubled (escaped) quotes: '' "" ``
                    if i + 1 < length && nsQuery.character(at: i + 1) == stringCharVal {
                        i += 1 // Skip the escaped quote
                    } else {
                        inString = false
                    }
                }
            }

            // Statement delimiter
            if ch == semicolonChar && !inString {
                let stmtEnd = i + 1
                if safePosition >= currentStart && safePosition <= stmtEnd {
                    let stmtRange = NSRange(location: currentStart, length: i - currentStart)
                    return nsQuery.substring(with: stmtRange)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentStart = stmtEnd
            }

            i += 1
        }

        // Cursor is in the last statement (no trailing semicolon)
        if currentStart < length {
            let stmtRange = NSRange(location: currentStart, length: length - currentStart)
            return nsQuery.substring(with: stmtRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return fullQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sorting

    func handleSort(columnIndex: Int, ascending: Bool, isMultiSort: Bool = false, selectedRowIndices: inout Set<Int>) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tab = tabManager.tabs[tabIndex]
        guard columnIndex >= 0 && columnIndex < tab.resultColumns.count else { return }

        var currentSort = tab.sortState
        let newDirection: SortDirection = ascending ? .ascending : .descending

        if isMultiSort {
            // Multi-sort: toggle existing or append new column
            if let existingIndex = currentSort.columns.firstIndex(where: { $0.columnIndex == columnIndex }) {
                if currentSort.columns[existingIndex].direction == newDirection {
                    // Same direction clicked again — remove from sort
                    currentSort.columns.remove(at: existingIndex)
                } else {
                    // Toggle direction
                    currentSort.columns[existingIndex].direction = newDirection
                }
            } else {
                // Add new column to sort list
                currentSort.columns.append(SortColumn(columnIndex: columnIndex, direction: newDirection))
            }
        } else {
            // Single sort: replace all with single column
            currentSort = SortState()
            currentSort.columns = [SortColumn(columnIndex: columnIndex, direction: newDirection)]
        }

        tabManager.tabs[tabIndex].sortState = currentSort
        tabManager.tabs[tabIndex].hasUserInteraction = true

        // Reset pagination to page 1 when sorting changes
        tabManager.tabs[tabIndex].pagination.reset()

        if tab.tabType == .query {
            let rows = tab.resultRows
            let tabId = tab.id
            let resultVersion = tab.resultVersion
            let sortColumns = currentSort.columns

            if rows.count > 10_000 {
                // Large dataset: sort on background thread to avoid UI freeze
                activeSortTasks[tabId]?.cancel()
                activeSortTasks.removeValue(forKey: tabId)
                tabManager.tabs[tabIndex].isExecuting = true
                toolbarState.setExecuting(true)
                querySortCache.removeValue(forKey: tabId)

                let sortStartTime = Date()
                let task = Task.detached { [weak self] in
                    let sortedIndices = Self.multiColumnSortIndices(rows: rows, sortColumns: sortColumns)
                    let sortDuration = Date().timeIntervalSince(sortStartTime)

                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        // Guard against stale completion: verify tab still expects this sort
                        guard let idx = self.tabManager.tabs.firstIndex(where: { $0.id == tabId }),
                              self.tabManager.tabs[idx].sortState == currentSort else {
                            return
                        }
                        self.querySortCache[tabId] = QuerySortCacheEntry(
                            sortedIndices: sortedIndices,
                            columnIndex: sortColumns.first?.columnIndex ?? 0,
                            direction: sortColumns.first?.direction ?? .ascending,
                            resultVersion: resultVersion
                        )
                        var sortedTab = self.tabManager.tabs[idx]
                        sortedTab.isExecuting = false
                        sortedTab.executionTime = sortDuration
                        self.tabManager.tabs[idx] = sortedTab
                        self.toolbarState.setExecuting(false)
                        self.toolbarState.lastQueryDuration = sortDuration
                        self.activeSortTasks.removeValue(forKey: tabId)
                        self.changeManager.reloadVersion += 1
                    }
                }
                activeSortTasks[tabId] = task
            } else {
                // Small dataset: view sorts synchronously, just trigger reload
                changeManager.reloadVersion += 1
            }
            return
        }

        // Table tabs: rebuild query with ORDER BY and re-execute
        let newQuery = queryBuilder.buildMultiSortQuery(
            baseQuery: tab.query,
            sortState: currentSort,
            columns: tab.resultColumns
        )
        tabManager.tabs[tabIndex].query = newQuery
        runQuery()
    }

    /// Multi-column sort returning index permutation (nonisolated for background thread).
    /// Returns an array of indices into the original `rows` array, sorted by the given columns.
    nonisolated private static func multiColumnSortIndices(
        rows: [QueryResultRow],
        sortColumns: [SortColumn]
    ) -> [Int] {
        var indices = Array(0..<rows.count)
        indices.sort { i1, i2 in
            let row1 = rows[i1]
            let row2 = rows[i2]
            for sortCol in sortColumns {
                let val1 = sortCol.columnIndex < row1.values.count
                    ? (row1.values[sortCol.columnIndex] ?? "") : ""
                let val2 = sortCol.columnIndex < row2.values.count
                    ? (row2.values[sortCol.columnIndex] ?? "") : ""
                let result = val1.localizedStandardCompare(val2)
                if result == .orderedSame { continue }
                return sortCol.direction == .ascending
                    ? result == .orderedAscending
                    : result == .orderedDescending
            }
            return false
        }
        return indices
    }

    // MARK: - Save Changes

    func saveChanges(
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>,
        tableOperationOptions: inout [String: TableOperationOptions]
    ) {
        guard !connection.isReadOnly else {
            if let index = tabManager.selectedTabIndex {
                tabManager.tabs[index].errorMessage = "Cannot save changes: connection is read-only"
            }
            return
        }

        let hasEditedCells = changeManager.hasChanges
        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

        guard hasEditedCells || hasPendingTableOps else { return }

        let allStatements: [ParameterizedStatement]
        do {
            allStatements = try assemblePendingStatements(
                pendingTruncates: pendingTruncates,
                pendingDeletes: pendingDeletes,
                tableOperationOptions: tableOperationOptions
            )
        } catch {
            if let index = tabManager.selectedTabIndex {
                tabManager.tabs[index].errorMessage = error.localizedDescription
            }
            return
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
    internal func generateTableOperationSQL(
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

        let viewNames: Set<String> = {
            guard let session = DatabaseManager.shared.currentSession else { return [] }
            return Set(session.tables.filter { $0.type == .view }.map(\.name))
        }()

        for tableName in sortedDeletes {
            let quotedName = dbType.quoteIdentifier(tableName)
            let tableOptions = options[tableName] ?? TableOperationOptions()
            statements.append(dropTableStatement(quotedName: quotedName, isView: viewNames.contains(tableName), options: tableOptions, dbType: dbType))
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
    internal func fkDisableStatements(for dbType: DatabaseType) -> [String] {
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
    internal func fkEnableStatements(for dbType: DatabaseType) -> [String] {
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

    /// Generates DROP TABLE/VIEW statement with optional CASCADE.
    private func dropTableStatement(quotedName: String, isView: Bool, options: TableOperationOptions, dbType: DatabaseType) -> String {
        let keyword = isView ? "VIEW" : "TABLE"
        switch dbType {
        case .postgresql:
            return "DROP \(keyword) \(quotedName)\(options.cascade ? " CASCADE" : "")"
        case .mysql, .mariadb, .sqlite:
            return "DROP \(keyword) \(quotedName)"
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
        _ statements: [ParameterizedStatement],
        clearTableOps: Bool,
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>,
        tableOperationOptions: inout [String: TableOperationOptions]
    ) {
        let validStatements = statements.filter { !$0.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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

        Task { @MainActor in
            let overallStartTime = Date()

            do {
                guard let driver = DatabaseManager.shared.activeDriver else {
                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].errorMessage = "Not connected to database"
                    }
                    throw DatabaseError.notConnected
                }

                for statement in validStatements {
                    let statementStartTime = Date()

                    // Execute parameterized query if has parameters, otherwise use regular execute
                    if statement.parameters.isEmpty {
                        _ = try await driver.execute(query: statement.sql)
                    } else {
                        _ = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
                    }

                    let executionTime = Date().timeIntervalSince(statementStartTime)

                    QueryHistoryManager.shared.recordQuery(
                        query: statement.sql.trimmingCharacters(in: .whitespacesAndNewlines),
                        connectionId: conn.id,
                        databaseName: conn.database,
                        executionTime: executionTime,
                        rowCount: 0,
                        wasSuccessful: true,
                        errorMessage: nil
                    )
                }

                changeManager.clearChanges()
                if let index = tabManager.selectedTabIndex {
                    let currentTabId = tabManager.tabs[index].id
                    tabManager.tabs[index].pendingChanges = TabPendingChanges()
                    tabPendingChanges.removeValue(forKey: currentTabId)
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

                if tabManager.selectedTabIndex != nil && !tabManager.tabs.isEmpty {
                    runQuery()
                }
            } catch {
                let executionTime = Date().timeIntervalSince(overallStartTime)

                // Try to re-enable FK checks if they were disabled
                if fkWasDisabled, let driver = DatabaseManager.shared.activeDriver {
                    for statement in self.fkEnableStatements(for: dbType) {
                        do {
                            _ = try await driver.execute(query: statement)
                        } catch {
                            Self.logger.warning("Failed to re-enable foreign key checks with statement '\(statement, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }

                let allSQL = validStatements.map { $0.sql }.joined(separator: "; ")
                QueryHistoryManager.shared.recordQuery(
                    query: allSQL,
                    connectionId: conn.id,
                    databaseName: conn.database,
                    executionTime: executionTime,
                    rowCount: 0,
                    wasSuccessful: false,
                    errorMessage: error.localizedDescription
                )

                if let index = tabManager.selectedTabIndex {
                    tabManager.tabs[index].errorMessage = "Save failed: \(error.localizedDescription)"
                }

                // Show error alert to user
                AlertHelper.showErrorSheet(
                    title: String(localized: "Save Failed"),
                    message: error.localizedDescription,
                    window: NSApplication.shared.keyWindow
                )

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

    // MARK: - Table Creation

    /// Execute sidebar changes immediately (single transaction)
    func executeSidebarChanges(statements: [String]) async throws {
        guard let driver = DatabaseManager.shared.activeDriver else {
            throw DatabaseError.notConnected
        }

        let dbType = connection.type
        var allStatements: [String] = []

        // Add database-specific BEGIN / START TRANSACTION
        let beginStatement: String
        switch dbType {
        case .mysql, .mariadb:
            beginStatement = "START TRANSACTION"
        default:
            beginStatement = "BEGIN"
        }
        allStatements.append(beginStatement)

        // Add user statements
        allStatements.append(contentsOf: statements)

        // Add COMMIT
        allStatements.append("COMMIT")

        // Execute all statements sequentially
        do {
            for sql in allStatements {
                _ = try await driver.execute(query: sql)
            }
        } catch {
            // Try to rollback on error
            _ = try? await driver.execute(query: "ROLLBACK")
            throw error
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
        Task { @MainActor in
            let startTime = Date()

            do {
                guard let driver = DatabaseManager.shared.activeDriver else {
                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].errorMessage = "Not connected to database"
                    }
                    throw DatabaseError.notConnected
                }

                // Execute CREATE TABLE
                _ = try await driver.execute(query: sql)

                _ = Date().timeIntervalSince(startTime)

                // Refresh schema to show new table (outside MainActor)
                await schemaProvider.invalidateCache()
                await loadSchema()

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

                // Execute query to load table data if needed (runs async)
                if needs {
                    runQuery()
                }
            } catch {
                if let index = tabManager.selectedTabIndex {
                    tabManager.tabs[index].errorMessage = "Failed to create table: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Discard Handling

    func handleDiscard(
        pendingTruncates: inout Set<String>,
        pendingDeletes: inout Set<String>
    ) {
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
            let currentTabId = tabManager.tabs[index].id
            tabManager.tabs[index].pendingChanges = TabPendingChanges()
            tabPendingChanges.removeValue(forKey: currentTabId)
        }

        NotificationCenter.default.post(name: .databaseDidConnect, object: nil)
    }

    // MARK: - Tab Operations

    func handleCloseAction() {
        if let tab = tabManager.selectedTab, !tab.isPinned {
            let hasEditedCells = changeManager.hasChanges

            // Always confirm if there are unsaved changes
            if hasEditedCells {
                Task { @MainActor in
                    let confirmed = await confirmDiscardChanges(action: .closeTab)
                    if confirmed {
                        closeCurrentTab()
                    }
                }
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
}

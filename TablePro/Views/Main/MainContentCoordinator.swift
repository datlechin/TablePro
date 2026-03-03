//
//  MainContentCoordinator.swift
//  TablePro
//
//  Coordinator managing business logic for MainContentView.
//  Separates view logic from presentation for better maintainability.
//

import CodeEditSourceEditor
import Foundation
import Observation
import os
import SwiftUI

/// Discard action types for unified alert handling
enum DiscardAction {
    case refresh, refreshAll
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
@MainActor @Observable
final class MainContentCoordinator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator")

    /// Per-connection shared schema providers so new tabs skip redundant schema loads
    private static var sharedSchemaProviders: [UUID: SQLSchemaProvider] = [:]
    /// Reference counts for shared schema providers (tracks how many coordinators use each)
    private static var schemaProviderRefCounts: [UUID: Int] = [:]
    /// Delayed removal tasks — cancelled if a new coordinator claims the provider within the grace period
    private static var schemaProviderRemovalTasks: [UUID: Task<Void, Never>] = [:]

    static func schemaProvider(for connectionId: UUID) -> SQLSchemaProvider? {
        sharedSchemaProviders[connectionId]
    }

    // MARK: - Dependencies

    nonisolated(unsafe) let connection: DatabaseConnection
    var connectionId: UUID { connection.id }
    let tabManager: QueryTabManager
    let changeManager: DataChangeManager
    let filterStateManager: FilterStateManager
    let toolbarState: ConnectionToolbarState

    // MARK: - Services

    internal let queryBuilder: TableQueryBuilder
    let tabPersistence: TabPersistenceService
    @ObservationIgnored internal lazy var rowOperationsManager: RowOperationsManager = {
        RowOperationsManager(changeManager: changeManager)
    }()

    // MARK: - Published State

    var schemaProvider: SQLSchemaProvider
    var cursorPositions: [CursorPosition] = []
    var tableMetadata: TableMetadata?
    // Removed: showErrorAlert and errorAlertMessage - errors now display inline
    var activeSheet: ActiveSheet?
    var importFileURL: URL?
    var needsLazyLoad = false

    /// Cache for async-sorted query tab rows (large datasets sorted on background thread)
    private(set) var querySortCache: [UUID: QuerySortCacheEntry] = [:]

    // MARK: - Internal State

    @ObservationIgnored internal var queryGeneration: Int = 0
    @ObservationIgnored internal var currentQueryTask: Task<Void, Never>?
    @ObservationIgnored private var changeManagerUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var activeSortTasks: [UUID: Task<Void, Never>] = [:]

    /// Set during handleTabChange to suppress redundant onChange(of: resultColumns) reconfiguration
    internal var isHandlingTabSwitch = false

    /// True while a database switch is in progress. Guards against
    /// side-effect window creation during the switch cascade.
    var isSwitchingDatabase = false

    /// Tracks whether teardown() was called; used by deinit to log missed teardowns
    @ObservationIgnored private var didTeardown = false

    /// Remove sort cache entries for tabs that no longer exist
    func cleanupSortCache(openTabIds: Set<UUID>) {
        if querySortCache.keys.contains(where: { !openTabIds.contains($0) }) {
            querySortCache = querySortCache.filter { openTabIds.contains($0.key) }
        }
        for (tabId, task) in activeSortTasks where !openTabIds.contains(tabId) {
            task.cancel()
            activeSortTasks.removeValue(forKey: tabId)
        }
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

        // Reuse existing schema provider for this connection, or create a new one
        if let existing = Self.sharedSchemaProviders[connection.id] {
            self.schemaProvider = existing
        } else {
            let provider = SQLSchemaProvider()
            Self.sharedSchemaProviders[connection.id] = provider
            self.schemaProvider = provider
        }

        Self.retainSchemaProvider(for: connection.id)
    }

    /// Explicit cleanup called from `onDisappear`. Releases schema provider
    /// synchronously on MainActor so we don't depend on deinit + Task scheduling.
    func teardown() {
        didTeardown = true
        currentQueryTask?.cancel()
        currentQueryTask = nil
        changeManagerUpdateTask?.cancel()
        changeManagerUpdateTask = nil
        for task in activeSortTasks.values { task.cancel() }
        activeSortTasks.removeAll()

        // Release heavy data so memory drops even if SwiftUI delays deallocation
        for tab in tabManager.tabs {
            tab.rowBuffer.evict()
        }
        querySortCache.removeAll()

        Self.releaseSchemaProvider(for: connection.id)
        Self.purgeUnusedSchemaProviders()
    }

    deinit {
        let connectionId = connection.id
        guard !didTeardown else { return }
        let logger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator")
        logger.warning("teardown() was not called before deallocation for connection \(connectionId)")
        Task { @MainActor in
            MainContentCoordinator.releaseSchemaProvider(for: connectionId)
            MainContentCoordinator.purgeUnusedSchemaProviders()
        }
    }

    // MARK: - Initialization Actions

    /// Synchronous toolbar setup — no I/O, safe to call inline
    func initializeToolbar() {
        toolbarState.update(from: connection)

        if let session = DatabaseManager.shared.session(for: connectionId) {
            toolbarState.connectionState = mapSessionStatus(session.status)
            if let driver = session.driver {
                toolbarState.databaseVersion = driver.serverVersion
            }
        } else if let driver = DatabaseManager.shared.driver(for: connectionId) {
            toolbarState.connectionState = .connected
            toolbarState.databaseVersion = driver.serverVersion
        }
    }

    /// Load schema only if the shared provider hasn't loaded yet
    func loadSchemaIfNeeded() async {
        let alreadyLoaded = await schemaProvider.isSchemaLoaded()
        if !alreadyLoaded {
            await loadSchema()
        }
    }

    /// Initialize view with connection info and load schema (legacy — used by first window)
    func initializeView() async {
        initializeToolbar()
        await loadSchemaIfNeeded()
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
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
        await schemaProvider.loadSchema(using: driver, connection: connection)
    }

    func loadTableMetadata(tableName: String) async {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }

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

    private static let mongoCollectionRegex = try? NSRegularExpression(
        pattern: #"^\s*db\.(\w+)\."#,
        options: []
    )

    private static let mongoBracketCollectionRegex = try? NSRegularExpression(
        pattern: #"^\s*db\["([^"]+)"\]"#,
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
        case .mongodb:
            explainSQL = Self.buildMongoExplain(for: stmt)
        }

        Task { @MainActor in
            executeQueryInternal(explainSQL)
        }
    }

    /// Internal query execution (called after any confirmations)
    private func executeQueryInternal(
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
                // Pre-check metadata cache before starting any queries.
                var parallelSchemaTask: Task<SchemaResult, Error>?
                var needsMetadataFetch = false

                if isEditable, let tableName = tableName {
                    let cached = isMetadataCached(tabId: tabId, tableName: tableName)
                    needsMetadataFetch = !cached

                    // If metadata is NOT cached and a dedicated metadata driver exists,
                    // start fetching columns+FKs on the separate connection so it runs
                    // in parallel with the main query.
                    if needsMetadataFetch, let metaDriver = DatabaseManager.shared.metadataDriver(for: connectionId) {
                        parallelSchemaTask = Task {
                            async let cols = metaDriver.fetchColumns(table: tableName)
                            async let fks = metaDriver.fetchForeignKeys(table: tableName)
                            let result = try await (columnInfo: cols, fkInfo: fks)
                            let approxCount = try? await metaDriver.fetchApproximateRowCount(table: tableName)
                            return (columnInfo: result.columnInfo, fkInfo: result.fkInfo, approximateRowCount: approxCount)
                        }
                    }
                }

                // Main data query (on primary driver — runs concurrently with metadata)
                guard let queryDriver = DatabaseManager.shared.driver(for: connectionId) else {
                    throw DatabaseError.notConnected
                }
                let safeColumns: [String]
                let safeColumnTypes: [ColumnType]
                let safeRows: [QueryResultRow]
                let safeExecutionTime: TimeInterval
                let safeRowsAffected: Int
                do {
                    let result = try await queryDriver.execute(query: effectiveSQL)
                    safeColumns = result.columns
                    safeColumnTypes = result.columnTypes
                    safeRows = result.rows.enumerated().map { index, row in
                        QueryResultRow(id: index, values: row)
                    }
                    safeExecutionTime = result.executionTime
                    safeRowsAffected = result.rowsAffected
                }

                guard !Task.isCancelled else {
                    parallelSchemaTask?.cancel()
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

                // Await schema result before Phase 1 so data + FK arrows appear together
                var schemaResult: SchemaResult?
                if needsMetadataFetch {
                    schemaResult = await awaitSchemaResult(
                        parallelTask: parallelSchemaTask,
                        tableName: tableName ?? ""
                    )
                }

                // Parse schema metadata if available
                let metadata = schemaResult.map { parseSchemaMetadata($0) }

                // Phase 1: Display data rows + FK arrows in a single MainActor update.
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    currentQueryTask = nil
                    toolbarState.setExecuting(false)
                    toolbarState.lastQueryDuration = safeExecutionTime

                    guard capturedGeneration == queryGeneration else { return }
                    guard !Task.isCancelled else { return }

                    applyPhase1Result(
                        tabId: tabId,
                        columns: safeColumns,
                        columnTypes: safeColumnTypes,
                        rows: safeRows,
                        executionTime: safeExecutionTime,
                        rowsAffected: safeRowsAffected,
                        tableName: tableName,
                        isEditable: isEditable,
                        metadata: metadata,
                        hasSchema: schemaResult != nil,
                        sql: sql,
                        connection: conn
                    )
                }

                // Phase 2: Background exact COUNT + enum values.
                if isEditable, let tableName = tableName, needsMetadataFetch {
                    launchPhase2Work(
                        tableName: tableName,
                        tabId: tabId,
                        capturedGeneration: capturedGeneration,
                        connectionType: conn.type,
                        schemaResult: schemaResult
                    )
                } else if !isEditable || tableName == nil {
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
                    handleQueryExecutionError(error, sql: sql, tabId: tabId, connection: conn)
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
        let nsRange = NSRange(sql.startIndex..., in: sql)

        // SQL: SELECT ... FROM tableName
        if let regex = Self.tableNameRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: sql) {
            return String(sql[range])
        }

        // MQL bracket notation: db["collectionName"].find(...)
        if let regex = Self.mongoBracketCollectionRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: sql) {
            return String(sql[range])
        }

        // MQL dot notation: db.collectionName.find(...)
        if let regex = Self.mongoCollectionRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: sql) {
            return String(sql[range])
        }

        return nil
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
                guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
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
                    tabManager.tabs[index].pendingChanges = TabPendingChanges()
                    tabManager.tabs[index].errorMessage = nil
                }

                if clearTableOps {
                    // Close tabs for deleted tables
                    if !deletedTables.isEmpty {
                        if let currentTab = tabManager.selectedTab,
                           let tableName = currentTab.tableName,
                           deletedTables.contains(tableName) {
                            NSApp.keyWindow?.close()
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
                if fkWasDisabled, let driver = DatabaseManager.shared.driver(for: connectionId) {
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
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
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
            tabManager.tabs[index].pendingChanges = TabPendingChanges()
        }

        NotificationCenter.default.post(name: .databaseDidConnect, object: nil)
    }

    /// Remove shared schema provider when a connection disconnects
    static func clearSharedSchema(for connectionId: UUID) {
        sharedSchemaProviders.removeValue(forKey: connectionId)
        schemaProviderRefCounts.removeValue(forKey: connectionId)
        schemaProviderRemovalTasks[connectionId]?.cancel()
        schemaProviderRemovalTasks.removeValue(forKey: connectionId)
    }

    /// Increment reference count for a connection's schema provider
    private static func retainSchemaProvider(for connectionId: UUID) {
        schemaProviderRemovalTasks[connectionId]?.cancel()
        schemaProviderRemovalTasks.removeValue(forKey: connectionId)
        schemaProviderRefCounts[connectionId, default: 0] += 1
    }

    /// Decrement reference count; schedule deferred removal when count reaches zero
    private static func releaseSchemaProvider(for connectionId: UUID) {
        guard var count = schemaProviderRefCounts[connectionId] else { return }
        count -= 1
        if count <= 0 {
            schemaProviderRefCounts.removeValue(forKey: connectionId)
            // Grace period: keep provider alive for 5s in case a new tab opens quickly
            schemaProviderRemovalTasks[connectionId] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                sharedSchemaProviders.removeValue(forKey: connectionId)
                schemaProviderRemovalTasks.removeValue(forKey: connectionId)
            }
        } else {
            schemaProviderRefCounts[connectionId] = count
        }
    }

    /// Remove entries with zero or missing reference counts that lack pending removal tasks.
    /// Guards against unbounded growth if releaseSchemaProvider fails to execute.
    private static func purgeUnusedSchemaProviders() {
        let orphanedIds = sharedSchemaProviders.keys.filter { connectionId in
            let count = schemaProviderRefCounts[connectionId] ?? 0
            let hasPendingRemoval = schemaProviderRemovalTasks[connectionId] != nil
            return count <= 0 && !hasPendingRemoval
        }
        for connectionId in orphanedIds {
            logger.info("Purging orphaned schema provider for connection \(connectionId)")
            sharedSchemaProviders.removeValue(forKey: connectionId)
            schemaProviderRefCounts.removeValue(forKey: connectionId)
        }
    }
}

// MARK: - Query Execution Helpers

private extension MainContentCoordinator {
    /// Parsed schema metadata ready to apply to a tab
    struct ParsedSchemaMetadata {
        let columnDefaults: [String: String?]
        let columnForeignKeys: [String: ForeignKeyInfo]
        let columnNullable: [String: Bool]
        let primaryKeyColumn: String?
        let approximateRowCount: Int?
    }

    /// Schema result from parallel or sequential metadata fetch
    typealias SchemaResult = (columnInfo: [ColumnInfo], fkInfo: [ForeignKeyInfo], approximateRowCount: Int?)

    /// Parse a SchemaResult into dictionaries ready for tab assignment
    func parseSchemaMetadata(_ schema: SchemaResult) -> ParsedSchemaMetadata {
        var defaults: [String: String?] = [:]
        var fks: [String: ForeignKeyInfo] = [:]
        var nullable: [String: Bool] = [:]
        for col in schema.columnInfo {
            defaults[col.name] = col.defaultValue
            nullable[col.name] = col.isNullable
        }
        for fk in schema.fkInfo {
            fks[fk.column] = fk
        }
        return ParsedSchemaMetadata(
            columnDefaults: defaults,
            columnForeignKeys: fks,
            columnNullable: nullable,
            primaryKeyColumn: schema.columnInfo.first(where: { $0.isPrimaryKey })?.name,
            approximateRowCount: schema.approximateRowCount
        )
    }

    /// Check whether metadata is already cached for the given table in a tab
    func isMetadataCached(tabId: UUID, tableName: String) -> Bool {
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            return false
        }
        let tab = tabManager.tabs[idx]
        guard tab.tableName == tableName,
              !tab.columnDefaults.isEmpty,
              tab.primaryKeyColumn != nil else {
            return false
        }
        // Ensure every ENUM/SET column has its allowed values loaded
        let enumSetColumnNames: [String] = tab.resultColumns.enumerated().compactMap { i, name in
            guard i < tab.columnTypes.count,
                  tab.columnTypes[i].isEnumType || tab.columnTypes[i].isSetType else { return nil }
            return name
        }
        if !enumSetColumnNames.isEmpty,
           !enumSetColumnNames.allSatisfy({ tab.columnEnumValues[$0] != nil }) {
            return false
        }
        return true
    }

    /// Await schema metadata from parallel task or fall back to sequential fetch
    func awaitSchemaResult(
        parallelTask: Task<SchemaResult, Error>?,
        tableName: String
    ) async -> SchemaResult? {
        if let parallelTask {
            return try? await parallelTask.value
        }
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return nil }
        do {
            async let cols = driver.fetchColumns(table: tableName)
            async let fks = driver.fetchForeignKeys(table: tableName)
            let (c, f) = try await (cols, fks)
            let approxCount = try? await driver.fetchApproximateRowCount(table: tableName)
            return (columnInfo: c, fkInfo: f, approximateRowCount: approxCount)
        } catch {
            Self.logger.error("Phase 2 schema fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Apply Phase 1 query result data and optional metadata to the tab
    func applyPhase1Result( // swiftlint:disable:this function_parameter_count
        tabId: UUID,
        columns: [String],
        columnTypes: [ColumnType],
        rows: [QueryResultRow],
        executionTime: TimeInterval,
        rowsAffected: Int,
        tableName: String?,
        isEditable: Bool,
        metadata: ParsedSchemaMetadata?,
        hasSchema: Bool,
        sql: String,
        connection conn: DatabaseConnection
    ) {
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }

        var updatedTab = tabManager.tabs[idx]
        updatedTab.resultColumns = columns
        updatedTab.columnTypes = columnTypes
        updatedTab.resultRows = rows
        updatedTab.resultVersion += 1
        updatedTab.executionTime = executionTime
        updatedTab.rowsAffected = rowsAffected
        updatedTab.isExecuting = false
        updatedTab.lastExecutedAt = Date()
        updatedTab.tableName = tableName
        updatedTab.isEditable = isEditable && updatedTab.isEditable

        // Merge FK metadata into the same update if available
        if let metadata {
            updatedTab.columnDefaults = metadata.columnDefaults
            updatedTab.columnForeignKeys = metadata.columnForeignKeys
            updatedTab.columnNullable = metadata.columnNullable
            if let approxCount = metadata.approximateRowCount, approxCount > 0 {
                updatedTab.pagination.totalRowCount = approxCount
                updatedTab.pagination.isApproximateRowCount = true
            }
        }
        if hasSchema {
            updatedTab.metadataVersion += 1
        }

        tabManager.tabs[idx] = updatedTab
        AppState.shared.isCurrentTabEditable = updatedTab.isEditable
            && !updatedTab.isView && updatedTab.tableName != nil
        toolbarState.isTableTab = updatedTab.tabType == .table

        if let pk = metadata?.primaryKeyColumn {
            tabManager.tabs[idx].primaryKeyColumn = pk

            if tabManager.selectedTabId == tabId {
                changeManager.configureForTable(
                    tableName: tableName ?? "",
                    columns: columns,
                    primaryKeyColumn: pk,
                    databaseType: conn.type
                )
            }
        }

        QueryHistoryManager.shared.recordQuery(
            query: sql,
            connectionId: conn.id,
            databaseName: conn.database,
            executionTime: executionTime,
            rowCount: rows.count,
            wasSuccessful: true,
            errorMessage: nil
        )

        // Clear stale edit state immediately so the save banner
        // doesn't linger while Phase 2 metadata loads in background.
        if isEditable {
            changeManager.clearChanges()
        }
    }

    /// Launch Phase 2 background work: exact COUNT(*) and enum value fetching
    func launchPhase2Work(
        tableName: String,
        tabId: UUID,
        capturedGeneration: Int,
        connectionType: DatabaseType,
        schemaResult: SchemaResult?
    ) {
        // Phase 2a: Fire-and-forget exact COUNT(*) to refine approximate count.
        let quotedTable = connectionType.quoteIdentifier(tableName)
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let mainDriver = DatabaseManager.shared.driver(for: connectionId) else { return }
            let countResult = try? await mainDriver.execute(
                query: "SELECT COUNT(*) FROM \(quotedTable)"
            )
            if let firstRow = countResult?.rows.first,
               let countStr = firstRow.first ?? nil,
               let count = Int(countStr) {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard capturedGeneration == queryGeneration else { return }
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.tabs[idx].pagination.totalRowCount = count
                        tabManager.tabs[idx].pagination.isApproximateRowCount = false
                    }
                }
            }
        }

        // Phase 2b: Fetch enum/set values
        let enumDriver = DatabaseManager.shared.metadataDriver(for: connectionId)
            ?? DatabaseManager.shared.driver(for: connectionId)
        guard let enumDriver else { return }

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)

            // Use schema if available, otherwise fetch column info for enum parsing
            let columnInfo: [ColumnInfo]
            if let schema = schemaResult {
                columnInfo = schema.columnInfo
            } else {
                do {
                    columnInfo = try await enumDriver.fetchColumns(table: tableName)
                } catch {
                    columnInfo = []
                }
            }

            let columnEnumValues = await self.fetchEnumValues(
                columnInfo: columnInfo,
                tableName: tableName,
                driver: enumDriver,
                connectionType: connectionType
            )

            guard !columnEnumValues.isEmpty else {
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard capturedGeneration == queryGeneration else { return }
                guard !Task.isCancelled else { return }
                if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                    tabManager.tabs[idx].columnEnumValues = columnEnumValues
                    tabManager.tabs[idx].metadataVersion += 1
                }
            }
        }
    }

    /// Handle query execution error: update tab state, record history, show alert
    func handleQueryExecutionError(
        _ error: Error,
        sql: String,
        tabId: UUID,
        connection conn: DatabaseConnection
    ) {
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

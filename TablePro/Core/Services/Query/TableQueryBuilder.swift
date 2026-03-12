//
//  TableQueryBuilder.swift
//  TablePro
//
//  Service responsible for building SQL queries for table operations.
//  Handles sorting, filtering, and quick search query construction.
//

import Foundation
import TableProPluginKit

/// Service for building SQL queries for table operations
struct TableQueryBuilder {
    // MARK: - Properties

    private let databaseType: DatabaseType
    private var pluginDriver: (any PluginDatabaseDriver)?

    // MARK: - Initialization

    init(databaseType: DatabaseType, pluginDriver: (any PluginDatabaseDriver)? = nil) {
        self.databaseType = databaseType
        self.pluginDriver = pluginDriver
    }

    mutating func setPluginDriver(_ driver: (any PluginDatabaseDriver)?) {
        pluginDriver = driver
    }

    // MARK: - Query Building

    /// Build a base SELECT query for a table with optional sorting and pagination
    /// - Parameters:
    ///   - tableName: The table to query
    ///   - sortState: Optional sort state to apply ORDER BY
    ///   - columns: Available columns (for sort column validation)
    ///   - limit: Row limit (default 200)
    ///   - offset: Starting row offset for pagination (default 0)
    /// - Returns: Complete SQL query string
    func buildBaseQuery(
        tableName: String,
        sortState: SortState? = nil,
        columns: [String] = [],
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        // Try plugin dispatch first (handles plugins with custom query building)
        if let pluginDriver {
            let sortCols = sortColumnsAsTuples(sortState)
            if let result = pluginDriver.buildBrowseQuery(
                table: tableName, sortColumns: sortCols,
                columns: columns, limit: limit, offset: offset
            ) {
                return result
            }
        }

        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"

        // Add ORDER BY if sort state is valid
        if let orderBy = buildOrderByClause(sortState: sortState, columns: columns) {
            query += " \(orderBy)"
        }

        query += " LIMIT \(limit) OFFSET \(offset)"
        return query
    }

    /// Build a query with filters applied and pagination support
    /// - Parameters:
    ///   - tableName: The table to query
    ///   - filters: Array of filters to apply
    ///   - logicMode: AND/OR logic for combining filters
    ///   - sortState: Optional sort state
    ///   - columns: Available columns
    ///   - limit: Row limit (default 200)
    ///   - offset: Starting row offset for pagination (default 0)
    /// - Returns: Complete SQL query string with WHERE clause
    func buildFilteredQuery(
        tableName: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode = .and,
        sortState: SortState? = nil,
        columns: [String] = [],
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        // Try plugin dispatch first (handles plugins with custom query building)
        if let pluginDriver {
            let sortCols = sortColumnsAsTuples(sortState)
            let filterTuples = filters
                .filter { $0.isEnabled && !$0.columnName.isEmpty }
                .map { ($0.columnName, $0.filterOperator.rawValue, $0.value) }
            if let result = pluginDriver.buildFilteredQuery(
                table: tableName, filters: filterTuples,
                logicMode: logicMode == .and ? "and" : "or",
                sortColumns: sortCols, columns: columns, limit: limit, offset: offset
            ) {
                return result
            }
        }

        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"

        // Add WHERE clause from filters
        let generator = FilterSQLGenerator(databaseType: databaseType)
        let whereClause = generator.generateWhereClause(from: filters, logicMode: logicMode)
        if !whereClause.isEmpty {
            query += " \(whereClause)"
        }

        // Add ORDER BY
        if let orderBy = buildOrderByClause(sortState: sortState, columns: columns) {
            query += " \(orderBy)"
        }

        query += " LIMIT \(limit) OFFSET \(offset)"
        return query
    }

    /// Build a quick search query that searches across all columns with pagination
    /// - Parameters:
    ///   - tableName: The table to query
    ///   - searchText: Text to search for
    ///   - columns: Columns to search in
    ///   - sortState: Optional sort state
    ///   - limit: Row limit (default 200)
    ///   - offset: Starting row offset for pagination (default 0)
    /// - Returns: Complete SQL query with OR conditions across all columns
    func buildQuickSearchQuery(
        tableName: String,
        searchText: String,
        columns: [String],
        sortState: SortState? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        // Try plugin dispatch first (handles plugins with custom query building)
        if let pluginDriver {
            let sortCols = sortColumnsAsTuples(sortState)
            if let result = pluginDriver.buildQuickSearchQuery(
                table: tableName, searchText: searchText, columns: columns,
                sortColumns: sortCols, limit: limit, offset: offset
            ) {
                return result
            }
        }

        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"

        // Build OR conditions for all columns
        let escapedSearch = escapeForLike(searchText)
        let conditions = columns.map { column -> String in
            let quotedColumn = databaseType.quoteIdentifier(column)
            return buildLikeCondition(column: quotedColumn, searchText: escapedSearch)
        }

        if !conditions.isEmpty {
            query += " WHERE (" + conditions.joined(separator: " OR ") + ")"
        }

        // Add ORDER BY
        if let orderBy = buildOrderByClause(sortState: sortState, columns: columns) {
            query += " \(orderBy)"
        }

        query += " LIMIT \(limit) OFFSET \(offset)"
        return query
    }

    /// Build a query combining filter rows AND quick search
    /// - Parameters:
    ///   - tableName: The table to query
    ///   - filters: Array of filters to apply
    ///   - logicMode: AND/OR logic for combining filters
    ///   - searchText: Quick search text
    ///   - searchColumns: Columns for quick search
    ///   - sortState: Optional sort state
    ///   - columns: Available columns (for sort validation)
    ///   - limit: Row limit
    ///   - offset: Pagination offset
    /// - Returns: Complete SQL query with both filter WHERE clause and quick search conditions
    func buildCombinedQuery(
        tableName: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode = .and,
        searchText: String,
        searchColumns: [String],
        sortState: SortState? = nil,
        columns: [String] = [],
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        // Try plugin dispatch first (handles plugins with custom query building)
        if let pluginDriver {
            let sortCols = sortColumnsAsTuples(sortState)
            let filterTuples = filters
                .filter { $0.isEnabled && !$0.columnName.isEmpty }
                .map { ($0.columnName, $0.filterOperator.rawValue, $0.value) }
            if let result = pluginDriver.buildCombinedQuery(
                table: tableName, filters: filterTuples,
                logicMode: logicMode == .and ? "and" : "or",
                searchText: searchText, searchColumns: searchColumns,
                sortColumns: sortCols, columns: columns, limit: limit, offset: offset
            ) {
                return result
            }
        }

        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"

        // Build filter conditions
        let generator = FilterSQLGenerator(databaseType: databaseType)
        let filterConditions = generator.generateConditions(from: filters, logicMode: logicMode)

        // Build quick search conditions
        let escapedSearch = escapeForLike(searchText)
        let searchConditions = searchColumns.map { column -> String in
            let quotedColumn = databaseType.quoteIdentifier(column)
            return buildLikeCondition(column: quotedColumn, searchText: escapedSearch)
        }
        let searchClause = searchConditions.isEmpty ? "" : "(" + searchConditions.joined(separator: " OR ") + ")"

        // Combine with AND
        var whereParts: [String] = []
        if !filterConditions.isEmpty {
            whereParts.append("(\(filterConditions))")
        }
        if !searchClause.isEmpty {
            whereParts.append(searchClause)
        }

        if !whereParts.isEmpty {
            query += " WHERE " + whereParts.joined(separator: " AND ")
        }

        // Add ORDER BY
        if let orderBy = buildOrderByClause(sortState: sortState, columns: columns) {
            query += " \(orderBy)"
        }

        query += " LIMIT \(limit) OFFSET \(offset)"
        return query
    }

    /// Build a sorted query by modifying an existing query
    /// - Parameters:
    ///   - baseQuery: The original query (ORDER BY will be removed and replaced)
    ///   - columnName: Column to sort by
    ///   - ascending: Sort direction
    /// - Returns: Modified query with new ORDER BY clause
    func buildSortedQuery(
        baseQuery: String,
        columnName: String,
        ascending: Bool
    ) -> String {
        // Plugin-based drivers handle sorting at query-build time, not via query rewriting
        if pluginDriver != nil {
            return baseQuery
        }

        var query = removeOrderBy(from: baseQuery)
        let direction = ascending ? "ASC" : "DESC"
        let quotedColumn = databaseType.quoteIdentifier(columnName)
        let orderByClause = "ORDER BY \(quotedColumn) \(direction)"

        // Insert ORDER BY before pagination clause
        if let limitRange = query.range(of: "LIMIT", options: .caseInsensitive) {
            let beforeLimit = query[..<limitRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let limitClause = query[limitRange.lowerBound...]
            query = "\(beforeLimit) \(orderByClause) \(limitClause)"
        } else if let offsetRange = query.range(of: "OFFSET", options: .caseInsensitive) {
            // MSSQL/Oracle use OFFSET ... ROWS FETCH NEXT ... ROWS ONLY
            let beforeOffset = query[..<offsetRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let offsetClause = query[offsetRange.lowerBound...]
            query = "\(beforeOffset) \(orderByClause) \(offsetClause)"
        } else {
            // Add ORDER BY at the end
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix(";") {
                query = String(trimmed.dropLast()) + " \(orderByClause);"
            } else {
                query = "\(trimmed) \(orderByClause)"
            }
        }

        return query
    }

    /// Build a sorted query with multi-column sort support
    /// - Parameters:
    ///   - baseQuery: The original query (ORDER BY will be removed and replaced)
    ///   - sortState: Multi-column sort state
    ///   - columns: Available column names for index validation
    /// - Returns: Modified query with new ORDER BY clause
    func buildMultiSortQuery(
        baseQuery: String,
        sortState: SortState,
        columns: [String]
    ) -> String {
        // Plugin-based drivers handle sorting at query-build time, not via query rewriting
        if pluginDriver != nil {
            return baseQuery
        }

        var query = removeOrderBy(from: baseQuery)

        if let orderBy = buildOrderByClause(sortState: sortState, columns: columns) {
            // Insert ORDER BY before pagination clause
            if let limitRange = query.range(of: "LIMIT", options: .caseInsensitive) {
                let beforeLimit = query[..<limitRange.lowerBound].trimmingCharacters(in: .whitespaces)
                let limitClause = query[limitRange.lowerBound...]
                query = "\(beforeLimit) \(orderBy) \(limitClause)"
            } else if let offsetRange = query.range(of: "OFFSET", options: .caseInsensitive) {
                // MSSQL/Oracle use OFFSET ... ROWS FETCH NEXT ... ROWS ONLY
                let beforeOffset = query[..<offsetRange.lowerBound].trimmingCharacters(in: .whitespaces)
                let offsetClause = query[offsetRange.lowerBound...]
                query = "\(beforeOffset) \(orderBy) \(offsetClause)"
            } else {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasSuffix(";") {
                    query = String(trimmed.dropLast()) + " \(orderBy);"
                } else {
                    query = "\(trimmed) \(orderBy)"
                }
            }
        }

        return query
    }

    // MARK: - Private Helpers

    /// Extract sort columns as tuples from sort state for plugin driver dispatch
    private func sortColumnsAsTuples(_ sortState: SortState?) -> [(columnIndex: Int, ascending: Bool)] {
        sortState?.columns.compactMap { sortCol -> (columnIndex: Int, ascending: Bool)? in
            guard sortCol.columnIndex >= 0 else { return nil }
            return (sortCol.columnIndex, sortCol.direction == .ascending)
        } ?? []
    }

    /// Build ORDER BY clause from sort state (supports multi-column)
    private func buildOrderByClause(sortState: SortState?, columns: [String]) -> String? {
        guard let state = sortState, state.isSorting else { return nil }

        let parts = state.columns.compactMap { sortCol -> String? in
            guard sortCol.columnIndex >= 0, sortCol.columnIndex < columns.count else { return nil }
            let columnName = columns[sortCol.columnIndex]
            let direction = sortCol.direction == .ascending ? "ASC" : "DESC"
            let quotedColumn = databaseType.quoteIdentifier(columnName)
            return "\(quotedColumn) \(direction)"
        }

        guard !parts.isEmpty else { return nil }
        return "ORDER BY " + parts.joined(separator: ", ")
    }

    /// Remove existing ORDER BY clause from a query
    private func removeOrderBy(from query: String) -> String {
        var result = query

        guard let orderByRange = result.range(of: "ORDER BY", options: [.caseInsensitive, .backwards]) else {
            return result
        }

        let afterOrderBy = result[orderByRange.upperBound...]

        // Find where ORDER BY clause ends (before LIMIT/OFFSET or end of query)
        if let limitRange = afterOrderBy.range(of: "LIMIT", options: .caseInsensitive) {
            // Keep LIMIT, remove ORDER BY clause
            let beforeOrderBy = result[..<orderByRange.lowerBound]
            let limitClause = result[limitRange.lowerBound...]
            result = String(beforeOrderBy) + String(limitClause)
        } else if let offsetRange = afterOrderBy.range(of: "OFFSET", options: .caseInsensitive) {
            // MSSQL/Oracle: keep OFFSET ... ROWS FETCH NEXT ... ROWS ONLY
            let beforeOrderBy = result[..<orderByRange.lowerBound]
            let offsetClause = result[offsetRange.lowerBound...]
            result = String(beforeOrderBy) + String(offsetClause)
        } else if afterOrderBy.range(of: ";") != nil {
            // Remove ORDER BY until semicolon
            result = String(result[..<orderByRange.lowerBound]) + ";"
        } else {
            // Remove ORDER BY until end
            result = String(result[..<orderByRange.lowerBound])
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Escape special characters for LIKE clause
    private func escapeForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "'", with: "''")
    }

    /// Build a LIKE condition with proper type casting for non-text columns
    /// PostgreSQL requires explicit cast to TEXT for numeric/other types.
    /// MySQL/MariaDB default to `\` as the LIKE escape character, so no ESCAPE clause needed.
    /// PostgreSQL and SQLite require an explicit ESCAPE declaration.
    private func buildLikeCondition(column: String, searchText: String) -> String {
        switch databaseType {
        case .postgresql, .redshift:
            return "\(column)::TEXT LIKE '%\(searchText)%' ESCAPE '\\'"
        case .mysql, .mariadb:
            return "CAST(\(column) AS CHAR) LIKE '%\(searchText)%'"
        case .clickhouse:
            return "toString(\(column)) LIKE '%\(searchText)%' ESCAPE '\\'"
        case .duckdb:
            return "CAST(\(column) AS VARCHAR) LIKE '%\(searchText)%' ESCAPE '\\'"
        case .sqlite, .mongodb, .redis:
            return "\(column) LIKE '%\(searchText)%' ESCAPE '\\'"
        case .mssql:
            return "CAST(\(column) AS NVARCHAR(MAX)) LIKE '%\(searchText)%' ESCAPE '\\'"
        case .oracle:
            return "CAST(\(column) AS VARCHAR2(4000)) LIKE '%\(searchText)%' ESCAPE '\\'"
        }
    }
}

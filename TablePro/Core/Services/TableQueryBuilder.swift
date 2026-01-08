//
//  TableQueryBuilder.swift
//  TablePro
//
//  Service responsible for building SQL queries for table operations.
//  Handles sorting, filtering, and quick search query construction.
//

import Foundation

/// Service for building SQL queries for table operations
struct TableQueryBuilder {
    // MARK: - Properties

    private let databaseType: DatabaseType

    // MARK: - Initialization

    init(databaseType: DatabaseType) {
        self.databaseType = databaseType
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
    ///   - sortState: Optional sort state
    ///   - columns: Available columns
    ///   - limit: Row limit (default 200)
    ///   - offset: Starting row offset for pagination (default 0)
    /// - Returns: Complete SQL query string with WHERE clause
    func buildFilteredQuery(
        tableName: String,
        filters: [TableFilter],
        sortState: SortState? = nil,
        columns: [String] = [],
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"

        // Add WHERE clause from filters
        let generator = FilterSQLGenerator(databaseType: databaseType)
        let whereClause = generator.generateWhereClause(from: filters)
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
        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"

        // Build OR conditions for all columns
        // Cast to text to handle numeric/non-text columns (PostgreSQL requires explicit cast)
        let conditions = columns.map { column -> String in
            let quotedColumn = databaseType.quoteIdentifier(column)
            let escapedSearch = escapeForLike(searchText)
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
        var query = removeOrderBy(from: baseQuery)
        let direction = ascending ? "ASC" : "DESC"
        let quotedColumn = databaseType.quoteIdentifier(columnName)
        let orderByClause = "ORDER BY \(quotedColumn) \(direction)"

        // Insert ORDER BY before LIMIT if exists
        if let limitRange = query.range(of: "LIMIT", options: .caseInsensitive) {
            let beforeLimit = query[..<limitRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let limitClause = query[limitRange.lowerBound...]
            query = "\(beforeLimit) \(orderByClause) \(limitClause)"
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

    // MARK: - Private Helpers

    /// Build ORDER BY clause from sort state
    private func buildOrderByClause(sortState: SortState?, columns: [String]) -> String? {
        guard let state = sortState,
              let columnIndex = state.columnIndex,
              columnIndex < columns.count else {
            return nil
        }

        let columnName = columns[columnIndex]
        let direction = state.direction == .ascending ? "ASC" : "DESC"
        let quotedColumn = databaseType.quoteIdentifier(columnName)
        return "ORDER BY \(quotedColumn) \(direction)"
    }

    /// Remove existing ORDER BY clause from a query
    private func removeOrderBy(from query: String) -> String {
        var result = query

        guard let orderByRange = result.range(of: "ORDER BY", options: [.caseInsensitive, .backwards]) else {
            return result
        }

        let afterOrderBy = result[orderByRange.upperBound...]

        // Find where ORDER BY clause ends (before LIMIT or end of query)
        if let limitRange = afterOrderBy.range(of: "LIMIT", options: .caseInsensitive) {
            // Keep LIMIT, remove ORDER BY clause
            let beforeOrderBy = result[..<orderByRange.lowerBound]
            let limitClause = result[limitRange.lowerBound...]
            result = String(beforeOrderBy) + String(limitClause)
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
    /// PostgreSQL requires explicit cast to TEXT for numeric/other types
    private func buildLikeCondition(column: String, searchText: String) -> String {
        switch databaseType {
        case .postgresql:
            // PostgreSQL: Cast to TEXT to handle numeric, date, and other non-text types
            return "\(column)::TEXT LIKE '%\(searchText)%'"
        case .mysql, .mariadb:
            // MySQL/MariaDB: Implicit conversion works, but CAST is safer for all types
            return "CAST(\(column) AS CHAR) LIKE '%\(searchText)%'"
        case .sqlite:
            // SQLite: Very lenient with type coercion, LIKE works on most types
            return "\(column) LIKE '%\(searchText)%'"
        }
    }
}

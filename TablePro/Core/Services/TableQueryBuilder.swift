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
        if databaseType == .mongodb {
            return buildMongoBaseQuery(
                tableName: tableName, sortState: sortState,
                columns: columns, limit: limit, offset: offset
            )
        }

        if databaseType == .redis {
            let redisBuilder = RedisQueryBuilder()
            return redisBuilder.buildBaseQuery(
                namespace: "", sortState: sortState,
                columns: columns, limit: limit, offset: offset
            )
        }

        if databaseType == .mssql {
            return buildMSSQLBaseQuery(
                tableName: tableName, sortState: sortState,
                columns: columns, limit: limit, offset: offset
            )
        }

        if databaseType == .oracle {
            return buildOracleBaseQuery(
                tableName: tableName, sortState: sortState,
                columns: columns, limit: limit, offset: offset
            )
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
        if databaseType == .mongodb {
            let mongoBuilder = MongoDBQueryBuilder()
            return mongoBuilder.buildFilteredQuery(
                collection: tableName,
                filters: filters,
                logicMode: logicMode,
                sortState: sortState,
                columns: columns,
                limit: limit,
                offset: offset
            )
        }

        if databaseType == .redis {
            let redisBuilder = RedisQueryBuilder()
            return redisBuilder.buildFilteredQuery(
                namespace: "",
                filters: filters,
                logicMode: logicMode,
                limit: limit
            )
        }

        if databaseType == .mssql {
            return buildMSSQLFilteredQuery(
                tableName: tableName,
                filters: filters,
                logicMode: logicMode,
                sortState: sortState,
                columns: columns,
                limit: limit,
                offset: offset
            )
        }

        if databaseType == .oracle {
            return buildOracleFilteredQuery(
                tableName: tableName,
                filters: filters,
                logicMode: logicMode,
                sortState: sortState,
                columns: columns,
                limit: limit,
                offset: offset
            )
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
        if databaseType == .mongodb {
            return buildMongoQuickSearchQuery(
                tableName: tableName, searchText: searchText, columns: columns,
                sortState: sortState, limit: limit, offset: offset
            )
        }

        if databaseType == .redis {
            let redisBuilder = RedisQueryBuilder()
            return redisBuilder.buildQuickSearchQuery(
                namespace: "",
                searchText: searchText,
                limit: limit
            )
        }

        if databaseType == .mssql {
            return buildMSSQLQuickSearchQuery(
                tableName: tableName, searchText: searchText, columns: columns,
                sortState: sortState, limit: limit, offset: offset
            )
        }

        if databaseType == .oracle {
            return buildOracleQuickSearchQuery(
                tableName: tableName, searchText: searchText, columns: columns,
                sortState: sortState, limit: limit, offset: offset
            )
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
        if databaseType == .redis {
            let redisBuilder = RedisQueryBuilder()
            let hasFilters = !filters.isEmpty
            let hasSearch = !searchText.isEmpty

            if hasSearch {
                return redisBuilder.buildQuickSearchQuery(
                    namespace: "",
                    searchText: searchText,
                    limit: limit
                )
            } else if hasFilters {
                return redisBuilder.buildFilteredQuery(
                    namespace: "",
                    filters: filters,
                    logicMode: logicMode,
                    limit: limit
                )
            } else {
                return redisBuilder.buildBaseQuery(
                    namespace: "",
                    limit: limit,
                    offset: offset
                )
            }
        }

        if databaseType == .mongodb {
            let mongoBuilder = MongoDBQueryBuilder()
            let hasFilters = !filters.isEmpty
            let hasSearch = !searchText.isEmpty && !searchColumns.isEmpty

            if hasFilters && hasSearch {
                return mongoBuilder.buildCombinedQuery(
                    collection: tableName,
                    filters: filters,
                    logicMode: logicMode,
                    searchText: searchText,
                    searchColumns: searchColumns,
                    sortState: sortState,
                    columns: columns,
                    limit: limit,
                    offset: offset
                )
            } else if hasSearch {
                return mongoBuilder.buildQuickSearchQuery(
                    collection: tableName,
                    searchText: searchText,
                    columns: searchColumns,
                    sortState: sortState,
                    limit: limit,
                    offset: offset
                )
            } else if hasFilters {
                return mongoBuilder.buildFilteredQuery(
                    collection: tableName,
                    filters: filters,
                    logicMode: logicMode,
                    sortState: sortState,
                    columns: columns,
                    limit: limit,
                    offset: offset
                )
            } else {
                return mongoBuilder.buildBaseQuery(
                    collection: tableName,
                    sortState: sortState,
                    columns: columns,
                    limit: limit,
                    offset: offset
                )
            }
        }

        if databaseType == .mssql {
            return buildMSSQLCombinedQuery(
                tableName: tableName, filters: filters, logicMode: logicMode,
                searchText: searchText, searchColumns: searchColumns,
                sortState: sortState, columns: columns, limit: limit, offset: offset
            )
        }

        if databaseType == .oracle {
            return buildOracleCombinedQuery(
                tableName: tableName, filters: filters, logicMode: logicMode,
                searchText: searchText, searchColumns: searchColumns,
                sortState: sortState, columns: columns, limit: limit, offset: offset
            )
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
        // Redis SCAN does not support server-side sorting
        if databaseType == .redis {
            return baseQuery
        }

        if databaseType == .mongodb, let parsed = parseMongoQuery(baseQuery) {
            let sortDoc = "\"\(Self.escapeMongoString(columnName))\": \(ascending ? 1 : -1)"
            return "\(Self.mongoCollectionAccessor(parsed.collection)).find(\(parsed.filter))"
                + ".sort({\(sortDoc)})"
                + ".limit(\(parsed.limit)).skip(\(parsed.skip))"
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
        // Redis SCAN does not support server-side sorting
        if databaseType == .redis {
            return baseQuery
        }

        if databaseType == .mongodb, let parsed = parseMongoQuery(baseQuery) {
            if let sortDoc = buildMongoSortDoc(sortState: sortState, columns: columns) {
                return "\(Self.mongoCollectionAccessor(parsed.collection)).find(\(parsed.filter))"
                    + ".sort({\(sortDoc)})"
                    + ".limit(\(parsed.limit)).skip(\(parsed.skip))"
            }
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

    // MARK: - MongoDB Query Helpers

    private func buildMongoBaseQuery(
        tableName: String,
        sortState: SortState? = nil,
        columns: [String] = [],
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        var query = "\(Self.mongoCollectionAccessor(tableName)).find({})"

        if let sortDoc = buildMongoSortDoc(sortState: sortState, columns: columns) {
            query += ".sort({\(sortDoc)})"
        }

        query += ".limit(\(limit)).skip(\(offset))"
        return query
    }

    private func buildMongoQuickSearchQuery(
        tableName: String,
        searchText: String,
        columns: [String],
        sortState: SortState? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        let escaped = Self.escapeMongoString(searchText)
        let orConditions = columns.map { column in
            "{\"" + Self.escapeMongoString(column) + "\": {\"$regex\": \"" + escaped + "\", \"$options\": \"i\"}}"
        }

        let filter: String
        if orConditions.isEmpty {
            filter = "{}"
        } else {
            filter = "{\"$or\": [" + orConditions.joined(separator: ", ") + "]}"
        }

        var query = "\(Self.mongoCollectionAccessor(tableName)).find(\(filter))"

        if let sortDoc = buildMongoSortDoc(sortState: sortState, columns: columns) {
            query += ".sort({\(sortDoc)})"
        }

        query += ".limit(\(limit)).skip(\(offset))"
        return query
    }

    private func buildMongoSortDoc(sortState: SortState?, columns: [String]) -> String? {
        guard let state = sortState, state.isSorting else { return nil }

        let parts = state.columns.compactMap { sortCol -> String? in
            guard sortCol.columnIndex >= 0, sortCol.columnIndex < columns.count else { return nil }
            let columnName = columns[sortCol.columnIndex]
            let direction = sortCol.direction == .ascending ? 1 : -1
            return "\"\(Self.escapeMongoString(columnName))\": \(direction)"
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    private struct MongoQueryParts {
        let collection: String
        let filter: String
        let limit: Int
        let skip: Int
    }

    private func parseMongoQuery(_ query: String) -> MongoQueryParts? {
        let nsQuery = query as NSString
        guard nsQuery.hasPrefix("db.") else { return nil }

        let afterDb = nsQuery.substring(from: 3)
        let nsAfterDb = afterDb as NSString

        let findRange = nsAfterDb.range(of: ".find(")
        guard findRange.location != NSNotFound else { return nil }

        let collection = nsAfterDb.substring(to: findRange.location)

        // Extract filter: content between .find( and the matching )
        let filterStart = findRange.location + findRange.length
        var depth = 1
        var filterEnd = filterStart
        while filterEnd < nsAfterDb.length, depth > 0 {
            let ch = nsAfterDb.character(at: filterEnd)
            if ch == 0x28 { depth += 1 } // (
            if ch == 0x29 { depth -= 1 } // )
            if depth > 0 { filterEnd += 1 }
        }
        let filter = nsAfterDb.substring(with: NSRange(location: filterStart, length: filterEnd - filterStart))

        // Extract .limit(N)
        var limit = 200
        let limitPattern = try? NSRegularExpression(pattern: #"\.limit\((\d+)\)"#)
        if let match = limitPattern?.firstMatch(in: afterDb, range: NSRange(location: 0, length: nsAfterDb.length)),
           match.numberOfRanges > 1 {
            limit = Int(nsAfterDb.substring(with: match.range(at: 1))) ?? 200
        }

        // Extract .skip(N)
        var skip = 0
        let skipPattern = try? NSRegularExpression(pattern: #"\.skip\((\d+)\)"#)
        if let match = skipPattern?.firstMatch(in: afterDb, range: NSRange(location: 0, length: nsAfterDb.length)),
           match.numberOfRanges > 1 {
            skip = Int(nsAfterDb.substring(with: match.range(at: 1))) ?? 0
        }

        return MongoQueryParts(collection: collection, filter: filter, limit: limit, skip: skip)
    }

    /// Escape special characters for MongoDB string values (handles Unicode control chars U+0000–U+001F)
    private static func escapeMongoString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity((value as NSString).length)
        for char in value {
            switch char {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if let ascii = char.asciiValue, ascii < 0x20 {
                    result += String(format: "\\u%04X", ascii)
                } else {
                    result.append(char)
                }
            }
        }
        return result
    }

    /// Access a MongoDB collection, using bracket notation for names with special chars
    private static func mongoCollectionAccessor(_ name: String) -> String {
        guard let firstChar = name.first,
              !firstChar.isNumber,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return "db[\"\(escapeMongoString(name))\"]"
        }
        return "db.\(name)"
    }

    // MARK: - Private Helpers

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
        case .sqlite, .mongodb, .redis:
            return "\(column) LIKE '%\(searchText)%' ESCAPE '\\'"
        case .mssql:
            return "CAST(\(column) AS NVARCHAR(MAX)) LIKE '%\(searchText)%' ESCAPE '\\'"
        case .oracle:
            return "CAST(\(column) AS VARCHAR2(4000)) LIKE '%\(searchText)%' ESCAPE '\\'"
        }
    }

    // MARK: - MSSQL Query Helpers

    private func buildMSSQLBaseQuery(
        tableName: String,
        sortState: SortState?,
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String {
        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"
        let orderBy = buildOrderByClause(sortState: sortState, columns: columns)
            ?? "ORDER BY (SELECT NULL)"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    private func buildMSSQLFilteredQuery(
        tableName: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        sortState: SortState?,
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String {
        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"
        let generator = FilterSQLGenerator(databaseType: databaseType)
        let whereClause = generator.generateWhereClause(from: filters, logicMode: logicMode)
        if !whereClause.isEmpty {
            query += " \(whereClause)"
        }
        let orderBy = buildOrderByClause(sortState: sortState, columns: columns)
            ?? "ORDER BY (SELECT NULL)"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    private func buildMSSQLQuickSearchQuery(
        tableName: String,
        searchText: String,
        columns: [String],
        sortState: SortState?,
        limit: Int,
        offset: Int
    ) -> String {
        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"
        let escapedSearch = escapeForLike(searchText)
        let conditions = columns.map { column -> String in
            let quotedColumn = databaseType.quoteIdentifier(column)
            return buildLikeCondition(column: quotedColumn, searchText: escapedSearch)
        }
        if !conditions.isEmpty {
            query += " WHERE (" + conditions.joined(separator: " OR ") + ")"
        }
        let orderBy = buildOrderByClause(sortState: sortState, columns: columns)
            ?? "ORDER BY (SELECT NULL)"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    private func buildMSSQLCombinedQuery(
        tableName: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        searchText: String,
        searchColumns: [String],
        sortState: SortState?,
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String {
        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"
        let generator = FilterSQLGenerator(databaseType: databaseType)
        let filterConditions = generator.generateConditions(from: filters, logicMode: logicMode)
        let escapedSearch = escapeForLike(searchText)
        let searchConditions = searchColumns.map { column -> String in
            let quotedColumn = databaseType.quoteIdentifier(column)
            return buildLikeCondition(column: quotedColumn, searchText: escapedSearch)
        }
        let searchClause = searchConditions.isEmpty ? "" : "(" + searchConditions.joined(separator: " OR ") + ")"
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
        let orderBy = buildOrderByClause(sortState: sortState, columns: columns)
            ?? "ORDER BY (SELECT NULL)"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    // MARK: - Oracle Query Helpers

    private func buildOracleBaseQuery(
        tableName: String,
        sortState: SortState?,
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String {
        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"
        let orderBy = buildOrderByClause(sortState: sortState, columns: columns)
            ?? "ORDER BY 1"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    private func buildOracleFilteredQuery(
        tableName: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        sortState: SortState?,
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String {
        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"
        let generator = FilterSQLGenerator(databaseType: databaseType)
        let whereClause = generator.generateWhereClause(from: filters, logicMode: logicMode)
        if !whereClause.isEmpty {
            query += " \(whereClause)"
        }
        let orderBy = buildOrderByClause(sortState: sortState, columns: columns)
            ?? "ORDER BY 1"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    private func buildOracleQuickSearchQuery(
        tableName: String,
        searchText: String,
        columns: [String],
        sortState: SortState?,
        limit: Int,
        offset: Int
    ) -> String {
        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"
        let escapedSearch = escapeForLike(searchText)
        let conditions = columns.map { column -> String in
            let quotedColumn = databaseType.quoteIdentifier(column)
            return buildLikeCondition(column: quotedColumn, searchText: escapedSearch)
        }
        if !conditions.isEmpty {
            query += " WHERE (" + conditions.joined(separator: " OR ") + ")"
        }
        let orderBy = buildOrderByClause(sortState: sortState, columns: columns)
            ?? "ORDER BY 1"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    private func buildOracleCombinedQuery(
        tableName: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        searchText: String,
        searchColumns: [String],
        sortState: SortState?,
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String {
        let quotedTable = databaseType.quoteIdentifier(tableName)
        var query = "SELECT * FROM \(quotedTable)"
        let generator = FilterSQLGenerator(databaseType: databaseType)
        let filterConditions = generator.generateConditions(from: filters, logicMode: logicMode)
        let escapedSearch = escapeForLike(searchText)
        let searchConditions = searchColumns.map { column -> String in
            let quotedColumn = databaseType.quoteIdentifier(column)
            return buildLikeCondition(column: quotedColumn, searchText: escapedSearch)
        }
        let searchClause = searchConditions.isEmpty ? "" : "(" + searchConditions.joined(separator: " OR ") + ")"
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
        let orderBy = buildOrderByClause(sortState: sortState, columns: columns)
            ?? "ORDER BY 1"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }
}

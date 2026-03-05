//
//  FilterSQLGenerator.swift
//  TablePro
//
//  Generates SQL WHERE clauses from filter definitions
//

import Foundation

/// Generates SQL WHERE clauses from filter definitions
struct FilterSQLGenerator {
    let databaseType: DatabaseType

    // MARK: - Public API

    /// Generate a complete WHERE clause from filters
    func generateWhereClause(from filters: [TableFilter], logicMode: FilterLogicMode = .and) -> String {
        let conditions = filters.compactMap { generateCondition(from: $0) }
        guard !conditions.isEmpty else { return "" }
        let separator = logicMode == .and ? " AND " : " OR "
        return "WHERE " + conditions.joined(separator: separator)
    }

    /// Generate just the conditions (without WHERE keyword)
    func generateConditions(from filters: [TableFilter], logicMode: FilterLogicMode = .and) -> String {
        let conditions = filters.compactMap { generateCondition(from: $0) }
        let separator = logicMode == .and ? " AND " : " OR "
        return conditions.joined(separator: separator)
    }

    /// Generate a single filter condition
    func generateCondition(from filter: TableFilter) -> String? {
        guard filter.isValid else { return nil }

        // Raw SQL mode - return as-is
        if filter.isRawSQL, let rawSQL = filter.rawSQL {
            return "(\(rawSQL))"
        }

        let quotedColumn = databaseType.quoteIdentifier(filter.columnName)

        switch filter.filterOperator {
        case .equal:
            return "\(quotedColumn) = \(escapeValue(filter.value))"

        case .notEqual:
            return "\(quotedColumn) != \(escapeValue(filter.value))"

        case .contains:
            return generateLikeCondition(column: quotedColumn, pattern: "%\(escapeLikeWildcards(filter.value))%")

        case .notContains:
            return generateNotLikeCondition(column: quotedColumn, pattern: "%\(escapeLikeWildcards(filter.value))%")

        case .startsWith:
            return generateLikeCondition(column: quotedColumn, pattern: "\(escapeLikeWildcards(filter.value))%")

        case .endsWith:
            return generateLikeCondition(column: quotedColumn, pattern: "%\(escapeLikeWildcards(filter.value))")

        case .greaterThan:
            return "\(quotedColumn) > \(escapeValue(filter.value))"

        case .greaterOrEqual:
            return "\(quotedColumn) >= \(escapeValue(filter.value))"

        case .lessThan:
            return "\(quotedColumn) < \(escapeValue(filter.value))"

        case .lessOrEqual:
            return "\(quotedColumn) <= \(escapeValue(filter.value))"

        case .isNull:
            return "\(quotedColumn) IS NULL"

        case .isNotNull:
            return "\(quotedColumn) IS NOT NULL"

        case .isEmpty:
            return "(\(quotedColumn) IS NULL OR \(quotedColumn) = '')"

        case .isNotEmpty:
            return "(\(quotedColumn) IS NOT NULL AND \(quotedColumn) != '')"

        case .inList:
            let values = parseListValues(filter.value)
                .map { escapeValue($0) }
                .joined(separator: ", ")
            guard !values.isEmpty else { return nil }
            return "\(quotedColumn) IN (\(values))"

        case .notInList:
            let values = parseListValues(filter.value)
                .map { escapeValue($0) }
                .joined(separator: ", ")
            guard !values.isEmpty else { return nil }
            return "\(quotedColumn) NOT IN (\(values))"

        case .between:
            guard let secondValue = filter.secondValue, !secondValue.isEmpty else { return nil }
            return "\(quotedColumn) BETWEEN \(escapeValue(filter.value)) AND \(escapeValue(secondValue))"

        case .regex:
            // SQLite doesn't support REGEXP without a custom function;
            // MongoDB filters are handled natively by MongoDBQueryBuilder
            if databaseType == .sqlite || databaseType == .mongodb || databaseType == .redis { return nil }
            return generateRegexCondition(column: quotedColumn, pattern: filter.value)
        }
    }

    // MARK: - LIKE Conditions

    /// Database-specific ESCAPE clause for LIKE patterns.
    /// MySQL/MariaDB default to `\` as the LIKE escape character, so no clause needed.
    /// PostgreSQL and SQLite require an explicit ESCAPE declaration.
    private var likeEscapeClause: String {
        switch databaseType {
        case .mysql, .mariadb:
            return ""
        case .postgresql, .redshift, .sqlite, .mongodb, .redis, .mssql:
            return " ESCAPE '\\'"
        }
    }

    private func generateLikeCondition(column: String, pattern: String) -> String {
        let quotedPattern = escapeSQLQuote(pattern)
        return "\(column) LIKE '\(quotedPattern)'\(likeEscapeClause)"
    }

    private func generateNotLikeCondition(column: String, pattern: String) -> String {
        let quotedPattern = escapeSQLQuote(pattern)
        return "\(column) NOT LIKE '\(quotedPattern)'\(likeEscapeClause)"
    }

    // MARK: - REGEX Conditions (Database-Specific)

    private func generateRegexCondition(column: String, pattern: String) -> String {
        let escapedPattern = escapeStringValue(pattern)

        switch databaseType {
        case .mysql, .mariadb:
            return "\(column) REGEXP '\(escapedPattern)'"
        case .postgresql, .redshift:
            return "\(column) ~ '\(escapedPattern)'"
        case .sqlite, .mongodb, .redis, .mssql:
            return "\(column) LIKE '%\(escapedPattern)%'"
        }
    }

    // MARK: - Value Escaping

    /// Escape a value for SQL, auto-detecting type
    private func escapeValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        // Check for NULL literal (case-insensitive without allocating uppercased copy)
        if trimmed.caseInsensitiveCompare("NULL") == .orderedSame {
            return "NULL"
        }

        // Check for boolean literals
        if trimmed.caseInsensitiveCompare("TRUE") == .orderedSame {
            return databaseType == .postgresql || databaseType == .redshift ? "TRUE" : "1"
        }
        if trimmed.caseInsensitiveCompare("FALSE") == .orderedSame {
            return databaseType == .postgresql || databaseType == .redshift ? "FALSE" : "0"
        }

        // Try to detect numeric values
        if Int(trimmed) != nil || Double(trimmed) != nil {
            return trimmed
        }

        // String value - escape and quote
        return "'\(escapeStringValue(trimmed))'"
    }

    /// Escape only single quotes for SQL string literal context.
    /// Used for LIKE patterns where backslashes are already escaped
    /// by escapeLikeWildcards for the ESCAPE clause.
    private func escapeSQLQuote(_ value: String) -> String {
        guard value.contains("'") else { return value }
        return value.replacingOccurrences(of: "'", with: "''")
    }

    /// Escape special characters in string values
    private func escapeStringValue(_ value: String) -> String {
        // Fast path: most values have no special chars
        guard value.contains("\\") || value.contains("'") else { return value }
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
    }

    /// Escape LIKE pattern wildcards (% and _) in user input
    private func escapeLikeWildcards(_ value: String) -> String {
        // Fast path: most values have no special chars
        guard value.contains("\\") || value.contains("%") || value.contains("_") else { return value }
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - List Parsing

    /// Parse comma-separated list values
    private func parseListValues(_ input: String) -> [String] {
        input.split(separator: ",", omittingEmptySubsequences: true)
            .compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
    }
}

// MARK: - Preview/Display Helpers

extension FilterSQLGenerator {
    /// Generate a preview-friendly query string (for display, not execution)
    func generatePreviewSQL(tableName: String, filters: [TableFilter], limit: Int = 1_000) -> String {
        if databaseType == .mongodb {
            let mongoBuilder = MongoDBQueryBuilder()
            return mongoBuilder.buildFilteredQuery(
                collection: tableName,
                filters: filters,
                limit: limit
            )
        }

        let quotedTable = databaseType.quoteIdentifier(tableName)
        var sql = "SELECT * FROM \(quotedTable)"

        let whereClause = generateWhereClause(from: filters)
        if !whereClause.isEmpty {
            sql += "\n\(whereClause)"
        }

        sql += "\nLIMIT \(limit)"
        return sql
    }
}

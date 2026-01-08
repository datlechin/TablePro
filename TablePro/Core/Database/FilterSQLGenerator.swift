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
            return generateRegexCondition(column: quotedColumn, pattern: filter.value)
        }
    }

    // MARK: - LIKE Conditions

    private func generateLikeCondition(column: String, pattern: String) -> String {
        let escapedPattern = escapeStringValue(pattern)
        return "\(column) LIKE '\(escapedPattern)'"
    }

    private func generateNotLikeCondition(column: String, pattern: String) -> String {
        let escapedPattern = escapeStringValue(pattern)
        return "\(column) NOT LIKE '\(escapedPattern)'"
    }

    // MARK: - REGEX Conditions (Database-Specific)

    private func generateRegexCondition(column: String, pattern: String) -> String {
        let escapedPattern = escapeStringValue(pattern)

        switch databaseType {
        case .mysql, .mariadb:
            return "\(column) REGEXP '\(escapedPattern)'"
        case .postgresql:
            return "\(column) ~ '\(escapedPattern)'"
        case .sqlite:
            // SQLite doesn't have built-in REGEXP unless extension loaded
            // Fall back to LIKE with wildcards as a best-effort approximation
            return "\(column) LIKE '%\(escapedPattern)%'"
        }
    }

    // MARK: - Value Escaping

    /// Escape a value for SQL, auto-detecting type
    private func escapeValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        // Check for NULL literal
        if trimmed.uppercased() == "NULL" {
            return "NULL"
        }

        // Check for boolean literals
        if trimmed.uppercased() == "TRUE" {
            return databaseType == .postgresql ? "TRUE" : "1"
        }
        if trimmed.uppercased() == "FALSE" {
            return databaseType == .postgresql ? "FALSE" : "0"
        }

        // Try to detect numeric values
        if Int(trimmed) != nil {
            return trimmed
        }
        if Double(trimmed) != nil {
            return trimmed
        }

        // String value - escape and quote
        return "'\(escapeStringValue(trimmed))'"
    }

    /// Escape special characters in string values
    private func escapeStringValue(_ value: String) -> String {
        var result = value
        // Escape backslashes first
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        // Escape single quotes
        result = result.replacingOccurrences(of: "'", with: "''")
        return result
    }

    /// Escape LIKE pattern wildcards (% and _) in user input
    private func escapeLikeWildcards(_ value: String) -> String {
        var result = value
        // Escape the escape character first
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        // Escape LIKE wildcards
        result = result.replacingOccurrences(of: "%", with: "\\%")
        result = result.replacingOccurrences(of: "_", with: "\\_")
        return result
    }

    // MARK: - List Parsing

    /// Parse comma-separated list values
    private func parseListValues(_ input: String) -> [String] {
        // Split by comma, trim whitespace, filter empty
        input
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Preview/Display Helpers

extension FilterSQLGenerator {
    /// Generate a preview-friendly SQL string (for display, not execution)
    func generatePreviewSQL(tableName: String, filters: [TableFilter], limit: Int = 1_000) -> String {
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

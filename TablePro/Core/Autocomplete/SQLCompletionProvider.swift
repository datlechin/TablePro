//
//  SQLCompletionProvider.swift
//  TablePro
//
//  Main orchestrator for SQL autocomplete
//

import Foundation

/// Main provider for SQL autocomplete suggestions
final class SQLCompletionProvider {
    // MARK: - Properties

    private let contextAnalyzer = SQLContextAnalyzer()
    private let schemaProvider: SQLSchemaProvider

    /// Minimum prefix length to trigger suggestions
    private let minPrefixLength = 1

    /// Maximum number of suggestions to return
    private let maxSuggestions = 20

    // MARK: - Init

    init(schemaProvider: SQLSchemaProvider) {
        self.schemaProvider = schemaProvider
    }

    // MARK: - Public API

    /// Get completion suggestions for the current cursor position
    func getCompletions(
        text: String,
        cursorPosition: Int
    ) async -> (items: [SQLCompletionItem], context: SQLContext) {
        // Analyze context
        let context = contextAnalyzer.analyze(query: text, cursorPosition: cursorPosition)

        // Don't complete inside strings or comments
        if context.isInsideString || context.isInsideComment {
            return ([], context)
        }

        // Get candidates based on context
        var candidates = await getCandidates(for: context)

        // Filter by prefix
        if !context.prefix.isEmpty {
            candidates = filterByPrefix(candidates, prefix: context.prefix)
        }

        // Rank results
        candidates = rankResults(candidates, prefix: context.prefix, context: context)

        // Limit results
        let limited = Array(candidates.prefix(maxSuggestions))

        return (limited, context)
    }

    // MARK: - Candidate Generation

    /// Get candidate completions based on context
    private func getCandidates(for context: SQLContext) async -> [SQLCompletionItem] {
        var items: [SQLCompletionItem] = []

        // If we have a dot prefix, we're looking for columns of a specific table
        if let dotPrefix = context.dotPrefix {
            // Resolve the table name from alias or direct reference
            if let tableName = await schemaProvider.resolveAlias(dotPrefix, in: context.tableReferences) {
                items = await schemaProvider.columnCompletionItems(for: tableName)
            }
            return items
        }

        // Add items based on clause type
        switch context.clauseType {
        case .from, .join, .into:
            // Tables + JOIN keywords (for typing after table name)
            items = await schemaProvider.tableCompletionItems()
            items += filterKeywords([
                "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN",
                "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN",
                "CROSS JOIN", "JOIN", "ON", "WHERE", "ORDER BY", "GROUP BY", "LIMIT"
            ])

        case .select:
            // Columns, functions, keywords (SELECT, DISTINCT, etc.)
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += SQLKeywords.functionItems()
            items += filterKeywords(["DISTINCT", "ALL", "AS", "FROM", "CASE", "WHEN"])

        case .where_, .and, .on, .having:
            // Columns, operators, logical keywords
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += SQLKeywords.operatorItems()
            items += filterKeywords(["AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "IS", "NULL", "TRUE", "FALSE", "EXISTS"])
            items += SQLKeywords.functionItems()

        case .groupBy, .orderBy:
            // Columns only
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            if context.clauseType == .orderBy {
                items += filterKeywords(["ASC", "DESC", "NULLS", "FIRST", "LAST"])
            }

        case .set:
            // Columns for UPDATE SET clause
            if let firstTable = context.tableReferences.first {
                items = await schemaProvider.columnCompletionItems(for: firstTable.tableName)
            }

        case .insertColumns:
            // Columns for INSERT column list
            if let firstTable = context.tableReferences.first {
                items = await schemaProvider.columnCompletionItems(for: firstTable.tableName)
            }

        case .values:
            // Functions and keywords for VALUES
            items = SQLKeywords.functionItems()
            items += filterKeywords(["NULL", "DEFAULT", "TRUE", "FALSE"])

        case .functionArg:
            // Inside function arguments - suggest columns and other functions
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += SQLKeywords.functionItems()
            items += filterKeywords(["NULL", "TRUE", "FALSE", "DISTINCT"])

        case .caseExpression:
            // Inside CASE expression
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += filterKeywords(["WHEN", "THEN", "ELSE", "END", "AND", "OR", "IS", "NULL", "TRUE", "FALSE"])
            items += SQLKeywords.operatorItems()
            items += SQLKeywords.functionItems()

        case .inList:
            // Inside IN (...) list - suggest values, subqueries, columns
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += filterKeywords(["SELECT", "NULL", "TRUE", "FALSE"])
            items += SQLKeywords.functionItems()

        case .limit:
            // After LIMIT/OFFSET - typically just numbers, but could include variables
            items += filterKeywords(["OFFSET", "FETCH", "NEXT", "ROWS", "ONLY"])

        case .alterTable:
            // After ALTER TABLE tablename - suggest DDL operations
            items = filterKeywords([
                "ADD", "DROP", "MODIFY", "CHANGE", "RENAME",
                "COLUMN", "INDEX", "PRIMARY", "FOREIGN", "KEY",
                "CONSTRAINT", "ENGINE", "CHARSET", "COLLATE"
            ])

        case .alterTableColumn:
            // After ALTER TABLE tablename DROP/MODIFY/CHANGE COLUMN - suggest column names
            if let firstTable = context.tableReferences.first {
                items = await schemaProvider.columnCompletionItems(for: firstTable.tableName)
            }
            items += filterKeywords(["COLUMN", "FIRST", "AFTER"])

        case .createTable:
            // Inside CREATE TABLE (...) - suggest constraints and data types
            items = filterKeywords([
                "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE",
                "NOT", "NULL", "DEFAULT", "AUTO_INCREMENT", "SERIAL",
                "CHECK", "CONSTRAINT", "INDEX"
            ])
            items += dataTypeKeywords()

        case .columnDef:
            // Typing column data type (after ADD COLUMN name)
            items = dataTypeKeywords()
            items += filterKeywords([
                "NOT", "NULL", "DEFAULT", "AUTO_INCREMENT", "SERIAL",
                "PRIMARY", "KEY", "UNIQUE", "REFERENCES", "CHECK",
                "UNSIGNED", "SIGNED", "FIRST", "AFTER"
            ])

        case .unknown:
            // Start of query - suggest statement keywords and tables
            items = filterKeywords(["SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "SHOW", "DESCRIBE", "EXPLAIN", "WITH", "TRUNCATE"])
            items += await schemaProvider.tableCompletionItems()
        }

        return items
    }

    /// SQL data type keywords
    private func dataTypeKeywords() -> [SQLCompletionItem] {
        filterKeywords([
            // Numeric
            "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "MEDIUMINT",
            "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL",
            // String
            "VARCHAR", "CHAR", "TEXT", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT",
            "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB",
            // Date/Time
            "DATE", "TIME", "DATETIME", "TIMESTAMP", "YEAR",
            // Other
            "BOOLEAN", "BOOL", "BIT", "JSON", "JSONB", "XML",
            "UUID", "BINARY", "VARBINARY", "ENUM", "SET"
        ])
    }

    /// Filter to specific keywords
    private func filterKeywords(_ keywords: [String]) -> [SQLCompletionItem] {
        keywords.map { SQLCompletionItem.keyword($0) }
    }

    // MARK: - Filtering

    /// Filter candidates by prefix (case-insensitive) with fuzzy matching support
    private func filterByPrefix(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        guard !prefix.isEmpty else { return items }

        let lowerPrefix = prefix.lowercased()

        return items.filter { item in
            // Exact prefix match
            if item.filterText.hasPrefix(lowerPrefix) {
                return true
            }

            // Contains match
            if item.filterText.contains(lowerPrefix) {
                return true
            }

            // Fuzzy match: check if all characters appear in order
            return fuzzyMatch(pattern: lowerPrefix, target: item.filterText)
        }
    }

    /// Fuzzy matching: checks if all pattern characters appear in target in order
    private func fuzzyMatch(pattern: String, target: String) -> Bool {
        var patternIndex = pattern.startIndex
        var targetIndex = target.startIndex

        while patternIndex < pattern.endIndex && targetIndex < target.endIndex {
            if pattern[patternIndex] == target[targetIndex] {
                patternIndex = pattern.index(after: patternIndex)
            }
            targetIndex = target.index(after: targetIndex)
        }

        return patternIndex == pattern.endIndex
    }

    // MARK: - Ranking

    /// Rank results by relevance
    private func rankResults(_ items: [SQLCompletionItem], prefix: String, context: SQLContext) -> [SQLCompletionItem] {
        let lowerPrefix = prefix.lowercased()

        return items.sorted { a, b in
            let aScore = calculateScore(for: a, prefix: lowerPrefix, context: context)
            let bScore = calculateScore(for: b, prefix: lowerPrefix, context: context)
            return aScore < bScore // Lower score = higher priority
        }
    }

    /// Calculate ranking score for an item (lower = better)
    private func calculateScore(for item: SQLCompletionItem, prefix: String, context: SQLContext) -> Int {
        var score = item.sortPriority

        // Exact prefix match bonus
        if item.filterText.hasPrefix(prefix) {
            score -= 500
        }

        // Exact match bonus
        if item.filterText == prefix {
            score -= 1_000
        }

        // Context-appropriate bonuses
        switch context.clauseType {
        case .from, .join, .into:
            if item.kind == .table || item.kind == .view {
                score -= 200
            }
        case .select, .where_, .and, .on, .having, .groupBy, .orderBy:
            if item.kind == .column {
                score -= 200
            }
        case .set, .insertColumns:
            if item.kind == .column {
                score -= 300
            }
        default:
            break
        }

        // Shorter names slightly preferred
        score += item.label.count

        return score
    }
}

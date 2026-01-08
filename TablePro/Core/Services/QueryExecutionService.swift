//
//  QueryExecutionService.swift
//  TablePro
//
//  Service responsible for query execution, parsing, and SQL statement extraction.
//  Extracted from MainContentView for better separation of concerns.
//

import Combine
import Foundation

/// Service for executing database queries and parsing SQL
@MainActor
final class QueryExecutionService: ObservableObject {
    // MARK: - Published State

    @Published var isExecuting: Bool = false
    @Published var executionTime: TimeInterval?
    @Published var errorMessage: String?

    // MARK: - Private State

    private var currentTask: Task<Void, Never>?
    private var queryGeneration: Int = 0

    // MARK: - Query Execution

    /// Execute a query and return results via callbacks
    /// - Parameters:
    ///   - sql: The SQL query to execute
    ///   - connection: Database connection configuration
    ///   - tableName: Optional table name for editable queries
    ///   - onSuccess: Callback with query result
    ///   - onError: Callback with error
    func execute(
        sql: String,
        connection: DatabaseConnection,
        tableName: String?,
        onSuccess: @escaping (QueryExecutionResult) async -> Void,
        onError: @escaping (Error) async -> Void
    ) {
        // Don't execute empty queries
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isExecuting = false
            return
        }

        // Cancel any previous running query
        currentTask?.cancel()

        // Increment generation for race condition prevention
        queryGeneration += 1
        let capturedGeneration = queryGeneration

        isExecuting = true
        executionTime = nil
        errorMessage = nil

        let isEditable = tableName != nil

        currentTask = Task {
            do {
                let result = try await DatabaseManager.shared.execute(query: sql)

                // Fetch column defaults and total row count if editable table
                var columnDefaults: [String: String?] = [:]
                var totalRowCount: Int?

                if isEditable, let tableName = tableName {
                    if let driver = DatabaseManager.shared.activeDriver {
                        // Execute both queries in parallel for better performance
                        async let columnInfoTask = driver.fetchColumns(table: tableName)
                        async let countTask: QueryResult = {
                            let quotedTable = connection.type.quoteIdentifier(tableName)
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

                // Deep copy all data to prevent C buffer retention issues
                // result.rows is [[String?]] - raw arrays, not QueryResultRow
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

                let safeResult = QueryExecutionResult(
                    columns: result.columns.map { String($0) },
                    rows: safeRows,
                    executionTime: result.executionTime,
                    columnDefaults: columnDefaults.mapValues { $0.map { String($0) } },
                    totalRowCount: totalRowCount,
                    tableName: tableName.map { String($0) },
                    isEditable: isEditable
                )

                // Check for cancellation
                guard !Task.isCancelled else {
                    await MainActor.run {
                        isExecuting = false
                        executionTime = safeResult.executionTime
                    }
                    return
                }

                // Check generation for race conditions
                guard capturedGeneration == queryGeneration else {
                    return
                }

                await MainActor.run {
                    isExecuting = false
                    executionTime = safeResult.executionTime
                }

                await onSuccess(safeResult)
            } catch {
                guard capturedGeneration == queryGeneration else { return }

                await MainActor.run {
                    isExecuting = false
                    errorMessage = error.localizedDescription
                }

                await onError(error)
            }
        }
    }

    /// Cancel any running query
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isExecuting = false
    }

    // MARK: - SQL Parsing

    /// Extract the SQL statement at the cursor position (semicolon-delimited)
    /// Enables TablePlus-like behavior: execute only the current query
    func extractQueryAtCursor(from fullQuery: String, at position: Int) -> String {
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
                        fullQuery.index(fullQuery.startIndex, offsetBy: currentStart)..<fullQuery.index(fullQuery.startIndex, offsetBy: i)
                    ]
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
            if statement.range.contains(safePosition) || statement.range.upperBound == safePosition {
                return statement.text
            }
        }

        // If cursor is at end or no match, return last statement
        return statements.last?.text ?? trimmed
    }

    /// Extract table name from a simple SELECT query
    func extractTableName(from sql: String) -> String? {
        let pattern = #"(?i)^\s*SELECT\s+.+?\s+FROM\s+[`"]?(\w+)[`"]?\s*(?:WHERE|ORDER|LIMIT|GROUP|HAVING|$|;)"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: sql, options: [], range: NSRange(sql.startIndex..., in: sql)),
              let range = Range(match.range(at: 1), in: sql)
        else {
            return nil
        }

        return String(sql[range])
    }
}

// MARK: - Query Execution Result

/// Result of a query execution with all necessary data
struct QueryExecutionResult {
    let columns: [String]
    let rows: [QueryResultRow]
    let executionTime: TimeInterval
    let columnDefaults: [String: String?]
    let totalRowCount: Int?
    let tableName: String?
    let isEditable: Bool
}

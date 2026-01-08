//
//  SQLStatementGenerator.swift
//  TablePro
//
//  Generates SQL statements (INSERT, UPDATE, DELETE) from tracked changes.
//  Extracted from DataChangeManager to improve separation of concerns.
//

import Foundation

/// Generates SQL statements from data changes
struct SQLStatementGenerator {
    let tableName: String
    let columns: [String]
    let primaryKeyColumn: String?
    let databaseType: DatabaseType

    // MARK: - Public API

    /// Generate all SQL statements from changes
    /// - Parameters:
    ///   - changes: Array of row changes to process
    ///   - insertedRowData: Lazy storage for inserted row values
    ///   - deletedRowIndices: Set of deleted row indices for validation
    ///   - insertedRowIndices: Set of inserted row indices for validation
    /// - Returns: Array of SQL statement strings
    func generateStatements(
        from changes: [RowChange],
        insertedRowData: [Int: [String?]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [String] {
        var statements: [String] = []

        // Collect UPDATE and DELETE changes to batch them
        var updateChanges: [RowChange] = []
        var deleteChanges: [RowChange] = []

        for change in changes {
            switch change.type {
            case .update:
                updateChanges.append(change)
            case .insert:
                // SAFETY: Verify the row is still marked as inserted
                guard insertedRowIndices.contains(change.rowIndex) else {
                    continue
                }
                if let sql = generateInsertSQL(for: change, insertedRowData: insertedRowData) {
                    statements.append(sql)
                }
            case .delete:
                // SAFETY: Verify the row is still marked as deleted
                guard deletedRowIndices.contains(change.rowIndex) else {
                    continue
                }
                deleteChanges.append(change)
            }
        }

        // Generate individual UPDATE statements with LIMIT 1 (safer than batched CASE/WHEN)
        // This prevents accidentally updating multiple rows with the same value
        if !updateChanges.isEmpty {
            for change in updateChanges {
                if let sql = generateUpdateSQL(for: change) {
                    statements.append(sql)
                }
            }
        }

        // Generate DELETE statements
        // Try batched DELETE first (uses PK if available), fall back to individual DELETEs
        if !deleteChanges.isEmpty {
            if let sql = generateBatchDeleteSQL(for: deleteChanges) {
                // Batched delete successful (has PK)
                statements.append(sql)
            } else {
                // No PK - generate individual DELETE statements matching all columns
                for change in deleteChanges {
                    if let sql = generateDeleteSQL(for: change) {
                        statements.append(sql)
                    }
                }
            }
        }

        return statements
    }

    // MARK: - INSERT Generation

    private func generateInsertSQL(for change: RowChange, insertedRowData: [Int: [String?]]) -> String? {
        // OPTIMIZATION: Get values from lazy storage instead of cellChanges
        if let values = insertedRowData[change.rowIndex] {
            return generateInsertSQLFromStoredData(rowIndex: change.rowIndex, values: values)
        }

        // Fallback: use cellChanges if stored data not available (backward compatibility)
        return generateInsertSQLFromCellChanges(for: change)
    }

    /// Generate INSERT SQL from lazy-stored row data (optimized path)
    private func generateInsertSQLFromStoredData(rowIndex: Int, values: [String?]) -> String? {
        var nonDefaultColumns: [String] = []
        var nonDefaultValues: [String] = []

        for (index, value) in values.enumerated() {
            // Skip DEFAULT columns - let DB handle them
            if value == "__DEFAULT__" { continue }

            guard index < columns.count else { continue }
            let columnName = columns[index]

            nonDefaultColumns.append(databaseType.quoteIdentifier(columnName))

            if let val = value {
                if isSQLFunctionExpression(val) {
                    nonDefaultValues.append(val.trimmingCharacters(in: .whitespaces).uppercased())
                } else {
                    nonDefaultValues.append("'\(escapeSQLString(val))'")
                }
            } else {
                nonDefaultValues.append("NULL")
            }
        }

        // If all columns are DEFAULT, don't generate INSERT
        guard !nonDefaultColumns.isEmpty else { return nil }

        let columnList = nonDefaultColumns.joined(separator: ", ")
        let valueList = nonDefaultValues.joined(separator: ", ")

        return "INSERT INTO \(databaseType.quoteIdentifier(tableName)) (\(columnList)) VALUES (\(valueList))"
    }

    /// Generate INSERT SQL from cellChanges (fallback for backward compatibility)
    private func generateInsertSQLFromCellChanges(for change: RowChange) -> String? {
        guard !change.cellChanges.isEmpty else { return nil }

        // Filter out DEFAULT columns - let DB handle them
        let nonDefaultChanges = change.cellChanges.filter {
            $0.newValue != "__DEFAULT__"
        }

        // If all columns are DEFAULT, don't generate INSERT
        guard !nonDefaultChanges.isEmpty else { return nil }

        let columnNames = nonDefaultChanges.map {
            databaseType.quoteIdentifier($0.columnName)
        }.joined(separator: ", ")

        let values = nonDefaultChanges.map { cellChange -> String in
            if let newValue = cellChange.newValue {
                if isSQLFunctionExpression(newValue) {
                    return newValue.trimmingCharacters(in: .whitespaces).uppercased()
                }
                return "'\(escapeSQLString(newValue))'"
            }
            return "NULL"
        }.joined(separator: ", ")

        return "INSERT INTO \(databaseType.quoteIdentifier(tableName)) (\(columnNames)) VALUES (\(values))"
    }

    // MARK: - UPDATE Generation

    /// Generate batched UPDATE statements grouped by columns being updated
    /// Example: UPDATE table SET col1 = CASE WHEN id=1 THEN 'val1' WHEN id=2 THEN 'val2' END WHERE id IN (1,2)
    private func generateBatchUpdateSQL(for changes: [RowChange]) -> [String] {
        guard !changes.isEmpty else { return [] }
        guard let pkColumn = primaryKeyColumn else {
            // Fallback to individual UPDATEs if no PK
            return changes.compactMap { generateUpdateSQL(for: $0) }
        }
        guard let pkIndex = columns.firstIndex(of: pkColumn) else {
            return changes.compactMap { generateUpdateSQL(for: $0) }
        }

        // Group changes by set of columns being updated
        var grouped: [[String]: [RowChange]] = [:]
        for change in changes {
            let columnNames = change.cellChanges.map { $0.columnName }.sorted()
            grouped[columnNames, default: []].append(change)
        }

        var statements: [String] = []

        for (columnNames, groupedChanges) in grouped {
            // Build CASE statements for each column
            var caseClauses: [String] = []

            for columnName in columnNames {
                var whenClauses: [String] = []

                for change in groupedChanges {
                    guard let originalRow = change.originalRow,
                          pkIndex < originalRow.count,
                          let cellChange = change.cellChanges.first(where: { $0.columnName == columnName }) else {
                        continue
                    }

                    let pkValue = originalRow[pkIndex].map { "'\(escapeSQLString($0))'" } ?? "NULL"

                    // Generate value
                    let value: String
                    if cellChange.newValue == "__DEFAULT__" {
                        value = "DEFAULT"
                    } else if let newValue = cellChange.newValue {
                        if isSQLFunctionExpression(newValue) {
                            value = newValue.trimmingCharacters(in: .whitespaces).uppercased()
                        } else {
                            value = "'\(escapeSQLString(newValue))'"
                        }
                    } else {
                        value = "NULL"
                    }

                    whenClauses.append("WHEN \(databaseType.quoteIdentifier(pkColumn)) = \(pkValue) THEN \(value)")
                }

                if !whenClauses.isEmpty {
                    let caseExpr = "CASE \(whenClauses.joined(separator: " ")) END"
                    caseClauses.append("\(databaseType.quoteIdentifier(columnName)) = \(caseExpr)")
                }
            }

            // Build WHERE IN clause with all PKs
            var pkValues: [String] = []
            for change in groupedChanges {
                guard let originalRow = change.originalRow,
                      pkIndex < originalRow.count else {
                    continue
                }
                let pkValue = originalRow[pkIndex].map { "'\(escapeSQLString($0))'" } ?? "NULL"
                pkValues.append(pkValue)
            }

            if !caseClauses.isEmpty && !pkValues.isEmpty {
                let whereClause = "\(databaseType.quoteIdentifier(pkColumn)) IN (\(pkValues.joined(separator: ", ")))"
                let sql = "UPDATE \(databaseType.quoteIdentifier(tableName)) SET \(caseClauses.joined(separator: ", ")) WHERE \(whereClause)"
                statements.append(sql)
            }
        }

        return statements
    }

    /// Generate individual UPDATE statement for a single row (fallback)
    private func generateUpdateSQL(for change: RowChange) -> String? {
        guard !change.cellChanges.isEmpty else { return nil }

        let setClauses = change.cellChanges.map { cellChange -> String in
            let value: String
            if cellChange.newValue == "__DEFAULT__" {
                value = "DEFAULT"
            } else if let newValue = cellChange.newValue {
                if isSQLFunctionExpression(newValue) {
                    value = newValue.trimmingCharacters(in: .whitespaces).uppercased()
                } else {
                    value = "'\(escapeSQLString(newValue))'"
                }
            } else {
                value = "NULL"
            }
            return "\(databaseType.quoteIdentifier(cellChange.columnName)) = \(value)"
        }.joined(separator: ", ")

        // CRITICAL FIX: Require primary key for safe updates
        // DO NOT generate UPDATE without WHERE clause - prevents data corruption
        guard let pkColumn = primaryKeyColumn,
              let pkColumnIndex = columns.firstIndex(of: pkColumn) else {
            // Cannot generate safe UPDATE without primary key - skip this update
            print("⚠️ WARNING: Skipping UPDATE for table '\(tableName)' - no primary key defined")
            return nil
        }

        // Try to get PK value from originalRow first
        var pkValue: String?
        if let originalRow = change.originalRow, pkColumnIndex < originalRow.count {
            pkValue = originalRow[pkColumnIndex].map { "'\(escapeSQLString($0))'" }
        }
        // Otherwise try from cellChanges (if PK column was edited)
        else if let pkChange = change.cellChanges.first(where: { $0.columnName == pkColumn }) {
            pkValue = pkChange.oldValue.map { "'\(escapeSQLString($0))'" }
        }

        // CRITICAL: Require valid PK value - do NOT fall back to WHERE 1=1
        guard let pkValue = pkValue else {
            print("⚠️ WARNING: Skipping UPDATE for table '\(tableName)' - cannot determine primary key value for row")
            return nil
        }

        let whereClause = "\(databaseType.quoteIdentifier(pkColumn)) = \(pkValue)"

        // Add LIMIT 1 for MySQL/MariaDB to ensure only one row is updated (TablePlus-style safety)
        // PostgreSQL doesn't support LIMIT in UPDATE, but the PK constraint ensures single row
        let limitClause = (databaseType == .mysql || databaseType == .mariadb) ? " LIMIT 1" : ""

        return "UPDATE \(databaseType.quoteIdentifier(tableName)) SET \(setClauses) WHERE \(whereClause)\(limitClause)"
    }

    // MARK: - DELETE Generation

    /// Generate a batched DELETE statement combining multiple rows with OR conditions
    /// Example: DELETE FROM table WHERE id = 1 OR id = 2 OR id = 3
    private func generateBatchDeleteSQL(for changes: [RowChange]) -> String? {
        guard !changes.isEmpty else { return nil }

        // If we have a primary key, use it for efficient deletion
        if let pkColumn = primaryKeyColumn,
           let pkIndex = columns.firstIndex(of: pkColumn) {
            // Build OR conditions for all rows using PK
            var conditions: [String] = []

            for change in changes {
                guard let originalRow = change.originalRow,
                      pkIndex < originalRow.count else {
                    continue
                }

                let pkValue = originalRow[pkIndex].map { "'\(escapeSQLString($0))'" } ?? "NULL"
                conditions.append("\(databaseType.quoteIdentifier(pkColumn)) = \(pkValue)")
            }

            guard !conditions.isEmpty else { return nil }

            // Combine all conditions with OR
            let whereClause = conditions.joined(separator: " OR ")
            return "DELETE FROM \(databaseType.quoteIdentifier(tableName)) WHERE \(whereClause)"
        }

        // Fallback: No primary key - generate individual DELETE statements matching all columns
        // This is safe but requires exact row matching
        return nil  // Return nil to trigger individual DELETE generation
    }

    /// Generate individual DELETE statement for a single row (used when no PK or as fallback)
    /// Matches all column values to ensure we delete the exact row
    private func generateDeleteSQL(for change: RowChange) -> String? {
        guard let originalRow = change.originalRow else { return nil }

        // Build WHERE clause matching ALL columns to uniquely identify the row
        var conditions: [String] = []

        for (index, columnName) in columns.enumerated() {
            guard index < originalRow.count else { continue }

            let value = originalRow[index]
            let quotedColumn = databaseType.quoteIdentifier(columnName)

            if let value = value {
                conditions.append("\(quotedColumn) = '\(escapeSQLString(value))'")
            } else {
                conditions.append("\(quotedColumn) IS NULL")
            }
        }

        guard !conditions.isEmpty else { return nil }

        let whereClause = conditions.joined(separator: " AND ")

        // Add LIMIT 1 for MySQL/MariaDB to be extra safe
        let limitClause = (databaseType == .mysql || databaseType == .mariadb) ? " LIMIT 1" : ""

        return "DELETE FROM \(databaseType.quoteIdentifier(tableName)) WHERE \(whereClause)\(limitClause)"
    }

    // MARK: - Helper Functions

    /// Check if a string is a SQL function expression that should not be quoted
    private func isSQLFunctionExpression(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces).uppercased()

        // Common SQL functions for datetime/timestamps
        let sqlFunctions = [
            "NOW()",
            "CURRENT_TIMESTAMP()",
            "CURRENT_TIMESTAMP",
            "CURDATE()",
            "CURTIME()",
            "UTC_TIMESTAMP()",
            "UTC_DATE()",
            "UTC_TIME()",
            "LOCALTIME()",
            "LOCALTIME",
            "LOCALTIMESTAMP()",
            "LOCALTIMESTAMP",
            "SYSDATE()",
            "UNIX_TIMESTAMP()",
            "CURRENT_DATE()",
            "CURRENT_DATE",
            "CURRENT_TIME()",
            "CURRENT_TIME",
        ]

        return sqlFunctions.contains(trimmed)
    }

    /// Escape characters that can break SQL strings
    /// Delegates to shared SQLEscaping utility for consistent escaping across the codebase
    private func escapeSQLString(_ str: String) -> String {
        SQLEscaping.escapeStringLiteral(str)
    }
}

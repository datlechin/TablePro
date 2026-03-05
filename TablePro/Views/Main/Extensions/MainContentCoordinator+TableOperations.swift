//
//  MainContentCoordinator+TableOperations.swift
//  TablePro
//
//  SQL generation for table truncate, drop, and FK handling operations.
//

import Foundation

extension MainContentCoordinator {
    // MARK: - Table Operation SQL Generation

    /// Generates SQL statements for table truncate/drop operations.
    /// - Parameters:
    ///   - truncates: Set of table names to truncate
    ///   - deletes: Set of table names to drop
    ///   - options: Per-table options for FK and cascade handling
    ///   - wrapInTransaction: Whether to wrap statements in BEGIN/COMMIT
    ///   - includeFKHandling: Whether to include FK disable/enable statements (set false when caller handles FK)
    /// - Returns: Array of SQL statements to execute
    func generateTableOperationSQL(
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

        // Check if any operation needs FK disabled (not applicable to PostgreSQL or MSSQL)
        let needsDisableFK = includeFKHandling && dbType != .postgresql && dbType != .mssql && truncates.union(deletes).contains { tableName in
            options[tableName]?.ignoreForeignKeys == true
        }

        // FK disable must be OUTSIDE transaction to ensure it takes effect even on rollback
        if needsDisableFK {
            statements.append(contentsOf: fkDisableStatements(for: dbType))
        }

        // Wrap in transaction for atomicity
        let needsTransaction = wrapInTransaction && (sortedTruncates.count + sortedDeletes.count) > 1
        if needsTransaction {
            statements.append(dbType == .mssql ? "BEGIN TRANSACTION" : "BEGIN")
        }

        for tableName in sortedTruncates {
            let quotedName = dbType.quoteIdentifier(tableName)
            let tableOptions = options[tableName] ?? TableOperationOptions()
            statements.append(contentsOf: truncateStatements(tableName: tableName, quotedName: quotedName, options: tableOptions, dbType: dbType))
        }

        let viewNames: Set<String> = {
            guard let session = DatabaseManager.shared.session(for: connectionId) else { return [] }
            return Set(session.tables.filter { $0.type == .view }.map(\.name))
        }()

        for tableName in sortedDeletes {
            let quotedName = dbType.quoteIdentifier(tableName)
            let tableOptions = options[tableName] ?? TableOperationOptions()
            statements.append(dropTableStatement(tableName: tableName, quotedName: quotedName, isView: viewNames.contains(tableName), options: tableOptions, dbType: dbType))
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

    // MARK: - Foreign Key Handling

    /// Returns SQL statements to disable foreign key checks for the database type.
    /// - Note: PostgreSQL doesn't support globally disabling FK checks; use CASCADE instead.
    func fkDisableStatements(for dbType: DatabaseType) -> [String] {
        switch dbType {
        case .mysql, .mariadb: return ["SET FOREIGN_KEY_CHECKS=0"]
        case .postgresql, .redshift, .mongodb, .redis, .mssql: return []
        case .sqlite: return ["PRAGMA foreign_keys = OFF"]
        }
    }

    /// Returns SQL statements to re-enable foreign key checks for the database type.
    func fkEnableStatements(for dbType: DatabaseType) -> [String] {
        switch dbType {
        case .mysql, .mariadb:
            return ["SET FOREIGN_KEY_CHECKS=1"]
        case .postgresql, .redshift, .mongodb, .redis, .mssql:
            return []
        case .sqlite:
            return ["PRAGMA foreign_keys = ON"]
        }
    }

    // MARK: - Private SQL Builders

    /// Generates TRUNCATE/DELETE statements for a table.
    /// - Note: SQLite uses DELETE and resets auto-increment via sqlite_sequence.
    private func truncateStatements(tableName: String, quotedName: String, options: TableOperationOptions, dbType: DatabaseType) -> [String] {
        switch dbType {
        case .mysql, .mariadb:
            return ["TRUNCATE TABLE \(quotedName)"]
        case .postgresql, .redshift:
            let cascade = options.cascade ? " CASCADE" : ""
            return ["TRUNCATE TABLE \(quotedName)\(cascade)"]
        case .mssql:
            return ["TRUNCATE TABLE \(quotedName)"]
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
        case .mongodb:
            let escaped = tableName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return ["db[\"\(escaped)\"].deleteMany({})"]
        case .redis:
            return ["FLUSHDB"]
        }
    }

    /// Generates DROP TABLE/VIEW statement with optional CASCADE.
    private func dropTableStatement(tableName: String, quotedName: String, isView: Bool, options: TableOperationOptions, dbType: DatabaseType) -> String {
        let keyword = isView ? "VIEW" : "TABLE"
        switch dbType {
        case .postgresql, .redshift:
            return "DROP \(keyword) \(quotedName)\(options.cascade ? " CASCADE" : "")"
        case .mysql, .mariadb, .sqlite, .mssql:
            return "DROP \(keyword) \(quotedName)"
        case .mongodb:
            let escaped = tableName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "db[\"\(escaped)\"].drop()"
        case .redis:
            return "DEL \(tableName)"
        }
    }
}

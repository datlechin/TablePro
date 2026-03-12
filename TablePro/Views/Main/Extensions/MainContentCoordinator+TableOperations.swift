//
//  MainContentCoordinator+TableOperations.swift
//  TablePro
//
//  SQL generation for table truncate, drop, and FK handling operations.
//

import Foundation

extension MainContentCoordinator {
    // MARK: - Plugin Adapter Access

    /// Returns the current connection's PluginDriverAdapter, if available.
    private var currentPluginDriverAdapter: PluginDriverAdapter? {
        DatabaseManager.shared.driver(for: connectionId) as? PluginDriverAdapter
    }

    // MARK: - Table Operation SQL Generation

    /// Generates SQL statements for table truncate/drop operations.
    /// - Parameters:
    ///   - truncates: Set of table names to truncate
    ///   - deletes: Set of table names to drop
    ///   - options: Per-table options for FK and cascade handling
    ///   - includeFKHandling: Whether to include FK disable/enable statements (set false when caller handles FK)
    /// - Returns: Array of SQL statements to execute
    func generateTableOperationSQL(
        truncates: Set<String>,
        deletes: Set<String>,
        options: [String: TableOperationOptions],
        includeFKHandling: Bool = true
    ) -> [String] {
        var statements: [String] = []
        let dbType = connection.type

        // Sort tables for consistent execution order
        let sortedTruncates = truncates.sorted()
        let sortedDeletes = deletes.sorted()

        // Check if any operation needs FK disabled (not applicable to PostgreSQL or MSSQL)
        let fkApplicable = dbType != .postgresql && dbType != .clickhouse
            && dbType != .mssql && dbType != .oracle && dbType != .duckdb
        let needsDisableFK = includeFKHandling && fkApplicable && truncates.union(deletes).contains { tableName in
            options[tableName]?.ignoreForeignKeys == true
        }

        // FK disable must be OUTSIDE transaction to ensure it takes effect even on rollback
        if needsDisableFK {
            statements.append(contentsOf: fkDisableStatements(for: dbType))
        }

        for tableName in sortedTruncates {
            let quotedName = dbType.quoteIdentifier(tableName)
            let tableOptions = options[tableName] ?? TableOperationOptions()
            statements.append(contentsOf: truncateStatements(
                tableName: tableName, quotedName: quotedName, options: tableOptions, dbType: dbType
            ))
        }

        let viewNames: Set<String> = {
            guard let session = DatabaseManager.shared.session(for: connectionId) else { return [] }
            return Set(session.tables.filter { $0.type == .view }.map(\.name))
        }()

        for tableName in sortedDeletes {
            let quotedName = dbType.quoteIdentifier(tableName)
            let tableOptions = options[tableName] ?? TableOperationOptions()
            statements.append(dropTableStatement(
                tableName: tableName, quotedName: quotedName,
                isView: viewNames.contains(tableName), options: tableOptions, dbType: dbType
            ))
        }

        // FK re-enable must be OUTSIDE transaction to ensure it runs even on rollback
        if needsDisableFK {
            statements.append(contentsOf: fkEnableStatements(for: dbType))
        }

        return statements
    }

    // MARK: - Foreign Key Handling

    /// Returns SQL statements to disable foreign key checks for the database type.
    /// Tries plugin-provided statements first, falls back to built-in switch.
    /// - Note: PostgreSQL doesn't support globally disabling FK checks; use CASCADE instead.
    func fkDisableStatements(for dbType: DatabaseType) -> [String] {
        if let adapter = currentPluginDriverAdapter,
           let stmts = adapter.foreignKeyDisableStatements() {
            return stmts
        }
        switch dbType {
        case .mysql, .mariadb: return ["SET FOREIGN_KEY_CHECKS=0"]
        case .postgresql, .redshift, .clickhouse, .mongodb, .redis, .mssql, .oracle, .duckdb: return []
        case .sqlite: return ["PRAGMA foreign_keys = OFF"]
        }
    }

    /// Returns SQL statements to re-enable foreign key checks for the database type.
    /// Tries plugin-provided statements first, falls back to built-in switch.
    func fkEnableStatements(for dbType: DatabaseType) -> [String] {
        if let adapter = currentPluginDriverAdapter,
           let stmts = adapter.foreignKeyEnableStatements() {
            return stmts
        }
        switch dbType {
        case .mysql, .mariadb:
            return ["SET FOREIGN_KEY_CHECKS=1"]
        case .postgresql, .redshift, .clickhouse, .mongodb, .redis, .mssql, .oracle, .duckdb:
            return []
        case .sqlite:
            return ["PRAGMA foreign_keys = ON"]
        }
    }

    // MARK: - Private SQL Builders

    /// Generates TRUNCATE/DELETE statements for a table.
    /// Tries plugin-provided statements first, falls back to built-in switch.
    /// - Note: SQLite uses DELETE and resets auto-increment via sqlite_sequence.
    private func truncateStatements(
        tableName: String, quotedName: String, options: TableOperationOptions, dbType: DatabaseType
    ) -> [String] {
        if let adapter = currentPluginDriverAdapter,
           let stmts = adapter.truncateTableStatements(
               table: tableName, schema: nil, cascade: options.cascade
           ) {
            return stmts
        }
        switch dbType {
        case .mysql, .mariadb, .clickhouse, .duckdb:
            return ["TRUNCATE TABLE \(quotedName)"]
        case .postgresql, .redshift:
            let cascade = options.cascade ? " CASCADE" : ""
            return ["TRUNCATE TABLE \(quotedName)\(cascade)"]
        case .mssql, .oracle:
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
            let escaped = tableName.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return ["db[\"\(escaped)\"].deleteMany({})"]
        case .redis:
            return ["FLUSHDB"]
        }
    }

    /// Generates DROP TABLE/VIEW statement with optional CASCADE.
    /// Tries plugin-provided statement first, falls back to built-in switch.
    private func dropTableStatement(
        tableName: String, quotedName: String, isView: Bool,
        options: TableOperationOptions, dbType: DatabaseType
    ) -> String {
        let keyword = isView ? "VIEW" : "TABLE"
        if let adapter = currentPluginDriverAdapter,
           let stmt = adapter.dropObjectStatement(
               name: tableName, objectType: keyword, schema: nil, cascade: options.cascade
           ) {
            return stmt
        }
        switch dbType {
        case .postgresql, .redshift:
            return "DROP \(keyword) \(quotedName)\(options.cascade ? " CASCADE" : "")"
        case .mysql, .mariadb, .clickhouse, .sqlite, .mssql, .oracle, .duckdb:
            return "DROP \(keyword) \(quotedName)"
        case .mongodb:
            let escaped = tableName.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "db[\"\(escaped)\"].drop()"
        case .redis:
            return "DEL \(tableName)"
        }
    }
}

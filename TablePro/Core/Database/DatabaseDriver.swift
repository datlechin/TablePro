//
//  DatabaseDriver.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import OSLog

/// Row limit configuration for driver-level result capping
enum DriverRowLimits {
    static let defaultMax = 100_000
    static let unlimitedMax = Int.max
}

/// Protocol defining database driver operations
protocol DatabaseDriver: AnyObject {
    // MARK: - Properties

    /// The connection configuration
    var connection: DatabaseConnection { get }

    /// Current connection status
    var status: ConnectionStatus { get }

    /// Server version string (e.g., "8.0.35" for MySQL)
    /// Optional - not all drivers may implement this
    var serverVersion: String? { get }

    // MARK: - Connection Management

    /// Connect to the database
    func connect() async throws

    /// Disconnect from the database
    func disconnect()

    /// Test the connection (connect and immediately disconnect)
    func testConnection() async throws -> Bool

    // MARK: - Configuration

    /// Apply query execution timeout (seconds, 0 = no limit)
    func applyQueryTimeout(_ seconds: Int) async throws

    // MARK: - Query Execution

    /// Execute a SQL query and return results
    func execute(query: String) async throws -> QueryResult

    /// Execute a prepared statement with parameters (prevents SQL injection)
    /// - Parameters:
    ///   - query: SQL query with placeholders (? for MySQL/SQLite, $1/$2 for PostgreSQL)
    ///   - parameters: Array of parameter values to bind
    /// - Returns: Query result
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult

    /// Fetch total row count for a query (wraps with COUNT(*))
    func fetchRowCount(query: String) async throws -> Int

    /// Fetch rows with LIMIT/OFFSET pagination
    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult

    // MARK: - Schema Operations

    /// Fetch all tables in the database
    func fetchTables() async throws -> [TableInfo]

    /// Fetch columns for a specific table
    func fetchColumns(table: String) async throws -> [ColumnInfo]

    /// Fetch columns for ALL tables in a single batch query (avoids N+1).
    /// Returns a dictionary keyed by table name.
    /// Default implementation falls back to per-table fetchColumns.
    func fetchAllColumns() async throws -> [String: [ColumnInfo]]

    /// Fetch indexes for a specific table
    func fetchIndexes(table: String) async throws -> [IndexInfo]

    /// Fetch foreign keys for a specific table
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo]

    /// Fetch the DDL (CREATE TABLE statement) for a specific table
    func fetchTableDDL(table: String) async throws -> String

    /// Fetch dependent type definitions (e.g., PostgreSQL enum types) for a table.
    /// Returns array of (typeName, labels) pairs. Default returns empty.
    func fetchDependentTypes(forTable table: String) async throws -> [(name: String, labels: [String])]

    /// Fetch dependent sequence definitions (e.g., PostgreSQL sequences used by table columns).
    /// Returns array of (sequenceName, CREATE SEQUENCE DDL) pairs. Default returns empty.
    func fetchDependentSequences(forTable table: String) async throws -> [(name: String, ddl: String)]

    /// Fetch the view definition (SELECT statement) for a specific view
    func fetchViewDefinition(view: String) async throws -> String

    /// Fetch table metadata (size, comment, engine, etc.)
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata

    /// Fetch list of all databases on the server
    func fetchDatabases() async throws -> [String]

    /// Fetch metadata for a specific database (table count, size, etc.)
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata

    /// Create a new database
    func createDatabase(name: String, charset: String, collation: String?) async throws

    // MARK: - Query Cancellation

    /// Cancel the currently running query, if any.
    /// Default implementation is a no-op for drivers that don't support cancellation.
    func cancelQuery() throws

    // MARK: - Transaction Management

    /// Begin a transaction
    func beginTransaction() async throws

    /// Commit the current transaction
    func commitTransaction() async throws

    /// Rollback the current transaction
    func rollbackTransaction() async throws
}

/// Default implementation for common operations
extension DatabaseDriver {
    /// Default implementation returns nil
    /// Override in drivers that support version querying
    var serverVersion: String? { nil }

    func testConnection() async throws -> Bool {
        try await connect()
        disconnect()
        return true
    }

    /// Default fetchAllColumns: falls back to per-table fetchColumns (N+1).
    /// Drivers should override with a single bulk query where possible.
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] {
        let allTables = try await fetchTables()
        var result: [String: [ColumnInfo]] = [:]
        for table in allTables {
            do {
                let columns = try await fetchColumns(table: table.name)
                result[table.name] = columns
            } catch {
                // Skip tables whose columns can't be fetched
            }
        }
        return result
    }

    /// Default: no dependent types (MySQL/SQLite don't have standalone enum types)
    func fetchDependentTypes(forTable table: String) async throws -> [(name: String, labels: [String])] {
        []
    }

    /// Default: no dependent sequences (MySQL/SQLite don't use standalone sequences)
    func fetchDependentSequences(forTable table: String) async throws -> [(name: String, ddl: String)] {
        []
    }

    /// Default no-op implementation for drivers that don't support query cancellation
    func cancelQuery() throws {
        // No-op by default
    }

    /// Default timeout implementation using database-specific session variables
    func applyQueryTimeout(_ seconds: Int) async throws {
        guard seconds > 0 else { return }
        let ms = seconds * 1_000
        do {
            switch connection.type {
            case .mysql:
                _ = try await execute(query: "SET SESSION max_execution_time = \(ms)")
            case .mariadb:
                _ = try await execute(query: "SET SESSION max_statement_time = \(seconds)")
            case .postgresql:
                _ = try await execute(query: "SET statement_timeout = '\(ms)'")
            case .sqlite:
                break  // SQLite busy_timeout handled by driver directly
            }
        } catch {
            Logger(subsystem: "com.TablePro", category: "DatabaseDriver")
                .warning("Failed to set query timeout: \(error.localizedDescription)")
        }
    }

    // MARK: - Default Transaction Implementation

    /// Default transaction implementation using database-specific SQL
    func beginTransaction() async throws {
        let sql: String
        switch connection.type {
        case .mysql, .mariadb:
            sql = "START TRANSACTION"
        case .postgresql:
            sql = "BEGIN"
        case .sqlite:
            sql = "BEGIN"
        }
        _ = try await execute(query: sql)
    }

    func commitTransaction() async throws {
        _ = try await execute(query: "COMMIT")
    }

    func rollbackTransaction() async throws {
        _ = try await execute(query: "ROLLBACK")
    }
}

/// Factory for creating database drivers
enum DatabaseDriverFactory {
    static func createDriver(for connection: DatabaseConnection) -> DatabaseDriver {
        switch connection.type {
        case .sqlite:
            return SQLiteDriver(connection: connection)
        case .mysql, .mariadb:
            return MySQLDriver(connection: connection)
        case .postgresql:
            return PostgreSQLDriver(connection: connection)
        }
    }
}

//
//  DatabaseDriver.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation

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

    // MARK: - Query Execution

    /// Execute a SQL query and return results
    func execute(query: String) async throws -> QueryResult

    /// Fetch total row count for a query (wraps with COUNT(*))
    func fetchRowCount(query: String) async throws -> Int

    /// Fetch rows with LIMIT/OFFSET pagination
    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult

    // MARK: - Schema Operations

    /// Fetch all tables in the database
    func fetchTables() async throws -> [TableInfo]

    /// Fetch columns for a specific table
    func fetchColumns(table: String) async throws -> [ColumnInfo]

    /// Fetch indexes for a specific table
    func fetchIndexes(table: String) async throws -> [IndexInfo]

    /// Fetch foreign keys for a specific table
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo]

    /// Fetch the DDL (CREATE TABLE statement) for a specific table
    func fetchTableDDL(table: String) async throws -> String

    /// Fetch table metadata (size, comment, engine, etc.)
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata

    /// Fetch list of all databases on the server
    func fetchDatabases() async throws -> [String]
}

/// Default implementation for common operations
extension DatabaseDriver {
    /// Default implementation returns nil
    /// Override in drivers that support version querying
    var serverVersion: String? { nil }

    func testConnection() async throws -> Bool {
        do {
            try await connect()
            disconnect()
            return true
        } catch {
            throw error
        }
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

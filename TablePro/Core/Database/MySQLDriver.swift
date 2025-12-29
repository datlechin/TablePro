//
//  MySQLDriver.swift
//  TablePro
//
//  MySQL/MariaDB database driver using libmariadb (MariaDB Connector/C)
//

import Foundation

/// MySQL/MariaDB database driver using libmariadb
/// Supports MySQL 5.7+, MySQL 8.x (all auth methods), and MariaDB
final class MySQLDriver: DatabaseDriver {
    let connection: DatabaseConnection
    private(set) var status: ConnectionStatus = .disconnected

    /// The underlying MariaDB connection
    private var mariadbConnection: MariaDBConnection?
    
    /// Static date formatter for parsing MySQL dates (performance optimization)
    private static let mysqlDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    // MARK: - Server Version

    /// Server version string from the connected database
    var serverVersion: String? {
        mariadbConnection?.serverVersion()
    }

    // MARK: - Connection

    func connect() async throws {
        status = .connecting

        // Get password from Keychain
        let password = ConnectionStorage.shared.loadPassword(for: connection.id)

        // Create connection
        let conn = MariaDBConnection(
            host: connection.host,
            port: connection.port,
            user: connection.username,
            password: password,
            database: connection.database
        )

        do {
            try await conn.connect()
            mariadbConnection = conn
            status = .connected
        } catch let error as MariaDBError {
            status = .error(error.message)
            throw DatabaseError.connectionFailed(error.localizedDescription)
        } catch {
            status = .error(error.localizedDescription)
            throw DatabaseError.connectionFailed(error.localizedDescription)
        }
    }

    func disconnect() {
        mariadbConnection?.disconnect()
        mariadbConnection = nil
        status = .disconnected
    }

    func testConnection() async throws -> Bool {
        try await connect()
        let isConnected = status == .connected
        disconnect()
        return isConnected
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        return try await executeWithReconnect(query: query, isRetry: false)
    }
    
    /// Execute query with automatic reconnection on connection-lost errors
    private func executeWithReconnect(query: String, isRetry: Bool) async throws -> QueryResult {
        let startTime = Date()

        guard let conn = mariadbConnection else {
            throw DatabaseError.notConnected
        }

        do {
            let result = try await conn.executeQuery(query)

            // Handle empty result for SELECT queries - try to get column names from table
            if result.columns.isEmpty && result.rows.isEmpty {
                if let tableName = extractTableName(from: query) {
                    let columns = try await fetchColumnNames(for: tableName)
                    return QueryResult(
                        columns: columns,
                        rows: [],
                        rowsAffected: Int(result.affectedRows),
                        executionTime: Date().timeIntervalSince(startTime),
                        error: nil
                    )
                }
            }

            return QueryResult(
                columns: result.columns,
                rows: result.rows,
                rowsAffected: Int(result.affectedRows),
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )
        } catch let error as MariaDBError where !isRetry && isConnectionLostError(error) {
            // Connection lost - attempt reconnect and retry once
            try await reconnect()
            return try await executeWithReconnect(query: query, isRetry: true)
        } catch let error as MariaDBError {
            throw DatabaseError.queryFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Auto-Reconnect
    
    /// Check if error indicates a lost connection that can be recovered
    private func isConnectionLostError(_ error: MariaDBError) -> Bool {
        // 2006 = Server has gone away
        // 2013 = Lost connection to MySQL server during query
        // 2055 = Lost connection to MySQL server at reading initial packet
        return [2006, 2013, 2055].contains(Int(error.code))
    }
    
    /// Reconnect to the database
    private func reconnect() async throws {
        // Close existing connection
        mariadbConnection?.disconnect()
        mariadbConnection = nil
        status = .connecting
        
        // Reconnect using stored connection info
        try await connect()
    }

    // MARK: - Schema

    func fetchTables() async throws -> [TableInfo] {
        let query = "SHOW FULL TABLES"
        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            guard let name = row[0] else { return nil }
            let typeStr = row.count > 1 ? (row[1] ?? "BASE TABLE") : "BASE TABLE"
            let type: TableInfo.TableType = typeStr.contains("VIEW") ? .view : .table

            return TableInfo(name: name, type: type, rowCount: nil)
        }
    }

    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        let query = "SHOW FULL COLUMNS FROM `\(table)`"
        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            // SHOW FULL COLUMNS returns:
            // 0: Field, 1: Type, 2: Collation, 3: Null, 4: Key, 5: Default, 6: Extra, 7: Privileges, 8: Comment
            guard row.count >= 7,
                let name = row[0],
                let dataType = row[1]
            else {
                return nil
            }

            let collation = row.count > 2 ? row[2] : nil
            let isNullable = row[3] == "YES"
            let isPrimaryKey = row[4] == "PRI"
            let defaultValue = row[5]
            let extra = row[6]
            let comment = row.count > 8 ? row[8] : nil
            
            // Extract charset from collation (e.g., "utf8mb4_general_ci" -> "utf8mb4")
            let charset: String? = {
                guard let coll = collation, coll != "NULL" else { return nil }
                return coll.components(separatedBy: "_").first
            }()

            return ColumnInfo(
                name: name,
                dataType: dataType.uppercased(),
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                extra: extra,
                charset: charset,
                collation: collation == "NULL" ? nil : collation,
                comment: comment?.isEmpty == false ? comment : nil
            )
        }
    }

    func fetchIndexes(table: String) async throws -> [IndexInfo] {
        let query = "SHOW INDEX FROM `\(table)`"
        let result = try await execute(query: query)

        // Group by index name (Key_name is column index 2)
        var indexMap: [String: (columns: [String], isUnique: Bool, type: String)] = [:]

        for row in result.rows {
            guard row.count >= 11,
                let indexName = row[2],  // Key_name
                let columnName = row[4]  // Column_name
            else {
                continue
            }

            let nonUnique = row[1] == "1"  // Non_unique: 0 = unique, 1 = not unique
            let indexType = row[10] ?? "BTREE"  // Index_type

            if var existing = indexMap[indexName] {
                existing.columns.append(columnName)
                indexMap[indexName] = existing
            } else {
                indexMap[indexName] = (
                    columns: [columnName],
                    isUnique: !nonUnique,
                    type: indexType
                )
            }
        }

        return indexMap.map { name, info in
            IndexInfo(
                name: name,
                columns: info.columns,
                isUnique: info.isUnique,
                isPrimary: name == "PRIMARY",
                type: info.type
            )
        }.sorted { $0.isPrimary && !$1.isPrimary }  // PRIMARY key first
    }

    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] {
        // Get database name from connection
        let dbName = connection.database

        let query = """
            SELECT
                kcu.CONSTRAINT_NAME,
                kcu.COLUMN_NAME,
                kcu.REFERENCED_TABLE_NAME,
                kcu.REFERENCED_COLUMN_NAME,
                rc.DELETE_RULE,
                rc.UPDATE_RULE
            FROM information_schema.KEY_COLUMN_USAGE kcu
            JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
                ON kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                AND kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
            WHERE kcu.TABLE_SCHEMA = '\(dbName)'
                AND kcu.TABLE_NAME = '\(table)'
                AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY kcu.CONSTRAINT_NAME
            """

        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            guard row.count >= 6,
                let name = row[0],
                let column = row[1],
                let refTable = row[2],
                let refColumn = row[3]
            else {
                return nil
            }

            return ForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: refTable,
                referencedColumn: refColumn,
                onDelete: row[4] ?? "NO ACTION",
                onUpdate: row[5] ?? "NO ACTION"
            )
        }
    }

    func fetchTableDDL(table: String) async throws -> String {
        // The `table` argument must be a valid MySQL/MariaDB table identifier, optionally
        // schema-qualified, and is interpolated verbatim into the query. Examples:
        //   - "users"
        //   - "`mydb`.`users`"
        //   - "`users`"
        //
        // This method does not add any quoting or escaping around `table`. It is the
        // caller's responsibility to provide a correctly formatted and safely quoted
        // identifier when needed.
        let query = "SHOW CREATE TABLE \(table)"
        let result = try await execute(query: query)
        
        // SHOW CREATE TABLE returns 2 columns: Table name and Create Table statement
        guard let firstRow = result.rows.first,
              firstRow.count >= 2,
              let ddl = firstRow[1]
        else {
            throw DatabaseError.queryFailed("Failed to fetch DDL for table '\(table)'")
        }
        
        return ddl
    }
    
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        let escapedTableName = tableName.replacingOccurrences(of: "'", with: "''")
        // NOTE: `SHOW TABLE STATUS LIKE` expects a pattern string literal, not an
        // identifier. For that reason we must use single-quoted string syntax here
        // instead of the backtick identifier quoting used in other schema queries
        // (e.g. `SHOW CREATE TABLE \`table\``). The table name is safely embedded
        // by escaping single quotes above.
        let query = "SHOW TABLE STATUS WHERE Name = '\(escapedTableName)'"
        let result = try await execute(query: query)
        
        guard let row = result.rows.first else {
            return TableMetadata(
                tableName: tableName,
                dataSize: nil,
                indexSize: nil,
                totalSize: nil,
                avgRowLength: nil,
                rowCount: nil,
                comment: nil,
                engine: nil,
                collation: nil,
                createTime: nil,
                updateTime: nil
            )
        }
        
        // SHOW TABLE STATUS columns:
        // 0: Name, 1: Engine, 2: Version, 3: Row_format, 4: Rows, 5: Avg_row_length,
        // 6: Data_length, 7: Max_data_length, 8: Index_length, 9: Data_free,
        // 10: Auto_increment, 11: Create_time, 12: Update_time, 13: Check_time,
        // 14: Collation, 15: Checksum, 16: Create_options, 17: Comment
        
        let engine = row.count > 1 ? row[1] : nil
        let rowCount = row.count > 4 ? Int64(row[4] ?? "0") : nil
        let avgRowLength = row.count > 5 ? Int64(row[5] ?? "0") : nil
        let dataSize = row.count > 6 ? Int64(row[6] ?? "0") : nil
        let indexSize = row.count > 8 ? Int64(row[8] ?? "0") : nil
        let collation = row.count > 14 ? row[14] : nil
        let comment = row.count > 17 ? row[17] : nil
        
        // Parse dates using static formatter for performance
        let createTime: Date? = {
            guard row.count > 11, let dateStr = row[11] else { return nil }
            return Self.mysqlDateFormatter.date(from: dateStr)
        }()
        
        let updateTime: Date? = {
            guard row.count > 12, let dateStr = row[12] else { return nil }
            return Self.mysqlDateFormatter.date(from: dateStr)
        }()
        
        let totalSize: Int64? = {
            guard let data = dataSize, let index = indexSize else { return nil }
            return data + index
        }()
        
        return TableMetadata(
            tableName: tableName,
            dataSize: dataSize,
            indexSize: indexSize,
            totalSize: totalSize,
            avgRowLength: avgRowLength,
            rowCount: rowCount,
            comment: comment?.isEmpty == true ? nil : comment,
            engine: engine,
            collation: collation,
            createTime: createTime,
            updateTime: updateTime
        )
    }

    // MARK: - Paginated Query Support

    func fetchRowCount(query: String) async throws -> Int {
        // Strip any existing LIMIT/OFFSET from the query
        let baseQuery = stripLimitOffset(from: query)
        let countQuery = "SELECT COUNT(*) AS cnt FROM (\(baseQuery)) AS __count_subquery__"

        let result = try await execute(query: countQuery)

        // Get the count from first row, first column
        guard let firstRow = result.rows.first,
            !firstRow.isEmpty,
            let countStr = firstRow[0],
            let count = Int(countStr)
        else {
            return 0
        }

        return count
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult {
        // Strip any existing LIMIT/OFFSET and apply new ones
        let baseQuery = stripLimitOffset(from: query)
        let paginatedQuery = "\(baseQuery) LIMIT \(limit) OFFSET \(offset)"
        return try await execute(query: paginatedQuery)
    }

    // MARK: - Helpers

    /// Extract table name from SELECT query
    private func extractTableName(from query: String) -> String? {
        let pattern = "(?i)\\bFROM\\s+[`\"']?([\\w]+)[`\"']?"
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
            let range = Range(match.range(at: 1), in: query)
        else {
            return nil
        }
        return String(query[range])
    }

    /// Fetch column names using DESCRIBE
    private func fetchColumnNames(for tableName: String) async throws -> [String] {
        let result = try await execute(query: "DESCRIBE `\(tableName)`")

        var columns: [String] = []
        for row in result.rows {
            if let columnName = row.first ?? nil {
                columns.append(columnName)
            }
        }
        return columns
    }

    /// Remove LIMIT and OFFSET clauses from a query
    private func stripLimitOffset(from query: String) -> String {
        var result = query

        // Remove LIMIT clause (handles LIMIT n or LIMIT n, m)
        let limitPattern = "(?i)\\s+LIMIT\\s+\\d+(\\s*,\\s*\\d+)?"
        if let regex = try? NSRegularExpression(pattern: limitPattern) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // Remove OFFSET clause
        let offsetPattern = "(?i)\\s+OFFSET\\s+\\d+"
        if let regex = try? NSRegularExpression(pattern: offsetPattern) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetch list of all databases on the server
    func fetchDatabases() async throws -> [String] {
        let result = try await execute(query: "SHOW DATABASES")
        return result.rows.compactMap { row in row.first.flatMap { $0 } }
    }
}

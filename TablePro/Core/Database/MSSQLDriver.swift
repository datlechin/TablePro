//
//  MSSQLDriver.swift
//  TablePro
//
//  Microsoft SQL Server driver using FreeTDS db-lib
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.TablePro", category: "MSSQLDriver")

/// SQL Server database driver using FreeTDS db-lib
final class MSSQLDriver: DatabaseDriver {
    let connection: DatabaseConnection
    private(set) var status: ConnectionStatus = .disconnected

    private var freeTDSConn: FreeTDSConnection?

    /// Active schema (default: dbo)
    private(set) var currentSchema: String = "dbo"

    /// Escaped schema name for use in SQL string literals
    var escapedSchema: String {
        currentSchema.replacingOccurrences(of: "'", with: "''")
    }

    var serverVersion: String? {
        _serverVersion
    }
    private var _serverVersion: String?

    init(connection: DatabaseConnection) {
        self.connection = connection
        if let schema = connection.mssqlSchema, !schema.isEmpty {
            self.currentSchema = schema
        }
    }

    // MARK: - Connection

    func connect() async throws {
        status = .connecting
        let conn = FreeTDSConnection(
            host: connection.host,
            port: connection.port,
            user: connection.username,
            password: ConnectionStorage.shared.loadPassword(for: connection.id) ?? "",
            database: connection.database
        )
        do {
            try await conn.connect()
            self.freeTDSConn = conn
            status = .connected
            if let result = try? await conn.executeQuery("SELECT @@VERSION"),
               let versionStr = result.rows.first?.first ?? nil {
                _serverVersion = String(versionStr.prefix(50))
            }
        } catch {
            status = .error(error.localizedDescription)
            throw error
        }
    }

    func disconnect() {
        freeTDSConn?.disconnect()
        freeTDSConn = nil
        status = .disconnected
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        guard let conn = freeTDSConn else {
            throw DatabaseError.connectionFailed("Not connected to SQL Server")
        }
        let startTime = Date()
        let result = try await conn.executeQuery(query)
        return mapToQueryResult(result, executionTime: Date().timeIntervalSince(startTime))
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        // FreeTDS db-lib does not support parameterized queries natively.
        // Use SQLParameterInliner for type-aware inlining (int/float unquoted, strings escaped, nil → NULL).
        let statement = ParameterizedStatement(sql: query, parameters: parameters)
        let built = SQLParameterInliner.inline(statement, databaseType: .mssql)
        return try await execute(query: built)
    }

    func fetchRowCount(query: String) async throws -> Int {
        let countQuery = "SELECT COUNT_BIG(*) FROM (\(query)) AS __cnt"
        let result = try await execute(query: countQuery)
        guard let row = result.rows.first,
              let cell = row.first,
              let str = cell,
              let count = Int(str) else {
            return 0
        }
        return count
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult {
        var base = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix(";") {
            base = String(base.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        base = stripMSSQLOffsetFetch(from: base)
        let orderBy = hasTopLevelOrderBy(base) ? "" : " ORDER BY (SELECT NULL)"
        let paginated = "\(base)\(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return try await execute(query: paginated)
    }

    /// Detect whether query has a top-level ORDER BY clause (not inside parentheses).
    private func hasTopLevelOrderBy(_ query: String) -> Bool {
        let ns = query.uppercased() as NSString
        let len = ns.length
        guard len >= 8 else { return false }
        var depth = 0
        var i = len - 1
        // Note: does not account for ORDER BY inside string literals — acceptable for TablePro's query patterns.
        while i >= 7 {
            let ch = ns.character(at: i)
            if ch == 0x29 { depth += 1 }       // ')'
            else if ch == 0x28 { depth -= 1 }  // '('
            else if depth == 0 && ch == 0x59 { // 'Y' — end of "ORDER BY"
                let start = i - 7
                if start >= 0 {
                    let candidate = ns.substring(with: NSRange(location: start, length: 8))
                    if candidate == "ORDER BY" { return true }
                }
            }
            i -= 1
        }
        return false
    }

    /// Strip trailing OFFSET … ROWS FETCH NEXT … ROWS ONLY added by TableQueryBuilder,
    /// so fetchRows can re-apply pagination with the correct offset and limit.
    private func stripMSSQLOffsetFetch(from query: String) -> String {
        let ns = query.uppercased() as NSString
        let len = ns.length
        guard len >= 6 else { return query }
        var depth = 0
        var i = len - 1
        while i >= 5 {
            let ch = ns.character(at: i)
            if ch == 0x29 { depth += 1 }       // ')'
            else if ch == 0x28 { depth -= 1 }  // '('
            else if depth == 0 && ch == 0x54 { // 'T' — end of "OFFSET"
                let start = i - 5
                if start >= 0 {
                    let candidate = ns.substring(with: NSRange(location: start, length: 6))
                    if candidate == "OFFSET" {
                        return (query as NSString).substring(to: start)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            i -= 1
        }
        return query
    }

    // MARK: - Schema Operations

    func fetchTables() async throws -> [TableInfo] {
        let sql = """
            SELECT t.TABLE_NAME, t.TABLE_TYPE
            FROM INFORMATION_SCHEMA.TABLES t
            WHERE t.TABLE_SCHEMA = '\(escapedSchema)'
              AND t.TABLE_TYPE IN ('BASE TABLE', 'VIEW')
            ORDER BY t.TABLE_NAME
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> TableInfo? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let rawType = row[safe: 1] ?? nil
            let tableType: TableInfo.TableType = (rawType == "VIEW") ? .view : .table
            return TableInfo(name: name, type: tableType, rowCount: nil)
        }
    }

    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT
                COLUMN_NAME,
                DATA_TYPE,
                CHARACTER_MAXIMUM_LENGTH,
                NUMERIC_PRECISION,
                NUMERIC_SCALE,
                IS_NULLABLE,
                COLUMN_DEFAULT,
                COLUMNPROPERTY(OBJECT_ID(TABLE_SCHEMA + '.' + TABLE_NAME), COLUMN_NAME, 'IsIdentity') AS IS_IDENTITY
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_NAME = '\(escapedTable)'
              AND TABLE_SCHEMA = '\(escapedSchema)'
            ORDER BY ORDINAL_POSITION
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> ColumnInfo? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let dataType = row[safe: 1] ?? nil
            let charLen = row[safe: 2] ?? nil
            let numPrecision = row[safe: 3] ?? nil
            let numScale = row[safe: 4] ?? nil
            let isNullable = (row[safe: 5] ?? nil) == "YES"
            let defaultValue = row[safe: 6] ?? nil
            let isIdentity = (row[safe: 7] ?? nil) == "1"

            let baseType = (dataType ?? "nvarchar").lowercased()
            // Types that don't take a size/precision suffix
            let fixedSizeTypes: Set<String> = [
                "int", "bigint", "smallint", "tinyint", "bit",
                "money", "smallmoney", "float", "real",
                "datetime", "datetime2", "smalldatetime", "date", "time",
                "uniqueidentifier", "text", "ntext", "image", "xml",
                "timestamp", "rowversion"
            ]
            var fullType = baseType
            if fixedSizeTypes.contains(baseType) {
                // No suffix needed
            } else if let charLen, let len = Int(charLen), len > 0 {
                fullType += "(\(len))"
            } else if charLen == "-1" {
                fullType += "(max)"
            } else if let prec = numPrecision, let scale = numScale,
                      let p = Int(prec), let s = Int(scale) {
                fullType += "(\(p),\(s))"
            }

            return ColumnInfo(
                name: name,
                dataType: fullType,
                isNullable: isNullable,
                isPrimaryKey: false,
                defaultValue: defaultValue,
                extra: isIdentity ? "IDENTITY" : nil,
                charset: nil,
                collation: nil,
                comment: nil
            )
        }
    }

    func fetchIndexes(table: String) async throws -> [IndexInfo] {
        let bracketedSchema = currentSchema.replacingOccurrences(of: "]", with: "]]")
        let bracketedTable = table.replacingOccurrences(of: "]", with: "]]")
        let bracketedFull = "[\(bracketedSchema)].[\(bracketedTable)]"
        let sql = """
            SELECT i.name, i.is_unique, i.is_primary_key, c.name AS column_name
            FROM sys.indexes i
            JOIN sys.index_columns ic
                ON i.object_id = ic.object_id AND i.index_id = ic.index_id
            JOIN sys.columns c
                ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE i.object_id = OBJECT_ID('\(bracketedFull)')
              AND i.name IS NOT NULL
            ORDER BY i.index_id, ic.key_ordinal
            """
        let result = try await execute(query: sql)
        var indexMap: [String: (unique: Bool, primary: Bool, columns: [String])] = [:]
        for row in result.rows {
            guard let idxName = row[safe: 0] ?? nil,
                  let colName = row[safe: 3] ?? nil else { continue }
            let isUnique = (row[safe: 1] ?? nil) == "1"
            let isPrimary = (row[safe: 2] ?? nil) == "1"
            if indexMap[idxName] == nil {
                indexMap[idxName] = (unique: isUnique, primary: isPrimary, columns: [])
            }
            indexMap[idxName]?.columns.append(colName)
        }
        return indexMap.map { name, info in
            IndexInfo(
                name: name,
                columns: info.columns,
                isUnique: info.unique,
                isPrimary: info.primary,
                type: "CLUSTERED"
            )
        }.sorted { $0.name < $1.name }
    }

    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT
                fk.name AS constraint_name,
                cp.name AS column_name,
                tr.name AS ref_table,
                cr.name AS ref_column
            FROM sys.foreign_keys fk
            JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
            JOIN sys.tables tp ON fkc.parent_object_id = tp.object_id
            JOIN sys.schemas s ON tp.schema_id = s.schema_id
            JOIN sys.columns cp
                ON fkc.parent_object_id = cp.object_id AND fkc.parent_column_id = cp.column_id
            JOIN sys.tables tr ON fkc.referenced_object_id = tr.object_id
            JOIN sys.columns cr
                ON fkc.referenced_object_id = cr.object_id AND fkc.referenced_column_id = cr.column_id
            WHERE tp.name = '\(escapedTable)' AND s.name = '\(escapedSchema)'
            ORDER BY fk.name
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> ForeignKeyInfo? in
            guard let constraintName = row[safe: 0] ?? nil,
                  let columnName = row[safe: 1] ?? nil,
                  let refTable = row[safe: 2] ?? nil,
                  let refColumn = row[safe: 3] ?? nil else { return nil }
            return ForeignKeyInfo(
                name: constraintName,
                column: columnName,
                referencedTable: refTable,
                referencedColumn: refColumn,
                onDelete: "NO ACTION",
                onUpdate: "NO ACTION"
            )
        }
    }

    func fetchApproximateRowCount(table: String) async throws -> Int? {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let objectName = "[\(escapedSchema)].[\(escapedTable)]"
        let sql = """
            SELECT SUM(p.rows)
            FROM sys.partitions p
            WHERE p.object_id = OBJECT_ID(N'\(objectName)') AND p.index_id IN (0, 1)
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first, let cell = row.first, let str = cell {
            return Int(str)
        }
        return nil
    }

    func fetchTableDDL(table: String) async throws -> String {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let cols = try await fetchColumns(table: table)
        let indexes = try await fetchIndexes(table: table)
        let fks = try await fetchForeignKeys(table: table)

        var ddl = "CREATE TABLE [\(escapedSchema)].[\(escapedTable)] (\n"
        let colDefs = cols.map { col -> String in
            var def = "    [\(col.name)] \(col.dataType.uppercased())"
            if col.extra == "IDENTITY" { def += " IDENTITY(1,1)" }
            def += col.isNullable ? " NULL" : " NOT NULL"
            if let d = col.defaultValue { def += " DEFAULT \(d)" }
            return def
        }

        let pkCols = indexes.filter(\.isPrimary).flatMap(\.columns)
        var parts = colDefs
        if !pkCols.isEmpty {
            let pkName = "PK_\(table)"
            let pkDef = "    CONSTRAINT [\(pkName)] PRIMARY KEY (\(pkCols.map { "[\($0)]" }.joined(separator: ", ")))"
            parts.append(pkDef)
        }

        for fk in fks {
            let fkDef = "    CONSTRAINT [\(fk.name)] FOREIGN KEY ([\(fk.column)]) REFERENCES [\(fk.referencedTable)] ([\(fk.referencedColumn)])"
            parts.append(fkDef)
        }

        ddl += parts.joined(separator: ",\n")
        ddl += "\n);"
        return ddl
    }

    func fetchViewDefinition(view: String) async throws -> String {
        let escapedView = "\(escapedSchema).\(view.replacingOccurrences(of: "'", with: "''"))"
        let sql = "SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID('\(escapedView)')"
        let result = try await execute(query: sql)
        return result.rows.first?.first?.flatMap { $0 } ?? ""
    }

    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        let escapedTable = tableName.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT
                SUM(p.rows) AS row_count,
                8 * SUM(a.used_pages) AS size_kb,
                ep.value AS comment
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            JOIN sys.partitions p
                ON t.object_id = p.object_id AND p.index_id IN (0, 1)
            JOIN sys.allocation_units a ON p.partition_id = a.container_id
            LEFT JOIN sys.extended_properties ep
                ON ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = 'MS_Description'
            WHERE t.name = '\(escapedTable)' AND s.name = '\(escapedSchema)'
            GROUP BY ep.value
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first {
            let rowCount = (row[safe: 0] ?? nil).flatMap { Int64($0) }
            let sizeKb = (row[safe: 1] ?? nil).flatMap { Int64($0) } ?? 0
            let comment = row[safe: 2] ?? nil
            return TableMetadata(
                tableName: tableName,
                dataSize: sizeKb * 1_024,
                indexSize: nil,
                totalSize: sizeKb * 1_024,
                avgRowLength: nil,
                rowCount: rowCount,
                comment: comment,
                engine: nil,
                collation: nil,
                createTime: nil,
                updateTime: nil
            )
        }
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

    func fetchDatabases() async throws -> [String] {
        let sql = "SELECT name FROM sys.databases ORDER BY name"
        let result = try await execute(query: sql)
        return result.rows.compactMap { $0.first ?? nil }
    }

    func fetchSchemas() async throws -> [String] {
        let sql = """
            SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA
            WHERE SCHEMA_NAME NOT IN (
                'information_schema','sys','db_owner','db_accessadmin',
                'db_securityadmin','db_ddladmin','db_backupoperator',
                'db_datareader','db_datawriter','db_denydatareader',
                'db_denydatawriter','guest'
            )
            ORDER BY SCHEMA_NAME
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { $0.first ?? nil }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        let sql = """
            SELECT
                SUM(size) * 8.0 / 1024 AS size_mb,
                (SELECT COUNT(*) FROM sys.tables) AS table_count
            FROM sys.database_files
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first {
            let sizeMb = (row[safe: 0] ?? nil).flatMap { Double($0) } ?? 0
            let tableCount = (row[safe: 1] ?? nil).flatMap { Int($0) } ?? 0
            return DatabaseMetadata(
                id: database,
                name: database,
                tableCount: tableCount,
                sizeBytes: Int64(sizeMb * 1_024 * 1_024),
                lastAccessed: nil,
                isSystemDatabase: false,
                icon: "cylinder.fill"
            )
        }
        return DatabaseMetadata.minimal(name: database)
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        let quotedName = connection.type.quoteIdentifier(name)
        _ = try await execute(query: "CREATE DATABASE \(quotedName)")
    }

    func cancelQuery() throws {
        // FreeTDS db-lib cancel is not safe to call from a different thread.
        // No-op — connection-level cancel not supported.
    }

    // MARK: - Schema Switching

    func switchSchema(to schema: String) async throws {
        currentSchema = schema
    }

    /// Switch the active database on the SQL Server connection
    func switchDatabase(to database: String) async throws {
        guard let conn = freeTDSConn else {
            throw DatabaseError.connectionFailed("Not connected to SQL Server")
        }
        try await conn.switchDatabase(database)
        currentSchema = "dbo"
    }

    // MARK: - Private Helpers

    private func mapToQueryResult(_ freetdsResult: FreeTDSQueryResult, executionTime: TimeInterval) -> QueryResult {
        let columnTypes = freetdsResult.columnTypeNames.map { rawType in
            ColumnType(fromSQLiteType: rawType)
        }
        return QueryResult(
            columns: freetdsResult.columns,
            columnTypes: columnTypes,
            rows: freetdsResult.rows,
            rowsAffected: freetdsResult.affectedRows,
            executionTime: executionTime,
            error: nil
        )
    }
}

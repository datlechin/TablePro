//
//  MSSQLPlugin.swift
//  TablePro
//

import CFreeTDS
import Foundation
import os
import TableProPluginKit

final class MSSQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "MSSQL Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Microsoft SQL Server support via FreeTDS db-lib"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "SQL Server"
    static let databaseDisplayName = "SQL Server"
    static let iconName = "server.rack"
    static let defaultPort = 1433
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(id: "mssqlSchema", label: "Schema", placeholder: "dbo")
    ]

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        MSSQLPluginDriver(config: config)
    }
}

// MARK: - Global FreeTDS initialization

private let freetdsLastErrorLock = NSLock()
private var _freetdsLastError = ""

private var freetdsLastError: String {
    get {
        freetdsLastErrorLock.lock()
        defer { freetdsLastErrorLock.unlock() }
        return _freetdsLastError
    }
    set {
        freetdsLastErrorLock.lock()
        defer { freetdsLastErrorLock.unlock() }
        _freetdsLastError = newValue
    }
}

private let freetdsLogger = Logger(subsystem: "com.TablePro", category: "FreeTDSConnection")

private let freetdsInitOnce: Void = {
    _ = dbinit()
    _ = dberrhandle { _, _, dberr, _, dberrstr, oserrstr in
        var msg = "db-lib error \(dberr)"
        if let s = dberrstr { msg += ": \(String(cString: s))" }
        if let s = oserrstr, String(cString: s) != "Success" { msg += " (os: \(String(cString: s)))" }
        freetdsLogger.error("FreeTDS: \(msg)")
        if freetdsLastError.isEmpty {
            freetdsLastError = msg
        }
        return INT_CANCEL
    }
    _ = dbmsghandle { _, msgno, _, severity, msgtext, _, _, _ in
        guard let text = msgtext else { return 0 }
        let msg = String(cString: text)
        if severity > 10 {
            freetdsLastError = msg
            freetdsLogger.error("FreeTDS msg \(msgno) sev \(severity): \(msg)")
        } else {
            freetdsLogger.debug("FreeTDS msg \(msgno): \(msg)")
        }
        return 0
    }
}()

// MARK: - FreeTDS Connection

private struct FreeTDSQueryResult {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[String?]]
    let affectedRows: Int
}

private final class FreeTDSConnection: @unchecked Sendable {
    private var dbproc: UnsafeMutablePointer<DBPROCESS>?
    private let queue: DispatchQueue
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let database: String
    private let lock = NSLock()
    private var _isConnected = false

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    init(host: String, port: Int, user: String, password: String, database: String) {
        self.queue = DispatchQueue(label: "com.TablePro.freetds.\(host).\(port)", qos: .userInitiated)
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        _ = freetdsInitOnce
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try self.connectSync()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func connectSync() throws {
        guard let login = dblogin() else {
            throw MSSQLPluginError.connectionFailed("Failed to create login")
        }
        defer { dbloginfree(login) }

        _ = dbsetlname(login, user, Int32(DBSETUSER))
        _ = dbsetlname(login, password, Int32(DBSETPWD))
        _ = dbsetlname(login, "TablePro", Int32(DBSETAPP))
        _ = dbsetlversion(login, UInt8(DBVERSION_74))

        freetdsLastError = ""
        let serverName = "\(host):\(port)"
        guard let proc = dbopen(login, serverName) else {
            let detail = freetdsLastError.isEmpty ? "Check host, port, and credentials" : freetdsLastError
            throw MSSQLPluginError.connectionFailed("Failed to connect to \(host):\(port) — \(detail)")
        }

        if !database.isEmpty {
            if dbuse(proc, database) == FAIL {
                _ = dbclose(proc)
                throw MSSQLPluginError.connectionFailed("Cannot open database '\(database)'")
            }
        }

        self.dbproc = proc
        lock.lock()
        _isConnected = true
        lock.unlock()
    }

    func switchDatabase(_ database: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let proc = self.dbproc else {
                    continuation.resume(throwing: MSSQLPluginError.notConnected)
                    return
                }
                if dbuse(proc, database) == FAIL {
                    continuation.resume(throwing: MSSQLPluginError.queryFailed("Cannot switch to database '\(database)'"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func disconnect() {
        let handle = dbproc
        dbproc = nil

        lock.lock()
        _isConnected = false
        lock.unlock()

        if let handle = handle {
            queue.async {
                _ = dbclose(handle)
            }
        }
    }

    func executeQuery(_ query: String) async throws -> FreeTDSQueryResult {
        let queryToRun = String(query)
        return try await withCheckedThrowingContinuation { [self] (cont: CheckedContinuation<FreeTDSQueryResult, Error>) in
            queue.async { [self] in
                do {
                    let result = try self.executeQuerySync(queryToRun)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func executeQuerySync(_ query: String) throws -> FreeTDSQueryResult {
        guard let proc = dbproc else {
            throw MSSQLPluginError.notConnected
        }

        _ = dbcanquery(proc)

        freetdsLastError = ""
        if dbcmd(proc, query) == FAIL {
            throw MSSQLPluginError.queryFailed("Failed to prepare query")
        }
        if dbsqlexec(proc) == FAIL {
            let detail = freetdsLastError.isEmpty ? "Query execution failed" : freetdsLastError
            throw MSSQLPluginError.queryFailed(detail)
        }

        var allColumns: [String] = []
        var allTypeNames: [String] = []
        var allRows: [[String?]] = []
        var firstResultSet = true

        while true {
            let resCode = dbresults(proc)
            if resCode == FAIL {
                throw MSSQLPluginError.queryFailed("Query execution failed")
            }
            if resCode == Int32(NO_MORE_RESULTS) {
                break
            }

            let numCols = dbnumcols(proc)
            if numCols <= 0 { continue }

            var cols: [String] = []
            var typeNames: [String] = []
            for i in 1...numCols {
                let name = dbcolname(proc, Int32(i)).map { String(cString: $0) } ?? "col\(i)"
                cols.append(name)
                typeNames.append(Self.freetdsTypeName(dbcoltype(proc, Int32(i))))
            }

            if firstResultSet {
                allColumns = cols
                allTypeNames = typeNames
                firstResultSet = false
            }

            while true {
                let rowCode = dbnextrow(proc)
                if rowCode == Int32(NO_MORE_ROWS) { break }
                if rowCode == FAIL { break }

                var row: [String?] = []
                for i in 1...numCols {
                    let len = dbdatlen(proc, Int32(i))
                    let colType = dbcoltype(proc, Int32(i))
                    if len <= 0 && colType != Int32(SYBBIT) {
                        row.append(nil)
                    } else if let ptr = dbdata(proc, Int32(i)) {
                        let str = Self.columnValueAsString(proc: proc, ptr: ptr, srcType: colType, srcLen: len)
                        row.append(str)
                    } else {
                        row.append(nil)
                    }
                }
                allRows.append(row)
            }
        }

        let affectedRows = allColumns.isEmpty ? 0 : allRows.count
        return FreeTDSQueryResult(
            columns: allColumns,
            columnTypeNames: allTypeNames,
            rows: allRows,
            affectedRows: affectedRows
        )
    }

    private static func columnValueAsString(proc: UnsafeMutablePointer<DBPROCESS>, ptr: UnsafePointer<BYTE>, srcType: Int32, srcLen: DBINT) -> String? {
        switch srcType {
        case Int32(SYBCHAR), Int32(SYBVARCHAR), Int32(SYBTEXT):
            return String(bytes: UnsafeBufferPointer(start: ptr, count: Int(srcLen)), encoding: .utf8)
                ?? String(bytes: UnsafeBufferPointer(start: ptr, count: Int(srcLen)), encoding: .isoLatin1)
        case Int32(SYBNCHAR), Int32(SYBNVARCHAR), Int32(SYBNTEXT):
            let data = Data(bytes: ptr, count: Int(srcLen))
            return String(data: data, encoding: .utf16LittleEndian)
        default:
            let bufSize: DBINT = 64
            var buf = [BYTE](repeating: 0, count: Int(bufSize))
            let converted = buf.withUnsafeMutableBufferPointer { bufPtr in
                dbconvert(proc, srcType, ptr, srcLen, Int32(SYBCHAR), bufPtr.baseAddress, bufSize)
            }
            if converted > 0 {
                return String(bytes: buf.prefix(Int(converted)), encoding: .utf8)
            }
            return nil
        }
    }

    private static func freetdsTypeName(_ type: Int32) -> String {
        switch type {
        case Int32(SYBCHAR), Int32(SYBVARCHAR): return "varchar"
        case Int32(SYBNCHAR), Int32(SYBNVARCHAR): return "nvarchar"
        case Int32(SYBTEXT): return "text"
        case Int32(SYBNTEXT): return "ntext"
        case Int32(SYBINT1): return "tinyint"
        case Int32(SYBINT2): return "smallint"
        case Int32(SYBINT4): return "int"
        case Int32(SYBINT8): return "bigint"
        case Int32(SYBFLT8): return "float"
        case Int32(SYBREAL): return "real"
        case Int32(SYBDECIMAL), Int32(SYBNUMERIC): return "decimal"
        case Int32(SYBMONEY), Int32(SYBMONEY4): return "money"
        case Int32(SYBBIT): return "bit"
        case Int32(SYBBINARY), Int32(SYBVARBINARY): return "varbinary"
        case Int32(SYBIMAGE): return "image"
        case Int32(SYBDATETIME), Int32(SYBDATETIMN): return "datetime"
        case Int32(SYBDATETIME4): return "smalldatetime"
        case Int32(SYBUNIQUE): return "uniqueidentifier"
        default: return "unknown"
        }
    }
}

// MARK: - MSSQL Plugin Driver

final class MSSQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var freeTDSConn: FreeTDSConnection?
    private var _currentSchema: String
    private var _serverVersion: String?

    private static let logger = Logger(subsystem: "com.TablePro", category: "MSSQLPluginDriver")

    var currentSchema: String? { _currentSchema }
    var serverVersion: String? { _serverVersion }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }

    init(config: DriverConnectionConfig) {
        self.config = config
        self._currentSchema = config.additionalFields["mssqlSchema"]?.isEmpty == false
            ? config.additionalFields["mssqlSchema"]!
            : "dbo"
    }

    private var escapedSchema: String {
        _currentSchema.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - Connection

    func connect() async throws {
        let conn = FreeTDSConnection(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password,
            database: config.database
        )
        try await conn.connect()
        self.freeTDSConn = conn
        if let result = try? await conn.executeQuery("SELECT @@VERSION"),
           let versionStr = result.rows.first?.first ?? nil {
            _serverVersion = String(versionStr.prefix(50))
        }
    }

    func disconnect() {
        freeTDSConn?.disconnect()
        freeTDSConn = nil
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    // MARK: - Transaction Management

    func beginTransaction() async throws {
        _ = try await execute(query: "BEGIN TRANSACTION")
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        guard let conn = freeTDSConn else {
            throw MSSQLPluginError.notConnected
        }
        let startTime = Date()
        let result = try await conn.executeQuery(query)
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: result.affectedRows,
            executionTime: Date().timeIntervalSince(startTime)
        )
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

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        var base = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix(";") {
            base = String(base.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        base = stripMSSQLOffsetFetch(from: base)
        let orderBy = hasTopLevelOrderBy(base) ? "" : " ORDER BY (SELECT NULL)"
        let paginated = "\(base)\(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return try await execute(query: paginated)
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let esc = (schema ?? _currentSchema).replacingOccurrences(of: "'", with: "''")
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let objectName = "[\(esc)].[\(escapedTable)]"
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

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let esc = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT t.TABLE_NAME, t.TABLE_TYPE
            FROM INFORMATION_SCHEMA.TABLES t
            WHERE t.TABLE_SCHEMA = '\(esc)'
              AND t.TABLE_TYPE IN ('BASE TABLE', 'VIEW')
            ORDER BY t.TABLE_NAME
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let rawType = row[safe: 1] ?? nil
            let tableType = (rawType == "VIEW") ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let esc = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.CHARACTER_MAXIMUM_LENGTH,
                c.NUMERIC_PRECISION,
                c.NUMERIC_SCALE,
                c.IS_NULLABLE,
                c.COLUMN_DEFAULT,
                COLUMNPROPERTY(OBJECT_ID(c.TABLE_SCHEMA + '.' + c.TABLE_NAME), c.COLUMN_NAME, 'IsIdentity') AS IS_IDENTITY,
                CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS IS_PK
            FROM INFORMATION_SCHEMA.COLUMNS c
            LEFT JOIN (
                SELECT kcu.COLUMN_NAME
                FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
                JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
                    ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
                    AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
                WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
                    AND tc.TABLE_SCHEMA = '\(esc)'
                    AND tc.TABLE_NAME = '\(escapedTable)'
            ) pk ON c.COLUMN_NAME = pk.COLUMN_NAME
            WHERE c.TABLE_NAME = '\(escapedTable)'
              AND c.TABLE_SCHEMA = '\(esc)'
            ORDER BY c.ORDINAL_POSITION
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginColumnInfo? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let dataType = row[safe: 1] ?? nil
            let charLen = row[safe: 2] ?? nil
            let numPrecision = row[safe: 3] ?? nil
            let numScale = row[safe: 4] ?? nil
            let isNullable = (row[safe: 5] ?? nil) == "YES"
            let defaultValue = row[safe: 6] ?? nil
            let isIdentity = (row[safe: 7] ?? nil) == "1"
            let isPk = (row[safe: 8] ?? nil) == "1"

            let baseType = (dataType ?? "nvarchar").lowercased()
            let fixedSizeTypes: Set<String> = [
                "int", "bigint", "smallint", "tinyint", "bit",
                "money", "smallmoney", "float", "real",
                "datetime", "datetime2", "smalldatetime", "date", "time",
                "uniqueidentifier", "text", "ntext", "image", "xml",
                "timestamp", "rowversion"
            ]
            var fullType = baseType
            if fixedSizeTypes.contains(baseType) {
                // No suffix
            } else if let charLen, let len = Int(charLen), len > 0 {
                fullType += "(\(len))"
            } else if charLen == "-1" {
                fullType += "(max)"
            } else if let prec = numPrecision, let scale = numScale,
                      let p = Int(prec), let s = Int(scale) {
                fullType += "(\(p),\(s))"
            }

            return PluginColumnInfo(
                name: name,
                dataType: fullType,
                isNullable: isNullable,
                isPrimaryKey: isPk,
                defaultValue: defaultValue,
                extra: isIdentity ? "IDENTITY" : nil
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let esc = (schema ?? _currentSchema).replacingOccurrences(of: "]", with: "]]")
        let bracketedTable = table.replacingOccurrences(of: "]", with: "]]")
        let bracketedFull = "[\(esc)].[\(bracketedTable)]"
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
            PluginIndexInfo(
                name: name,
                columns: info.columns,
                isUnique: info.unique,
                isPrimary: info.primary,
                type: "CLUSTERED"
            )
        }.sorted { $0.name < $1.name }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let esc = effectiveSchemaEscaped(schema)
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
            WHERE tp.name = '\(escapedTable)' AND s.name = '\(esc)'
            ORDER BY fk.name
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginForeignKeyInfo? in
            guard let constraintName = row[safe: 0] ?? nil,
                  let columnName = row[safe: 1] ?? nil,
                  let refTable = row[safe: 2] ?? nil,
                  let refColumn = row[safe: 3] ?? nil else { return nil }
            return PluginForeignKeyInfo(
                name: constraintName,
                column: columnName,
                referencedTable: refTable,
                referencedColumn: refColumn
            )
        }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let esc = effectiveSchemaEscaped(schema)
        let cols = try await fetchColumns(table: table, schema: schema)
        let indexes = try await fetchIndexes(table: table, schema: schema)
        let fks = try await fetchForeignKeys(table: table, schema: schema)

        var ddl = "CREATE TABLE [\(esc)].[\(escapedTable)] (\n"
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

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let esc = effectiveSchemaEscaped(schema)
        let escapedView = "\(esc).\(view.replacingOccurrences(of: "'", with: "''"))"
        let sql = "SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID('\(escapedView)')"
        let result = try await execute(query: sql)
        return result.rows.first?.first?.flatMap { $0 } ?? ""
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let esc = effectiveSchemaEscaped(schema)
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
            WHERE t.name = '\(escapedTable)' AND s.name = '\(esc)'
            GROUP BY ep.value
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first {
            let rowCount = (row[safe: 0] ?? nil).flatMap { Int64($0) }
            let sizeKb = (row[safe: 1] ?? nil).flatMap { Int64($0) } ?? 0
            let comment = row[safe: 2] ?? nil
            return PluginTableMetadata(
                tableName: table,
                dataSize: sizeKb * 1_024,
                totalSize: sizeKb * 1_024,
                rowCount: rowCount,
                comment: comment
            )
        }
        return PluginTableMetadata(tableName: table)
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

    func switchSchema(to schema: String) async throws {
        _currentSchema = schema
    }

    func switchDatabase(to database: String) async throws {
        guard let conn = freeTDSConn else {
            throw MSSQLPluginError.notConnected
        }
        try await conn.switchDatabase(database)
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
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
            return PluginDatabaseMetadata(
                name: database,
                tableCount: tableCount,
                sizeBytes: Int64(sizeMb * 1_024 * 1_024)
            )
        }
        return PluginDatabaseMetadata(name: database)
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        let quotedName = "[\(name.replacingOccurrences(of: "]", with: "]]"))]"
        _ = try await execute(query: "CREATE DATABASE \(quotedName)")
    }

    // MARK: - Private Helpers

    private func effectiveSchemaEscaped(_ schema: String?) -> String {
        let raw = schema ?? _currentSchema
        return raw.replacingOccurrences(of: "'", with: "''")
    }

    private func hasTopLevelOrderBy(_ query: String) -> Bool {
        let ns = query.uppercased() as NSString
        let len = ns.length
        guard len >= 8 else { return false }
        var depth = 0
        var i = len - 1
        while i >= 7 {
            let ch = ns.character(at: i)
            if ch == 0x29 { depth += 1 }
            else if ch == 0x28 { depth -= 1 }
            else if depth == 0 && ch == 0x59 {
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

    private func stripMSSQLOffsetFetch(from query: String) -> String {
        let ns = query.uppercased() as NSString
        let len = ns.length
        guard len >= 6 else { return query }
        var depth = 0
        var i = len - 1
        while i >= 5 {
            let ch = ns.character(at: i)
            if ch == 0x29 { depth += 1 }
            else if ch == 0x28 { depth -= 1 }
            else if depth == 0 && ch == 0x54 {
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
}

// MARK: - Errors

enum MSSQLPluginError: LocalizedError {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message): return "SQL Server Error: \(message)"
        case .notConnected: return "SQL Server Error: Not connected to database"
        case .queryFailed(let message): return "SQL Server Error: \(message)"
        }
    }
}

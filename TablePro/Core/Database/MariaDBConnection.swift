//
//  MariaDBConnection.swift
//  TablePro
//
//  Swift wrapper around libmariadb (MariaDB Connector/C)
//  Provides thread-safe, async-friendly MySQL/MariaDB connections
//

import CMariaDB
import Foundation

// MySQL/MariaDB field flag constants
private let mysqlBinaryFlag: UInt = 0x0080   // 128
private let mysqlEnumFlag: UInt = 0x0100     // 256
private let mysqlSetFlag: UInt = 0x0800      // 2048

// MARK: - Error Types

/// MySQL/MariaDB error with server error code and message
struct MariaDBError: Error, LocalizedError {
    let code: UInt32
    let message: String
    let sqlState: String?

    var errorDescription: String? {
        if let state = sqlState {
            return "MySQL Error \(code) (\(state)): \(message)"
        }
        return "MySQL Error \(code): \(message)"
    }

    static let notConnected = MariaDBError(
        code: 0, message: "Not connected to database", sqlState: nil)
    static let connectionFailed = MariaDBError(
        code: 0, message: "Failed to establish connection", sqlState: nil)
    static let initFailed = MariaDBError(
        code: 0, message: "Failed to initialize MySQL client", sqlState: nil)
}

// MARK: - Query Result

/// Result from a MySQL query execution
struct MariaDBQueryResult {
    let columns: [String]
    let columnTypes: [UInt32]  // NEW: MySQL field type for each column
    let columnTypeNames: [String]  // NEW: Raw type names (e.g., "TEXT", "LONGTEXT")
    let rows: [[String?]]
    let affectedRows: UInt64
    let insertId: UInt64
}

// MARK: - Column Metadata

/// Metadata for a result column
struct MariaDBColumnInfo {
    let name: String
    let type: UInt32
    let flags: UInt32
    let decimals: UInt32
}

// MARK: - Type Mapping

/// Converts a MySQL/MariaDB field type enum value to a human-readable type name.
///
/// This helper interprets the raw MySQL type code together with the field length
/// and flags (including `BINARY_FLAG`) to distinguish between text and binary
/// variants (e.g. `TINYTEXT` vs `TINYBLOB`) and between `TEXT`/`BLOB` and
/// `LONGTEXT`/`LONGBLOB`.
///
/// Reference: https://dev.mysql.com/doc/c-api/8.0/en/c-api-data-structures.html
///
/// - Parameters:
///   - type: The MySQL type enum value (e.g. `MYSQL_TYPE_LONG`, `MYSQL_TYPE_BLOB`)
///           represented as a `UInt32`.
///   - length: The declared maximum length of the field, used to distinguish
///             between `TEXT`/`BLOB` and `LONGTEXT`/`LONGBLOB` for certain types.
///   - flags: The field flags bitmask (including `BINARY_FLAG`) used to determine
///            whether a field should be treated as binary (e.g. `BLOB`) or text
///            (e.g. `TEXT`).
///
/// - Returns: A string containing the normalized MySQL type name
///            (for example, `"INT"`, `"VARCHAR"`, `"TEXT"`, `"BLOB"`).
private func mysqlTypeToString(_ type: UInt32, length: UInt, flags: UInt) -> String {
    // ENUM/SET fields may be reported as STRING (254) or VAR_STRING (253)
    // in result sets — check flags first
    if (flags & mysqlEnumFlag) != 0 { return "ENUM" }
    if (flags & mysqlSetFlag) != 0 { return "SET" }

    // Check if this is a text-based field (not binary)
    let isBinary = (flags & mysqlBinaryFlag) != 0

    switch type {
    case 0: return "DECIMAL"
    case 1: return "TINYINT"
    case 2: return "SMALLINT"
    case 3: return "INT"
    case 4: return "FLOAT"
    case 5: return "DOUBLE"
    case 6: return "NULL"
    case 7: return "TIMESTAMP"
    case 8: return "BIGINT"
    case 9: return "MEDIUMINT"
    case 10: return "DATE"
    case 11: return "TIME"
    case 12: return "DATETIME"
    case 13: return "YEAR"
    case 14: return "NEWDATE"
    case 15: return "VARCHAR"
    case 16: return "BIT"
    case 245: return "JSON"
    case 246: return "NEWDECIMAL"
    case 247: return "ENUM"
    case 248: return "SET"
    case 249:  // TINYBLOB/TINYTEXT
        return isBinary ? "TINYBLOB" : "TINYTEXT"
    case 250:  // MEDIUMBLOB/MEDIUMTEXT
        return isBinary ? "MEDIUMBLOB" : "MEDIUMTEXT"
    case 251:  // LONGBLOB/LONGTEXT
        return isBinary ? "LONGBLOB" : "LONGTEXT"
    case 252:  // BLOB/TEXT - distinguish by length
        if isBinary {
            return length > 65_535 ? "LONGBLOB" : "BLOB"
        } else {
            return length > 65_535 ? "LONGTEXT" : "TEXT"
        }
    case 253: return "VARCHAR"  // VAR_STRING
    case 254: return "CHAR"      // STRING
    case 255: return "GEOMETRY"
    default: return "UNKNOWN"
    }
}

// MARK: - Connection Class

/// Thread-safe MySQL/MariaDB connection using libmariadb
/// All blocking C calls are dispatched to a dedicated serial queue
final class MariaDBConnection: @unchecked Sendable {
    // MARK: - Properties

    /// The underlying MYSQL pointer (opaque handle)
    /// Access only through the serial queue
    private var mysql: UnsafeMutablePointer<MYSQL>?

    /// Serial queue for thread-safe access to the C library
    private let queue = DispatchQueue(label: "com.TablePro.mariadb", qos: .userInitiated)

    /// Connection parameters
    private let host: String
    private let port: UInt32
    private let user: String
    private let password: String?
    private let database: String

    /// Connection state - accessed only from queue
    private var _isConnected: Bool = false

    /// Thread-safe connection state accessor
    var isConnected: Bool {
        queue.sync { _isConnected }
    }

    /// Flag to prevent new queries during shutdown
    private var isShuttingDown: Bool = false

    // MARK: - Initialization

    private let sslConfig: SSLConfiguration

    init(
        host: String,
        port: Int,
        user: String,
        password: String?,
        database: String,
        sslConfig: SSLConfiguration = SSLConfiguration()
    ) {
        self.host = host
        self.port = UInt32(port)
        self.user = user
        self.password = password
        self.database = database
        self.sslConfig = sslConfig
    }

    deinit {
        // Ensure all pending queue work completes before cleanup
        queue.sync {
            if let mysql = mysql {
                mysql_close(mysql)
            }
            mysql = nil
        }
    }

    // MARK: - Connection Management

    /// Connect to the MySQL/MariaDB server
    /// - Throws: MariaDBError if connection fails
    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                // Initialize MySQL client
                guard let mysql = mysql_init(nil) else {
                    continuation.resume(throwing: MariaDBError.initFailed)
                    return
                }

                self.mysql = mysql

                // Set connection options
                // DISABLE auto-reconnect - it can cause memory corruption when reconnecting during queries
                var reconnect: my_bool = 0
                mysql_options(mysql, MYSQL_OPT_RECONNECT, &reconnect)

                // Set connection timeout (10 seconds)
                var timeout: UInt32 = 10
                mysql_options(mysql, MYSQL_OPT_CONNECT_TIMEOUT, &timeout)

                // Set read timeout (30 seconds)
                var readTimeout: UInt32 = 30
                mysql_options(mysql, MYSQL_OPT_READ_TIMEOUT, &readTimeout)

                // Set write timeout (30 seconds)
                var writeTimeout: UInt32 = 30
                mysql_options(mysql, MYSQL_OPT_WRITE_TIMEOUT, &writeTimeout)

                // Force TCP protocol (instead of Unix socket for localhost)
                var protocol_tcp = UInt32(MYSQL_PROTOCOL_TCP.rawValue)
                mysql_options(mysql, MYSQL_OPT_PROTOCOL, &protocol_tcp)

                // SSL/TLS configuration
                switch self.sslConfig.mode {
                case .disabled:
                    var sslEnforce: my_bool = 0
                    mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)
                    var sslVerify: my_bool = 0
                    mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sslVerify)

                case .preferred:
                    // Don't enforce, but allow SSL if server supports it
                    var sslEnforce: my_bool = 0
                    mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)
                    var sslVerify: my_bool = 0
                    mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sslVerify)

                case .required:
                    var sslEnforce: my_bool = 1
                    mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)
                    var sslVerify: my_bool = 0
                    mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sslVerify)

                case .verifyCa, .verifyIdentity:
                    var sslEnforce: my_bool = 1
                    mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)
                    var sslVerify: my_bool = 1
                    mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sslVerify)
                }

                // SSL certificate paths
                if !self.sslConfig.caCertificatePath.isEmpty {
                    _ = self.sslConfig.caCertificatePath.withCString { path in
                        mysql_options(mysql, MYSQL_OPT_SSL_CA, path)
                    }
                }
                if !self.sslConfig.clientCertificatePath.isEmpty {
                    _ = self.sslConfig.clientCertificatePath.withCString { path in
                        mysql_options(mysql, MYSQL_OPT_SSL_CERT, path)
                    }
                }
                if !self.sslConfig.clientKeyPath.isEmpty {
                    _ = self.sslConfig.clientKeyPath.withCString { path in
                        mysql_options(mysql, MYSQL_OPT_SSL_KEY, path)
                    }
                }

                // Set character set to UTF-8
                mysql_options(mysql, MYSQL_SET_CHARSET_NAME, "utf8mb4")

                // Connect to server
                // mysql_real_connect returns the handle on success, NULL on failure
                // IMPORTANT: All withCString closures must be nested so pointers remain valid
                let dbToUse = self.database.isEmpty ? nil : self.database
                let passToUse = self.password

                let result: UnsafeMutablePointer<MYSQL>?

                if let db = dbToUse, let pass = passToUse {
                    // Both database and password
                    result = self.host.withCString { hostPtr in
                        self.user.withCString { userPtr in
                            pass.withCString { passPtr in
                                db.withCString { dbPtr in
                                    mysql_real_connect(
                                        mysql, hostPtr, userPtr, passPtr, dbPtr,
                                        self.port, nil, 0
                                    )
                                }
                            }
                        }
                    }
                } else if let db = dbToUse {
                    // Database but no password
                    result = self.host.withCString { hostPtr in
                        self.user.withCString { userPtr in
                            db.withCString { dbPtr in
                                mysql_real_connect(
                                    mysql, hostPtr, userPtr, nil, dbPtr,
                                    self.port, nil, 0
                                )
                            }
                        }
                    }
                } else if let pass = passToUse {
                    // Password but no database
                    result = self.host.withCString { hostPtr in
                        self.user.withCString { userPtr in
                            pass.withCString { passPtr in
                                mysql_real_connect(
                                    mysql, hostPtr, userPtr, passPtr, nil,
                                    self.port, nil, 0
                                )
                            }
                        }
                    }
                } else {
                    // Neither database nor password
                    result = self.host.withCString { hostPtr in
                        self.user.withCString { userPtr in
                            mysql_real_connect(
                                mysql, hostPtr, userPtr, nil, nil,
                                self.port, nil, 0
                            )
                        }
                    }
                }

                if result == nil {
                    // Connection failed
                    let error = self.getError()
                    mysql_close(mysql)
                    self.mysql = nil
                    continuation.resume(throwing: error)
                    return
                }

                self._isConnected = true
                continuation.resume()
            }
        }
    }

    /// Disconnect from the server
    func disconnect() {
        queue.sync {
            isShuttingDown = true
            if let mysql = mysql {
                mysql_close(mysql)
            }
            mysql = nil
            _isConnected = false
        }
    }

    // MARK: - Query Execution

    /// Execute a SQL query and fetch all results
    /// - Parameter query: SQL query string
    /// - Returns: Query result with columns and rows
    /// - Throws: MariaDBError on failure
    func executeQuery(_ query: String) async throws -> MariaDBQueryResult {
        // Capture query string to avoid potential issues with closure capture
        let queryToRun = String(query)

        return try await withCheckedThrowingContinuation { [self] (cont: CheckedContinuation<MariaDBQueryResult, Error>) in
            queue.async { [self] in
                // Check if shutting down
                guard !isShuttingDown else {
                    cont.resume(throwing: MariaDBError.notConnected)
                    return
                }

                do {
                    let result = try executeQuerySync(queryToRun)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Execute a parameterized query using prepared statements (prevents SQL injection)
    /// - Parameters:
    ///   - query: SQL query with ? placeholders
    ///   - parameters: Array of parameter values to bind
    /// - Returns: Query result
    /// - Throws: MariaDBError on failure
    func executeParameterizedQuery(_ query: String, parameters: [Any?]) async throws -> MariaDBQueryResult {
        let queryToRun = String(query)
        let params = parameters // Capture parameters

        return try await withCheckedThrowingContinuation { [self] (cont: CheckedContinuation<MariaDBQueryResult, Error>) in
            queue.async { [self] in
                guard !isShuttingDown else {
                    cont.resume(throwing: MariaDBError.notConnected)
                    return
                }

                do {
                    let result = try executeParameterizedQuerySync(queryToRun, parameters: params)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous query execution - must be called on the serial queue
    private func executeQuerySync(_ query: String) throws -> MariaDBQueryResult {
        guard !isShuttingDown, let mysql = self.mysql else {
            throw MariaDBError.notConnected
        }

        // Execute query using a local copy of the query string
        let localQuery = String(query)
        let queryStatus = localQuery.withCString { queryPtr in
            mysql_real_query(mysql, queryPtr, UInt(localQuery.utf8.count))
        }

        if queryStatus != 0 {
            throw self.getError()
        }

        // Try to get result set (for SELECT queries)
        // Use mysql_store_result for full dataset (safer for multiple queries)
        let resultPtr = mysql_store_result(mysql)

        if resultPtr == nil {
            // Check if this was a non-SELECT query or an error
            let fieldCount = mysql_field_count(mysql)
            if fieldCount == 0 {
                // Non-SELECT query (INSERT, UPDATE, DELETE, etc.)
                let affected = mysql_affected_rows(mysql)
                let insertId = mysql_insert_id(mysql)
                return MariaDBQueryResult(
                    columns: [],
                    columnTypes: [],
                    columnTypeNames: [],
                    rows: [],
                    affectedRows: affected,
                    insertId: insertId
                )
            } else {
                // Error occurred
                throw self.getError()
            }
        }

        // Fetch column metadata
        let numFields = Int(mysql_num_fields(resultPtr))
        var columns: [String] = []
        var columnTypes: [UInt32] = []  // NEW: Store column types
        var columnTypeNames: [String] = []  // NEW: Store raw type names
        columns.reserveCapacity(numFields)
        columnTypes.reserveCapacity(numFields)
        columnTypeNames.reserveCapacity(numFields)

        if let fields = mysql_fetch_fields(resultPtr) {
            for i in 0..<numFields {
                let field = fields[i]
                // Extract column name
                if let namePtr = field.name {
                    // Create completely independent copy of column name
                    let cStr = String(cString: namePtr)
                    columns.append(String(cStr.unicodeScalars.map { Character($0) }))
                } else {
                    columns.append("column_\(i)")
                }
                // Extract column type — correct ENUM/SET codes from flags
                let fieldFlags = UInt(field.flags)
                var fieldType = field.type.rawValue
                if (fieldFlags & mysqlEnumFlag) != 0 { fieldType = 247 }
                if (fieldFlags & mysqlSetFlag) != 0 { fieldType = 248 }
                columnTypes.append(fieldType)
                // Extract raw type name
                columnTypeNames.append(mysqlTypeToString(
                    fieldType,
                    length: field.length,
                    flags: fieldFlags
                ))
            }
        }

        // Fetch all rows - CRITICAL: Copy all data to Swift-owned memory
        // before calling mysql_free_result
        var rows: [[String?]] = []
        // Pre-allocate capacity for better performance
        rows.reserveCapacity(1_000)  // Initial capacity

        while let rowPtr = mysql_fetch_row(resultPtr) {
            // Get lengths for each field (needed for binary data)
            let lengths = mysql_fetch_lengths(resultPtr)

            var row: [String?] = []
            row.reserveCapacity(numFields)

            for i in 0..<numFields {
                if let fieldPtr = rowPtr[i] {
                    let lengthValue: UInt = lengths?[i] ?? 0
                    let length = Int(lengthValue)

                    // Create string by explicitly copying bytes to a Swift array first
                    // This ensures complete memory isolation from C buffers
                    var byteArray = [UInt8](repeating: 0, count: length)
                    if length > 0 {
                        memcpy(&byteArray, fieldPtr, length)
                    }

                    if let str = String(bytes: byteArray, encoding: .utf8) {
                        // Create a new string to ensure no shared storage
                        row.append(String(str.unicodeScalars.map { Character($0) }))
                    } else {
                        // Fallback: create string from byte array as Latin1
                        let latin1Str = String(bytes: byteArray, encoding: .isoLatin1) ?? ""
                        row.append(String(latin1Str.unicodeScalars.map { Character($0) }))
                    }
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }

        // Free result set - CRITICAL to avoid memory leaks
        // At this point, ALL string data has been copied to Swift-owned memory
        mysql_free_result(resultPtr)

        return MariaDBQueryResult(
            columns: columns,
            columnTypes: columnTypes,
            columnTypeNames: columnTypeNames,
            rows: rows,
            affectedRows: UInt64(rows.count),
            insertId: 0
        )
    }

    /// Helper struct to manage MYSQL_BIND parameter lifecycle
    private struct ParameterBindings {
        var binds: [MYSQL_BIND]
        var buffers: [UnsafeMutableRawPointer?]

        func cleanup() {
            for buffer in buffers where buffer != nil {
                buffer?.deallocate()
            }
            for bind in binds {
                bind.length?.deallocate()
                bind.is_null?.deallocate()
            }
        }
    }

    /// Bind parameters to a prepared statement
    private func bindParameters(
        _ parameters: [Any?],
        toStatement stmt: UnsafeMutablePointer<MYSQL_STMT>
    ) throws -> ParameterBindings {
        let paramCount = parameters.count
        var binds: [MYSQL_BIND] = Array(repeating: MYSQL_BIND(), count: paramCount)
        var buffers: [UnsafeMutableRawPointer?] = []

        for (index, param) in parameters.enumerated() {
            if let param = param {
                let stringValue: String
                if let str = param as? String {
                    stringValue = str
                } else if let num = param as? any Numeric {
                    stringValue = "\(num)"
                } else {
                    stringValue = "\(param)"
                }

                let data = stringValue.data(using: .utf8) ?? Data()
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 1)
                data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)

                binds[index].buffer_type = MYSQL_TYPE_STRING
                binds[index].buffer = buffer
                binds[index].buffer_length = UInt(data.count)
                binds[index].length = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
                binds[index].length?.pointee = UInt(data.count)
                binds[index].is_null = UnsafeMutablePointer<my_bool>.allocate(capacity: 1)
                binds[index].is_null?.pointee = 0

                buffers.append(buffer)
            } else {
                binds[index].buffer_type = MYSQL_TYPE_NULL
                binds[index].is_null = UnsafeMutablePointer<my_bool>.allocate(capacity: 1)
                binds[index].is_null?.pointee = 1
            }
        }

        if mysql_stmt_bind_param(stmt, &binds) != 0 {
            let bindings = ParameterBindings(binds: binds, buffers: buffers)
            bindings.cleanup()
            throw getStmtError(stmt)
        }

        return ParameterBindings(binds: binds, buffers: buffers)
    }

    /// Fetch result set from a prepared statement
    private func fetchResultSet(
        from stmt: UnsafeMutablePointer<MYSQL_STMT>,
        metadata: UnsafeMutablePointer<MYSQL_RES>,
        columns: [String],
        columnTypes: [UInt32],
        columnTypeNames: [String]
    ) throws -> [[String?]] {
        let numFields = columns.count
        var resultBinds: [MYSQL_BIND] = Array(repeating: MYSQL_BIND(), count: numFields)
        var resultBuffers: [UnsafeMutableRawPointer] = []

        defer {
            for buffer in resultBuffers {
                buffer.deallocate()
            }
            for bind in resultBinds {
                bind.length?.deallocate()
                bind.is_null?.deallocate()
            }
        }

        for i in 0..<numFields {
            let bufferSize = 65_536
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
            resultBuffers.append(buffer)

            resultBinds[i].buffer_type = MYSQL_TYPE_STRING
            resultBinds[i].buffer = buffer
            resultBinds[i].buffer_length = UInt(bufferSize)
            resultBinds[i].length = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
            resultBinds[i].is_null = UnsafeMutablePointer<my_bool>.allocate(capacity: 1)
        }

        if mysql_stmt_bind_result(stmt, &resultBinds) != 0 {
            throw getStmtError(stmt)
        }

        var rows: [[String?]] = []
        while mysql_stmt_fetch(stmt) == 0 {
            var row: [String?] = []
            for i in 0..<numFields {
                if resultBinds[i].is_null?.pointee == 1 {
                    row.append(nil)
                } else {
                    let length = Int(resultBinds[i].length?.pointee ?? 0)
                    let buffer = resultBuffers[i].assumingMemoryBound(to: UInt8.self)
                    let data = Data(bytes: buffer, count: length)
                    if let str = String(data: data, encoding: .utf8) {
                        row.append(String(str.unicodeScalars.map { Character($0) }))
                    } else {
                        row.append(nil)
                    }
                }
            }
            rows.append(row)
        }

        return rows
    }

    /// Synchronous parameterized query execution using prepared statements
    /// MUST be called on the serial queue
    private func executeParameterizedQuerySync(_ query: String, parameters: [Any?]) throws -> MariaDBQueryResult {
        guard !isShuttingDown, let mysql = self.mysql else {
            throw MariaDBError.notConnected
        }

        // Initialize prepared statement
        guard let stmt = mysql_stmt_init(mysql) else {
            throw MariaDBError(code: 0, message: "Failed to initialize prepared statement", sqlState: nil)
        }

        defer {
            mysql_stmt_close(stmt)
        }

        // Prepare the statement
        let prepareResult = query.withCString { queryPtr in
            mysql_stmt_prepare(stmt, queryPtr, UInt(query.utf8.count))
        }

        if prepareResult != 0 {
            throw getStmtError(stmt)
        }

        // Verify parameter count matches
        let paramCount = Int(mysql_stmt_param_count(stmt))
        guard paramCount == parameters.count else {
            throw MariaDBError(
                code: 0,
                message: "Parameter count mismatch: expected \(paramCount), got \(parameters.count)",
                sqlState: nil
            )
        }

        // Bind and execute parameters if any
        if paramCount > 0 {
            let bindings = try bindParameters(parameters, toStatement: stmt)
            defer { bindings.cleanup() }

            if mysql_stmt_execute(stmt) != 0 {
                throw getStmtError(stmt)
            }
        } else {
            if mysql_stmt_execute(stmt) != 0 {
                throw getStmtError(stmt)
            }
        }

        // Check if this is a SELECT query (has result set)
        let fieldCount = Int(mysql_stmt_field_count(stmt))

        if fieldCount == 0 {
            // Non-SELECT query (INSERT, UPDATE, DELETE, etc.)
            let affected = mysql_stmt_affected_rows(stmt)
            let insertId = mysql_stmt_insert_id(stmt)
            return MariaDBQueryResult(
                columns: [],
                columnTypes: [],
                columnTypeNames: [],
                rows: [],
                affectedRows: UInt64(affected),
                insertId: UInt64(insertId)
            )
        }

        // Fetch result metadata
        guard let metadata = mysql_stmt_result_metadata(stmt) else {
            throw MariaDBError(code: 0, message: "Failed to fetch result metadata", sqlState: nil)
        }

        defer {
            mysql_free_result(metadata)
        }

        // Get column information
        var columns: [String] = []
        var columnTypes: [UInt32] = []
        var columnTypeNames: [String] = []
        let numFields = Int(mysql_num_fields(metadata))

        if let fields = mysql_fetch_fields(metadata) {
            for i in 0..<numFields {
                let field = fields[i]
                if let namePtr = field.name {
                    let cStr = String(cString: namePtr)
                    columns.append(String(cStr.unicodeScalars.map { Character($0) }))
                } else {
                    columns.append("column_\(i)")
                }
                let fieldFlags = UInt(field.flags)
                var fieldType = field.type.rawValue
                if (fieldFlags & mysqlEnumFlag) != 0 { fieldType = 247 }
                if (fieldFlags & mysqlSetFlag) != 0 { fieldType = 248 }
                columnTypes.append(fieldType)
                columnTypeNames.append(mysqlTypeToString(
                    fieldType,
                    length: field.length,
                    flags: fieldFlags
                ))
            }
        }

        // Fetch all rows
        let rows = try fetchResultSet(
            from: stmt,
            metadata: metadata,
            columns: columns,
            columnTypes: columnTypes,
            columnTypeNames: columnTypeNames
        )

        return MariaDBQueryResult(
            columns: columns,
            columnTypes: columnTypes,
            columnTypeNames: columnTypeNames,
            rows: rows,
            affectedRows: UInt64(rows.count),
            insertId: 0
        )
    }

    /// Execute a query using streaming (mysql_use_result) for large result sets
    /// Returns rows one at a time via AsyncSequence
    func executeQueryStreaming(_ query: String) async throws -> MariaDBStreamingResult {
        let queryToRun = String(query)

        return try await withCheckedThrowingContinuation { [self] (continuation: CheckedContinuation<MariaDBStreamingResult, Error>) in
            queue.async { [self] in
                guard !isShuttingDown, let mysql = mysql else {
                    continuation.resume(throwing: MariaDBError.notConnected)
                    return
                }

                // Execute query
                let queryResult = queryToRun.withCString { queryPtr in
                    mysql_real_query(mysql, queryPtr, UInt(queryToRun.utf8.count))
                }

                if queryResult != 0 {
                    continuation.resume(throwing: getError())
                    return
                }

                // Use mysql_use_result for streaming (doesn't load entire result into memory)
                guard let resultPtr = mysql_use_result(mysql) else {
                    continuation.resume(throwing: getError())
                    return
                }

                // Get column count
                let numFields = Int(mysql_num_fields(resultPtr))

                // Fetch column names
                var columns: [String] = []
                columns.reserveCapacity(numFields)
                if let fields = mysql_fetch_fields(resultPtr) {
                    for i in 0..<numFields {
                        let field = fields[i]
                        if let namePtr = field.name {
                            let cStr = String(cString: namePtr)
                            columns.append(String(cStr.unicodeScalars.map { Character($0) }))
                        } else {
                            columns.append("column_\(i)")
                        }
                    }
                }

                let streamingResult = MariaDBStreamingResult(
                    resultPtr: resultPtr,
                    columns: columns,
                    numFields: numFields,
                    queue: queue
                )

                continuation.resume(returning: streamingResult)
            }
        }
    }

    // MARK: - Server Information

    /// Get the server version string
    func serverVersion() -> String? {
        queue.sync {
            guard let mysql = mysql else { return nil }
            guard let version = mysql_get_server_info(mysql) else { return nil }
            return String(cString: version)
        }
    }

    /// Get the current database name
    func currentDatabase() -> String {
        database
    }

    // MARK: - Private Helpers

    /// Get the current error from the MySQL handle
    private func getError() -> MariaDBError {
        guard let mysql = mysql else {
            return MariaDBError.notConnected
        }

        let code = mysql_errno(mysql)
        let message: String
        if let msgPtr = mysql_error(mysql) {
            message = String(cString: msgPtr)
        } else {
            message = "Unknown error"
        }

        var sqlState: String?
        if let statePtr = mysql_sqlstate(mysql), statePtr[0] != 0 {
            sqlState = String(cString: statePtr)
        }

        return MariaDBError(code: code, message: message, sqlState: sqlState)
    }

    /// Get error from a prepared statement
    private func getStmtError(_ stmt: UnsafeMutablePointer<MYSQL_STMT>) -> MariaDBError {
        let code = mysql_stmt_errno(stmt)
        let message: String
        if let msgPtr = mysql_stmt_error(stmt) {
            message = String(cString: msgPtr)
        } else {
            message = "Unknown statement error"
        }

        var sqlState: String?
        if let statePtr = mysql_stmt_sqlstate(stmt), statePtr[0] != 0 {
            sqlState = String(cString: statePtr)
        }

        return MariaDBError(code: code, message: message, sqlState: sqlState)
    }
}

// MARK: - Streaming Result

/// Streaming result set for large queries
/// IMPORTANT: Must call close() when done to free resources
final class MariaDBStreamingResult: @unchecked Sendable {
    private var resultPtr: UnsafeMutablePointer<MYSQL_RES>?
    let columns: [String]
    let numFields: Int
    private let queue: DispatchQueue
    private var isClosed = false

    init(
        resultPtr: UnsafeMutablePointer<MYSQL_RES>, columns: [String], numFields: Int,
        queue: DispatchQueue
    ) {
        self.resultPtr = resultPtr
        self.columns = columns
        self.numFields = numFields
        self.queue = queue
    }

    deinit {
        // Ensure cleanup on serial queue
        queue.sync {
            if !isClosed, let ptr = resultPtr {
                mysql_free_result(ptr)
                resultPtr = nil
                isClosed = true
            }
        }
    }

    /// Fetch the next row, returns nil when no more rows
    func fetchNextRow() async -> [String?]? {
        await withCheckedContinuation { [self] (cont: CheckedContinuation<[String?]?, Never>) in
            queue.async { [self] in
                let row = fetchNextRowSync()
                cont.resume(returning: row)
            }
        }
    }

    /// Synchronous row fetch - must be called on the serial queue
    private func fetchNextRowSync() -> [String?]? {
        guard !isClosed, let resultPtr = resultPtr else {
            return nil
        }

        guard let rowPtr = mysql_fetch_row(resultPtr) else {
            return nil
        }

        let lengths = mysql_fetch_lengths(resultPtr)
        var row: [String?] = []
        row.reserveCapacity(numFields)

        for i in 0..<numFields {
            if let fieldPtr = rowPtr[i] {
                let lengthValue: UInt = lengths?[i] ?? 0
                let length = Int(lengthValue)

                // Create string by explicitly copying bytes to a Swift array first
                var byteArray = [UInt8](repeating: 0, count: length)
                if length > 0 {
                    memcpy(&byteArray, fieldPtr, length)
                }

                if let str = String(bytes: byteArray, encoding: .utf8) {
                    row.append(String(str.unicodeScalars.map { Character($0) }))
                } else {
                    let latin1Str = String(bytes: byteArray, encoding: .isoLatin1) ?? ""
                    row.append(String(latin1Str.unicodeScalars.map { Character($0) }))
                }
            } else {
                row.append(nil)
            }
        }

        return row
    }

    /// Close the result set and free resources
    func close() {
        queue.sync {
            guard !isClosed, let ptr = resultPtr else { return }
            mysql_free_result(ptr)
            resultPtr = nil
            isClosed = true
        }
    }
}

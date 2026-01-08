//
//  MariaDBConnection.swift
//  TablePro
//
//  Swift wrapper around libmariadb (MariaDB Connector/C)
//  Provides thread-safe, async-friendly MySQL/MariaDB connections
//

import CMariaDB
import Foundation

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

    init(host: String, port: Int, user: String, password: String?, database: String) {
        self.host = host
        self.port = UInt32(port)
        self.user = user
        self.password = password
        self.database = database
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

                // Configure plugin directory to use bundled plugins
                // Plugins are bundled directly in Resources/ folder
                if let pluginDir = Bundle.main.resourcePath {
                    _ = pluginDir.withCString { pluginDirPtr in
                        mysql_options(mysql, MYSQL_PLUGIN_DIR, pluginDirPtr)
                    }
                }

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

                // Disable SSL requirement - allows connection to servers without SSL
                var sslEnforce: my_bool = 0
                mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)

                // Disable SSL certificate verification
                var sslVerify: my_bool = 0
                mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sslVerify)

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
        columns.reserveCapacity(numFields)

        if let fields = mysql_fetch_fields(resultPtr) {
            for i in 0..<numFields {
                let field = fields[i]
                if let namePtr = field.name {
                    // Create completely independent copy of column name
                    let cStr = String(cString: namePtr)
                    columns.append(String(cStr.unicodeScalars.map { Character($0) }))
                } else {
                    columns.append("column_\(i)")
                }
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

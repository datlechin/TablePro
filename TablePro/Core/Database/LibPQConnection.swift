//
//  LibPQConnection.swift
//  TablePro
//
//  Swift wrapper around libpq (PostgreSQL C API)
//  Provides thread-safe, async-friendly PostgreSQL connections
//

import CLibPQ
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.TablePro", category: "LibPQConnection")

// MARK: - Error Types

/// PostgreSQL error with server error code and message
struct LibPQError: Error, LocalizedError {
    let message: String
    let sqlState: String?
    let detail: String?

    var errorDescription: String? {
        var desc = "PostgreSQL Error: \(message)"
        if let state = sqlState {
            desc += " (SQLSTATE: \(state))"
        }
        if let detail = detail, !detail.isEmpty {
            desc += "\nDetail: \(detail)"
        }
        return desc
    }

    static let notConnected = LibPQError(
        message: "Not connected to database", sqlState: nil, detail: nil)
    static let connectionFailed = LibPQError(
        message: "Failed to establish connection", sqlState: nil, detail: nil)
}

// MARK: - Query Result

/// Result from a PostgreSQL query execution
struct LibPQQueryResult {
    let columns: [String]
    let columnOids: [UInt32]  // PostgreSQL Oid for each column
    let columnTypeNames: [String]  // Raw type names (e.g., "text", "varchar")
    let rows: [[String?]]
    let affectedRows: Int
    let commandTag: String?
    let isTruncated: Bool
}

// MARK: - Type Mapping

/// Converts a PostgreSQL OID value into a human-readable type name string.
/// - Parameter oid: The PostgreSQL object identifier (OID) for the column type.
/// - Returns: The PostgreSQL type name corresponding to the given `oid`, or `"unknown"` if it is not mapped.
/// - SeeAlso: https://www.postgresql.org/docs/current/datatype-oid.html
private func pgOidToTypeName(_ oid: UInt32) -> String {
    switch oid {
    case 16: return "boolean"
    case 17: return "bytea"
    case 18: return "char"
    case 19: return "name"
    case 20: return "bigint"
    case 21: return "smallint"
    case 23: return "integer"
    case 25: return "text"
    case 26: return "oid"
    case 114: return "json"
    case 142: return "xml"
    case 600: return "point"
    case 601: return "lseg"
    case 602: return "path"
    case 603: return "box"
    case 604: return "polygon"
    case 628: return "line"
    case 650: return "cidr"
    case 700: return "real"
    case 701: return "double precision"
    case 718: return "circle"
    case 829: return "macaddr"
    case 869: return "inet"
    case 1_009: return "text[]"
    case 1_042: return "char"
    case 1_043: return "varchar"
    case 1_082: return "date"
    case 1_083: return "time"
    case 1_114: return "timestamp"
    case 1_184: return "timestamptz"
    case 1_266: return "timetz"
    case 1_700: return "numeric"
    case 2_950: return "uuid"
    case 3_802: return "jsonb"
    default: return "unknown"
    }
}

// MARK: - Connection Class

/// Thread-safe PostgreSQL connection using libpq
/// All blocking C calls are dispatched to a dedicated serial queue.
/// Uses `queue.async` + continuations (never `queue.sync`) to prevent deadlocks.
final class LibPQConnection: @unchecked Sendable {
    // MARK: - Properties

    /// The underlying PGconn pointer (opaque handle)
    /// Protected by `stateLock` for reads/writes from any thread
    private var conn: OpaquePointer?

    /// Serial queue for thread-safe access to the C library
    private let queue = DispatchQueue(label: "com.TablePro.libpq", qos: .userInitiated)

    /// Connection parameters
    private let host: String
    private let port: Int
    private let user: String
    private let password: String?
    private let database: String

    /// Lock-protected connection state — avoids `queue.sync` deadlocks
    private let stateLock = NSLock()
    private var _isConnected: Bool = false
    private var _isShuttingDown: Bool = false

    /// Cached server version string, set at connect time on the serial queue
    private var _cachedServerVersion: String?

    /// Cancellation flag — set from any thread, checked in row-fetch loops
    private var _isCancelled: Bool = false

    /// Thread-safe connection state accessor
    var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isConnected
    }

    /// Thread-safe shutdown flag accessor
    private var isShuttingDown: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isShuttingDown
        }
        set {
            stateLock.lock()
            _isShuttingDown = newValue
            stateLock.unlock()
        }
    }

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
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.sslConfig = sslConfig
    }

    deinit {
        // Capture the handle and queue to clean up asynchronously.
        // By the time deinit runs, no other references exist, so the
        // dispatched block is the sole owner of the pointer.
        let handle = conn
        let cleanupQueue = queue
        conn = nil
        if let handle = handle {
            cleanupQueue.async {
                PQfinish(handle)
            }
        }
    }

    // MARK: - Connection Management

    /// Connect to the PostgreSQL server
    /// - Throws: LibPQError if connection fails
    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                // Build connection string
                // Escape values for libpq key=value format (backslash and single quote)
                func escapeConnParam(_ value: String) -> String {
                    value.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "'", with: "\\'")
                }

                var connStr = "host='\(escapeConnParam(host))' port='\(port)' dbname='\(escapeConnParam(database))' connect_timeout='10'"

                if !user.isEmpty {
                    connStr += " user='\(escapeConnParam(user))'"
                }

                if let password = password, !password.isEmpty {
                    connStr += " password='\(escapeConnParam(password))'"
                }

                // SSL/TLS configuration
                switch self.sslConfig.mode {
                case .disabled:
                    connStr += " sslmode='disable'"
                case .preferred:
                    connStr += " sslmode='prefer'"
                case .required:
                    connStr += " sslmode='require'"
                case .verifyCa:
                    connStr += " sslmode='verify-ca'"
                case .verifyIdentity:
                    connStr += " sslmode='verify-full'"
                }

                if self.sslConfig.verifiesCertificate, !self.sslConfig.caCertificatePath.isEmpty {
                    connStr += " sslrootcert='\(escapeConnParam(self.sslConfig.caCertificatePath))'"
                }
                if !self.sslConfig.clientCertificatePath.isEmpty {
                    connStr += " sslcert='\(escapeConnParam(self.sslConfig.clientCertificatePath))'"
                }
                if !self.sslConfig.clientKeyPath.isEmpty {
                    connStr += " sslkey='\(escapeConnParam(self.sslConfig.clientKeyPath))'"
                }

                // Connect to PostgreSQL server
                let connection = connStr.withCString { cStr in
                    PQconnectdb(cStr)
                }

                guard let connection = connection else {
                    continuation.resume(throwing: LibPQError.connectionFailed)
                    return
                }

                // Check connection status
                if PQstatus(connection) != CONNECTION_OK {
                    let error = getError(from: connection)
                    PQfinish(connection)
                    continuation.resume(throwing: error)
                    return
                }

                // Set client encoding to UTF-8
                _ = "SET client_encoding TO 'UTF8'".withCString { cStr in
                    PQexec(connection, cStr)
                }

                // Cache server version while on the serial queue
                let version = PQserverVersion(connection)
                if version > 0 {
                    let major = version / 10_000
                    let minor = (version / 100) % 100
                    let revision = version % 100
                    self._cachedServerVersion = "\(major).\(minor).\(revision)"
                }

                self.stateLock.lock()
                self.conn = connection
                self._isConnected = true
                self.stateLock.unlock()
                continuation.resume()
            }
        }
    }

    /// Disconnect from the server
    func disconnect() {
        isShuttingDown = true

        stateLock.lock()
        _isConnected = false
        let handle = conn
        conn = nil
        stateLock.unlock()

        _cachedServerVersion = nil

        if let handle {
            queue.async {
                PQfinish(handle)
            }
        }
    }

    // MARK: - Query Cancellation

    /// Cancel the currently running query using PQcancel.
    /// Sets a flag checked in row-fetch loops and sends a cancel request to the server.
    func cancelCurrentQuery() {
        stateLock.lock()
        _isCancelled = true
        let currentConn = conn
        stateLock.unlock()

        guard let currentConn else { return }
        let cancelObj = PQgetCancel(currentConn)
        guard let cancelObj else { return }
        defer { PQfreeCancel(cancelObj) }

        var errbuf = [CChar](repeating: 0, count: 256)
        PQcancel(cancelObj, &errbuf, Int32(errbuf.count))
    }

    // MARK: - Query Execution

    /// Execute a SQL query and fetch all results
    /// - Parameter query: SQL query string
    /// - Returns: Query result with columns and rows
    /// - Throws: LibPQError on failure
    func executeQuery(_ query: String) async throws -> LibPQQueryResult {
        // Capture query string to avoid potential issues with closure capture
        let queryToRun = String(query)

        return try await withCheckedThrowingContinuation { [self] (cont: CheckedContinuation<LibPQQueryResult, Error>) in
            queue.async { [self] in
                // Check if shutting down
                guard !isShuttingDown else {
                    cont.resume(throwing: LibPQError.notConnected)
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
    /// PostgreSQL uses $1, $2, etc. as placeholders
    /// - Parameters:
    ///   - query: SQL query with $1, $2, etc. placeholders
    ///   - parameters: Array of parameter values to bind
    /// - Returns: Query result
    /// - Throws: LibPQError on failure
    func executeParameterizedQuery(_ query: String, parameters: [Any?]) async throws -> LibPQQueryResult {
        let queryToRun = String(query)
        let params = parameters

        return try await withCheckedThrowingContinuation { [self] (cont: CheckedContinuation<LibPQQueryResult, Error>) in
            queue.async { [self] in
                guard !isShuttingDown else {
                    cont.resume(throwing: LibPQError.notConnected)
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
    private func executeQuerySync(_ query: String) throws -> LibPQQueryResult {
        stateLock.lock()
        let conn = self.conn
        stateLock.unlock()

        guard !isShuttingDown, let conn else {
            throw LibPQError.notConnected
        }

        // Execute query
        // TODO: (DB-2) PQexec buffers the entire result set in libpq memory before
        // the Swift-level row cap takes effect. To stream results, switch to
        // PQsendQuery + PQsetSingleRowMode + PQgetResult loop, which delivers one
        // row at a time. This is a significant API change — deferred for now.
        let localQuery = String(query)
        let result: OpaquePointer? = localQuery.withCString { queryPtr in
            PQexec(conn, queryPtr)
        }

        guard let result = result else {
            throw getError(from: conn)
        }

        // Check result status
        let status = PQresultStatus(result)

        switch status {
        case PGRES_COMMAND_OK:
            // Non-SELECT query (INSERT, UPDATE, DELETE, etc.)
            let affected = getAffectedRows(from: result)
            let cmdTag = getCommandTag(from: result)
            PQclear(result)
            return LibPQQueryResult(
                columns: [],
                columnOids: [],
                columnTypeNames: [],
                rows: [],
                affectedRows: affected,
                commandTag: cmdTag,
                isTruncated: false
            )

        case PGRES_TUPLES_OK:
            // SELECT query - fetch results
            let queryResult = try fetchResults(from: result)
            PQclear(result)
            return queryResult

        default:
            // Error occurred
            let error = getResultError(from: result)
            PQclear(result)
            throw error
        }
    }

    /// Synchronous parameterized query execution using PQexecParams
    /// MUST be called on the serial queue
    private func executeParameterizedQuerySync(_ query: String, parameters: [Any?]) throws -> LibPQQueryResult {
        stateLock.lock()
        let conn = self.conn
        stateLock.unlock()

        guard !isShuttingDown, let conn else {
            throw LibPQError.notConnected
        }

        // Convert parameters to C strings
        var paramValues: [UnsafePointer<CChar>?] = []
        var paramStrings: [String] = []

        defer {
            // Free strdup-allocated C strings — must use free(), not deallocate(),
            // because strdup uses malloc internally
            for ptr in paramValues {
                if let ptr = ptr {
                    free(UnsafeMutablePointer(mutating: ptr))
                }
            }
        }

        for param in parameters {
            if let param = param {
                // Convert parameter to string
                let stringValue: String
                if let str = param as? String {
                    stringValue = str
                } else {
                    stringValue = "\(param)"
                }
                paramStrings.append(stringValue)

                // Allocate and copy C string
                let cStr = strdup(stringValue)
                paramValues.append(UnsafePointer(cStr))
            } else {
                // NULL parameter
                paramValues.append(nil)
            }
        }

        // Execute parameterized query using PQexecParams
        let localQuery = String(query)
        let result: OpaquePointer? = localQuery.withCString { queryPtr in
            PQexecParams(
                conn,
                queryPtr,
                Int32(parameters.count),
                nil,  // paramTypes (NULL = infer types)
                paramValues,  // paramValues
                nil,  // paramLengths (NULL = text format)
                nil,  // paramFormats (NULL = all text)
                0  // resultFormat (0 = text)
            )
        }

        guard let result = result else {
            throw getError(from: conn)
        }

        // Check result status
        let status = PQresultStatus(result)

        switch status {
        case PGRES_COMMAND_OK:
            // Non-SELECT query (INSERT, UPDATE, DELETE, etc.)
            let affected = getAffectedRows(from: result)
            let cmdTag = getCommandTag(from: result)
            PQclear(result)
            return LibPQQueryResult(
                columns: [],
                columnOids: [],
                columnTypeNames: [],
                rows: [],
                affectedRows: affected,
                commandTag: cmdTag,
                isTruncated: false
            )

        case PGRES_TUPLES_OK:
            // SELECT query - fetch results
            let queryResult = try fetchResults(from: result)
            PQclear(result)
            return queryResult

        default:
            // Error occurred
            let error = getResultError(from: result)
            PQclear(result)
            throw error
        }
    }

    // MARK: - Result Parsing

    /// Fetch all results from a PGresult
    private func fetchResults(from result: OpaquePointer) throws -> LibPQQueryResult {
        let numFields = Int(PQnfields(result))
        let numRows = Int(PQntuples(result))

        // Fetch column names and types
        var columns: [String] = []
        var columnOids: [UInt32] = []
        var columnTypeNames: [String] = []
        columns.reserveCapacity(numFields)
        columnOids.reserveCapacity(numFields)
        columnTypeNames.reserveCapacity(numFields)

        for i in 0..<numFields {
            // Extract column name
            if let namePtr = PQfname(result, Int32(i)) {
                columns.append(String(cString: namePtr))
            } else {
                columns.append("column_\(i)")
            }

            // Extract column type Oid (NEW)
            let oid = PQftype(result, Int32(i))
            columnOids.append(UInt32(oid))
            columnTypeNames.append(pgOidToTypeName(UInt32(oid)))
        }

        // Fetch rows with row limit
        let maxRows = DriverRowLimits.defaultMax
        let effectiveRowCount = min(numRows, maxRows)
        let truncated = numRows > maxRows

        var rows: [[String?]] = []
        rows.reserveCapacity(effectiveRowCount)

        for rowIndex in 0..<effectiveRowCount {
            // Check cancellation flag (atomic read-then-clear via stateLock)
            stateLock.lock()
            let shouldCancel = _isCancelled
            if shouldCancel { _isCancelled = false }
            stateLock.unlock()
            if shouldCancel {
                PQclear(result)
                throw LibPQError(message: "Query cancelled", sqlState: nil, detail: nil)
            }

            var row: [String?] = []
            row.reserveCapacity(numFields)

            for colIndex in 0..<numFields {
                if PQgetisnull(result, Int32(rowIndex), Int32(colIndex)) == 1 {
                    row.append(nil)
                } else if let valuePtr = PQgetvalue(result, Int32(rowIndex), Int32(colIndex)) {
                    let length = Int(PQgetlength(result, Int32(rowIndex), Int32(colIndex)))

                    // Pass C pointer directly to String via UnsafeBufferPointer
                    // Avoids intermediate [UInt8] allocation — String copies internally
                    let bufferPtr = UnsafeRawBufferPointer(start: valuePtr, count: length)

                    if let str = String(bytes: bufferPtr, encoding: .utf8) {
                        // Boolean OID (16): convert "t"/"f" to "true"/"false"
                        if columnOids[colIndex] == 16 {
                            row.append(str == "t" ? "true" : "false")
                        } else {
                            row.append(str)
                        }
                    } else {
                        // Fallback: create string from buffer as Latin1
                        row.append(String(bytes: bufferPtr, encoding: .isoLatin1) ?? "")
                    }
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }

        if truncated {
            logger.warning("Result set truncated at \(maxRows) rows (DriverRowLimits.defaultMax)")
        }

        return LibPQQueryResult(
            columns: columns,
            columnOids: columnOids,
            columnTypeNames: columnTypeNames,
            rows: rows,
            affectedRows: numRows,
            commandTag: getCommandTag(from: result),
            isTruncated: truncated
        )
    }

    // MARK: - Server Information

    /// Get the server version string (cached at connect time)
    func serverVersion() -> String? {
        _cachedServerVersion
    }

    /// Get the current database name
    func currentDatabase() -> String {
        database
    }

    // MARK: - Private Helpers

    /// Get the current error from the connection handle
    private func getError(from conn: OpaquePointer) -> LibPQError {
        var message = "Unknown error"
        if let msgPtr = PQerrorMessage(conn) {
            message = String(cString: msgPtr).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return LibPQError(message: message, sqlState: nil, detail: nil)
    }

    /// Get error from a result handle
    private func getResultError(from result: OpaquePointer) -> LibPQError {
        var message = "Unknown error"
        var sqlState: String?
        var detail: String?

        if let msgPtr = PQresultErrorMessage(result) {
            message = String(cString: msgPtr).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let statePtr = PQresultErrorField(result, Int32(80)) {  // 'P' = PG_DIAG_SQLSTATE
            sqlState = String(cString: statePtr)
        }

        if let detailPtr = PQresultErrorField(result, Int32(68)) {  // 'D' = PG_DIAG_MESSAGE_DETAIL
            detail = String(cString: detailPtr)
        }

        return LibPQError(message: message, sqlState: sqlState, detail: detail)
    }

    /// Get affected rows from a result
    private func getAffectedRows(from result: OpaquePointer) -> Int {
        if let affectedPtr = PQcmdTuples(result), affectedPtr.pointee != 0 {
            return Int(String(cString: affectedPtr)) ?? 0
        }
        return 0
    }

    /// Get command tag from a result
    private func getCommandTag(from result: OpaquePointer) -> String? {
        if let tagPtr = PQcmdStatus(result), tagPtr.pointee != 0 {
            return String(cString: tagPtr)
        }
        return nil
    }
}

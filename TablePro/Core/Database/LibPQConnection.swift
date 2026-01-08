//
//  LibPQConnection.swift
//  TablePro
//
//  Swift wrapper around libpq (PostgreSQL C API)
//  Provides thread-safe, async-friendly PostgreSQL connections
//

import CLibPQ
import Foundation

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
    let rows: [[String?]]
    let affectedRows: Int
    let commandTag: String?
}

// MARK: - Connection Class

/// Thread-safe PostgreSQL connection using libpq
/// All blocking C calls are dispatched to a dedicated serial queue
final class LibPQConnection: @unchecked Sendable {
    // MARK: - Properties

    /// The underlying PGconn pointer (opaque handle)
    /// Access only through the serial queue
    private var conn: OpaquePointer?

    /// Serial queue for thread-safe access to the C library
    private let queue = DispatchQueue(label: "com.TablePro.libpq", qos: .userInitiated)

    /// Connection parameters
    private let host: String
    private let port: Int
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
        self.port = port
        self.user = user
        self.password = password
        self.database = database
    }

    deinit {
        // Ensure all pending queue work completes before cleanup
        queue.sync {
            if let conn = conn {
                PQfinish(conn)
            }
            conn = nil
        }
    }

    // MARK: - Connection Management

    /// Connect to the PostgreSQL server
    /// - Throws: LibPQError if connection fails
    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                // Build connection string
                var connStr = "host='\(host)' port='\(port)' dbname='\(database)'"

                if !user.isEmpty {
                    connStr += " user='\(user)'"
                }

                if let password = password, !password.isEmpty {
                    connStr += " password='\(password)'"
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

                self.conn = connection
                self._isConnected = true
                continuation.resume()
            }
        }
    }

    /// Disconnect from the server
    func disconnect() {
        queue.sync {
            isShuttingDown = true
            if let conn = conn {
                PQfinish(conn)
            }
            conn = nil
            _isConnected = false
        }
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

    /// Synchronous query execution - must be called on the serial queue
    private func executeQuerySync(_ query: String) throws -> LibPQQueryResult {
        guard !isShuttingDown, let conn = self.conn else {
            throw LibPQError.notConnected
        }

        // Execute query
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
                rows: [],
                affectedRows: affected,
                commandTag: cmdTag
            )

        case PGRES_TUPLES_OK:
            // SELECT query - fetch results
            let queryResult = fetchResults(from: result)
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
    private func fetchResults(from result: OpaquePointer) -> LibPQQueryResult {
        let numFields = Int(PQnfields(result))
        let numRows = Int(PQntuples(result))

        // Fetch column names
        var columns: [String] = []
        columns.reserveCapacity(numFields)

        for i in 0..<numFields {
            if let namePtr = PQfname(result, Int32(i)) {
                let cStr = String(cString: namePtr)
                columns.append(String(cStr.unicodeScalars.map { Character($0) }))
            } else {
                columns.append("column_\(i)")
            }
        }

        // Fetch all rows
        var rows: [[String?]] = []
        rows.reserveCapacity(numRows)

        for rowIndex in 0..<numRows {
            var row: [String?] = []
            row.reserveCapacity(numFields)

            for colIndex in 0..<numFields {
                if PQgetisnull(result, Int32(rowIndex), Int32(colIndex)) == 1 {
                    row.append(nil)
                } else if let valuePtr = PQgetvalue(result, Int32(rowIndex), Int32(colIndex)) {
                    let length = Int(PQgetlength(result, Int32(rowIndex), Int32(colIndex)))

                    // Create string by explicitly copying bytes to a Swift array first
                    // This ensures complete memory isolation from C buffers
                    var byteArray = [UInt8](repeating: 0, count: length)
                    if length > 0 {
                        memcpy(&byteArray, valuePtr, length)
                    }

                    if let str = String(bytes: byteArray, encoding: .utf8) {
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

        return LibPQQueryResult(
            columns: columns,
            rows: rows,
            affectedRows: numRows,
            commandTag: getCommandTag(from: result)
        )
    }

    // MARK: - Server Information

    /// Get the server version string
    func serverVersion() -> String? {
        queue.sync {
            guard let conn = conn else { return nil }
            let version = PQserverVersion(conn)
            // Return nil if not connected (version == 0)
            guard version > 0 else { return nil }
            // Format: XXYYYZZ where XX is major, YYY is minor, ZZ is revision
            let major = version / 10_000
            let minor = (version / 100) % 100
            let revision = version % 100
            return "\(major).\(minor).\(revision)"
        }
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

//
//  FreeTDSConnection.swift
//  TablePro
//
//  Swift wrapper around FreeTDS db-lib (sybdb) C API.
//  Provides thread-safe, async-friendly SQL Server connections.
//

import CFreeTDS
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.TablePro", category: "FreeTDSConnection")

// MARK: - Global FreeTDS initialization

/// Last error captured by the FreeTDS error/message handlers — surfaced in connection failures
private let freetdsLastErrorLock = NSLock()
private var _freetdsLastError = ""

var freetdsLastError: String {
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

private let freetdsInitOnce: Void = {
    _ = dbinit()
    _ = dberrhandle { _, _, dberr, _, dberrstr, oserrstr in
        var msg = "db-lib error \(dberr)"
        if let s = dberrstr { msg += ": \(String(cString: s))" }
        if let s = oserrstr, String(cString: s) != "Success" { msg += " (os: \(String(cString: s)))" }
        logger.error("FreeTDS: \(msg)")
        // Preserve SQL Server message set by dbmsghandle — it's more descriptive than the db-lib wrapper
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
            logger.error("FreeTDS msg \(msgno) sev \(severity): \(msg)")
        } else {
            logger.debug("FreeTDS msg \(msgno): \(msg)")
        }
        return 0
    }
}()

// MARK: - Error Types

/// FreeTDS db-lib error with descriptive message
struct FreeTDSError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { "SQL Server Error: \(message)" }

    static let notConnected = FreeTDSError(message: "Not connected to database")
    static let connectionFailed = FreeTDSError(message: "Failed to establish connection")
    static let queryFailed = FreeTDSError(message: "Query execution failed")
}

// MARK: - Query Result

/// Result from a FreeTDS db-lib query execution
struct FreeTDSQueryResult {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[String?]]
    let affectedRows: Int
}

// MARK: - Connection Class

/// Thread-safe SQL Server connection using FreeTDS db-lib.
/// All blocking C calls are dispatched to a dedicated serial queue.
/// Uses `queue.async` + continuations (never `queue.sync`) to prevent deadlocks.
final class FreeTDSConnection: @unchecked Sendable {
    // MARK: - Properties

    /// The underlying DBPROCESS pointer
    /// Access only through the serial queue
    private var dbproc: UnsafeMutablePointer<DBPROCESS>?

    /// Serial queue for thread-safe access to the C library
    private let queue: DispatchQueue

    /// Connection parameters
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let database: String

    /// Lock-protected connection state — avoids `queue.sync` deadlocks
    private let lock = NSLock()
    private var _isConnected = false

    /// Thread-safe connection state accessor
    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    // MARK: - Initialization

    init(host: String, port: Int, user: String, password: String, database: String) {
        self.queue = DispatchQueue(label: "com.TablePro.freetds.\(host).\(port)", qos: .userInitiated)
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        _ = freetdsInitOnce
    }

    // MARK: - Connection

    /// Connect to SQL Server asynchronously
    /// - Throws: FreeTDSError if connection fails
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

    /// Synchronous connect — must be called on the serial queue
    private func connectSync() throws {
        guard let login = dblogin() else {
            throw FreeTDSError.connectionFailed
        }
        defer { dbloginfree(login) }

        _ = dbsetlname(login, user, Int32(DBSETUSER))
        _ = dbsetlname(login, password, Int32(DBSETPWD))
        _ = dbsetlname(login, "TablePro", Int32(DBSETAPP))
        _ = dbsetlversion(login, UInt8(DBVERSION_74))

        // FreeTDS db-lib accepts "host:port" as the server name for direct TCP connections
        freetdsLastError = ""
        let serverName = "\(host):\(port)"
        guard let proc = dbopen(login, serverName) else {
            let detail = freetdsLastError.isEmpty ? "Check host, port, and credentials" : freetdsLastError
            throw FreeTDSError(message: "Failed to connect to \(host):\(port) — \(detail)")
        }
        logger.debug("Connected to \(serverName)")

        if !database.isEmpty {
            if dbuse(proc, database) == FAIL {
                _ = dbclose(proc)
                throw FreeTDSError(message: "Cannot open database '\(database)'")
            }
        }

        self.dbproc = proc
        lock.lock()
        _isConnected = true
        lock.unlock()
    }

    /// Switch to a different database on the existing connection
    func switchDatabase(_ database: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let proc = self.dbproc else {
                    continuation.resume(throwing: FreeTDSError.notConnected)
                    return
                }
                if dbuse(proc, database) == FAIL {
                    continuation.resume(throwing: FreeTDSError(message: "Cannot switch to database '\(database)'"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Disconnect from SQL Server
    func disconnect() {
        // Capture handle for async cleanup — avoids queue.sync deadlock
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

    // MARK: - Query Execution

    /// Execute a SQL query and fetch all results
    /// - Parameter query: SQL query string
    /// - Returns: FreeTDSQueryResult with columns and rows
    /// - Throws: FreeTDSError on failure
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

    /// Synchronous query execution — must be called on the serial queue
    private func executeQuerySync(_ query: String) throws -> FreeTDSQueryResult {
        guard let proc = dbproc else {
            throw FreeTDSError.notConnected
        }

        // Cancel any pending results before issuing new command
        _ = dbcanquery(proc)

        freetdsLastError = ""
        if dbcmd(proc, query) == FAIL {
            throw FreeTDSError(message: "Failed to prepare query")
        }
        if dbsqlexec(proc) == FAIL {
            let detail = freetdsLastError.isEmpty ? "Query execution failed" : freetdsLastError
            throw FreeTDSError(message: detail)
        }

        var allColumns: [String] = []
        var allTypeNames: [String] = []
        var allRows: [[String?]] = []
        var firstResultSet = true

        while true {
            let resCode = dbresults(proc)
            if resCode == FAIL {
                throw FreeTDSError.queryFailed
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
                typeNames.append(freetdsTypeName(dbcoltype(proc, Int32(i))))
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
                        let str = columnValueAsString(proc: proc, ptr: ptr, srcType: colType, srcLen: len)
                        row.append(str)
                    } else {
                        row.append(nil)
                    }
                }
                allRows.append(row)
            }
        }

        // For SELECT results (columns present) report the fetched row count.
        // For DML statements (INSERT/UPDATE/DELETE), columns are empty and allRows.count
        // reflects nothing useful — report 0 since dbcount() is not available in the stub.
        let affectedRows = allColumns.isEmpty ? 0 : allRows.count
        return FreeTDSQueryResult(
            columns: allColumns,
            columnTypeNames: allTypeNames,
            rows: allRows,
            affectedRows: affectedRows
        )
    }

    // MARK: - Private Helpers

    /// Convert a raw column value to String using dbconvert for non-text types.
    /// Text/nvarchar types are decoded directly as UTF-8 or UTF-16LE; all others go through dbconvert to SYBCHAR.
    private func columnValueAsString(proc: UnsafeMutablePointer<DBPROCESS>, ptr: UnsafePointer<BYTE>, srcType: Int32, srcLen: DBINT) -> String? {
        switch srcType {
        case Int32(SYBCHAR), Int32(SYBVARCHAR), Int32(SYBTEXT):
            return String(bytes: UnsafeBufferPointer(start: ptr, count: Int(srcLen)), encoding: .utf8)
                ?? String(bytes: UnsafeBufferPointer(start: ptr, count: Int(srcLen)), encoding: .isoLatin1)
        case Int32(SYBNCHAR), Int32(SYBNVARCHAR), Int32(SYBNTEXT):
            // UTF-16LE encoded Unicode text
            let data = Data(bytes: ptr, count: Int(srcLen))
            return String(data: data, encoding: .utf16LittleEndian)
        default:
            // Use dbconvert to convert numeric/binary/date types to a character string
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

    private func freetdsTypeName(_ type: Int32) -> String {
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
        // Note: datetime2, date, and time constants are not present in the FreeTDS stub header.
        case Int32(SYBUNIQUE): return "uniqueidentifier"
        default: return "unknown"
        }
    }
}

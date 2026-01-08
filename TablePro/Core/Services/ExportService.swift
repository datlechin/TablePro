//
//  ExportService.swift
//  TablePro
//
//  Service responsible for exporting table data to CSV, JSON, and SQL formats.
//  Supports configurable options for each format including compression.
//

import Combine
import Foundation

// MARK: - Export Error

/// Errors that can occur during export operations
enum ExportError: LocalizedError {
    case notConnected
    case noTablesSelected
    case exportFailed(String)
    case compressionFailed
    case fileWriteFailed(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to database"
        case .noTablesSelected:
            return "No tables selected for export"
        case .exportFailed(let message):
            return "Export failed: \(message)"
        case .compressionFailed:
            return "Failed to compress data"
        case .fileWriteFailed(let path):
            return "Failed to write file: \(path)"
        case .encodingFailed:
            return "Failed to encode content as UTF-8"
        }
    }
}

// MARK: - String Extension for Safe Encoding

private extension String {
    /// Safely encode string to UTF-8 data, throwing if encoding fails
    func toUTF8Data() throws -> Data {
        guard let data = self.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        return data
    }
}

// MARK: - Export Service

/// Service responsible for exporting table data to various formats
@MainActor
final class ExportService: ObservableObject {
    // MARK: - Published State

    @Published var isExporting: Bool = false
    @Published var progress: Double = 0.0
    @Published var currentTable: String = ""
    @Published var currentTableIndex: Int = 0
    @Published var totalTables: Int = 0
    @Published var processedRows: Int = 0
    @Published var totalRows: Int = 0
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?
    /// Non-fatal warnings that occurred during export (e.g., DDL fetch failures)
    @Published var warningMessage: String?

    // MARK: - DDL Failure Tracking

    /// Tables that failed DDL fetch during SQL export
    private var ddlFailures: [String] = []

    // MARK: - Cancellation

    private let isCancelledLock = NSLock()
    private var _isCancelled: Bool = false
    private var isCancelled: Bool {
        get {
            isCancelledLock.lock()
            defer { isCancelledLock.unlock() }
            return _isCancelled
        }
        set {
            isCancelledLock.lock()
            _isCancelled = newValue
            isCancelledLock.unlock()
        }
    }

    // MARK: - Progress Throttling

    /// Number of rows to process before updating UI
    private let progressUpdateInterval: Int = 1_000
    /// Internal counter for processed rows (updated every row)
    private var internalProcessedRows: Int = 0

    // MARK: - Dependencies

    private let driver: DatabaseDriver
    private let databaseType: DatabaseType

    // MARK: - Initialization

    init(driver: DatabaseDriver, databaseType: DatabaseType) {
        self.driver = driver
        self.databaseType = databaseType
    }

    // MARK: - Public API

    /// Cancel the current export operation
    func cancelExport() {
        isCancelled = true
    }

    /// Export selected tables to the specified URL
    /// - Parameters:
    ///   - tables: Array of table items to export (with SQL options for SQL format)
    ///   - config: Export configuration with format and options
    ///   - url: Destination file URL
    func export(
        tables: [ExportTableItem],
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        guard !tables.isEmpty else {
            throw ExportError.noTablesSelected
        }

        // Reset state
        isExporting = true
        isCancelled = false
        progress = 0.0
        processedRows = 0
        internalProcessedRows = 0
        totalRows = 0
        totalTables = tables.count
        currentTableIndex = 0
        statusMessage = ""
        errorMessage = nil
        warningMessage = nil
        ddlFailures = []

        defer {
            isExporting = false
            isCancelled = false
            statusMessage = ""
        }

        // Fetch total row counts for all tables
        totalRows = await fetchTotalRowCount(for: tables)

        do {
            switch config.format {
            case .csv:
                try await exportToCSV(tables: tables, config: config, to: url)
            case .json:
                try await exportToJSON(tables: tables, config: config, to: url)
            case .sql:
                try await exportToSQL(tables: tables, config: config, to: url)
            }
        } catch {
            // Clean up partial file on cancellation or error
            try? FileManager.default.removeItem(at: url)
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Fetch total row count for all tables.
    /// - Returns: The total row count across all tables. Any failures are logged but do not affect the returned value.
    /// - Note: When row count fails for some tables, the statusMessage is updated to inform the user that progress is estimated.
    private func fetchTotalRowCount(for tables: [ExportTableItem]) async -> Int {
        var total = 0
        var failedCount = 0
        for table in tables {
            let tableRef = qualifiedTableRef(for: table)
            do {
                let result = try await driver.execute(query: "SELECT COUNT(*) FROM \(tableRef)")
                if let countStr = result.rows.first?.first, let count = Int(countStr ?? "0") {
                    total += count
                }
            } catch {
                // Log the error but continue - progress will be less accurate
                failedCount += 1
                print("Warning: Failed to get row count for \(table.qualifiedName): \(error.localizedDescription)")
            }
        }
        if failedCount > 0 {
            print("Warning: \(failedCount) table(s) failed row count - progress indicator may be inaccurate")
            // Update status message so user knows progress is estimated
            statusMessage = "Progress estimated (\(failedCount) table\(failedCount > 1 ? "s" : "") could not be counted)"
        }
        return total
    }

    /// Check if export was cancelled and throw if so
    private func checkCancellation() throws {
        if isCancelled {
            throw NSError(
                domain: "ExportService",
                code: NSUserCancelledError,
                userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]
            )
        }
    }

    /// Increment processed rows with throttled UI updates
    /// Only updates @Published properties every `progressUpdateInterval` rows
    /// Uses Task.yield() to allow UI to refresh
    private func incrementProgress() async {
        internalProcessedRows += 1

        // Only update UI every N rows
        if internalProcessedRows % progressUpdateInterval == 0 {
            processedRows = internalProcessedRows
            if totalRows > 0 {
                progress = Double(internalProcessedRows) / Double(totalRows)
            }
            // Yield to allow UI to update
            await Task.yield()
        }
    }

    /// Finalize progress for current table (ensures UI shows final count)
    private func finalizeTableProgress() async {
        processedRows = internalProcessedRows
        if totalRows > 0 {
            progress = Double(internalProcessedRows) / Double(totalRows)
        }
        // Yield to allow UI to update
        await Task.yield()
    }

    // MARK: - Helpers

    /// Build fully qualified and quoted table reference (database.table or just table)
    private func qualifiedTableRef(for table: ExportTableItem) -> String {
        if table.databaseName.isEmpty {
            return databaseType.quoteIdentifier(table.name)
        } else {
            let quotedDb = databaseType.quoteIdentifier(table.databaseName)
            let quotedTable = databaseType.quoteIdentifier(table.name)
            return "\(quotedDb).\(quotedTable)"
        }
    }

    /// Sanitize a name for use in SQL comments to prevent comment injection
    ///
    /// Removes characters that could break out of or nest SQL comments:
    /// - Newlines (could start new SQL statements)
    /// - Comment sequences (/* */ --)
    ///
    /// Logs a warning when the name is modified.
    private func sanitizeForSQLComment(_ name: String) -> String {
        var result = name
        // Replace newlines with spaces
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(of: "\r", with: " ")
        // Remove comment sequences (both opening and closing)
        result = result.replacingOccurrences(of: "/*", with: "")
        result = result.replacingOccurrences(of: "*/", with: "")
        result = result.replacingOccurrences(of: "--", with: "")

        // Log when sanitization modifies the name
        if result != name {
            print("Warning: Table name '\(name)' was sanitized to '\(result)' for SQL comment safety")
        }

        return result
    }

    // MARK: - File Helpers

    /// Create a file at the given URL and return a FileHandle for writing
    private func createFileHandle(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ExportError.fileWriteFailed(url.path)
        }
        return try FileHandle(forWritingTo: url)
    }

    /// Close a file handle with error logging instead of silent suppression
    ///
    /// Used in defer blocks where we can't throw but want visibility into failures.
    private func closeFileHandle(_ handle: FileHandle) {
        do {
            try handle.close()
        } catch {
            print("Warning: Failed to close export file handle: \(error.localizedDescription)")
        }
    }

    // MARK: - CSV Export

    private func exportToCSV(
        tables: [ExportTableItem],
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        // Create file and get handle for streaming writes
        let fileHandle = try createFileHandle(at: url)
        defer { closeFileHandle(fileHandle) }

        let lineBreak = config.csvOptions.lineBreak.value

        for (index, table) in tables.enumerated() {
            try checkCancellation()

            currentTableIndex = index + 1
            currentTable = table.qualifiedName

            // Add table header comment if multiple tables
            // Sanitize name to prevent newlines from breaking the comment line
            if tables.count > 1 {
                let sanitizedName = sanitizeForSQLComment(table.qualifiedName)
                try fileHandle.write(contentsOf: "# Table: \(sanitizedName)\n".toUTF8Data())
            }

            // Fetch data from table in batches to avoid loading everything into memory
            let tableRef = qualifiedTableRef(for: table)
            let batchSize = 10_000
            var offset = 0
            var isFirstBatch = true

            while true {
                try checkCancellation()

                let query = "SELECT * FROM \(tableRef) LIMIT \(batchSize) OFFSET \(offset)"
                let result = try await driver.execute(query: query)

                // No more rows to process
                if result.rows.isEmpty {
                    break
                }

                // Stream CSV content for this batch directly to file
                // Only include headers on the first batch to avoid duplication
                var batchOptions = config.csvOptions
                if !isFirstBatch {
                    batchOptions.includeFieldNames = false
                }

                try await writeCSVContentWithProgress(
                    columns: result.columns,
                    rows: result.rows,
                    options: batchOptions,
                    to: fileHandle
                )

                isFirstBatch = false
                offset += batchSize
            }
            if index < tables.count - 1 {
                try fileHandle.write(contentsOf: "\(lineBreak)\(lineBreak)".toUTF8Data())
            }
        }

        try checkCancellation()
        progress = 1.0
    }

    private func writeCSVContentWithProgress(
        columns: [String],
        rows: [[String?]],
        options: CSVExportOptions,
        to fileHandle: FileHandle
    ) async throws {
        let delimiter = options.delimiter.actualValue
        let lineBreak = options.lineBreak.value

        // Header row
        if options.includeFieldNames {
            let headerLine = columns
                .map { escapeCSVField($0, options: options) }
                .joined(separator: delimiter)
            try fileHandle.write(contentsOf: (headerLine + lineBreak).toUTF8Data())
        }

        // Data rows with progress tracking - stream directly to file
        for row in rows {
            try checkCancellation()

            let rowLine = row.map { value -> String in
                guard let val = value else {
                    return options.convertNullToEmpty ? "" : "NULL"
                }

                var processed = val

                // Check for line breaks BEFORE converting them (for quote detection)
                let hadLineBreaks = val.contains("\n") || val.contains("\r")

                // Convert line breaks to space
                if options.convertLineBreakToSpace {
                    processed = processed
                        .replacingOccurrences(of: "\r\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                }

                // Handle decimal format
                if options.decimalFormat == .comma,
                   processed.range(of: #"^[+-]?\d+\.\d+$"#, options: .regularExpression) != nil {
                    processed = processed.replacingOccurrences(of: ".", with: ",")
                }

                return escapeCSVField(processed, options: options, originalHadLineBreaks: hadLineBreaks)
            }.joined(separator: delimiter)

            // Write row directly to file
            try fileHandle.write(contentsOf: (rowLine + lineBreak).toUTF8Data())

            // Update progress (throttled)
            await incrementProgress()
        }

        // Ensure final count is shown
        await finalizeTableProgress()
    }

    /// Escape and quote a CSV field according to the specified options
    /// - Parameters:
    ///   - field: The field value to escape
    ///   - options: CSV export options
    ///   - originalHadLineBreaks: Whether the original value had line breaks before conversion.
    ///                            Used for proper quote detection when convertLineBreakToSpace is enabled.
    private func escapeCSVField(_ field: String, options: CSVExportOptions, originalHadLineBreaks: Bool = false) -> String {
        var processed = field

        // Sanitize formula-like prefixes to prevent CSV formula injection
        // Values starting with these characters can be executed as formulas in Excel/LibreOffice
        if options.sanitizeFormulas {
            let dangerousPrefixes: [Character] = ["=", "+", "-", "@", "\t", "\r"]
            if let first = processed.first, dangerousPrefixes.contains(first) {
                // Prefix with single quote - Excel/LibreOffice treats this as text
                processed = "'" + processed
            }
        }

        switch options.quoteHandling {
        case .always:
            let escaped = processed.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        case .never:
            return processed
        case .asNeeded:
            // Check current content for special characters, OR if original had line breaks
            // (important when convertLineBreakToSpace is enabled - original line breaks
            // mean the field should still be quoted even after conversion to spaces)
            let needsQuotes = processed.contains(options.delimiter.actualValue) ||
                processed.contains("\"") ||
                processed.contains("\n") ||
                processed.contains("\r") ||
                originalHadLineBreaks
            if needsQuotes {
                let escaped = processed.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            return processed
        }
    }

    // MARK: - JSON Export

    private func exportToJSON(
        tables: [ExportTableItem],
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        // Stream JSON directly to file to minimize memory usage
        let fileHandle = try createFileHandle(at: url)
        defer { closeFileHandle(fileHandle) }

        let prettyPrint = config.jsonOptions.prettyPrint
        let indent = prettyPrint ? "  " : ""
        let newline = prettyPrint ? "\n" : ""

        // Opening brace
        try fileHandle.write(contentsOf: "{\(newline)".toUTF8Data())

        for (tableIndex, table) in tables.enumerated() {
            try checkCancellation()

            currentTableIndex = tableIndex + 1
            currentTable = table.qualifiedName

            let tableRef = qualifiedTableRef(for: table)

            // Write table key and opening bracket
            let escapedTableName = escapeJSONString(table.qualifiedName)
            try fileHandle.write(contentsOf: "\(indent)\"\(escapedTableName)\": [\(newline)".toUTF8Data())

            // Stream rows in batches to avoid loading the entire table into memory
            let batchSize = 1_000
            var offset = 0
            var hasWrittenRow = false
            var columns: [String]?

            batchLoop: while true {
                try checkCancellation()

                let result = try await driver.execute(
                    query: "SELECT * FROM \(tableRef) LIMIT \(batchSize) OFFSET \(offset)"
                )

                if result.rows.isEmpty {
                    break batchLoop
                }

                if columns == nil {
                    columns = result.columns
                }

                for row in result.rows {
                    try checkCancellation()

                    // Stream JSON row object directly to file to avoid building large strings in memory
                    let rowPrefix = prettyPrint ? "\(indent)\(indent)" : ""

                    // Write comma/newline before every row except the first
                    if hasWrittenRow {
                        try fileHandle.write(contentsOf: ",\(newline)".toUTF8Data())
                    }

                    // Write row prefix and opening brace
                    try fileHandle.write(contentsOf: rowPrefix.toUTF8Data())
                    try fileHandle.write(contentsOf: "{".toUTF8Data())

                    if let columns = columns {
                        var isFirstField = true
                        for (colIndex, column) in columns.enumerated() {
                            if colIndex < row.count {
                                let value = row[colIndex]
                                if config.jsonOptions.includeNullValues || value != nil {
                                    if !isFirstField {
                                        try fileHandle.write(contentsOf: ", ".toUTF8Data())
                                    }
                                    isFirstField = false

                                    let escapedKey = escapeJSONString(column)
                                    let jsonValue = formatJSONValue(
                                        value,
                                        preserveAsString: config.jsonOptions.preserveAllAsStrings
                                    )
                                    try fileHandle.write(contentsOf: "\"\(escapedKey)\": \(jsonValue)".toUTF8Data())
                                }
                            }
                        }
                    }

                    // Close row object
                    try fileHandle.write(contentsOf: "}".toUTF8Data())

                    hasWrittenRow = true

                    // Update progress (throttled)
                    await incrementProgress()
                }

                offset += result.rows.count
            }

            // Ensure final count is shown for this table
            await finalizeTableProgress()

            // Close array
            if hasWrittenRow {
                try fileHandle.write(contentsOf: newline.toUTF8Data())
            }
            let tableSuffix = tableIndex < tables.count - 1 ? ",\(newline)" : newline
            try fileHandle.write(contentsOf: "\(indent)]\(tableSuffix)".toUTF8Data())
        }

        // Closing brace
        try fileHandle.write(contentsOf: "}".toUTF8Data())

        try checkCancellation()
        progress = 1.0
    }

    /// Escape a string for JSON output per RFC 8259
    ///
    /// Escapes:
    /// - Quotation mark, backslash (required)
    /// - Control characters U+0000 to U+001F (required by spec)
    private func escapeJSONString(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for char in string {
            switch char {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"  // Backspace
            case "\u{0C}": result += "\\f"  // Form feed
            default:
                // Escape other control characters (U+0000 to U+001F) as \uXXXX
                if let scalar = char.unicodeScalars.first,
                   scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.append(char)
                }
            }
        }
        return result
    }

    /// Format a value for JSON output with optional type detection
    ///
    /// - Parameters:
    ///   - value: The value to format
    ///   - preserveAsString: If true, always output as string without type detection
    ///                       (preserves leading zeros in ZIP codes, phone numbers, etc.)
    ///
    /// - Note: When type detection is enabled (preserveAsString = false), integers beyond
    ///   JavaScript's Number.MAX_SAFE_INTEGER (2^53-1 = 9007199254740991) may lose precision
    ///   when parsed by JavaScript. For large IDs or precise numeric data, enable the
    ///   "Preserve All Values as Strings" option in export settings.
    private func formatJSONValue(_ value: String?, preserveAsString: Bool) -> String {
        guard let val = value else { return "null" }

        // If preserving all as strings, skip type detection
        if preserveAsString {
            return "\"\(escapeJSONString(val))\""
        }

        // Try to detect numbers and booleans
        // Note: Large integers (> 2^53-1) may lose precision in JavaScript consumers
        if let intVal = Int(val) {
            return String(intVal)
        }
        if let doubleVal = Double(val), !val.contains("e") && !val.contains("E") {
            // Avoid scientific notation issues
            let jsMaxSafeInteger = 9_007_199_254_740_991.0 // 2^53 - 1, JavaScript's Number.MAX_SAFE_INTEGER

            if doubleVal.truncatingRemainder(dividingBy: 1) == 0 && !val.contains(".") {
                // For integral values, only convert to Int when within both Int and JS safe integer bounds
                if abs(doubleVal) <= jsMaxSafeInteger,
                   doubleVal >= Double(Int.min),
                   doubleVal <= Double(Int.max) {
                    return String(Int(doubleVal))
                } else {
                    // Preserve original integral representation to avoid scientific notation / precision changes
                    return val
                }
            }
            return String(doubleVal)
        }
        if val.lowercased() == "true" || val.lowercased() == "false" {
            return val.lowercased()
        }

        // String value - escape and quote
        return "\"\(escapeJSONString(val))\""
    }

    // MARK: - SQL Export

    private func exportToSQL(
        tables: [ExportTableItem],
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        // For gzip, write to temp file first then compress
        // For non-gzip, stream directly to destination
        let targetURL: URL
        let tempFileURL: URL?

        if config.sqlOptions.compressWithGzip {
            tempFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".sql")
            targetURL = tempFileURL!
        } else {
            tempFileURL = nil
            targetURL = url
        }

        // Create file and get handle for streaming writes
        let fileHandle = try createFileHandle(at: targetURL)

        do {
            // Add header comment
            let dateFormatter = ISO8601DateFormatter()
            try fileHandle.write(contentsOf: "-- TablePro SQL Export\n".toUTF8Data())
            try fileHandle.write(contentsOf: "-- Generated: \(dateFormatter.string(from: Date()))\n".toUTF8Data())
            try fileHandle.write(contentsOf: "-- Database Type: \(databaseType.rawValue)\n\n".toUTF8Data())

            for (index, table) in tables.enumerated() {
                try checkCancellation()

                currentTableIndex = index + 1
                currentTable = table.qualifiedName

                let sqlOptions = table.sqlOptions
                let tableRef = databaseType.quoteIdentifier(table.name)

                let sanitizedName = sanitizeForSQLComment(table.name)
                try fileHandle.write(contentsOf: "-- --------------------------------------------------------\n".toUTF8Data())
                try fileHandle.write(contentsOf: "-- Table: \(sanitizedName)\n".toUTF8Data())
                try fileHandle.write(contentsOf: "-- --------------------------------------------------------\n\n".toUTF8Data())

                // DROP statement
                if sqlOptions.includeDrop {
                    try fileHandle.write(contentsOf: "DROP TABLE IF EXISTS \(tableRef);\n\n".toUTF8Data())
                }

                // CREATE TABLE (structure)
                if sqlOptions.includeStructure {
                    do {
                        let ddl = try await driver.fetchTableDDL(table: tableRef)
                        try fileHandle.write(contentsOf: ddl.toUTF8Data())
                        if !ddl.hasSuffix(";") {
                            try fileHandle.write(contentsOf: ";".toUTF8Data())
                        }
                        try fileHandle.write(contentsOf: "\n\n".toUTF8Data())
                    } catch {
                        // Track the failure for user notification
                        ddlFailures.append(sanitizedName)

                        // Use sanitizedName (already defined above) for safe comment output
                        let ddlWarning = "Warning: failed to fetch DDL for table \(sanitizedName): \(error)"
                        print(ddlWarning)
                        try fileHandle.write(contentsOf: "-- \(sanitizeForSQLComment(ddlWarning))\n\n".toUTF8Data())
                    }
                }

                // INSERT statements (data) - stream directly to file in batches
                if sqlOptions.includeData {
                    let batchSize = config.sqlOptions.batchSize
                    var offset = 0
                    var wroteAnyRows = false

                    while true {
                        try checkCancellation()

                        let query = "SELECT * FROM \(tableRef) LIMIT \(batchSize) OFFSET \(offset)"
                        let result = try await driver.execute(query: query)

                        if result.rows.isEmpty {
                            break
                        }

                        try await writeInsertStatementsWithProgress(
                            table: table,
                            columns: result.columns,
                            rows: result.rows,
                            batchSize: batchSize,
                            to: fileHandle
                        )

                        wroteAnyRows = true
                        offset += batchSize
                    }

                    if wroteAnyRows {
                        try fileHandle.write(contentsOf: "\n".toUTF8Data())
                    }
                }
            }

            try fileHandle.close()
        } catch {
            closeFileHandle(fileHandle)
            if let tempURL = tempFileURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
            throw error
        }

        // Handle gzip compression
        if config.sqlOptions.compressWithGzip, let tempURL = tempFileURL {
            statusMessage = "Compressing..."
            await Task.yield()

            do {
                defer {
                    // Always remove the temporary file, regardless of success or failure
                    try? FileManager.default.removeItem(at: tempURL)
                }

                try await compressFileToFile(source: tempURL, destination: url)
            } catch {
                // Remove the (possibly partially written) destination file on compression failure
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }

        // Surface DDL failures to user as a warning
        if !ddlFailures.isEmpty {
            let failedTables = ddlFailures.joined(separator: ", ")
            warningMessage = "Export completed with warnings: Could not fetch table structure for: \(failedTables)"
        }

        progress = 1.0
    }

    private func writeInsertStatementsWithProgress(
        table: ExportTableItem,
        columns: [String],
        rows: [[String?]],
        batchSize: Int,
        to fileHandle: FileHandle
    ) async throws {
        // Use unqualified table name for INSERT statements (schema-agnostic export)
        let tableRef = databaseType.quoteIdentifier(table.name)
        let quotedColumns = columns
            .map { databaseType.quoteIdentifier($0) }
            .joined(separator: ", ")

        let insertPrefix = "INSERT INTO \(tableRef) (\(quotedColumns)) VALUES\n"

        // Effective batch size (<=1 means no batching, one row per INSERT)
        let effectiveBatchSize = batchSize <= 1 ? 1 : batchSize
        var valuesBatch: [String] = []
        valuesBatch.reserveCapacity(effectiveBatchSize)

        for row in rows {
            try checkCancellation()

            let values = row.map { value -> String in
                guard let val = value else { return "NULL" }
                // Use proper SQL escaping to prevent injection (handles backslashes, quotes, etc.)
                let escaped = SQLEscaping.escapeStringLiteral(val)
                return "'\(escaped)'"
            }.joined(separator: ", ")

            valuesBatch.append("  (\(values))")

            // Write batch when full
            if valuesBatch.count >= effectiveBatchSize {
                let statement = insertPrefix + valuesBatch.joined(separator: ",\n") + ";\n\n"
                try fileHandle.write(contentsOf: statement.toUTF8Data())
                valuesBatch.removeAll(keepingCapacity: true)
            }

            // Update progress (throttled)
            await incrementProgress()
        }

        // Write remaining rows in final batch
        if !valuesBatch.isEmpty {
            let statement = insertPrefix + valuesBatch.joined(separator: ",\n") + ";\n\n"
            try fileHandle.write(contentsOf: statement.toUTF8Data())
        }

        // Ensure final count is shown
        await finalizeTableProgress()
    }

    // MARK: - Compression

    private func compressFileToFile(source: URL, destination: URL) async throws {
        // Run compression on background thread to avoid blocking main thread
        try await Task.detached(priority: .userInitiated) {
            // Pre-flight check: verify gzip is available
            let gzipPath = "/usr/bin/gzip"
            guard FileManager.default.isExecutableFile(atPath: gzipPath) else {
                throw ExportError.exportFailed(
                    "Compression unavailable: gzip not found at \(gzipPath). " +
                        "Please install gzip or disable compression in export options."
                )
            }

            // Create output file
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw ExportError.fileWriteFailed(destination.path)
            }

            // Use gzip to compress the file
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gzipPath)

            // Derive a sanitized, non-encoded filesystem path for the source
            let sanitizedSourcePath = source.standardizedFileURL.path(percentEncoded: false)

            // Basic validation to avoid passing obviously malformed paths to the process
            if sanitizedSourcePath.contains("\0") ||
                sanitizedSourcePath.contains(where: { $0.isNewline }) {
                throw ExportError.exportFailed("Invalid source path for compression")
            }

            process.arguments = ["-c", sanitizedSourcePath]
            let outputFile = try FileHandle(forWritingTo: destination)
            defer {
                try? outputFile.close()
            }
            process.standardOutput = outputFile

            // Capture stderr to provide detailed error messages on failure
            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let status = process.terminationStatus
            guard status == 0 else {
                // Explicitly close the file handle before throwing to ensure
                // the destination file can be deleted in the error handler
                try? outputFile.close()

                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let message: String
                if errorString.isEmpty {
                    message = "Compression failed with exit status \(status)"
                } else {
                    message = "Compression failed with exit status \(status): \(errorString)"
                }

                throw ExportError.exportFailed(message)
            }
        }.value
    }
}

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
    private let progressUpdateInterval: Int = 1000
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

    /// Fetch total row count for all tables
    private func fetchTotalRowCount(for tables: [ExportTableItem]) async -> Int {
        var total = 0
        for table in tables {
            let tableRef = qualifiedTableRef(for: table)
            do {
                let result = try await driver.execute(query: "SELECT COUNT(*) FROM \(tableRef)")
                if let countStr = result.rows.first?.first, let count = Int(countStr ?? "0") {
                    total += count
                }
            } catch {
                // If count fails, estimate based on 0 (progress will be less accurate)
            }
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

    // MARK: - File Helpers

    /// Create a file at the given URL and return a FileHandle for writing
    private func createFileHandle(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ExportError.fileWriteFailed(url.path)
        }
        return try FileHandle(forWritingTo: url)
    }

    // MARK: - CSV Export

    private func exportToCSV(
        tables: [ExportTableItem],
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        // Create file and get handle for streaming writes
        let fileHandle = try createFileHandle(at: url)
        defer { try? fileHandle.close() }

        let lineBreak = config.csvOptions.lineBreak.value

        for (index, table) in tables.enumerated() {
            try checkCancellation()

            currentTableIndex = index + 1
            currentTable = table.qualifiedName

            // Add table header comment if multiple tables
            if tables.count > 1 {
                try fileHandle.write(contentsOf: "# Table: \(table.qualifiedName)\n".toUTF8Data())
            }

            // Fetch all data from table
            let tableRef = qualifiedTableRef(for: table)
            let result = try await driver.execute(query: "SELECT * FROM \(tableRef)")

            // Stream CSV content directly to file
            try await writeCSVContentWithProgress(
                columns: result.columns,
                rows: result.rows,
                options: config.csvOptions,
                to: fileHandle
            )

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

                // Convert line breaks to space
                if options.convertLineBreakToSpace {
                    processed = processed
                        .replacingOccurrences(of: "\r\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                }

                // Handle decimal format
                if options.decimalFormat == .comma,
                   Double(processed) != nil {
                    processed = processed.replacingOccurrences(of: ".", with: ",")
                }

                return escapeCSVField(processed, options: options)
            }.joined(separator: delimiter)

            // Write row directly to file
            try fileHandle.write(contentsOf: (rowLine + lineBreak).toUTF8Data())

            // Update progress (throttled)
            await incrementProgress()
        }

        // Ensure final count is shown
        await finalizeTableProgress()
    }

    private func escapeCSVField(_ field: String, options: CSVExportOptions) -> String {
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
            let needsQuotes = processed.contains(options.delimiter.actualValue) ||
                              processed.contains("\"") ||
                              processed.contains("\n") ||
                              processed.contains("\r")
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
        defer { try? fileHandle.close() }

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
            let result = try await driver.execute(query: "SELECT * FROM \(tableRef)")

            // Write table key and opening bracket
            let escapedTableName = escapeJSONString(table.qualifiedName)
            try fileHandle.write(contentsOf: "\(indent)\"\(escapedTableName)\": [\(newline)".toUTF8Data())

            // Write rows
            for (rowIndex, row) in result.rows.enumerated() {
                try checkCancellation()

                // Stream JSON row object directly to file to avoid building large strings in memory
                let rowPrefix = prettyPrint ? "\(indent)\(indent)" : ""
                let rowSuffix = rowIndex < result.rows.count - 1 ? ",\(newline)" : newline

                // Write row prefix and opening brace
                try fileHandle.write(contentsOf: rowPrefix.toUTF8Data())
                try fileHandle.write(contentsOf: "{".toUTF8Data())

                var isFirstField = true
                for (colIndex, column) in result.columns.enumerated() {
                    if colIndex < row.count {
                        let value = row[colIndex]
                        if config.jsonOptions.includeNullValues || value != nil {
                            if !isFirstField {
                                try fileHandle.write(contentsOf: ", ".toUTF8Data())
                            }
                            isFirstField = false

                            let escapedKey = escapeJSONString(column)
                            let jsonValue = formatJSONValue(value, preserveAsString: config.jsonOptions.preserveAllAsStrings)
                            try fileHandle.write(contentsOf: "\"\(escapedKey)\": \(jsonValue)".toUTF8Data())
                        }
                    }
                }

                // Close row object and write row suffix
                try fileHandle.write(contentsOf: "}".toUTF8Data())
                try fileHandle.write(contentsOf: rowSuffix.toUTF8Data())

                // Update progress (throttled)
                await incrementProgress()
            }

            // Ensure final count is shown for this table
            await finalizeTableProgress()

            // Close array
            let tableSuffix = tableIndex < tables.count - 1 ? ",\(newline)" : newline
            try fileHandle.write(contentsOf: "\(indent)]\(tableSuffix)".toUTF8Data())
        }

        // Closing brace
        try fileHandle.write(contentsOf: "}".toUTF8Data())

        try checkCancellation()
        progress = 1.0
    }

    /// Escape a string for JSON output
    private func escapeJSONString(_ string: String) -> String {
        var result = ""
        for char in string {
            switch char {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(char)
            }
        }
        return result
    }

    /// Format a value for JSON output
    /// - Parameters:
    ///   - value: The value to format
    ///   - preserveAsString: If true, always output as string without type detection
    ///                       (preserves leading zeros in ZIP codes, phone numbers, etc.)
    private func formatJSONValue(_ value: String?, preserveAsString: Bool) -> String {
        guard let val = value else { return "null" }

        // If preserving all as strings, skip type detection
        if preserveAsString {
            return "\"\(escapeJSONString(val))\""
        }

        // Try to detect numbers and booleans
        if let intVal = Int(val) {
            return String(intVal)
        }
        if let doubleVal = Double(val), !val.contains("e") && !val.contains("E") {
            // Avoid scientific notation issues
            if doubleVal.truncatingRemainder(dividingBy: 1) == 0 && !val.contains(".") {
                return String(Int(doubleVal))
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
                let tableRef = qualifiedTableRef(for: table)

                try fileHandle.write(contentsOf: "-- --------------------------------------------------------\n".toUTF8Data())
                try fileHandle.write(contentsOf: "-- Table: \(table.qualifiedName)\n".toUTF8Data())
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
                        let warningMessage = "Warning: failed to fetch DDL for table \(table.qualifiedName): \(error)"
                        print(warningMessage)
                        try fileHandle.write(contentsOf: "-- \(warningMessage)\n\n".toUTF8Data())
                    }
                }

                // INSERT statements (data) - stream directly to file
                if sqlOptions.includeData {
                    let result = try await driver.execute(query: "SELECT * FROM \(tableRef)")

                    if !result.rows.isEmpty {
                        try await writeInsertStatementsWithProgress(
                            table: table,
                            columns: result.columns,
                            rows: result.rows,
                            to: fileHandle
                        )
                        try fileHandle.write(contentsOf: "\n".toUTF8Data())
                    }
                }
            }

            try fileHandle.close()
        } catch {
            try? fileHandle.close()
            if let tempURL = tempFileURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
            throw error
        }

        try checkCancellation()

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

        progress = 1.0
    }

    private func writeInsertStatementsWithProgress(
        table: ExportTableItem,
        columns: [String],
        rows: [[String?]],
        to fileHandle: FileHandle
    ) async throws {
        let tableRef = qualifiedTableRef(for: table)
        let quotedColumns = columns
            .map { databaseType.quoteIdentifier($0) }
            .joined(separator: ", ")

        for row in rows {
            try checkCancellation()

            let values = row.map { value -> String in
                guard let val = value else { return "NULL" }
                // Use proper SQL escaping to prevent injection (handles backslashes, quotes, etc.)
                let escaped = SQLEscaping.escapeStringLiteral(val)
                return "'\(escaped)'"
            }.joined(separator: ", ")

            let statement = "INSERT INTO \(tableRef) (\(quotedColumns)) VALUES (\(values));\n"
            try fileHandle.write(contentsOf: statement.toUTF8Data())

            // Update progress (throttled)
            await incrementProgress()
        }

        // Ensure final count is shown
        await finalizeTableProgress()
    }

    // MARK: - Compression

    private func compressFileToFile(source: URL, destination: URL) async throws {
        // Run compression on background thread to avoid blocking main thread
        try await Task.detached(priority: .userInitiated) {
            // Create output file
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw ExportError.fileWriteFailed(destination.path)
            }

            // Use gzip to compress the file
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-c", source.path]

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

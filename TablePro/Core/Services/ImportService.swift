//
//  ImportService.swift
//  TablePro
//
//  Service responsible for importing SQL files with transaction support
//  and foreign key handling.
//

import Combine
import Foundation

// MARK: - Import Service

/// Service responsible for importing SQL files
@MainActor
final class ImportService: ObservableObject {
    // MARK: - Published State

    @Published var isImporting: Bool = false
    @Published var progress: Double = 0.0
    @Published var currentStatement: String = ""
    @Published var currentStatementIndex: Int = 0
    @Published var totalStatements: Int = 0
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
            defer { isCancelledLock.unlock() }
            _isCancelled = newValue
        }
    }

    func cancelImport() {
        isCancelled = true
    }

    // MARK: - Dependencies

    private let connection: DatabaseConnection
    private let parser = SQLFileParser()

    // MARK: - Initialization

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    // MARK: - Public API

    /// Import SQL file
    /// - Parameters:
    ///   - url: File URL to import
    ///   - config: Import configuration
    /// - Returns: Import result with execution summary
    func importSQL(
        from url: URL,
        config: ImportConfiguration
    ) async throws -> ImportResult {
        isImporting = true
        isCancelled = false
        progress = 0.0
        currentStatementIndex = 0
        errorMessage = nil

        defer {
            isImporting = false
        }

        // 1. Decompress .gz if needed
        let fileURL = try await decompressIfNeeded(url)
        let needsCleanup = fileURL != url
        defer {
            if needsCleanup {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                } catch {
                    print("WARNING: Failed to clean up temporary file at \(fileURL.path): \(error)")
                }
            }
        }

        // 2. Count statements for progress
        statusMessage = "Analyzing file..."
        totalStatements = try await parser.countStatements(url: fileURL, encoding: config.encoding)
        statusMessage = ""

        // Check for cancellation after counting (before starting execution)
        try checkCancellation()

        // Check if file is empty
        guard totalStatements > 0 else {
            throw ImportError.fileReadFailed("File contains no SQL statements")
        }

        // 3. Get database driver
        guard let driver = DatabaseManager.shared.activeDriver else {
            throw DatabaseError.notConnected
        }

        let startTime = Date()
        var executedCount = 0
        var failedStatement: String?
        var failedLine: Int?

        do {
            // 4. Disable FK checks (if enabled) - BEFORE transaction
            if config.disableForeignKeyChecks {
                let fkDisableStmts = fkDisableStatements(for: connection.type)
                for stmt in fkDisableStmts {
                    _ = try await driver.execute(query: stmt)
                }
            }

            // 5. Begin transaction (if enabled)
            if config.wrapInTransaction {
                _ = try await driver.execute(query: beginTransactionStatement(for: connection.type))
            }

            // 6. Parse and execute statements
            // NOTE:
            // This call may re-parse the file after a prior pass that counted
            // the total number of statements for progress reporting. For large
            // files this can roughly double the I/O and parsing overhead.
            //
            // This is currently an intentional tradeoff in favor of providing
            // an accurate, determinate progress value (executedCount /
            // totalStatements) to the UI. If import performance for very large
            // files becomes an issue, consider:
            //   - Removing the initial counting pass and using an indeterminate
            //     progress indicator instead, or
            //   - Parsing once and caching the statements, at the cost of
            //     additional memory usage.
            let stream = try await parser.parseFile(url: fileURL, encoding: config.encoding)

            for try await (statement, lineNumber) in stream {
                try checkCancellation()

                currentStatement = statement.count > 50 ? String(statement.prefix(50)) + "..." : statement
                currentStatementIndex = executedCount + 1

                let statementStartTime = Date()

                do {
                    _ = try await driver.execute(query: statement)

                    let executionTime = Date().timeIntervalSince(statementStartTime)

                    // Record to history
                    QueryHistoryManager.shared.recordQuery(
                        query: statement,
                        connectionId: connection.id,
                        databaseName: connection.database ?? "",
                        executionTime: executionTime,
                        rowCount: 0,
                        wasSuccessful: true,
                        errorMessage: nil
                    )

                    executedCount += 1
                    progress = Double(executedCount) / Double(totalStatements)
                } catch {
                    // Statement execution failed
                    failedStatement = statement
                    failedLine = lineNumber

                    // Record failed query to history
                    QueryHistoryManager.shared.recordQuery(
                        query: statement,
                        connectionId: connection.id,
                        databaseName: connection.database ?? "",
                        executionTime: 0,
                        rowCount: 0,
                        wasSuccessful: false,
                        errorMessage: error.localizedDescription
                    )

                    throw ImportError.importFailed(
                        statement: statement,
                        line: lineNumber,
                        error: error.localizedDescription
                    )
                }
            }

            // 7. Commit transaction (if enabled)
            if config.wrapInTransaction {
                _ = try await driver.execute(query: commitStatement(for: connection.type))
            }

            // 8. Re-enable FK checks (if enabled) - AFTER transaction
            if config.disableForeignKeyChecks {
                let fkEnableStmts = fkEnableStatements(for: connection.type)
                for stmt in fkEnableStmts {
                    _ = try await driver.execute(query: stmt)
                }
            }
        } catch {
            // Rollback on error - this is CRITICAL and must not fail silently
            if config.wrapInTransaction {
                do {
                    _ = try await driver.execute(query: rollbackStatement(for: connection.type))
                } catch {
                    // Rollback failed - database may be in inconsistent state
                    // This is a critical error that MUST be reported to the user
                    throw ImportError.rollbackFailed(rollbackError.localizedDescription)
                }
            }

            // Re-enable FK checks on error - important for data integrity
            if config.disableForeignKeyChecks {
                let fkEnableStmts = fkEnableStatements(for: connection.type)
                var fkReenableErrors: [String] = []
                for stmt in fkEnableStmts {
                    do {
                        _ = try await driver.execute(query: stmt)
                    } catch {
                        // FK re-enable failed - warn user but don't override original error
                        // Store this as a warning that should be shown alongside the original error
                        let message = fkError.localizedDescription
                        fkReenableErrors.append(message)
                        print("WARNING: Failed to re-enable FK checks: \(message)")
                        // Note: We don't throw here to preserve the original import error
                        // but we should log this for the user to see
                    }
                }

                // If FK re-enable failed, surface this information alongside the original error
                if !fkReenableErrors.isEmpty {
                    let fkDetails = fkReenableErrors.joined(separator: "; ")
                    let combinedMessage = """
                    Import failed: \(error.localizedDescription)
                    Additionally, failed to re-enable foreign key checks: \(fkDetails)
                    """
                    // Expose the combined message so callers / UI can present it to the user
                    statusMessage = combinedMessage
                    errorMessage = combinedMessage
                }
            }

            throw error
        }

        let executionTime = Date().timeIntervalSince(startTime)

        return ImportResult(
            totalStatements: totalStatements,
            executedStatements: executedCount,
            failedStatement: failedStatement,
            failedLine: failedLine,
            executionTime: executionTime
        )
    }

    // MARK: - Private Helpers

    /// Returns a filesystem path string for the given URL, using the
    /// preferred `URL.path()` API on macOS 13+ and falling back to
    /// the legacy `path` property on earlier versions.
    private func fileSystemPath(for url: URL) -> String {
        if #available(macOS 13.0, *) {
            return url.path()
        } else {
            return url.path
        }
    }

    private func decompressIfNeeded(_ url: URL) async throws -> URL {
        try await FileDecompressor.decompressIfNeeded(url, fileSystemPath: fileSystemPath)
    }

    private func checkCancellation() throws {
        if isCancelled {
            throw ImportError.cancelled
        }
    }

    private func fkDisableStatements(for dbType: DatabaseType) -> [String] {
        switch dbType {
        case .mysql, .mariadb:
            return ["SET FOREIGN_KEY_CHECKS=0"]
        case .postgresql:
            // PostgreSQL doesn't support globally disabling non-deferrable FKs.
            return []
        case .sqlite:
            return ["PRAGMA foreign_keys = OFF"]
        }
    }

    private func fkEnableStatements(for dbType: DatabaseType) -> [String] {
        switch dbType {
        case .mysql, .mariadb:
            return ["SET FOREIGN_KEY_CHECKS=1"]
        case .postgresql:
            return []
        case .sqlite:
            return ["PRAGMA foreign_keys = ON"]
        }
    }

    private func beginTransactionStatement(for dbType: DatabaseType) -> String {
        switch dbType {
        case .mysql, .mariadb:
            return "START TRANSACTION"
        case .postgresql, .sqlite:
            return "BEGIN"
        }
    }

    private func commitStatement(for dbType: DatabaseType) -> String {
        "COMMIT"
    }

    private func rollbackStatement(for dbType: DatabaseType) -> String {
        "ROLLBACK"
    }
}

//
//  ImportService.swift
//  TablePro
//
//  Service responsible for importing SQL files with transaction support
//  and foreign key handling.
//

import Foundation
import Observation
import os

// MARK: - Import State

/// Consolidated state struct to minimize @Published update overhead.
/// A single @Published property avoids N separate objectWillChange notifications per statement.
struct ImportState {
    var isImporting: Bool = false
    var progress: Double = 0.0
    var currentStatement: String = ""
    var currentStatementIndex: Int = 0
    var totalStatements: Int = 0
    var statusMessage: String = ""
    var errorMessage: String?
}

// MARK: - Import Service

/// Service responsible for importing SQL files
@MainActor @Observable
final class ImportService {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportService")
    // MARK: - Published State

    var state = ImportState()

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
        state = ImportState(isImporting: true)
        isCancelled = false

        defer {
            state.isImporting = false
        }

        // 1. Decompress .gz if needed
        let fileURL = try await decompressIfNeeded(url)
        let needsCleanup = fileURL != url
        defer {
            if needsCleanup {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                } catch {
                    Self.logger.warning("Failed to clean up temporary file at \(fileURL.path): \(error)")
                }
            }
        }

        // 2. Estimate statement count from file size (skip counting pass to avoid double-parsing)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        let fileSizeBytes = attrs[.size] as? Int64 ?? 0

        // Rough heuristic: ~500 bytes per statement on average.
        // SQL dumps typically contain large INSERT/DDL statements (5k-50k bytes each),
        // so a smaller divisor (e.g. 200) grossly overestimates the count and causes the
        // progress bar to crawl and never visually reach 100%.
        let estimatedStatements = max(1, Int(fileSizeBytes / 500))
        state.totalStatements = estimatedStatements

        try checkCancellation()

        // 3. Get database driver
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
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
                let beginStmt = beginTransactionStatement(for: connection.type)
                if !beginStmt.isEmpty {
                    _ = try await driver.execute(query: beginStmt)
                }
            }

            // 6. Parse and execute statements (single pass — no prior counting pass)
            let stream = try await parser.parseFile(url: fileURL, encoding: config.encoding)

            for try await (statement, lineNumber) in stream {
                try checkCancellation()

                let nsStmt = statement as NSString
                state.currentStatement = nsStmt.length > 50 ? nsStmt.substring(to: 50) + "..." : statement
                state.currentStatementIndex = executedCount + 1

                do {
                    _ = try await driver.execute(query: statement)

                    executedCount += 1
                    state.progress = min(1.0, Double(executedCount) / Double(state.totalStatements))
                } catch {
                    // Statement execution failed
                    failedStatement = statement
                    failedLine = lineNumber

                    throw ImportError.importFailed(
                        statement: statement,
                        line: lineNumber,
                        error: error.localizedDescription
                    )
                }
            }

            // Update to actual count so UI shows correct final state
            state.totalStatements = executedCount
            state.currentStatementIndex = executedCount
            state.progress = 1.0

            // 7. Commit transaction (if enabled)
            if config.wrapInTransaction {
                let commitStmt = commitStatement(for: connection.type)
                if !commitStmt.isEmpty {
                    _ = try await driver.execute(query: commitStmt)
                }
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
                    let rollbackStmt = rollbackStatement(for: connection.type)
                    if !rollbackStmt.isEmpty {
                        _ = try await driver.execute(query: rollbackStmt)
                    }
                } catch let rollbackError {
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
                    } catch let fkError {
                        // FK re-enable failed - warn user but don't override original error
                        // Store this as a warning that should be shown alongside the original error
                        let message = fkError.localizedDescription
                        fkReenableErrors.append(message)
                        Self.logger.warning("Failed to re-enable FK checks: \(message)")
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
                    state.statusMessage = combinedMessage
                    state.errorMessage = combinedMessage
                }
            }

            // Record a single summary history entry for the failed import
            let failedImportTime = Date().timeIntervalSince(startTime)
            QueryHistoryManager.shared.recordQuery(
                query: "-- Import from \(fileURL.lastPathComponent) (\(executedCount) statements before failure)",
                connectionId: connection.id,
                databaseName: connection.database,
                executionTime: failedImportTime,
                rowCount: executedCount,
                wasSuccessful: false,
                errorMessage: error.localizedDescription
            )

            throw error
        }

        let executionTime = Date().timeIntervalSince(startTime)

        // Record a single summary history entry for the entire import
        QueryHistoryManager.shared.recordQuery(
            query: "-- Import from \(fileURL.lastPathComponent) (\(executedCount) statements)",
            connectionId: connection.id,
            databaseName: connection.database,
            executionTime: executionTime,
            rowCount: executedCount,
            wasSuccessful: true,
            errorMessage: nil
        )

        return ImportResult(
            totalStatements: executedCount,
            executedStatements: executedCount,
            failedStatement: failedStatement,
            failedLine: failedLine,
            executionTime: executionTime
        )
    }

    // MARK: - Private Helpers

    /// Returns a filesystem path string for the given URL.
    private func fileSystemPath(for url: URL) -> String {
        url.path()
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
        case .postgresql, .redshift, .mssql:
            // These databases don't support globally disabling non-deferrable FKs.
            return []
        case .sqlite:
            return ["PRAGMA foreign_keys = OFF"]
        case .mongodb, .redis:
            return []
        }
    }

    private func fkEnableStatements(for dbType: DatabaseType) -> [String] {
        switch dbType {
        case .mysql, .mariadb:
            return ["SET FOREIGN_KEY_CHECKS=1"]
        case .postgresql, .redshift, .mssql:
            return []
        case .sqlite:
            return ["PRAGMA foreign_keys = ON"]
        case .mongodb, .redis:
            return []
        }
    }

    private func beginTransactionStatement(for dbType: DatabaseType) -> String {
        switch dbType {
        case .mysql, .mariadb:
            return "START TRANSACTION"
        case .postgresql, .redshift, .sqlite:
            return "BEGIN"
        case .mssql:
            return "BEGIN TRANSACTION"
        case .mongodb, .redis:
            return ""
        }
    }

    private func commitStatement(for dbType: DatabaseType) -> String {
        switch dbType {
        case .mongodb, .redis:
            return ""
        default:
            return "COMMIT"
        }
    }

    private func rollbackStatement(for dbType: DatabaseType) -> String {
        switch dbType {
        case .mongodb, .redis:
            return ""
        default:
            return "ROLLBACK"
        }
    }
}

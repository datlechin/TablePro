//
//  DatabaseSwitcherViewModel.swift
//  TablePro
//
//  ViewModel for DatabaseSwitcherSheet.
//  Handles database fetching, metadata loading, recent tracking, and switching logic.
//

import Foundation
import Observation
import os
import SwiftUI

@MainActor @Observable
class DatabaseSwitcherViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseSwitcherViewModel")
    // MARK: - Published State

    var databases: [DatabaseMetadata] = []
    var recentDatabases: [String] = []
    var searchText = ""
    var selectedDatabase: String?
    var isLoading = false
    var errorMessage: String?
    var showPreview = false

    /// Whether we're switching schemas (PostgreSQL) or databases (MySQL)
    var isSchemaMode: Bool { databaseType == .postgresql || databaseType == .redshift }

    // MARK: - Dependencies

    private let connectionId: UUID
    private let currentDatabase: String?
    private let databaseType: DatabaseType

    // MARK: - Computed Properties

    var filteredDatabases: [DatabaseMetadata] {
        if searchText.isEmpty {
            return databases
        }
        return databases.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var recentDatabaseMetadata: [DatabaseMetadata] {
        recentDatabases.compactMap { dbName in
            databases.first { $0.name == dbName }
        }
    }

    var allDatabases: [DatabaseMetadata] {
        // Filter out recent databases from "all" list
        filteredDatabases.filter { db in
            !recentDatabases.contains(db.name)
        }
    }

    // MARK: - Initialization

    init(connectionId: UUID, currentDatabase: String?, databaseType: DatabaseType) {
        self.connectionId = connectionId
        self.currentDatabase = currentDatabase
        self.databaseType = databaseType
        self.recentDatabases = UserDefaults.standard.recentDatabases(for: connectionId)
    }

    // MARK: - Public Methods

    /// Fetch databases (or schemas for PostgreSQL) and their metadata
    func fetchDatabases() async {
        isLoading = true
        errorMessage = nil

        do {
            guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
                errorMessage = String(localized: "No active connection")
                isLoading = false
                return
            }

            if isSchemaMode {
                // PostgreSQL: fetch schemas instead of databases
                let schemaNames = try await driver.fetchSchemas()
                databases = schemaNames.map { name in
                    DatabaseMetadata.minimal(name: name, isSystem: isSystemItem(name))
                }
            } else {
                // Show database names immediately, then load metadata
                let dbNames = try await driver.fetchDatabases()
                databases = dbNames.sorted().map { name in
                    DatabaseMetadata.minimal(name: name, isSystem: isSystemItem(name))
                }

                // Pre-select before metadata loads so the UI is interactive immediately
                preselectDatabase()

                // Fetch all metadata in a single batched query
                isLoading = false
                do {
                    let metadataList = try await driver.fetchAllDatabaseMetadata()
                    databases = metadataList.sorted { $0.name < $1.name }
                } catch {
                    Self.logger.error("Failed to fetch database metadata: \(error)")
                }
                return
            }

            isLoading = false
            preselectDatabase()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Refresh database list
    func refreshDatabases() async {
        await fetchDatabases()
    }

    /// Create a new database
    func createDatabase(name: String, charset: String, collation: String?) async throws {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }

        try await driver.createDatabase(name: name, charset: charset, collation: collation)
    }

    /// Track database access
    func trackAccess(database: String) {
        UserDefaults.standard.trackDatabaseAccess(database, for: connectionId)
        recentDatabases = UserDefaults.standard.recentDatabases(for: connectionId)
    }

    // MARK: - Private Methods

    private func preselectDatabase() {
        if let current = currentDatabase, databases.contains(where: { $0.name == current }) {
            selectedDatabase = current
        } else {
            selectedDatabase = databases.first?.name
        }
    }

    /// Determine if a database or schema is a system item
    private func isSystemItem(_ name: String) -> Bool {
        if isSchemaMode {
            return name.hasPrefix("pg_")
        }
        switch databaseType {
        case .mysql, .mariadb:
            return ["information_schema", "mysql", "performance_schema", "sys"].contains(name)
        case .postgresql:
            return ["postgres", "template0", "template1"].contains(name)
        case .redshift:
            return ["dev", "padb_harvest"].contains(name)
        case .sqlite:
            return false
        case .mongodb:
            return false
        case .redis:
            return false
        case .mssql:
            return ["master", "tempdb", "model", "msdb"].contains(name)
        }
    }
}

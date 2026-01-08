//
//  SQLSchemaProvider.swift
//  TablePro
//
//  Cached database schema provider for autocomplete
//

import Foundation

/// Provides cached database schema information for autocomplete
actor SQLSchemaProvider {
    // MARK: - Properties

    private var tables: [TableInfo] = []
    private var columnCache: [String: [ColumnInfo]] = [:]
    private var isLoading = false
    private var lastLoadError: Error?

    // Store the driver reference used during schema loading for column fetching
    private var cachedDriver: DatabaseDriver?

    // Store connection info for reference
    private var connectionInfo: DatabaseConnection?

    // MARK: - Public API

    /// Load schema from the database (driver should already be connected)
    func loadSchema(using driver: DatabaseDriver, connection: DatabaseConnection? = nil) async {
        guard !isLoading else { return }

        // Store driver reference for later column fetching
        self.cachedDriver = driver
        self.connectionInfo = connection
        isLoading = true
        lastLoadError = nil

        do {
            // Fetch all tables
            tables = try await driver.fetchTables()

            // Pre-load columns for common tables (up to 5)
            for table in tables.prefix(5) {
                let columns = try await driver.fetchColumns(table: table.name)
                columnCache[table.name.lowercased()] = columns
            }

            // Clear remaining column cache
            isLoading = false

            // Driver will be disconnected by caller, we'll reconnect for additional column loading
        } catch {
            lastLoadError = error
            isLoading = false
            print("[SQLSchemaProvider] Failed to load schema: \(error)")
        }
    }

    /// Get all tables
    func getTables() -> [TableInfo] {
        tables
    }

    /// Get columns for a specific table (with caching)
    func getColumns(for tableName: String) async -> [ColumnInfo] {
        // Check cache first
        if let cached = columnCache[tableName.lowercased()] {
            return cached
        }

        // Use the cached driver from loadSchema() to ensure we're querying the correct connection
        guard let driver = cachedDriver else {
            print("[SQLSchemaProvider] No cached driver for column loading")
            return []
        }

        do {
            let columns = try await driver.fetchColumns(table: tableName)
            columnCache[tableName.lowercased()] = columns
            return columns
        } catch {
            print("[SQLSchemaProvider] Failed to load columns for \(tableName): \(error)")
            return []
        }
    }

    /// Check if schema is loaded
    func isSchemaLoaded() -> Bool {
        !tables.isEmpty
    }

    /// Check if currently loading
    func isCurrentlyLoading() -> Bool {
        isLoading
    }

    /// Invalidate cache and reload
    func invalidateCache() {
        tables.removeAll()
        columnCache.removeAll()
        cachedDriver = nil
    }

    /// Find table name from alias
    func resolveAlias(_ aliasOrName: String, in references: [TableReference]) -> String? {
        // First check if it's an alias
        for ref in references {
            if ref.alias?.lowercased() == aliasOrName.lowercased() {
                return ref.tableName
            }
        }

        // Then check if it's a table name directly
        for ref in references {
            if ref.tableName.lowercased() == aliasOrName.lowercased() {
                return ref.tableName
            }
        }

        // Finally check against known tables
        for table in tables {
            if table.name.lowercased() == aliasOrName.lowercased() {
                return table.name
            }
        }

        return nil
    }

    // MARK: - Completion Items

    /// Get completion items for tables
    func tableCompletionItems() async -> [SQLCompletionItem] {
        let tableData = tables.map { (name: $0.name, isView: $0.type == .view) }
        return await MainActor.run {
            tableData.map { SQLCompletionItem.table($0.name, isView: $0.isView) }
        }
    }

    /// Get completion items for columns of a specific table
    func columnCompletionItems(for tableName: String) async -> [SQLCompletionItem] {
        let columns = await getColumns(for: tableName)
        let columnData = columns.map { (name: $0.name, type: $0.dataType) }
        return await MainActor.run {
            columnData.map {
                SQLCompletionItem.column($0.name, dataType: $0.type, tableName: tableName)
            }
        }
    }

    /// Get completion items for all columns of tables in scope
    func allColumnsInScope(for references: [TableReference]) async -> [SQLCompletionItem] {
        var itemDataBuilder: [(label: String, insertText: String, type: String, table: String)] = []

        for ref in references {
            let columns = await getColumns(for: ref.tableName)
            let refId = await ref.identifier
            for column in columns {
                // Include table/alias prefix for clarity when multiple tables
                let label = references.count > 1 ? "\(refId).\(column.name)" : column.name
                let insertText = references.count > 1 ? "\(refId).\(column.name)" : column.name

                itemDataBuilder.append(
                    (
                        label: label, insertText: insertText, type: column.dataType,
                        table: ref.tableName
                    ))
            }
        }

        // Capture as immutable for Sendable compliance
        let itemData = itemDataBuilder

        return await MainActor.run {
            itemData.map {
                SQLCompletionItem(
                    label: $0.label,
                    kind: .column,
                    insertText: $0.insertText,
                    detail: $0.type,
                    documentation: "Column from \($0.table)"
                )
            }
        }
    }
}

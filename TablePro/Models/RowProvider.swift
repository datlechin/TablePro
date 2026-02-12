//
//  RowProvider.swift
//  TablePro
//
//  Protocol for virtualized row data access
//

import Foundation
import os

/// Protocol for virtualized data access with lazy loading support
protocol RowProvider: AnyObject {
    /// Total number of rows available
    var totalRowCount: Int { get }

    /// Column names
    var columns: [String] { get }

    /// Column default values from schema
    var columnDefaults: [String: String?] { get }

    /// Fetch rows for the given range
    /// - Parameters:
    ///   - offset: Starting row index
    ///   - limit: Maximum number of rows to fetch
    /// - Returns: Array of row data
    func fetchRows(offset: Int, limit: Int) -> [TableRowData]

    /// Prefetch rows at specific indices for smoother scrolling
    func prefetchRows(at indices: [Int])

    /// Invalidate cached data (e.g., after refresh)
    func invalidateCache()
}

/// Represents a single row of table data
final class TableRowData {
    let index: Int
    var values: [String?]

    init(index: Int, values: [String?]) {
        self.index = index
        self.values = values
    }

    /// Get value at column index
    func value(at columnIndex: Int) -> String? {
        guard columnIndex < values.count else { return nil }
        return values[columnIndex]
    }

    /// Set value at column index
    func setValue(_ value: String?, at columnIndex: Int) {
        guard columnIndex < values.count else { return }
        values[columnIndex] = value
    }
}

// MARK: - In-Memory Row Provider

/// Row provider that keeps all data in memory (for existing QueryResultRow data).
/// Uses lazy TableRowData creation to avoid O(n) heap allocations on init.
final class InMemoryRowProvider: RowProvider {
    private var sourceRows: [QueryResultRow]
    private var rowCache: [Int: TableRowData] = [:]
    private(set) var columns: [String]
    private(set) var columnDefaults: [String: String?]
    private(set) var columnTypes: [ColumnType]
    private(set) var columnForeignKeys: [String: ForeignKeyInfo]
    private(set) var columnEnumValues: [String: [String]]
    private(set) var columnNullable: [String: Bool]

    var totalRowCount: Int {
        sourceRows.count
    }

    init(
        rows: [QueryResultRow],
        columns: [String],
        columnDefaults: [String: String?] = [:],
        columnTypes: [ColumnType]? = nil,
        columnForeignKeys: [String: ForeignKeyInfo] = [:],
        columnEnumValues: [String: [String]] = [:],
        columnNullable: [String: Bool] = [:]
    ) {
        self.columns = columns
        self.columnDefaults = columnDefaults
        self.columnTypes = columnTypes ?? Array(repeating: ColumnType.text(rawType: nil), count: columns.count)
        self.columnForeignKeys = columnForeignKeys
        self.columnEnumValues = columnEnumValues
        self.columnNullable = columnNullable
        self.sourceRows = rows
    }

    func fetchRows(offset: Int, limit: Int) -> [TableRowData] {
        let endIndex = min(offset + limit, sourceRows.count)
        guard offset < endIndex else { return [] }
        var result: [TableRowData] = []
        result.reserveCapacity(endIndex - offset)
        for i in offset..<endIndex {
            result.append(materializeRow(at: i))
        }
        return result
    }

    func prefetchRows(at indices: [Int]) {
        // No-op for in-memory provider - all data already available
    }

    func invalidateCache() {
        rowCache.removeAll()
    }

    /// Update a cell value
    func updateValue(_ value: String?, at rowIndex: Int, columnIndex: Int) {
        guard rowIndex < sourceRows.count else { return }
        // Update the source row
        sourceRows[rowIndex].values[columnIndex] = value
        // Update cached TableRowData if it exists
        rowCache[rowIndex]?.setValue(value, at: columnIndex)
    }

    /// Get row data at index
    func row(at index: Int) -> TableRowData? {
        guard index >= 0 && index < sourceRows.count else { return nil }
        return materializeRow(at: index)
    }

    /// Update rows from QueryResultRow array
    func updateRows(_ newRows: [QueryResultRow]) {
        self.sourceRows = newRows
        self.rowCache.removeAll()
    }

    /// Append a new row with given values
    /// Returns the index of the new row
    func appendRow(values: [String?]) -> Int {
        let newIndex = sourceRows.count
        sourceRows.append(QueryResultRow(values: values))
        let rowData = TableRowData(index: newIndex, values: values)
        rowCache[newIndex] = rowData
        return newIndex
    }

    /// Remove row at index (used when discarding new rows)
    func removeRow(at index: Int) {
        guard index >= 0 && index < sourceRows.count else { return }
        sourceRows.remove(at: index)
        // Clear entire cache since indices shift
        rowCache.removeAll()
    }

    /// Remove multiple rows at indices (used when discarding new rows)
    /// Indices should be sorted in descending order to maintain correct removal
    func removeRows(at indices: Set<Int>) {
        for index in indices.sorted(by: >) {
            guard index >= 0 && index < sourceRows.count else { continue }
            sourceRows.remove(at: index)
        }
        // Clear entire cache since indices shift
        rowCache.removeAll()
    }

    // MARK: - Private

    private func materializeRow(at index: Int) -> TableRowData {
        if let cached = rowCache[index] {
            return cached
        }
        let rowData = TableRowData(index: index, values: sourceRows[index].values)
        rowCache[index] = rowData
        return rowData
    }
}

// MARK: - Database Row Provider (for virtualized access via driver)

/// Row provider that fetches data on-demand from database
final class DatabaseRowProvider: RowProvider {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RowProvider")
    private let driver: DatabaseDriver
    private let baseQuery: String
    private var cache: [Int: TableRowData] = [:]
    private let pageSize: Int

    private(set) var totalRowCount: Int = 0
    private(set) var columns: [String]
    private(set) var columnDefaults: [String: String?]

    private var isInitialized = false

    init(driver: DatabaseDriver, query: String, columns: [String], columnDefaults: [String: String?] = [:], pageSize: Int = 200) {
        self.driver = driver
        self.baseQuery = query
        self.columns = columns
        self.columnDefaults = columnDefaults
        self.pageSize = pageSize
    }

    /// Initialize by fetching total row count
    func initialize() async throws {
        guard !isInitialized else { return }

        totalRowCount = try await driver.fetchRowCount(query: baseQuery)
        isInitialized = true
    }

    func fetchRows(offset: Int, limit: Int) -> [TableRowData] {
        var result: [TableRowData] = []

        for i in offset..<min(offset + limit, totalRowCount) {
            if let cached = cache[i] {
                result.append(cached)
            } else {
                // Return placeholder - actual data filled via prefetch
                let placeholder = TableRowData(index: i, values: Array(repeating: "...", count: columns.count))
                result.append(placeholder)
            }
        }

        return result
    }

    func prefetchRows(at indices: [Int]) {
        let missingIndices = indices.filter { cache[$0] == nil }
        guard !missingIndices.isEmpty else { return }

        guard let minIndex = missingIndices.min(),
              let maxIndex = missingIndices.max() else { return }

        let offset = minIndex
        let limit = min(maxIndex - minIndex + pageSize, totalRowCount - offset)

        Task { @MainActor in
            do {
                let result = try await driver.fetchRows(query: baseQuery, offset: offset, limit: limit)
                for (i, row) in result.rows.enumerated() {
                    let rowData = TableRowData(index: offset + i, values: row)
                    cache[offset + i] = rowData
                }
            } catch {
                Self.logger.error("Prefetch error: \(error)")
            }
        }
    }

    func invalidateCache() {
        cache.removeAll()
        isInitialized = false
    }

    /// Synchronously fetch and cache rows (for initial load)
    func loadRows(offset: Int, limit: Int) async throws {
        let result = try await driver.fetchRows(query: baseQuery, offset: offset, limit: limit)
        for (i, row) in result.rows.enumerated() {
            let rowData = TableRowData(index: offset + i, values: row)
            cache[offset + i] = rowData
        }
    }

    /// Get row data at index (nil if not cached)
    func row(at index: Int) -> TableRowData? {
        cache[index]
    }

    /// Update a cached cell value
    func updateValue(_ value: String?, at rowIndex: Int, columnIndex: Int) {
        cache[rowIndex]?.setValue(value, at: columnIndex)
    }
}

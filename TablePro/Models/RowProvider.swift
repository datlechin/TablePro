//
//  RowProvider.swift
//  TablePro
//
//  Protocol for virtualized row data access
//

import Foundation

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

/// Row provider that keeps all data in memory (for existing QueryResultRow data)
final class InMemoryRowProvider: RowProvider {
    private var rows: [TableRowData] = []
    private(set) var columns: [String]
    private(set) var columnDefaults: [String: String?]

    var totalRowCount: Int {
        rows.count
    }

    init(rows: [QueryResultRow], columns: [String], columnDefaults: [String: String?] = [:]) {
        self.columns = columns
        self.columnDefaults = columnDefaults
        self.rows = rows.enumerated().map { index, row in
            TableRowData(index: index, values: row.values)
        }
    }

    func fetchRows(offset: Int, limit: Int) -> [TableRowData] {
        let endIndex = min(offset + limit, rows.count)
        guard offset < endIndex else { return [] }
        return Array(rows[offset..<endIndex])
    }

    func prefetchRows(at indices: [Int]) {
        // No-op for in-memory provider - all data already loaded
    }

    func invalidateCache() {
        // No-op for in-memory provider
    }

    /// Update a cell value
    func updateValue(_ value: String?, at rowIndex: Int, columnIndex: Int) {
        guard rowIndex < rows.count else { return }
        rows[rowIndex].setValue(value, at: columnIndex)
    }

    /// Get row data at index
    func row(at index: Int) -> TableRowData? {
        guard index >= 0 && index < rows.count else { return nil }
        return rows[index]
    }

    /// Update rows from QueryResultRow array
    func updateRows(_ newRows: [QueryResultRow]) {
        self.rows = newRows.enumerated().map { index, row in
            TableRowData(index: index, values: row.values)
        }
    }

    /// Append a new row with given values
    /// Returns the index of the new row
    func appendRow(values: [String?]) -> Int {
        let newIndex = rows.count
        let newRow = TableRowData(index: newIndex, values: values)
        rows.append(newRow)
        return newIndex
    }

    /// Remove row at index (used when discarding new rows)
    func removeRow(at index: Int) {
        guard index >= 0 && index < rows.count else { return }
        rows.remove(at: index)
        // Re-index remaining rows
        for i in index..<rows.count {
            rows[i] = TableRowData(index: i, values: rows[i].values)
        }
    }

    /// Remove multiple rows at indices (used when discarding new rows)
    /// Indices should be sorted in descending order to maintain correct removal
    func removeRows(at indices: Set<Int>) {
        for index in indices.sorted(by: >) {
            guard index >= 0 && index < rows.count else { continue }
            rows.remove(at: index)
        }
        // Re-index all remaining rows
        for i in 0..<rows.count {
            rows[i] = TableRowData(index: i, values: rows[i].values)
        }
    }
}

// MARK: - Database Row Provider (for virtualized access via driver)

/// Row provider that fetches data on-demand from database
final class DatabaseRowProvider: RowProvider {
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
                print("Prefetch error: \(error)")
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

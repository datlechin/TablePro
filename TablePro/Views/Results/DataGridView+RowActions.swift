//
//  DataGridView+RowActions.swift
//  TablePro
//
//  Row action methods extracted from DataGridView for maintainability.
//

import AppKit

// MARK: - Row Actions

extension TableViewCoordinator {
    @MainActor
    func undoDeleteRow(at index: Int) {
        changeManager.undoRowDeletion(rowIndex: index)
        tableView?.reloadData(
            forRowIndexes: IndexSet(integer: index),
            columnIndexes: IndexSet(integersIn: 0..<(tableView?.numberOfColumns ?? 0)))
    }

    func addNewRow() {
        onAddRow?()
    }

    @MainActor
    func undoInsertRow(at index: Int) {
        onUndoInsert?(index)
        changeManager.undoRowInsertion(rowIndex: index)
        rowProvider.removeRow(at: index)
        updateCache()
        tableView?.reloadData()
    }

    func copyRows(at indices: Set<Int>) {
        let sortedIndices = indices.sorted()
        var lines: [String] = []

        for index in sortedIndices {
            guard let values = rowProvider.rowValues(at: index) else { continue }
            let line = values.map { $0 ?? "NULL" }.joined(separator: "\t")
            lines.append(line)
        }

        let text = lines.joined(separator: "\n")
        ClipboardService.shared.writeText(text)
    }

    func copyRowsWithHeaders(at indices: Set<Int>) {
        let sortedIndices = indices.sorted()
        var lines: [String] = []

        // Add header row
        lines.append(rowProvider.columns.joined(separator: "\t"))

        for index in sortedIndices {
            guard let values = rowProvider.rowValues(at: index) else { continue }
            let line = values.map { $0 ?? "NULL" }.joined(separator: "\t")
            lines.append(line)
        }

        let text = lines.joined(separator: "\n")
        ClipboardService.shared.writeText(text)
    }

    @MainActor
    func setCellValue(_ value: String?, at rowIndex: Int) {
        guard let tableView = tableView else { return }
        var columnIndex = max(0, tableView.selectedColumn - 1)
        if columnIndex < 0 { columnIndex = 0 }
        setCellValueAtColumn(value, at: rowIndex, columnIndex: columnIndex)
    }

    @MainActor
    func setCellValueAtColumn(_ value: String?, at rowIndex: Int, columnIndex: Int) {
        guard let tableView = tableView else { return }
        guard columnIndex >= 0 && columnIndex < rowProvider.columns.count else { return }

        let columnName = rowProvider.columns[columnIndex]
        let oldValue = rowProvider.value(atRow: rowIndex, column: columnIndex)
        let originalRow = rowProvider.rowValues(at: rowIndex) ?? []

        changeManager.recordCellChange(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: value,
            originalRow: originalRow
        )

        rowProvider.updateValue(value, at: rowIndex, columnIndex: columnIndex)

        let tableColumnIndex = columnIndex + 1
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: rowIndex),
            columnIndexes: IndexSet(integer: tableColumnIndex))
    }

    func copyCellValue(at rowIndex: Int, columnIndex: Int) {
        guard columnIndex >= 0 && columnIndex < rowProvider.columns.count else { return }

        let value = rowProvider.value(atRow: rowIndex, column: columnIndex) ?? "NULL"
        ClipboardService.shared.writeText(value)
    }

    func copyRowsAsInsert(at indices: Set<Int>) {
        guard let tableName, let databaseType else { return }
        let driver = resolveDriver()
        let converter = SQLRowToStatementConverter(
            tableName: tableName,
            columns: rowProvider.columns,
            primaryKeyColumn: primaryKeyColumn,
            databaseType: databaseType,
            quoteIdentifier: driver?.quoteIdentifier,
            escapeStringLiteral: driver?.escapeStringLiteral
        )
        let rows = indices.sorted().compactMap { rowProvider.rowValues(at: $0) }
        guard !rows.isEmpty else { return }
        ClipboardService.shared.writeText(converter.generateInserts(rows: rows))
    }

    func copyRowsAsUpdate(at indices: Set<Int>) {
        guard let tableName, let databaseType else { return }
        let driver = resolveDriver()
        let converter = SQLRowToStatementConverter(
            tableName: tableName,
            columns: rowProvider.columns,
            primaryKeyColumn: primaryKeyColumn,
            databaseType: databaseType,
            quoteIdentifier: driver?.quoteIdentifier,
            escapeStringLiteral: driver?.escapeStringLiteral
        )
        let rows = indices.sorted().compactMap { rowProvider.rowValues(at: $0) }
        guard !rows.isEmpty else { return }
        ClipboardService.shared.writeText(converter.generateUpdates(rows: rows))
    }

    func copyRowsAsJson(at indices: Set<Int>) {
        let rows = indices.sorted().compactMap { rowProvider.rowValues(at: $0) }
        guard !rows.isEmpty else { return }
        let columnTypes = (rowProvider as? InMemoryRowProvider)?.columnTypes
            ?? Array(repeating: ColumnType.text(rawType: nil), count: rowProvider.columns.count)
        let converter = JsonRowConverter(columns: rowProvider.columns, columnTypes: columnTypes)
        ClipboardService.shared.writeText(converter.generateJson(rows: rows))
    }

    private func resolveDriver() -> (any DatabaseDriver)? {
        guard let connectionId else { return nil }
        return DatabaseManager.shared.driver(for: connectionId)
    }
}

//
//  RowOperationsManager.swift
//  TablePro
//
//  Service responsible for row operations: add, delete, duplicate, undo/redo.
//  Extracted from MainContentView for better separation of concerns.
//

import AppKit
import Foundation

/// Manager for row operations in the data grid
@MainActor
final class RowOperationsManager {
    // MARK: - Dependencies

    private let changeManager: DataChangeManager

    // MARK: - Initialization

    init(changeManager: DataChangeManager) {
        self.changeManager = changeManager
    }

    // MARK: - Add Row

    /// Add a new row to a table tab
    /// - Parameters:
    ///   - columns: Column names
    ///   - columnDefaults: Column default values
    ///   - resultRows: Current rows (will be mutated)
    /// - Returns: Tuple of (newRowIndex, newRowValues) or nil if failed
    func addNewRow(
        columns: [String],
        columnDefaults: [String: String?],
        resultRows: inout [QueryResultRow]
    ) -> (rowIndex: Int, values: [String?])? {
        // Create new row values with DEFAULT markers
        var newRowValues: [String?] = []
        for column in columns {
            if let defaultValue = columnDefaults[column], defaultValue != nil {
                // Use __DEFAULT__ marker so generateInsertSQL skips this column
                newRowValues.append("__DEFAULT__")
            } else {
                // NULL for columns without defaults
                newRowValues.append(nil)
            }
        }

        // Add to resultRows
        let newRow = QueryResultRow(values: newRowValues)
        resultRows.append(newRow)

        // Get the new row index
        let newRowIndex = resultRows.count - 1

        // Record in change manager as pending INSERT
        changeManager.recordRowInsertion(rowIndex: newRowIndex, values: newRowValues)

        return (newRowIndex, newRowValues)
    }

    // MARK: - Duplicate Row

    /// Duplicate a row with new primary key
    /// - Parameters:
    ///   - sourceRowIndex: Index of row to duplicate
    ///   - columns: Column names
    ///   - resultRows: Current rows (will be mutated)
    /// - Returns: Tuple of (newRowIndex, newRowValues) or nil if failed
    func duplicateRow(
        sourceRowIndex: Int,
        columns: [String],
        resultRows: inout [QueryResultRow]
    ) -> (rowIndex: Int, values: [String?])? {
        guard sourceRowIndex < resultRows.count else { return nil }

        // Copy values from selected row
        let sourceRow = resultRows[sourceRowIndex]
        var newValues = sourceRow.values

        // Set primary key column to DEFAULT so DB auto-generates
        if let pkColumn = changeManager.primaryKeyColumn,
           let pkIndex = columns.firstIndex(of: pkColumn) {
            newValues[pkIndex] = "__DEFAULT__"
        }

        // Add the duplicated row
        let newRow = QueryResultRow(values: newValues)
        resultRows.append(newRow)

        // Get the new row index
        let newRowIndex = resultRows.count - 1

        // Record in change manager as pending INSERT
        changeManager.recordRowInsertion(rowIndex: newRowIndex, values: newValues)

        return (newRowIndex, newValues)
    }

    // MARK: - Delete Rows

    /// Delete selected rows
    /// - Parameters:
    ///   - selectedIndices: Indices of rows to delete
    ///   - resultRows: Current rows (will be mutated)
    /// - Returns: Next row index to select after deletion, or -1 if no rows left
    func deleteSelectedRows(
        selectedIndices: Set<Int>,
        resultRows: inout [QueryResultRow]
    ) -> Int {
        guard !selectedIndices.isEmpty else { return -1 }

        // Separate inserted rows from existing rows
        var insertedRowsToDelete: [Int] = []
        var existingRowsToDelete: [(rowIndex: Int, originalRow: [String?])] = []

        // Find the lowest selected row index for selection movement
        let minSelectedRow = selectedIndices.min() ?? 0
        let maxSelectedRow = selectedIndices.max() ?? 0

        // Categorize rows (process in descending order to maintain correct indices)
        for rowIndex in selectedIndices.sorted(by: >) {
            if changeManager.isRowInserted(rowIndex) {
                insertedRowsToDelete.append(rowIndex)
            } else if !changeManager.isRowDeleted(rowIndex) {
                if rowIndex < resultRows.count {
                    let originalRow = resultRows[rowIndex].values
                    existingRowsToDelete.append((rowIndex: rowIndex, originalRow: originalRow))
                }
            }
        }

        // Process inserted rows deletion
        if !insertedRowsToDelete.isEmpty {
            let sortedInsertedRows = insertedRowsToDelete.sorted(by: >)

            // Remove from resultRows first (descending order)
            for rowIndex in sortedInsertedRows {
                guard rowIndex < resultRows.count else { continue }
                resultRows.remove(at: rowIndex)
            }

            // Update changeManager for ALL deleted inserted rows at once
            changeManager.undoBatchRowInsertion(rowIndices: sortedInsertedRows)
        }

        // Record batch deletion for existing rows (single undo action for all rows)
        if !existingRowsToDelete.isEmpty {
            changeManager.recordBatchRowDeletion(rows: existingRowsToDelete)
        }

        // Calculate next row selection, accounting for deleted inserted rows
        let totalRows = resultRows.count
        let rowsDeleted = insertedRowsToDelete.count
        let adjustedMaxRow = maxSelectedRow - rowsDeleted
        let adjustedMinRow = minSelectedRow - insertedRowsToDelete.filter { $0 < minSelectedRow }.count

        if adjustedMaxRow + 1 < totalRows {
            return min(adjustedMaxRow + 1, totalRows - 1)
        } else if adjustedMinRow > 0 {
            return adjustedMinRow - 1
        } else if totalRows > 0 {
            return 0
        } else {
            return -1
        }
    }

    // MARK: - Undo/Redo

    /// Undo the last change
    /// - Parameter resultRows: Current rows (will be mutated)
    /// - Returns: Updated selection indices
    func undoLastChange(resultRows: inout [QueryResultRow]) -> Set<Int>? {
        guard let result = changeManager.undoLastChange() else { return nil }

        var adjustedSelection: Set<Int>?

        switch result.action {
        case .cellEdit(let rowIndex, let columnIndex, _, let previousValue, _):
            if rowIndex < resultRows.count {
                resultRows[rowIndex].values[columnIndex] = previousValue
            }

        case .rowInsertion(let rowIndex):
            if rowIndex < resultRows.count {
                resultRows.remove(at: rowIndex)
                adjustedSelection = Set<Int>()
            }

        case .rowDeletion:
            // Row is restored in changeManager - visual indicator will be removed
            break

        case .batchRowDeletion:
            // All rows are restored in changeManager
            break

        case .batchRowInsertion(let rowIndices, let rowValues):
            // Restore deleted inserted rows - add them back to resultRows
            for (index, rowIndex) in rowIndices.enumerated().reversed() {
                guard index < rowValues.count else { continue }
                guard rowIndex <= resultRows.count else { continue }

                let values = rowValues[index]
                let newRow = QueryResultRow(values: values)
                resultRows.insert(newRow, at: rowIndex)
            }
        }

        return adjustedSelection
    }

    /// Redo the last undone change
    /// - Parameters:
    ///   - resultRows: Current rows (will be mutated)
    ///   - columns: Column names for new row creation
    /// - Returns: Updated selection indices
    func redoLastChange(resultRows: inout [QueryResultRow], columns: [String]) -> Set<Int>? {
        guard let result = changeManager.redoLastChange() else { return nil }

        switch result.action {
        case .cellEdit(let rowIndex, let columnIndex, _, _, let newValue):
            if rowIndex < resultRows.count {
                resultRows[rowIndex].values[columnIndex] = newValue
            }

        case .rowInsertion(let rowIndex):
            let newValues = [String?](repeating: nil, count: columns.count)
            let newRow = QueryResultRow(values: newValues)
            if rowIndex <= resultRows.count {
                resultRows.insert(newRow, at: rowIndex)
            }

        case .rowDeletion:
            // Row is re-marked as deleted in changeManager
            break

        case .batchRowDeletion:
            // Rows are re-marked as deleted
            break

        case .batchRowInsertion(let rowIndices, _):
            // Redo the deletion - remove the rows from resultRows again
            for rowIndex in rowIndices.sorted(by: >) {
                guard rowIndex < resultRows.count else { continue }
                resultRows.remove(at: rowIndex)
            }
        }

        return nil
    }

    // MARK: - Undo Insert Row

    /// Remove a row that was inserted (called by undo context menu)
    /// - Parameters:
    ///   - rowIndex: Index of the inserted row
    ///   - resultRows: Current rows (will be mutated)
    ///   - selectedIndices: Current selection (will be adjusted)
    /// - Returns: Adjusted selection indices
    func undoInsertRow(
        at rowIndex: Int,
        resultRows: inout [QueryResultRow],
        selectedIndices: Set<Int>
    ) -> Set<Int> {
        guard rowIndex >= 0 && rowIndex < resultRows.count else { return selectedIndices }

        // Remove the row from resultRows
        resultRows.remove(at: rowIndex)

        // Adjust selection indices
        var adjustedSelection = Set<Int>()
        for idx in selectedIndices {
            if idx == rowIndex {
                continue  // Skip the removed row
            } else if idx > rowIndex {
                adjustedSelection.insert(idx - 1)
            } else {
                adjustedSelection.insert(idx)
            }
        }

        return adjustedSelection
    }

    // MARK: - Copy Rows

    /// Copy selected rows to clipboard as tab-separated values
    /// - Parameters:
    ///   - selectedIndices: Indices of rows to copy
    ///   - resultRows: Current rows
    func copySelectedRowsToClipboard(selectedIndices: Set<Int>, resultRows: [QueryResultRow]) {
        guard !selectedIndices.isEmpty else { return }

        let sortedIndices = selectedIndices.sorted()
        var lines: [String] = []

        for rowIndex in sortedIndices {
            guard rowIndex < resultRows.count else { continue }
            let row = resultRows[rowIndex]
            let line = row.values.map { $0 ?? "NULL" }.joined(separator: "\t")
            lines.append(line)
        }

        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

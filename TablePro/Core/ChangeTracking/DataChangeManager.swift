//
//  DataChangeManager.swift
//  TablePro
//
//  Manager for tracking data changes with O(1) lookups.
//  Delegates SQL generation to SQLStatementGenerator.
//  Delegates undo/redo stack management to DataChangeUndoManager.
//

import Combine
import Foundation

/// Manager for tracking and applying data changes
/// @MainActor ensures thread-safe access - critical for avoiding EXC_BAD_ACCESS
/// when multiple queries complete simultaneously (e.g., rapid sorting over SSH tunnel)
@MainActor
final class DataChangeManager: ObservableObject {
    @Published var changes: [RowChange] = []
    @Published var hasChanges: Bool = false
    @Published var reloadVersion: Int = 0  // Incremented to trigger table reload

    var tableName: String = ""
    var primaryKeyColumn: String?
    var databaseType: DatabaseType = .mysql

    // Simple storage with explicit deep copy to avoid memory corruption
    private var _columnsStorage: [String] = []
    var columns: [String] {
        get { _columnsStorage }
        set { _columnsStorage = newValue.map { String($0) } }
    }

    // MARK: - Cached Lookups for O(1) Performance

    /// Set of row indices that are marked for deletion - O(1) lookup
    private var deletedRowIndices: Set<Int> = []

    /// Set of row indices that are newly inserted - O(1) lookup
    private(set) var insertedRowIndices: Set<Int> = []

    /// Set of "rowIndex-colIndex" strings for modified cells - O(1) lookup
    private var modifiedCells: Set<String> = []

    /// Lazy storage for inserted row values - avoids creating CellChange objects until needed
    private var insertedRowData: [Int: [String?]] = [:]

    /// Undo/redo manager
    private let undoManager = DataChangeUndoManager()

    // MARK: - Undo/Redo Properties

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    // MARK: - Helper Methods

    private func cellKey(rowIndex: Int, columnIndex: Int) -> String {
        "\(rowIndex)-\(columnIndex)"
    }

    // MARK: - Configuration

    /// Clear all changes (called after successful save)
    func clearChanges() {
        changes.removeAll()
        deletedRowIndices.removeAll()
        insertedRowIndices.removeAll()
        modifiedCells.removeAll()
        insertedRowData.removeAll()
        undoManager.clearAll()
        hasChanges = false
        reloadVersion += 1
    }

    /// Atomically configure the manager for a new table
    func configureForTable(
        tableName: String,
        columns: [String],
        primaryKeyColumn: String?,
        databaseType: DatabaseType = .mysql
    ) {
        self.tableName = tableName
        self.columns = columns
        self.primaryKeyColumn = primaryKeyColumn
        self.databaseType = databaseType

        deletedRowIndices.removeAll()
        insertedRowIndices.removeAll()
        modifiedCells.removeAll()
        insertedRowData.removeAll()
        undoManager.clearAll()

        changes.removeAll()
        hasChanges = false
        reloadVersion += 1
    }

    // MARK: - Change Tracking

    func recordCellChange(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: String?,
        newValue: String?,
        originalRow: [String?]? = nil
    ) {
        guard oldValue != newValue else { return }

        let cellChange = CellChange(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue
        )

        let key = cellKey(rowIndex: rowIndex, columnIndex: columnIndex)

        // Check if this is an edit to an INSERTED row
        if let insertIndex = changes.firstIndex(where: {
            $0.rowIndex == rowIndex && $0.type == .insert
        }) {
            // Update stored values directly
            if var storedValues = insertedRowData[rowIndex] {
                if columnIndex < storedValues.count {
                    storedValues[columnIndex] = newValue
                    insertedRowData[rowIndex] = storedValues
                }
            }

            // Update/create CellChange for this column
            if let cellIndex = changes[insertIndex].cellChanges.firstIndex(where: {
                $0.columnIndex == columnIndex
            }) {
                changes[insertIndex].cellChanges[cellIndex] = CellChange(
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    columnName: columnName,
                    oldValue: nil,
                    newValue: newValue
                )
            } else {
                changes[insertIndex].cellChanges.append(CellChange(
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    columnName: columnName,
                    oldValue: nil,
                    newValue: newValue
                ))
            }
            pushUndo(.cellEdit(
                rowIndex: rowIndex,
                columnIndex: columnIndex,
                columnName: columnName,
                previousValue: oldValue,
                newValue: newValue
            ))
            hasChanges = !changes.isEmpty
            return
        }

        // Find existing UPDATE row change or create new one
        if let existingIndex = changes.firstIndex(where: {
            $0.rowIndex == rowIndex && $0.type == .update
        }) {
            if let cellIndex = changes[existingIndex].cellChanges.firstIndex(where: {
                $0.columnIndex == columnIndex
            }) {
                let originalOldValue = changes[existingIndex].cellChanges[cellIndex].oldValue
                changes[existingIndex].cellChanges[cellIndex] = CellChange(
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    columnName: columnName,
                    oldValue: originalOldValue,
                    newValue: newValue
                )

                // If value is back to original, remove the change
                if originalOldValue == newValue {
                    changes[existingIndex].cellChanges.remove(at: cellIndex)
                    modifiedCells.remove(key)
                    if changes[existingIndex].cellChanges.isEmpty {
                        changes.remove(at: existingIndex)
                    }
                }
            } else {
                changes[existingIndex].cellChanges.append(cellChange)
                modifiedCells.insert(key)
            }
        } else {
            let rowChange = RowChange(
                rowIndex: rowIndex,
                type: .update,
                cellChanges: [cellChange],
                originalRow: originalRow
            )
            changes.append(rowChange)
            modifiedCells.insert(key)
        }

        pushUndo(.cellEdit(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: columnName,
            previousValue: oldValue,
            newValue: newValue
        ))
        hasChanges = !changes.isEmpty
    }

    func recordRowDeletion(rowIndex: Int, originalRow: [String?]) {
        changes.removeAll { $0.rowIndex == rowIndex && $0.type == .update }
        modifiedCells = modifiedCells.filter { !$0.hasPrefix("\(rowIndex)-") }

        let rowChange = RowChange(rowIndex: rowIndex, type: .delete, originalRow: originalRow)
        changes.append(rowChange)
        deletedRowIndices.insert(rowIndex)
        pushUndo(.rowDeletion(rowIndex: rowIndex, originalRow: originalRow))
        hasChanges = true
        reloadVersion += 1
    }

    func recordBatchRowDeletion(rows: [(rowIndex: Int, originalRow: [String?])]) {
        guard rows.count > 1 else {
            if let row = rows.first {
                recordRowDeletion(rowIndex: row.rowIndex, originalRow: row.originalRow)
            }
            return
        }

        var batchData: [(rowIndex: Int, originalRow: [String?])] = []

        for (rowIndex, originalRow) in rows {
            changes.removeAll { $0.rowIndex == rowIndex && $0.type == .update }
            modifiedCells = modifiedCells.filter { !$0.hasPrefix("\(rowIndex)-") }

            let rowChange = RowChange(rowIndex: rowIndex, type: .delete, originalRow: originalRow)
            changes.append(rowChange)
            deletedRowIndices.insert(rowIndex)
            batchData.append((rowIndex: rowIndex, originalRow: originalRow))
        }

        pushUndo(.batchRowDeletion(rows: batchData))
        hasChanges = true
        reloadVersion += 1
    }

    func recordRowInsertion(rowIndex: Int, values: [String?]) {
        insertedRowData[rowIndex] = values
        let rowChange = RowChange(rowIndex: rowIndex, type: .insert, cellChanges: [])
        changes.append(rowChange)
        insertedRowIndices.insert(rowIndex)
        pushUndo(.rowInsertion(rowIndex: rowIndex))
        hasChanges = true
    }

    // MARK: - Undo Operations

    func undoRowDeletion(rowIndex: Int) {
        guard deletedRowIndices.contains(rowIndex) else { return }
        changes.removeAll { $0.rowIndex == rowIndex && $0.type == .delete }
        deletedRowIndices.remove(rowIndex)
        hasChanges = !changes.isEmpty
        reloadVersion += 1
    }

    func undoRowInsertion(rowIndex: Int) {
        guard insertedRowIndices.contains(rowIndex) else { return }

        changes.removeAll { $0.rowIndex == rowIndex && $0.type == .insert }
        insertedRowIndices.remove(rowIndex)
        insertedRowData.removeValue(forKey: rowIndex)

        // Shift down indices for rows after the removed row
        var shiftedInsertedIndices = Set<Int>()
        for idx in insertedRowIndices {
            shiftedInsertedIndices.insert(idx > rowIndex ? idx - 1 : idx)
        }
        insertedRowIndices = shiftedInsertedIndices

        for i in 0..<changes.count {
            if changes[i].rowIndex > rowIndex {
                changes[i].rowIndex -= 1
            }
        }

        hasChanges = !changes.isEmpty
    }

    func undoBatchRowInsertion(rowIndices: [Int]) {
        guard !rowIndices.isEmpty else { return }

        let validRows = rowIndices.filter { insertedRowIndices.contains($0) }
        guard !validRows.isEmpty else { return }

        // Collect row values for undo/redo
        var rowValues: [[String?]] = []
        for rowIndex in validRows {
            if let insertChange = changes.first(where: { $0.rowIndex == rowIndex && $0.type == .insert }) {
                let values = insertChange.cellChanges.sorted { $0.columnIndex < $1.columnIndex }
                    .map { $0.newValue }
                rowValues.append(values)
            } else {
                rowValues.append(Array(repeating: nil, count: columns.count))
            }
        }

        for rowIndex in validRows {
            changes.removeAll { $0.rowIndex == rowIndex && $0.type == .insert }
            insertedRowIndices.remove(rowIndex)
            insertedRowData.removeValue(forKey: rowIndex)
        }

        pushUndo(.batchRowInsertion(rowIndices: validRows, rowValues: rowValues))

        for deletedIndex in validRows.reversed() {
            var shiftedIndices = Set<Int>()
            for idx in insertedRowIndices {
                shiftedIndices.insert(idx > deletedIndex ? idx - 1 : idx)
            }
            insertedRowIndices = shiftedIndices

            for i in 0..<changes.count {
                if changes[i].rowIndex > deletedIndex {
                    changes[i].rowIndex -= 1
                }
            }
        }

        hasChanges = !changes.isEmpty
    }

    // MARK: - Undo/Redo Stack Management

    func pushUndo(_ action: UndoAction) {
        undoManager.push(action)
    }

    func popUndo() -> UndoAction? {
        undoManager.popUndo()
    }

    func clearUndoStack() {
        undoManager.clearUndo()
    }

    func clearRedoStack() {
        undoManager.clearRedo()
    }

    /// Undo the last change and return details needed to update the UI
    func undoLastChange() -> (action: UndoAction, needsRowRemoval: Bool, needsRowRestore: Bool, restoreRow: [String?]?)? {
        guard let action = popUndo() else { return nil }

        undoManager.moveToRedo(action)

        switch action {
        case .cellEdit(let rowIndex, let columnIndex, let columnName, let previousValue, _):
            if let changeIndex = changes.firstIndex(where: {
                $0.rowIndex == rowIndex && ($0.type == .update || $0.type == .insert)
            }) {
                if let cellIndex = changes[changeIndex].cellChanges.firstIndex(where: {
                    $0.columnIndex == columnIndex
                }) {
                    if changes[changeIndex].type == .update {
                        let originalValue = changes[changeIndex].cellChanges[cellIndex].oldValue
                        if previousValue == originalValue {
                            changes[changeIndex].cellChanges.remove(at: cellIndex)
                            modifiedCells.remove(cellKey(rowIndex: rowIndex, columnIndex: columnIndex))
                            if changes[changeIndex].cellChanges.isEmpty {
                                changes.remove(at: changeIndex)
                            }
                        } else {
                            let originalOldValue = changes[changeIndex].cellChanges[cellIndex].oldValue
                            changes[changeIndex].cellChanges[cellIndex] = CellChange(
                                rowIndex: rowIndex,
                                columnIndex: columnIndex,
                                columnName: columnName,
                                oldValue: originalOldValue,
                                newValue: previousValue
                            )
                        }
                    } else if changes[changeIndex].type == .insert {
                        changes[changeIndex].cellChanges[cellIndex] = CellChange(
                            rowIndex: rowIndex,
                            columnIndex: columnIndex,
                            columnName: columnName,
                            oldValue: nil,
                            newValue: previousValue
                        )
                    }
                }
            }
            hasChanges = !changes.isEmpty
            reloadVersion += 1
            return (action, false, false, nil)

        case .rowInsertion(let rowIndex):
            undoRowInsertion(rowIndex: rowIndex)
            return (action, true, false, nil)

        case .rowDeletion(let rowIndex, let originalRow):
            undoRowDeletion(rowIndex: rowIndex)
            return (action, false, true, originalRow)

        case .batchRowDeletion(let rows):
            for (rowIndex, _) in rows.reversed() {
                undoRowDeletion(rowIndex: rowIndex)
            }
            return (action, false, true, nil)

        case .batchRowInsertion(let rowIndices, let rowValues):
            for (index, rowIndex) in rowIndices.enumerated().reversed() {
                guard index < rowValues.count else { continue }
                let values = rowValues[index]

                let cellChanges = values.enumerated().map { colIndex, value in
                    CellChange(
                        rowIndex: rowIndex,
                        columnIndex: colIndex,
                        columnName: columns[safe: colIndex] ?? "",
                        oldValue: nil,
                        newValue: value
                    )
                }
                let rowChange = RowChange(rowIndex: rowIndex, type: .insert, cellChanges: cellChanges)
                changes.append(rowChange)
                insertedRowIndices.insert(rowIndex)
            }

            hasChanges = !changes.isEmpty
            reloadVersion += 1
            return (action, true, false, nil)
        }
    }

    /// Redo the last undone change
    func redoLastChange() -> (action: UndoAction, needsRowInsert: Bool, needsRowDelete: Bool)? {
        guard let action = undoManager.popRedo() else { return nil }

        undoManager.moveToUndo(action)

        switch action {
        case .cellEdit(let rowIndex, let columnIndex, let columnName, let previousValue, let newValue):
            recordCellChange(
                rowIndex: rowIndex,
                columnIndex: columnIndex,
                columnName: columnName,
                oldValue: previousValue,
                newValue: newValue
            )
            _ = undoManager.popUndo()  // Remove extra undo
            reloadVersion += 1
            return (action, false, false)

        case .rowInsertion(let rowIndex):
            insertedRowIndices.insert(rowIndex)
            let cellChanges = columns.enumerated().map { index, columnName in
                CellChange(
                    rowIndex: rowIndex,
                    columnIndex: index,
                    columnName: columnName,
                    oldValue: nil,
                    newValue: nil
                )
            }
            let rowChange = RowChange(rowIndex: rowIndex, type: .insert, cellChanges: cellChanges)
            changes.append(rowChange)
            hasChanges = true
            reloadVersion += 1
            return (action, true, false)

        case .rowDeletion(let rowIndex, let originalRow):
            recordRowDeletion(rowIndex: rowIndex, originalRow: originalRow)
            _ = undoManager.popUndo()
            return (action, false, true)

        case .batchRowDeletion(let rows):
            for (rowIndex, originalRow) in rows {
                recordRowDeletion(rowIndex: rowIndex, originalRow: originalRow)
                _ = undoManager.popUndo()
            }
            return (action, false, true)

        case .batchRowInsertion(let rowIndices, _):
            for rowIndex in rowIndices {
                changes.removeAll { $0.rowIndex == rowIndex && $0.type == .insert }
                insertedRowIndices.remove(rowIndex)
            }
            hasChanges = !changes.isEmpty
            reloadVersion += 1
            return (action, true, false)
        }
    }

    // MARK: - SQL Generation

    func generateSQL() throws -> [String] {
        let generator = SQLStatementGenerator(
            tableName: tableName,
            columns: columns,
            primaryKeyColumn: primaryKeyColumn,
            databaseType: databaseType
        )
        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )

        // Count expected UPDATE statements (DELETEs can work without PK using full row match)
        let expectedUpdates = changes.filter { $0.type == .update }.count
        let actualUpdates = statements.filter { $0.hasPrefix("UPDATE") }.count

        // Check if any UPDATE statements were skipped due to missing primary key
        // Note: DELETEs are allowed without PK (they match all columns)
        if expectedUpdates > 0 && actualUpdates < expectedUpdates {
            throw DatabaseError.queryFailed(
                "Cannot save UPDATE changes to table '\(tableName)' without a primary key. " +
                    "Please add a primary key to this table or use raw SQL queries instead."
            )
        }

        return statements
    }

    // MARK: - Actions

    func getOriginalValues() -> [(rowIndex: Int, columnIndex: Int, value: String?)] {
        var originals: [(rowIndex: Int, columnIndex: Int, value: String?)] = []

        for change in changes {
            if change.type == .update {
                for cellChange in change.cellChanges {
                    originals.append((
                        rowIndex: change.rowIndex,
                        columnIndex: cellChange.columnIndex,
                        value: cellChange.oldValue
                    ))
                }
            }
        }

        return originals
    }

    func discardChanges() {
        changes.removeAll()
        deletedRowIndices.removeAll()
        insertedRowIndices.removeAll()
        modifiedCells.removeAll()
        insertedRowData.removeAll()
        hasChanges = false
        reloadVersion += 1
    }

    // MARK: - Per-Tab State Management

    func saveState() -> TabPendingChanges {
        var state = TabPendingChanges()
        state.changes = changes
        state.deletedRowIndices = deletedRowIndices
        state.insertedRowIndices = insertedRowIndices
        state.modifiedCells = modifiedCells
        state.insertedRowData = insertedRowData
        state.primaryKeyColumn = primaryKeyColumn
        state.columns = columns
        return state
    }

    func restoreState(from state: TabPendingChanges, tableName: String) {
        self.tableName = tableName
        self.changes = state.changes
        self.deletedRowIndices = state.deletedRowIndices
        self.insertedRowIndices = state.insertedRowIndices
        self.modifiedCells = state.modifiedCells
        self.insertedRowData = state.insertedRowData
        self.primaryKeyColumn = state.primaryKeyColumn
        self.columns = state.columns
        self.hasChanges = !state.changes.isEmpty
    }

    // MARK: - O(1) Lookups

    func isRowDeleted(_ rowIndex: Int) -> Bool {
        deletedRowIndices.contains(rowIndex)
    }

    func isRowInserted(_ rowIndex: Int) -> Bool {
        insertedRowIndices.contains(rowIndex)
    }

    func isCellModified(rowIndex: Int, columnIndex: Int) -> Bool {
        modifiedCells.contains(cellKey(rowIndex: rowIndex, columnIndex: columnIndex))
    }

    func getModifiedColumnsForRow(_ rowIndex: Int) -> Set<Int> {
        var result: Set<Int> = []
        let prefix = "\(rowIndex)-"
        for key in modifiedCells {
            if key.hasPrefix(prefix) {
                if let colIndex = Int(key.dropFirst(prefix.count)) {
                    result.insert(colIndex)
                }
            }
        }
        return result
    }
}

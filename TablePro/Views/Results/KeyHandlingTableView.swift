//
//  KeyHandlingTableView.swift
//  TablePro
//
//  NSTableView subclass that handles Delete key and TablePlus-style cell focus.
//  Extracted from DataGridView for better maintainability.
//

import AppKit

/// NSTableView subclass that handles Delete key to mark rows for deletion
/// Also implements TablePlus-style cell focus on click
final class KeyHandlingTableView: NSTableView, NSMenuItemValidation {
    weak var coordinator: TableViewCoordinator?

    /// Currently focused row index (-1 = no focus)
    var focusedRow: Int = -1 {
        didSet {
            if oldValue != focusedRow && oldValue >= 0 {
                if focusedColumn >= 0 && focusedColumn < numberOfColumns && oldValue < numberOfRows {
                    reloadData(forRowIndexes: IndexSet(integer: oldValue),
                               columnIndexes: IndexSet(integer: focusedColumn))
                }
            }
        }
    }

    /// Currently focused column index (-1 = no focus, 0 = row number column)
    var focusedColumn: Int = -1 {
        didSet {
            if oldValue != focusedColumn {
                let rowToUpdate = focusedRow
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if oldValue >= 0 && oldValue < self.numberOfColumns && rowToUpdate >= 0 && rowToUpdate < self.numberOfRows {
                        self.reloadData(forRowIndexes: IndexSet(integer: rowToUpdate),
                                        columnIndexes: IndexSet(integer: oldValue))
                    }
                    if self.focusedColumn >= 0 && self.focusedColumn < self.numberOfColumns && self.focusedRow >= 0 && self.focusedRow < self.numberOfRows {
                        self.reloadData(forRowIndexes: IndexSet(integer: self.focusedRow),
                                        columnIndexes: IndexSet(integer: self.focusedColumn))
                    }
                }
            }
        }
    }

    /// Anchor row for Shift+Arrow range selection (-1 = no anchor)
    var selectionAnchor: Int = -1

    /// Current pivot row for Shift+Arrow navigation
    var selectionPivot: Int = -1

    // MARK: - TablePlus-Style Cell Focus

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedColumn = column(at: point)

        // Double-click in empty area adds a new row
        if event.clickCount == 2 && clickedRow == -1 && coordinator?.isEditable == true {
            NotificationCenter.default.post(name: .addNewRow, object: nil)
            return
        }

        // Reset anchor/pivot when clicking without Shift
        if clickedRow >= 0 && !event.modifierFlags.contains(.shift) {
            selectionAnchor = clickedRow
            selectionPivot = clickedRow
        }

        super.mouseDown(with: event)

        guard clickedRow >= 0,
              clickedColumn >= 0,
              clickedColumn < numberOfColumns,
              selectedRowIndexes.contains(clickedRow) else {
            return
        }

        let column = tableColumns[clickedColumn]
        if column.identifier.rawValue == "__rowNumber__" {
            focusedRow = -1
            focusedColumn = -1
            return
        }

        focusedRow = clickedRow
        focusedColumn = clickedColumn
        editColumn(clickedColumn, row: clickedRow, with: nil, select: false)
    }

    // MARK: - Standard Edit Menu Actions

    @objc func delete(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        guard !selectedRowIndexes.isEmpty else { return }
        NotificationCenter.default.post(name: .deleteSelectedRows, object: nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(delete(_:)) {
            return coordinator?.isEditable == true && !selectedRowIndexes.isEmpty
        }
        if let action = menuItem.action {
            return responds(to: action)
        }
        return false
    }

    // MARK: - Keyboard Handling

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 51 || event.keyCode == 117 {
            if !selectedRowIndexes.isEmpty && coordinator?.isEditable == true {
                NotificationCenter.default.post(name: .deleteSelectedRows, object: nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let row = selectedRow
        let isShiftHeld = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 126: // Up arrow
            handleUpArrow(currentRow: row, isShiftHeld: isShiftHeld)
            return

        case 125: // Down arrow
            handleDownArrow(currentRow: row, isShiftHeld: isShiftHeld)
            return

        case 123: // Left arrow
            if focusedColumn > 1 {
                focusedColumn -= 1
                if row >= 0 { scrollColumnToVisible(focusedColumn) }
            } else if focusedColumn == -1 && numberOfColumns > 1 {
                focusedColumn = numberOfColumns - 1
                if row >= 0 { scrollColumnToVisible(focusedColumn) }
            }
            return

        case 124: // Right arrow
            if focusedColumn >= 1 && focusedColumn < numberOfColumns - 1 {
                focusedColumn += 1
                if row >= 0 { scrollColumnToVisible(focusedColumn) }
            } else if focusedColumn == -1 && numberOfColumns > 1 {
                focusedColumn = 1
                if row >= 0 { scrollColumnToVisible(focusedColumn) }
            }
            return

        case 36: // Enter/Return
            if row >= 0 && focusedColumn >= 1 && coordinator?.isEditable == true {
                editColumn(focusedColumn, row: row, with: nil, select: true)
            }
            return

        case 53: // Escape
            focusedRow = -1
            focusedColumn = -1
            NotificationCenter.default.post(name: .clearSelection, object: nil)
            return

        case 51, 117: // Delete or Backspace
            if !selectedRowIndexes.isEmpty {
                NotificationCenter.default.post(name: .deleteSelectedRows, object: nil)
                return
            }

        case 48: // Tab
            if row >= 0 && focusedColumn >= 1 {
                var nextColumn = focusedColumn + 1
                var nextRow = row

                if nextColumn >= numberOfColumns {
                    nextColumn = 1
                    nextRow += 1
                }
                if nextRow >= numberOfRows {
                    nextRow = numberOfRows - 1
                    nextColumn = numberOfColumns - 1
                }

                selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
                focusedRow = nextRow
                focusedColumn = nextColumn
                scrollRowToVisible(nextRow)
                scrollColumnToVisible(nextColumn)
            }
            return

        default:
            break
        }

        super.keyDown(with: event)
    }

    // MARK: - Arrow Key Selection Helpers

    private func handleUpArrow(currentRow: Int, isShiftHeld: Bool) {
        guard numberOfRows > 0 else { return }

        if currentRow == -1 {
            let targetRow = numberOfRows - 1
            selectionAnchor = targetRow
            selectionPivot = targetRow
            focusedRow = targetRow
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            scrollRowToVisible(targetRow)
            return
        }

        if isShiftHeld {
            if selectionAnchor == -1 {
                selectionAnchor = currentRow
                selectionPivot = currentRow
            }

            let currentPivot = selectionPivot >= 0 ? selectionPivot : currentRow
            let targetRow = max(0, currentPivot - 1)
            selectionPivot = targetRow

            let startRow = min(selectionAnchor, selectionPivot)
            let endRow = max(selectionAnchor, selectionPivot)
            let range = IndexSet(integersIn: startRow...endRow)
            selectRowIndexes(range, byExtendingSelection: false)
            scrollRowToVisible(targetRow)
        } else {
            let targetRow = max(0, currentRow - 1)
            selectionAnchor = targetRow
            selectionPivot = targetRow
            focusedRow = targetRow
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            scrollRowToVisible(targetRow)
        }
    }

    private func handleDownArrow(currentRow: Int, isShiftHeld: Bool) {
        guard numberOfRows > 0 else { return }

        if currentRow == -1 {
            selectionAnchor = 0
            selectionPivot = 0
            focusedRow = 0
            selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            scrollRowToVisible(0)
            return
        }

        if isShiftHeld {
            if selectionAnchor == -1 {
                selectionAnchor = currentRow
                selectionPivot = currentRow
            }

            let currentPivot = selectionPivot >= 0 ? selectionPivot : currentRow
            let targetRow = min(numberOfRows - 1, currentPivot + 1)
            selectionPivot = targetRow

            let startRow = min(selectionAnchor, selectionPivot)
            let endRow = max(selectionAnchor, selectionPivot)
            let range = IndexSet(integersIn: startRow...endRow)
            selectRowIndexes(range, byExtendingSelection: false)
            scrollRowToVisible(targetRow)
        } else {
            let targetRow = min(numberOfRows - 1, currentRow + 1)
            selectionAnchor = targetRow
            selectionPivot = targetRow
            focusedRow = targetRow
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            scrollRowToVisible(targetRow)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        if clickedRow >= 0,
           let rowView = rowView(atRow: clickedRow, makeIfNecessary: false) as? TableRowViewWithMenu {
            if !selectedRowIndexes.contains(clickedRow) {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
            return rowView.menu(for: event)
        }

        return super.menu(for: event)
    }
}

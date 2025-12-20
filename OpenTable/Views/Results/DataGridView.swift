//
//  DataGridView.swift
//  OpenTable
//
//  High-performance NSTableView wrapper for SwiftUI
//

import AppKit
import SwiftUI

/// High-performance table view using AppKit NSTableView
/// Wrapped for SwiftUI via NSViewRepresentable
struct DataGridView: NSViewRepresentable {
    let rowProvider: InMemoryRowProvider
    @ObservedObject var changeManager: DataChangeManager
    let isEditable: Bool
    var onCommit: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onCellEdit: ((Int, Int, String?) -> Void)?  // (rowIndex, columnIndex, newValue)
    var onDeleteRows: ((Set<Int>) -> Void)?  // Called when Delete key pressed
    var onSort: ((Int, Bool) -> Void)?  // Called when column header clicked (columnIndex, ascending)

    @Binding var selectedRowIndices: Set<Int>
    @Binding var sortState: SortState

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // Use custom table view that handles Delete key
        let tableView = KeyHandlingTableView()
        tableView.coordinator = context.coordinator
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.rowHeight = 24

        // Set delegate and data source
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        // Add row number column
        let rowNumberColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("__rowNumber__"))
        rowNumberColumn.title = "#"
        rowNumberColumn.width = 40
        rowNumberColumn.minWidth = 40
        rowNumberColumn.maxWidth = 60
        rowNumberColumn.isEditable = false
        rowNumberColumn.resizingMask = []  // Disable resizing
        tableView.addTableColumn(rowNumberColumn)

        // Add data columns
        for (index, columnName) in rowProvider.columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(index)"))
            column.title = columnName
            
            // Auto-size column width to fit header text
            let calculatedWidth = calculateColumnWidth(for: columnName)
            column.width = calculatedWidth
            column.minWidth = 30
            // Don't set maxWidth - let column stay at calculated width
            column.resizingMask = .userResizingMask
            column.isEditable = isEditable
            // Use stable key for native sort descriptors (not column title which may change)
            // AppKit will automatically show native sort indicators when user clicks header
            column.sortDescriptorPrototype = NSSortDescriptor(key: "col_\(index)", ascending: true)

            tableView.addTableColumn(column)
        }
        
        // Use default NSTableHeaderView - 100% native sorting behavior
        // Set up context menu using NSMenuDelegate (no subclassing needed)
        if let headerView = tableView.headerView {
            let headerMenu = NSMenu()
            headerMenu.delegate = context.coordinator
            headerView.menu = headerMenu
        }

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView


        return scrollView
    }
    
    /// Calculate column width based on header text length
    private func calculateColumnWidth(for columnName: String) -> CGFloat {
        // Use header font (system default for table headers)
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = (columnName as NSString).size(withAttributes: attributes)
        
        // Add generous padding: 12px left + text + 24px for sort indicator + 12px right
        let width = size.width + 48
        
        // Min 30px, no max (always fit full header text)
        return max(width, 30)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }

        let coordinator = context.coordinator

        // Don't update while editing - this would cancel the edit
        if tableView.editedRow >= 0 {
            return
        }

        // Check if data source changed or changes were cleared (after save)
        let versionChanged = coordinator.lastReloadVersion != changeManager.reloadVersion

        // Use cached values for comparison to avoid potential issues with deallocated provider
        let oldRowCount = coordinator.cachedRowCount
        let oldColumnCount = coordinator.cachedColumnCount
        let newRowCount = rowProvider.totalRowCount
        let newColumnCount = rowProvider.columns.count

        // Check if row data changed (for sorting - same count but different order)
        let rowDataChanged: Bool = {
            if oldRowCount != newRowCount {
                return true
            }
            // Only compare first row if counts match and both have data
            if oldRowCount > 0 && newRowCount > 0 {
                if let oldFirstRow = coordinator.rowProvider.row(at: 0),
                    let newFirstRow = rowProvider.row(at: 0),
                    oldFirstRow.values != newFirstRow.values
                {
                    return true
                }
            }
            return false
        }()


        let needsReload =
            oldRowCount != newRowCount
            || oldColumnCount != newColumnCount
            || versionChanged
            || rowDataChanged

        // Update coordinator references (but not version tracker yet - see below)
        coordinator.rowProvider = rowProvider
        coordinator.updateCache()  // Update cached counts after provider change
        coordinator.changeManager = changeManager
        coordinator.isEditable = isEditable
        coordinator.onCommit = onCommit
        coordinator.onRefresh = onRefresh
        coordinator.onCellEdit = onCellEdit
        coordinator.onSort = onSort

        // Check if columns changed - compare actual column names, not just count
        let currentDataColumns = tableView.tableColumns.dropFirst() // Skip row number column
        let currentColumnNames = currentDataColumns.map { $0.title }
        
        // Only rebuild if columns actually changed AND we have columns to show
        let columnsChanged = !rowProvider.columns.isEmpty && (currentColumnNames != rowProvider.columns)
        
        if columnsChanged {
            // Rebuild columns - remove ALL data columns (keep only row number column)
            let columnsToRemove = tableView.tableColumns.filter { 
                $0.identifier.rawValue != "__rowNumber__" 
            }
            for column in columnsToRemove {
                tableView.removeTableColumn(column)
            }

            for (index, columnName) in rowProvider.columns.enumerated() {
                let column = NSTableColumn(
                    identifier: NSUserInterfaceItemIdentifier("col_\(index)"))
                
                column.title = columnName
                let calculatedWidth = calculateColumnWidth(for: columnName)
                column.width = calculatedWidth
                column.minWidth = 30
                // Don't set maxWidth - let column stay at calculated width
                column.resizingMask = .userResizingMask
                column.isEditable = isEditable

                // Use stable key for native sort descriptors
                column.sortDescriptorPrototype = NSSortDescriptor(key: "col_\(index)", ascending: true)

                tableView.addTableColumn(column)
            }
            
            // Force header to recalculate layout after column changes
            // Default NSTableHeaderView handles native sort indicators automatically
            tableView.sizeToFit()
        }

        // Sync SwiftUI sort state → NSTableView (one-way)
        // AppKit handles drawing native sort indicators automatically
        // Use flag to prevent delegate from triggering infinite loop
        coordinator.isSyncingSortDescriptors = true
        defer { coordinator.isSyncingSortDescriptors = false }
        
        if !sortState.isSorting {
            // No sort active - clear sort descriptors
            if !tableView.sortDescriptors.isEmpty {
                tableView.sortDescriptors = []
            }
        } else if let columnIndex = sortState.columnIndex,
                  columnIndex >= 0 && columnIndex < rowProvider.columns.count {
            let key = "col_\(columnIndex)"
            let ascending = sortState.direction == .ascending
            
            // Only update if different to avoid unnecessary updates
            let currentDescriptor = tableView.sortDescriptors.first
            if currentDescriptor?.key != key || currentDescriptor?.ascending != ascending {
                tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            }
        }

        // Only reload if data actually changed
        if needsReload {
            tableView.reloadData()
        }
        
        // CRITICAL: Update version tracker AFTER reload check
        // This ensures versionChanged is true when changeManager.reloadVersion increments
        // (e.g., when clearChanges() is called after discarding or saving changes)
        coordinator.lastReloadVersion = changeManager.reloadVersion

        // Sync selection
        let currentSelection = tableView.selectedRowIndexes
        let targetSelection = IndexSet(selectedRowIndices)

        if currentSelection != targetSelection {
            tableView.selectRowIndexes(targetSelection, byExtendingSelection: false)
        }
    }

    func makeCoordinator() -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            rowProvider: rowProvider,
            changeManager: changeManager,
            isEditable: isEditable,
            selectedRowIndices: $selectedRowIndices,
            onCommit: onCommit,
            onRefresh: onRefresh,
            onCellEdit: onCellEdit
        )
        
        // onColumnResize callback will be set by coordinator property directly
        // Coordinator will update columnWidths via binding when column is resized
        
        return coordinator
    }
}

// MARK: - Coordinator

/// Coordinator handling NSTableView delegate and data source
final class TableViewCoordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource,
    NSControlTextEditingDelegate, NSTextFieldDelegate, NSMenuDelegate
{
    var rowProvider: InMemoryRowProvider
    var changeManager: DataChangeManager
    var isEditable: Bool
    var onCommit: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onCellEdit: ((Int, Int, String?) -> Void)?

    weak var tableView: NSTableView?

    @Binding var selectedRowIndices: Set<Int>

    // Track reload version to detect changes cleared
    var lastReloadVersion: Int = 0

    // Cache column count and row count to avoid accessing potentially invalid provider
    private(set) var cachedRowCount: Int = 0
    private(set) var cachedColumnCount: Int = 0
    
    // Guard flag to prevent infinite loop when syncing sort descriptors
    // Set to true when programmatically setting sortDescriptors from updateNSView
    var isSyncingSortDescriptors: Bool = false

    // Cell reuse identifiers
    private let cellIdentifier = NSUserInterfaceItemIdentifier("DataCell")
    private let rowNumberCellIdentifier = NSUserInterfaceItemIdentifier("RowNumberCell")

    init(
        rowProvider: InMemoryRowProvider,
        changeManager: DataChangeManager,
        isEditable: Bool,
        selectedRowIndices: Binding<Set<Int>>,
        onCommit: ((String) -> Void)?,
        onRefresh: (() -> Void)?,
        onCellEdit: ((Int, Int, String?) -> Void)?
    ) {
        self.rowProvider = rowProvider
        self.changeManager = changeManager
        self.isEditable = isEditable
        self._selectedRowIndices = selectedRowIndices
        self.onCommit = onCommit
        self.onRefresh = onRefresh
        self.onCellEdit = onCellEdit
        super.init()
        updateCache()
    }

    /// Update cached counts from current rowProvider
    func updateCache() {
        cachedRowCount = rowProvider.totalRowCount
        cachedColumnCount = rowProvider.columns.count
    }

    /// Callback when column header clicked for sorting: (columnIndex, ascending)
    var onSort: ((Int, Bool) -> Void)?

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        // Use cached count for safety - updated when provider changes
        return cachedRowCount
    }
    
    // MARK: - Native Sorting via NSTableViewDelegate
    
    /// Called by AppKit when user clicks column header to sort
    /// This is the native NSTableView sorting mechanism
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        // CRITICAL: Ignore if we're programmatically syncing from SwiftUI
        // This prevents infinite loop: updateNSView → sortDescriptorsDidChange → onSort → updateNSView
        guard !isSyncingSortDescriptors else { return }
        
        // Get the new primary sort descriptor
        guard let sortDescriptor = tableView.sortDescriptors.first,
              let key = sortDescriptor.key,
              key.hasPrefix("col_"),
              let columnIndex = Int(key.dropFirst(4)) else {
            return
        }
        
        // Validate column index
        guard columnIndex >= 0 && columnIndex < rowProvider.columns.count else {
            return
        }
        
        // Call parent's sort handler with column index AND direction from AppKit
        // This ensures parent uses the exact direction AppKit determined
        onSort?(columnIndex, sortDescriptor.ascending)
    }
    
    // MARK: - NSMenuDelegate (Header Context Menu)
    
    /// Dynamically populate header context menu based on clicked column
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        
        guard let tableView = tableView,
              let headerView = tableView.headerView,
              let window = tableView.window else {
            return
        }
        
        // Get mouse location in header coordinates
        let mouseLocation = window.mouseLocationOutsideOfEventStream
        let pointInHeader = headerView.convert(mouseLocation, from: nil)
        let columnIndex = headerView.column(at: pointInHeader)
        
        guard columnIndex >= 0 && columnIndex < tableView.tableColumns.count else {
            return
        }
        
        let column = tableView.tableColumns[columnIndex]
        
        // Skip row number column
        if column.identifier.rawValue == "__rowNumber__" {
            return
        }
        
        let copyItem = NSMenuItem(
            title: "Copy Column Name",
            action: #selector(copyColumnName(_:)),
            keyEquivalent: "")
        copyItem.representedObject = column.title
        copyItem.target = self
        menu.addItem(copyItem)
    }
    
    @objc private func copyColumnName(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(columnName, forType: .string)
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let column = tableColumn else { return nil }

        let columnId = column.identifier.rawValue

        // Row number column
        if columnId == "__rowNumber__" {
            return makeRowNumberCell(tableView: tableView, row: row)
        }

        // Data column
        guard columnId.hasPrefix("col_"),
            let columnIndex = Int(columnId.dropFirst(4))
        else {
            return nil
        }

        return makeDataCell(tableView: tableView, row: row, columnIndex: columnIndex)
    }

    private func makeRowNumberCell(tableView: NSTableView, row: Int) -> NSView {
        // Use NSTableCellView for proper vertical centering (same as data cells)
        let cellViewId = NSUserInterfaceItemIdentifier("RowNumberCellView")
        let cellView: NSTableCellView
        let cell: NSTextField

        if let reused = tableView.makeView(withIdentifier: cellViewId, owner: nil)
            as? NSTableCellView,
            let textField = reused.textField
        {
            cellView = reused
            cell = textField
        } else {
            // Create container view for vertical centering
            cellView = NSTableCellView()
            cellView.identifier = cellViewId

            // Create text field
            cell = NSTextField(labelWithString: "")
            cell.alignment = .right
            cell.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.textColor = .secondaryLabelColor
            cell.translatesAutoresizingMaskIntoConstraints = false

            cellView.textField = cell
            cellView.addSubview(cell)

            // Center text field vertically, stretch horizontally with padding
            NSLayoutConstraint.activate([
                cell.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                cell.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                cell.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        // Boundary check
        guard row >= 0 && row < cachedRowCount else {
            cell.stringValue = ""
            return cellView
        }

        cell.stringValue = "\(row + 1)"

        // Style deleted rows
        if changeManager.isRowDeleted(row) {
            cell.textColor = .systemRed.withAlphaComponent(0.5)
        } else {
            cell.textColor = .secondaryLabelColor
        }

        return cellView
    }

    private func makeDataCell(tableView: NSTableView, row: Int, columnIndex: Int) -> NSView {
        // Use NSTableCellView for proper vertical centering
        let cellViewId = NSUserInterfaceItemIdentifier("DataCellView")
        let cellView: NSTableCellView
        let cell: NSTextField

        if let reused = tableView.makeView(withIdentifier: cellViewId, owner: nil)
            as? NSTableCellView,
            let textField = reused.textField
        {
            cellView = reused
            cell = textField
        } else {
            // Create container view for vertical centering
            cellView = NSTableCellView()
            cellView.identifier = cellViewId

            // Create text field
            cell = NSTextField()
            cell.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            cell.drawsBackground = true
            cell.isBordered = false
            cell.focusRingType = .none
            cell.lineBreakMode = .byTruncatingTail
            cell.cell?.truncatesLastVisibleLine = true
            cell.translatesAutoresizingMaskIntoConstraints = false

            cellView.textField = cell
            cellView.addSubview(cell)
            cellView.wantsLayer = true

            // Center text vertically and fill horizontally
            NSLayoutConstraint.activate([
                cell.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                cell.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                cell.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        // Always set editable state and delegate
        cell.isEditable = isEditable
        cell.delegate = self
        cell.identifier = cellIdentifier  // For editing callbacks

        // Boundary check - return empty cell if row is out of bounds
        guard row >= 0 && row < cachedRowCount else {
            cell.stringValue = ""
            return cellView
        }

        // Get row data
        guard let rowData = rowProvider.row(at: row) else {
            cell.stringValue = ""
            return cellView
        }

        // Boundary check for column
        guard columnIndex >= 0 && columnIndex < cachedColumnCount else {
            cell.stringValue = ""
            return cellView
        }

        let value = rowData.value(at: columnIndex)
        
        // CRITICAL: Defensive checks for changeManager access during scrolling
        // After sorting large tables (25+ columns), changeManager might have stale data
        // or be in an inconsistent state. Validate before accessing to prevent crashes.
        let isDeleted: Bool
        let isModified: Bool
        
        // Check against actual data bounds, not changes array size
        if row >= 0 && row < cachedRowCount && columnIndex >= 0 && columnIndex < cachedColumnCount {
            isDeleted = changeManager.isRowDeleted(row)
            isModified = changeManager.isCellModified(rowIndex: row, columnIndex: columnIndex)
        } else {
            // Out of bounds - assume no changes
            isDeleted = false
            isModified = false
        }

        // Configure cell appearance
        // Reset placeholder first
        cell.placeholderString = nil

        if value == nil {
            // Use placeholder for NULL so editing starts with empty field
            cell.stringValue = ""
            cell.placeholderString = "NULL"
            cell.textColor = .tertiaryLabelColor
            cell.font = .monospacedSystemFont(ofSize: 13, weight: .regular).withTraits(.italic)
        } else if value == "__DEFAULT__" {
            cell.stringValue = ""
            cell.placeholderString = "DEFAULT"
            cell.textColor = .systemBlue
            cell.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        } else if value == "" {
            // Use placeholder for empty string so it's visible
            cell.stringValue = ""
            cell.placeholderString = "Empty"
            cell.textColor = .tertiaryLabelColor
            cell.font = .monospacedSystemFont(ofSize: 13, weight: .regular).withTraits(.italic)
        } else {
            cell.stringValue = value ?? ""
            cell.textColor = .labelColor
            cell.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        }

        // Modified cell background - apply to cellView for full coverage
        cell.drawsBackground = false
        cellView.wantsLayer = true
        
        // Deleted row takes precedence over modified cell
        if isDeleted {
            cellView.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
        } else if isModified {
            cellView.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.3).cgColor
        } else {
            cellView.layer?.backgroundColor = nil
        }

        return cellView
    }

    // MARK: - Row View (for context menu)

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = TableRowViewWithMenu()
        rowView.coordinator = self
        rowView.rowIndex = row
        return rowView
    }

    // MARK: - Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }

        let newSelection = Set(tableView.selectedRowIndexes.map { $0 })
        if newSelection != selectedRowIndices {
            DispatchQueue.main.async {
                self.selectedRowIndices = newSelection
            }
        }
    }

    // MARK: - Editing

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int)
        -> Bool
    {
        guard isEditable,
            let columnId = tableColumn?.identifier.rawValue,
            columnId != "__rowNumber__",
            !changeManager.isRowDeleted(row)
        else {
            return false
        }
        return true
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard let textField = control as? NSTextField,
            let tableView = tableView
        else {
            return true
        }

        let row = tableView.row(for: textField)
        let column = tableView.column(for: textField)

        guard row >= 0, column > 0 else { return true }  // column 0 is row number

        let columnIndex = column - 1  // Adjust for row number column
        // Keep empty string as empty (not NULL) - use context menu "Set NULL" for NULL
        let newValue: String? = textField.stringValue

        // Get old value
        guard let rowData = rowProvider.row(at: row) else { return true }
        let oldValue = rowData.value(at: columnIndex)

        // Skip if no change
        guard oldValue != newValue else { return true }

        // Record change with entire row for WHERE clause PK lookup
        let columnName = rowProvider.columns[columnIndex]
        changeManager.recordCellChange(
            rowIndex: row,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: rowData.values
        )

        // Update local data
        rowProvider.updateValue(newValue, at: row, columnIndex: columnIndex)

        // Notify parent view to update tab.resultRows
        onCellEdit?(row, columnIndex, newValue)

        // Reload the edited cell to show yellow background
        DispatchQueue.main.async {
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
        }

        return true
    }

    // MARK: - Row Actions

    func deleteRow(at index: Int) {
        guard let rowData = rowProvider.row(at: index) else { return }
        changeManager.recordRowDeletion(rowIndex: index, originalRow: rowData.values)
        
        // Move selection to next row (or previous if last row)
        // This makes the red background visible instead of being hidden by blue selection
        if selectedRowIndices.contains(index) {
            var newSelection = Set<Int>()
            
            // Try to select next row
            if index + 1 < cachedRowCount {
                newSelection.insert(index + 1)
            } 
            // If deleted row was last, select previous row
            else if index > 0 {
                newSelection.insert(index - 1)
            }
            
            // Update selection
            DispatchQueue.main.async {
                self.selectedRowIndices = newSelection
            }
        }
        
        tableView?.reloadData(
            forRowIndexes: IndexSet(integer: index),
            columnIndexes: IndexSet(integersIn: 0..<(tableView?.numberOfColumns ?? 0)))
    }

    func undoDeleteRow(at index: Int) {
        changeManager.undoRowDeletion(rowIndex: index)
        tableView?.reloadData(
            forRowIndexes: IndexSet(integer: index),
            columnIndexes: IndexSet(integersIn: 0..<(tableView?.numberOfColumns ?? 0)))
    }

    func copyRows(at indices: Set<Int>) {
        let sortedIndices = indices.sorted()
        var lines: [String] = []

        for index in sortedIndices {
            guard let rowData = rowProvider.row(at: index) else { continue }
            let line = rowData.values.map { $0 ?? "NULL" }.joined(separator: "\t")
            lines.append(line)
        }

        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Set a cell value (for Set NULL / Set Empty actions - legacy, uses selected column)
    func setCellValue(_ value: String?, at rowIndex: Int) {
        guard let tableView = tableView else { return }

        // Get selected column (default to first data column)
        var columnIndex = max(0, tableView.selectedColumn - 1)
        if columnIndex < 0 { columnIndex = 0 }

        setCellValueAtColumn(value, at: rowIndex, columnIndex: columnIndex)
    }

    /// Set a cell value at specific column
    func setCellValueAtColumn(_ value: String?, at rowIndex: Int, columnIndex: Int) {
        guard let tableView = tableView else { return }
        guard columnIndex >= 0 && columnIndex < rowProvider.columns.count else { return }

        let columnName = rowProvider.columns[columnIndex]
        let oldValue = rowProvider.row(at: rowIndex)?.value(at: columnIndex)

        // Record the change
        changeManager.recordCellChange(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: value
        )

        // Update local data
        rowProvider.updateValue(value, at: rowIndex, columnIndex: columnIndex)

        // Reload the row
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: rowIndex),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    /// Copy cell value to clipboard
    func copyCellValue(at rowIndex: Int, columnIndex: Int) {
        guard columnIndex >= 0 && columnIndex < rowProvider.columns.count else { return }

        if let rowData = rowProvider.row(at: rowIndex) {
            let value = rowData.value(at: columnIndex) ?? "NULL"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }
}

// MARK: - Custom Row View with Context Menu

final class TableRowViewWithMenu: NSTableRowView {
    weak var coordinator: TableViewCoordinator?
    var rowIndex: Int = 0

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator = coordinator,
            let tableView = coordinator.tableView
        else { return nil }

        // Determine which column was clicked
        let locationInRow = convert(event.locationInWindow, from: nil)
        let locationInTable = tableView.convert(locationInRow, from: self)
        let clickedColumn = tableView.column(at: locationInTable)

        // Adjust for row number column (index 0)
        let dataColumnIndex = clickedColumn > 0 ? clickedColumn - 1 : -1

        let menu = NSMenu()

        if coordinator.changeManager.isRowDeleted(rowIndex) {
            menu.addItem(
                withTitle: "Undo Delete", action: #selector(undoDeleteRow), keyEquivalent: ""
            ).target = self
        } else {
            // Edit actions (if editable)
            if coordinator.isEditable && dataColumnIndex >= 0 {
                let setValueMenu = NSMenu()

                let emptyItem = NSMenuItem(
                    title: "Empty", action: #selector(setEmptyValue(_:)), keyEquivalent: "")
                emptyItem.representedObject = dataColumnIndex
                emptyItem.target = self
                setValueMenu.addItem(emptyItem)

                let nullItem = NSMenuItem(
                    title: "NULL", action: #selector(setNullValue(_:)), keyEquivalent: "")
                nullItem.representedObject = dataColumnIndex
                nullItem.target = self
                setValueMenu.addItem(nullItem)

                let defaultItem = NSMenuItem(
                    title: "Default", action: #selector(setDefaultValue(_:)), keyEquivalent: "")
                defaultItem.representedObject = dataColumnIndex
                defaultItem.target = self
                setValueMenu.addItem(defaultItem)

                let setValueItem = NSMenuItem(title: "Set Value", action: nil, keyEquivalent: "")
                setValueItem.submenu = setValueMenu
                menu.addItem(setValueItem)

                menu.addItem(NSMenuItem.separator())
            }

            // Copy actions
            if dataColumnIndex >= 0 {
                let copyCellItem = NSMenuItem(
                    title: "Copy Cell Value", action: #selector(copyCellValue(_:)),
                    keyEquivalent: "")
                copyCellItem.representedObject = dataColumnIndex
                copyCellItem.target = self
                menu.addItem(copyCellItem)
            }

            let copyRowItem = NSMenuItem(
                title: "Copy Row", action: #selector(copyRow), keyEquivalent: "")
            copyRowItem.target = self
            menu.addItem(copyRowItem)

            if coordinator.selectedRowIndices.count > 1 {
                let copySelectedItem = NSMenuItem(
                    title: "Copy Selected Rows (\(coordinator.selectedRowIndices.count))",
                    action: #selector(copySelectedRows), keyEquivalent: "")
                copySelectedItem.target = self
                menu.addItem(copySelectedItem)
            }

            if coordinator.isEditable {
                menu.addItem(NSMenuItem.separator())

                let deleteItem = NSMenuItem(
                    title: "Delete Row", action: #selector(deleteRow), keyEquivalent: "")
                deleteItem.target = self
                menu.addItem(deleteItem)
            }
        }

        return menu
    }

    @objc private func deleteRow() {
        coordinator?.deleteRow(at: rowIndex)
    }

    @objc private func undoDeleteRow() {
        coordinator?.undoDeleteRow(at: rowIndex)
    }

    @objc private func copyRow() {
        coordinator?.copyRows(at: [rowIndex])
    }

    @objc private func copySelectedRows() {
        guard let selectedIndices = coordinator?.selectedRowIndices else { return }
        coordinator?.copyRows(at: selectedIndices)
    }

    @objc private func copyCellValue(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        coordinator?.copyCellValue(at: rowIndex, columnIndex: columnIndex)
    }

    @objc private func setNullValue(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        coordinator?.setCellValueAtColumn(nil, at: rowIndex, columnIndex: columnIndex)
    }

    @objc private func setEmptyValue(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        coordinator?.setCellValueAtColumn("", at: rowIndex, columnIndex: columnIndex)
    }

    @objc private func setDefaultValue(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        coordinator?.setCellValueAtColumn("__DEFAULT__", at: rowIndex, columnIndex: columnIndex)
    }
    
    // Column resize tracking removed - too complex for current implementation
}

// MARK: - NSFont Extension

extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - Preview

#Preview {
    DataGridView(
        rowProvider: InMemoryRowProvider(
            rows: [
                QueryResultRow(values: ["1", "John", "john@example.com"]),
                QueryResultRow(values: ["2", "Jane", nil]),
                QueryResultRow(values: ["3", "Bob", "bob@example.com"]),
            ],
            columns: ["id", "name", "email"]
        ),
        changeManager: DataChangeManager(),
        isEditable: true,
        selectedRowIndices: .constant([]),
        sortState: .constant(SortState())
    )
    .frame(width: 600, height: 400)
}

// MARK: - Custom TableView with Key Handling

/// NSTableView subclass that handles Delete key to mark rows for deletion
/// Also implements TablePlus-style cell focus on click
final class KeyHandlingTableView: NSTableView {
    weak var coordinator: TableViewCoordinator?

    // MARK: - TablePlus-Style Cell Focus
    
    override func mouseDown(with event: NSEvent) {
        // Capture clicked location before super changes selection
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedColumn = column(at: point)
        
        // Let super handle row selection
        super.mouseDown(with: event)
        
        // After selection, focus the specific cell (TablePlus behavior)
        // This makes Enter key edit that cell, not column 0
        guard clickedRow >= 0,
              clickedColumn >= 0,
              clickedColumn < numberOfColumns,
              selectedRowIndexes.contains(clickedRow) else {
            return
        }
        
        // Skip row number column (not editable)
        let column = tableColumns[clickedColumn]
        if column.identifier.rawValue == "__rowNumber__" {
            return
        }
        
        // Focus the cell without opening editor (select: false)
        // This is the native AppKit way to set cell focus
        // When user presses Enter, this cell will be edited
        editColumn(clickedColumn, row: clickedRow, with: nil, select: false)
    }
    
    // MARK: - Delete Key Handling

    override func keyDown(with event: NSEvent) {
        // Delete or Backspace key
        if event.keyCode == 51 || event.keyCode == 117 {
            // Get selected row indices
            let selectedIndices = Set(selectedRowIndexes.map { $0 })
            if !selectedIndices.isEmpty {
                // Mark rows for deletion
                for rowIndex in selectedIndices.sorted(by: >) {
                    coordinator?.deleteRow(at: rowIndex)
                }
                return
            }
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        // If clicked on a valid row, get its row view's menu
        if clickedRow >= 0,
            let rowView = rowView(atRow: clickedRow, makeIfNecessary: false)
                as? TableRowViewWithMenu
        {
            // Select the row if not already selected
            if !selectedRowIndexes.contains(clickedRow) {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
            return rowView.menu(for: event)
        }

        return super.menu(for: event)
    }
}

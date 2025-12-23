//
//  DataGridView.swift
//  OpenTable
//
//  High-performance NSTableView wrapper for SwiftUI
//

import AppKit
import SwiftUI

/// Position of a cell in the grid (row, column)
struct CellPosition: Equatable {
    let row: Int
    let column: Int
}

// MARK: - Row Visual State Cache

/// Cached visual state for a row - avoids repeated changeManager lookups during cell rendering
/// Computed once per row, read by all cells in that row
struct RowVisualState {
    let isDeleted: Bool
    let isInserted: Bool
    let modifiedColumns: Set<Int>

    /// Empty state for rows with no changes
    static let empty = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [])
}

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
    var onAddRow: (() -> Void)?  // Called when user triggers add row (Cmd+N)
    var onUndoInsert: ((Int) -> Void)?  // Called when user undoes row insertion (rowIndex)
    var onFilterColumn: ((String) -> Void)?  // Called when user selects "Filter with column" from header context menu

    @Binding var selectedRowIndices: Set<Int>
    @Binding var sortState: SortState
    @Binding var editingCell: CellPosition?  // Triggers editing of specific cell

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

        // PERF: Version check for change tracking (increments on clear/save)
        let versionChanged = coordinator.lastReloadVersion != changeManager.reloadVersion

        // PERF: Use cached values - avoids potential issues with deallocated provider
        let oldRowCount = coordinator.cachedRowCount
        let oldColumnCount = coordinator.cachedColumnCount
        let newRowCount = rowProvider.totalRowCount
        let newColumnCount = rowProvider.columns.count

        // PERF: Only reload on structural changes, NOT on sort
        // Sorting changes row order but not count - NSTableView handles this internally
        // Removed: rowDataChanged comparison that caused O(n) overhead per update
        let needsReload =
            oldRowCount != newRowCount
            || oldColumnCount != newColumnCount
            || versionChanged

        // Update coordinator references (but not version tracker yet - see below)
        coordinator.rowProvider = rowProvider
        coordinator.updateCache()  // Update cached counts after provider change
        coordinator.changeManager = changeManager
        coordinator.isEditable = isEditable
        coordinator.onCommit = onCommit
        coordinator.onRefresh = onRefresh
        coordinator.onCellEdit = onCellEdit
        coordinator.onSort = onSort
        coordinator.onAddRow = onAddRow
        coordinator.onUndoInsert = onUndoInsert
        coordinator.onFilterColumn = onFilterColumn

        // PERF: Rebuild visual state cache once per update cycle
        // Cells read from this cache instead of calling changeManager directly
        coordinator.rebuildVisualStateCache()

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
        
        // Handle editingCell - start editing the specified cell
        if let cell = editingCell {
            let tableColumn = cell.column + 1  // +1 to skip row number column
            if cell.row < tableView.numberOfRows && tableColumn < tableView.numberOfColumns {
                // Scroll to the row first
                tableView.scrollRowToVisible(cell.row)
                
                // Select the row and start editing after a brief delay (allows scroll to complete)
                DispatchQueue.main.async { [weak tableView] in
                    guard let tableView = tableView else { return }
                    tableView.selectRowIndexes(IndexSet(integer: cell.row), byExtendingSelection: false)
                    tableView.editColumn(tableColumn, row: cell.row, with: nil, select: true)
                }
            }
            
            // Clear the binding after handling
            DispatchQueue.main.async {
                self.editingCell = nil
            }
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

    // MARK: - Row Visual State Cache
    // Caches per-row visual state (deleted/inserted/modified) to avoid repeated changeManager lookups
    // Rebuilt on each updateNSView cycle, read during cell rendering
    private var rowVisualStateCache: [Int: RowVisualState] = [:]

    /// Large dataset threshold - above this, disable expensive visual features
    private let largeDatasetThreshold = 5000

    /// Whether current dataset is "large" and should use simplified rendering
    var isLargeDataset: Bool {
        cachedRowCount > largeDatasetThreshold
    }

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

    // MARK: - Row Visual State Cache

    /// Rebuild visual state cache from changeManager
    /// Called once per updateNSView cycle - O(changes) not O(rows)
    func rebuildVisualStateCache() {
        rowVisualStateCache.removeAll(keepingCapacity: true)

        // Skip cache building for large datasets with no changes
        guard changeManager.hasChanges else { return }

        // Build cache from changeManager's efficient O(1) lookups
        // Only cache rows that have changes (sparse cache)
        for change in changeManager.changes {
            let rowIndex = change.rowIndex
            let isDeleted = change.type == .delete
            let isInserted = change.type == .insert
            let modifiedColumns: Set<Int> = change.type == .update
                ? Set(change.cellChanges.map { $0.columnIndex })
                : []

            rowVisualStateCache[rowIndex] = RowVisualState(
                isDeleted: isDeleted,
                isInserted: isInserted,
                modifiedColumns: modifiedColumns
            )
        }
    }

    /// Get cached visual state for a row - O(1) dictionary lookup
    /// Returns .empty for rows without changes (no cache entry)
    func visualState(for row: Int) -> RowVisualState {
        rowVisualStateCache[row] ?? .empty
    }

    /// Clear visual state cache (called when data changes significantly)
    func clearVisualStateCache() {
        rowVisualStateCache.removeAll()
    }

    /// Callback when column header clicked for sorting: (columnIndex, ascending)
    var onSort: ((Int, Bool) -> Void)?
    
    /// Callback when user triggers add row (Cmd+N)
    var onAddRow: (() -> Void)?
    
    /// Callback when user undoes row insertion
    var onUndoInsert: ((Int) -> Void)?
    
    /// Callback when user selects "Filter with column" from header context menu
    var onFilterColumn: ((String) -> Void)?

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
        
        // Add "Filter with column" menu item
        let filterItem = NSMenuItem(
            title: "Filter with column",
            action: #selector(filterWithColumn(_:)),
            keyEquivalent: "")
        filterItem.representedObject = column.title
        filterItem.target = self
        menu.addItem(filterItem)
    }
    
    @objc private func copyColumnName(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(columnName, forType: .string)
    }
    
    @objc private func filterWithColumn(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        onFilterColumn?(columnName)
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
        // PERF: Reuse cell views, configure once
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
            // PERF: Configure once - font, alignment, constraints
            cellView = NSTableCellView()
            cellView.identifier = cellViewId

            cell = NSTextField(labelWithString: "")
            cell.alignment = .right
            cell.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.textColor = .secondaryLabelColor
            cell.translatesAutoresizingMaskIntoConstraints = false

            cellView.textField = cell
            cellView.addSubview(cell)

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

        // PERF: Update only text and color on reuse
        cell.stringValue = "\(row + 1)"

        // PERF: Read from cached visual state instead of changeManager
        let state = visualState(for: row)
        cell.textColor = state.isDeleted ? .systemRed.withAlphaComponent(0.5) : .secondaryLabelColor

        return cellView
    }

    private func makeDataCell(tableView: NSTableView, row: Int, columnIndex: Int) -> NSView {
        // PERF: Reuse cells - only configure once, update text+background on reuse
        let cellViewId = NSUserInterfaceItemIdentifier("DataCellView")
        let cellView: NSTableCellView
        let cell: NSTextField
        let isNewCell: Bool

        if let reused = tableView.makeView(withIdentifier: cellViewId, owner: nil)
            as? NSTableCellView,
            let textField = reused.textField
        {
            cellView = reused
            cell = textField
            isNewCell = false
        } else {
            // PERF: Configure once - fonts, layers, constraints are set only on creation
            cellView = NSTableCellView()
            cellView.identifier = cellViewId
            cellView.wantsLayer = true  // Set once, never toggle

            cell = CellTextField()
            cell.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            cell.drawsBackground = false  // Set once - background via layer
            cell.isBordered = false
            cell.focusRingType = .none
            cell.lineBreakMode = .byTruncatingTail
            cell.cell?.truncatesLastVisibleLine = true
            cell.translatesAutoresizingMaskIntoConstraints = false

            cellView.textField = cell
            cellView.addSubview(cell)

            // PERF: Constraints set once, never modified
            NSLayoutConstraint.activate([
                cell.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                cell.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                cell.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
            isNewCell = true
        }

        // Set editable/delegate on reuse (cheap operations)
        cell.isEditable = isEditable
        cell.delegate = self
        cell.identifier = cellIdentifier

        // Boundary check - return empty cell if out of bounds
        guard row >= 0 && row < cachedRowCount,
              columnIndex >= 0 && columnIndex < cachedColumnCount,
              let rowData = rowProvider.row(at: row)
        else {
            cell.stringValue = ""
            cell.placeholderString = nil
            cell.textColor = .labelColor
            cellView.layer?.backgroundColor = nil
            cellView.layer?.borderWidth = 0
            return cellView
        }

        let value = rowData.value(at: columnIndex)

        // PERF: Read from cached visual state instead of changeManager
        // visualState is computed once per updateNSView cycle, shared by all cells in row
        let state = visualState(for: row)
        let isDeleted = state.isDeleted
        let isInserted = state.isInserted
        let isModified = state.modifiedColumns.contains(columnIndex)

        // PERF: Update text content (always needed on reuse)
        cell.placeholderString = nil

        if value == nil {
            cell.stringValue = ""
            // PERF: For large datasets, skip placeholder styling
            if !isLargeDataset {
                cell.placeholderString = "NULL"
                cell.textColor = .secondaryLabelColor
                if isNewCell || cell.font?.fontDescriptor.symbolicTraits.contains(.italic) != true {
                    cell.font = .monospacedSystemFont(ofSize: 13, weight: .regular).withTraits(.italic)
                }
            } else {
                cell.textColor = .secondaryLabelColor
            }
        } else if value == "__DEFAULT__" {
            cell.stringValue = ""
            if !isLargeDataset {
                cell.placeholderString = "DEFAULT"
                cell.textColor = .systemBlue
                cell.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            } else {
                cell.textColor = .systemBlue
            }
        } else if value == "" {
            cell.stringValue = ""
            if !isLargeDataset {
                cell.placeholderString = "Empty"
                cell.textColor = .secondaryLabelColor
                if isNewCell || cell.font?.fontDescriptor.symbolicTraits.contains(.italic) != true {
                    cell.font = .monospacedSystemFont(ofSize: 13, weight: .regular).withTraits(.italic)
                }
            } else {
                cell.textColor = .secondaryLabelColor
            }
        } else {
            cell.stringValue = value ?? ""
            cell.textColor = .labelColor
            // Only reset font if it was changed (avoid font allocation)
            if cell.font?.fontDescriptor.symbolicTraits.contains(.italic) == true ||
               cell.font?.fontDescriptor.symbolicTraits.contains(.bold) == true {
                cell.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            }
        }

        // PERF: Update background color (priority: deleted > inserted > modified)
        // For large datasets, skip modified cell highlighting
        if isDeleted {
            cellView.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
        } else if isInserted {
            cellView.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.15).cgColor
        } else if isModified && !isLargeDataset {
            cellView.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.3).cgColor
        } else {
            cellView.layer?.backgroundColor = nil
        }

        // PERF: Focus ring - skip for large datasets
        if isLargeDataset {
            cellView.layer?.borderWidth = 0
        } else {
            let tableColumnIndex = columnIndex + 1
            let isFocused: Bool = {
                guard let keyTableView = tableView as? KeyHandlingTableView,
                      keyTableView.focusedRow == row,  // Use focusedRow, not selectedRow
                      keyTableView.focusedColumn == tableColumnIndex
                else { return false }
                return true
            }()

            if isFocused {
                cellView.layer?.borderWidth = 2
                cellView.layer?.borderColor = NSColor.selectedControlColor.cgColor
            } else {
                cellView.layer?.borderWidth = 0
            }
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
        
        // Clear focus if selection is empty
        if let keyTableView = tableView as? KeyHandlingTableView {
            if newSelection.isEmpty {
                keyTableView.focusedRow = -1
                keyTableView.focusedColumn = -1
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
    
    /// Handle Tab/Shift+Tab navigation between cells during editing
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let tableView = tableView else { return false }
        
        let currentRow = tableView.row(for: control)
        let currentColumn = tableView.column(for: control)
        
        guard currentRow >= 0, currentColumn >= 0 else { return false }
        
        // Tab key - move to next cell
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            // End current editing first (value will be saved by textShouldEndEditing)
            tableView.window?.makeFirstResponder(tableView)
            
            // Calculate next cell position
            var nextColumn = currentColumn + 1
            var nextRow = currentRow
            
            // Skip to next row if at end of columns
            if nextColumn >= tableView.numberOfColumns {
                nextColumn = 1  // Skip row number column (column 0)
                nextRow += 1
            }
            
            // If at end of table, stay on last cell
            if nextRow >= tableView.numberOfRows {
                nextRow = tableView.numberOfRows - 1
                nextColumn = tableView.numberOfColumns - 1
            }
            
            // Start editing next cell after a brief delay
            DispatchQueue.main.async {
                tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
                tableView.editColumn(nextColumn, row: nextRow, with: nil, select: true)
            }
            
            return true
        }
        
        // Shift+Tab - move to previous cell
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            // End current editing first
            tableView.window?.makeFirstResponder(tableView)
            
            // Calculate previous cell position
            var prevColumn = currentColumn - 1
            var prevRow = currentRow
            
            // Skip to previous row if at start of columns
            if prevColumn < 1 {  // Column 0 is row number
                prevColumn = tableView.numberOfColumns - 1
                prevRow -= 1
            }
            
            // If at start of table, stay on first cell
            if prevRow < 0 {
                prevRow = 0
                prevColumn = 1
            }
            
            // Start editing previous cell after a brief delay
            DispatchQueue.main.async {
                tableView.selectRowIndexes(IndexSet(integer: prevRow), byExtendingSelection: false)
                tableView.editColumn(prevColumn, row: prevRow, with: nil, select: true)
            }
            
            return true
        }
        
        // Return key - end editing, stay on row (don't move to next row)
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            tableView.window?.makeFirstResponder(tableView)
            return true
        }
        
        // Escape key - cancel editing
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            tableView.window?.makeFirstResponder(tableView)
            return true
        }
        
        return false
    }

    // MARK: - Row Actions

    func deleteRow(at index: Int) {
        // If this is a newly inserted row, remove it completely instead of marking for deletion
        if changeManager.isRowInserted(index) {
            undoInsertRow(at: index)
            return
        }
        
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
            
            // Update selection synchronously to prevent flash
            self.selectedRowIndices = newSelection
        }
        
        // Reload row data after selection has been updated
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
    
    /// Trigger adding a new row (calls parent's onAddRow callback)
    func addNewRow() {
        onAddRow?()
    }
    
    /// Undo a row insertion (remove from data and change tracking)
    func undoInsertRow(at index: Int) {
        // Notify parent to remove from resultRows FIRST (before indices change)
        onUndoInsert?(index)
        
        // Remove from change manager
        changeManager.undoRowInsertion(rowIndex: index)
        
        // Remove from row provider
        rowProvider.removeRow(at: index)
        
        // Update cached counts
        updateCache()
        
        // Reload entire table since row indices shifted
        tableView?.reloadData()
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
        }
        
        // Normal row menu (or additional items for inserted rows)
        if !coordinator.changeManager.isRowDeleted(rowIndex) {
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

            let copyItem = NSMenuItem(
                title: "Copy", action: #selector(copySelectedOrCurrentRow), keyEquivalent: "c")
            copyItem.keyEquivalentModifierMask = .command
            copyItem.target = self
            menu.addItem(copyItem)

            if coordinator.isEditable {
                menu.addItem(NSMenuItem.separator())

                let duplicateItem = NSMenuItem(
                    title: "Duplicate", action: #selector(duplicateRow), keyEquivalent: "d")
                duplicateItem.keyEquivalentModifierMask = .command
                duplicateItem.target = self
                menu.addItem(duplicateItem)

                let deleteItem = NSMenuItem(
                    title: "Delete", action: #selector(deleteRow), keyEquivalent: String(Character(UnicodeScalar(NSBackspaceCharacter)!)))
                deleteItem.keyEquivalentModifierMask = []
                deleteItem.target = self
                menu.addItem(deleteItem)
            }
        }

        return menu
    }

    @objc private func deleteRow() {
        coordinator?.deleteRow(at: rowIndex)
    }

    @objc private func duplicateRow() {
        // Post notification to duplicate the selected row
        NotificationCenter.default.post(name: .duplicateRow, object: nil)
    }

    @objc private func undoDeleteRow() {
        coordinator?.undoDeleteRow(at: rowIndex)
    }
    
    @objc private func undoInsertRow() {
        coordinator?.undoInsertRow(at: rowIndex)
    }

    @objc private func copyRow() {
        coordinator?.copyRows(at: [rowIndex])
    }

    @objc private func copySelectedRows() {
        guard let selectedIndices = coordinator?.selectedRowIndices else { return }
        coordinator?.copyRows(at: selectedIndices)
    }
    
    @objc private func copySelectedOrCurrentRow() {
        guard let coordinator = coordinator else { return }
        // If rows are selected, copy all selected; otherwise copy current row
        if !coordinator.selectedRowIndices.isEmpty {
            coordinator.copyRows(at: coordinator.selectedRowIndices)
        } else {
            coordinator.copyRows(at: [rowIndex])
        }
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

// MARK: - Custom TextField that delegates context menu to row view

/// NSTextField subclass that shows row context menu instead of text editing menu
/// This ensures our custom menu (Undo Insert, Set Value, etc.) works even when editing
final class CellTextField: NSTextField {
    
    /// Override to provide our custom cell that handles context menu
    override class var cellClass: AnyClass? {
        get { CellTextFieldCell.self }
        set { }
    }
    
    /// Override right mouse down to end editing and show row context menu
    /// The field editor (NSTextView) normally handles right-click during editing,
    /// so we intercept here before it gets to the field editor
    override func rightMouseDown(with event: NSEvent) {
        // End editing first
        window?.makeFirstResponder(nil)
        
        // Find the row view and show its menu
        var view: NSView? = self
        while let parent = view?.superview {
            if let rowView = parent as? TableRowViewWithMenu {
                if let menu = rowView.menu(for: event) {
                    NSMenu.popUpContextMenu(menu, with: event, for: self)
                }
                return
            }
            view = parent
        }
    }
    
    override func menu(for event: NSEvent) -> NSMenu? {
        // End editing first so the menu shows correctly
        window?.makeFirstResponder(nil)
        
        // Find the row view and delegate to it
        var view: NSView? = self
        while let parent = view?.superview {
            if let rowView = parent as? TableRowViewWithMenu {
                return rowView.menu(for: event)
            }
            view = parent
        }
        
        // Fallback to no menu (don't show system text editing menu)
        return nil
    }
}

/// Custom text field cell that provides a field editor with custom context menu behavior
final class CellTextFieldCell: NSTextFieldCell {
    
    /// Custom field editor that forwards right-click to parent text field
    private class CellFieldEditor: NSTextView {
        
        override func rightMouseDown(with event: NSEvent) {
            // End editing and find parent CellTextField
            window?.makeFirstResponder(nil)
            
            // Find the CellTextField and let it handle the menu
            var view: NSView? = self
            while let parent = view?.superview {
                if let cellTextField = parent as? CellTextField {
                    cellTextField.rightMouseDown(with: event)
                    return
                }
                view = parent
            }
        }
        
        override func menu(for event: NSEvent) -> NSMenu? {
            // Don't show system text editing menu
            return nil
        }
    }
    
    /// Lazy field editor instance
    private var customFieldEditor: CellFieldEditor?
    
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        if customFieldEditor == nil {
            customFieldEditor = CellFieldEditor()
            customFieldEditor?.isFieldEditor = true
        }
        return customFieldEditor
    }
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
        sortState: .constant(SortState()),
        editingCell: .constant(nil as CellPosition?)
    )
    .frame(width: 600, height: 400)
}

// MARK: - Custom TableView with Key Handling

/// NSTableView subclass that handles Delete key to mark rows for deletion
/// Also implements TablePlus-style cell focus on click
final class KeyHandlingTableView: NSTableView, NSMenuItemValidation {
    weak var coordinator: TableViewCoordinator?

    /// Currently focused row index (-1 = no focus)
    /// Tracked separately from selectedRow to avoid async timing bugs
    var focusedRow: Int = -1 {
        didSet {
            if oldValue != focusedRow && oldValue >= 0 {
                // Clear focus border from old row
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
                // Capture current focusedRow to avoid async timing bug
                let rowToUpdate = focusedRow
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Clear old column's border using captured row
                    if oldValue >= 0 && oldValue < self.numberOfColumns && rowToUpdate >= 0 && rowToUpdate < self.numberOfRows {
                        self.reloadData(forRowIndexes: IndexSet(integer: rowToUpdate),
                                   columnIndexes: IndexSet(integer: oldValue))
                    }
                    // Draw new column's border using current focusedRow
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
    
    /// Current pivot row for Shift+Arrow navigation (where the user is navigating to)
    var selectionPivot: Int = -1

    // MARK: - TablePlus-Style Cell Focus
    
    override func mouseDown(with event: NSEvent) {
        // Capture clicked location before super changes selection
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedColumn = column(at: point)
        
        // Double-click in empty area (no row) adds a new row (TablePlus behavior)
        if event.clickCount == 2 && clickedRow == -1 && coordinator?.isEditable == true {
            NotificationCenter.default.post(name: .addNewRow, object: nil)
            return
        }
        
        // Reset anchor/pivot when clicking without Shift (starting new selection)
        if clickedRow >= 0 && !event.modifierFlags.contains(.shift) {
            selectionAnchor = clickedRow
            selectionPivot = clickedRow
        }
        
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
            focusedRow = -1
            focusedColumn = -1
            return
        }

        // Track focused row and column for keyboard navigation
        focusedRow = clickedRow
        focusedColumn = clickedColumn

        // Focus the cell without opening editor (select: false)
        // This is the native AppKit way to set cell focus
        // When user presses Enter, this cell will be edited
        editColumn(clickedColumn, row: clickedRow, with: nil, select: false)
    }
    
    // MARK: - Standard Edit Menu Actions
    
    /// Respond to Edit > Delete menu item
    @objc func delete(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        let selectedIndices = Set(selectedRowIndexes.map { $0 })
        guard !selectedIndices.isEmpty else { return }
        
        // Mark rows for deletion
        for rowIndex in selectedIndices.sorted(by: >) {
            coordinator?.deleteRow(at: rowIndex)
        }
    }
    
    /// Enable/disable Edit menu items based on state
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(delete(_:)) {
            // Enable Delete when rows are selected and table is editable
            return coordinator?.isEditable == true && !selectedRowIndexes.isEmpty
        }
        // For other items, check if we can respond to them
        if let action = menuItem.action {
            return responds(to: action)
        }
        return false
    }
    
    // MARK: - Keyboard Handling
    
    /// Override to catch Delete/Backspace before menu items can intercept
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Delete (keyCode 51) or Forward Delete (keyCode 117)
        if event.keyCode == 51 || event.keyCode == 117 {
            let selectedIndices = Set(selectedRowIndexes.map { $0 })
            if !selectedIndices.isEmpty && coordinator?.isEditable == true {
                // Mark rows for deletion
                for rowIndex in selectedIndices.sorted(by: >) {
                    coordinator?.deleteRow(at: rowIndex)
                }
                return true  // We handled it
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Note: Cmd+N is captured by app menu (New Connection)
        // Use File > Add Row (Cmd+I) for adding rows

        let row = selectedRow
        let isShiftHeld = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 126: // Up arrow - move to previous row (Shift extends selection)
            handleUpArrow(currentRow: row, isShiftHeld: isShiftHeld)
            return

        case 125: // Down arrow - move to next row (Shift extends selection)
            handleDownArrow(currentRow: row, isShiftHeld: isShiftHeld)
            return

        case 123: // Left arrow - move to previous column
            if focusedColumn > 1 { // Skip row number column (index 0)
                focusedColumn -= 1
                if row >= 0 {
                    scrollColumnToVisible(focusedColumn)
                }
            } else if focusedColumn == -1 && numberOfColumns > 1 {
                // No focus yet, start at last column
                focusedColumn = numberOfColumns - 1
                if row >= 0 {
                    scrollColumnToVisible(focusedColumn)
                }
            }
            return

        case 124: // Right arrow - move to next column
            if focusedColumn >= 1 && focusedColumn < numberOfColumns - 1 {
                focusedColumn += 1
                if row >= 0 {
                    scrollColumnToVisible(focusedColumn)
                }
            } else if focusedColumn == -1 && numberOfColumns > 1 {
                // No focus yet, start at first data column
                focusedColumn = 1
                if row >= 0 {
                    scrollColumnToVisible(focusedColumn)
                }
            }
            return

        case 36: // Enter/Return - edit focused cell
            if row >= 0 && focusedColumn >= 1 && coordinator?.isEditable == true {
                editColumn(focusedColumn, row: row, with: nil, select: true)
            }
            return

        case 53: // Escape - clear focus and selection
            focusedRow = -1
            focusedColumn = -1
            NotificationCenter.default.post(name: .clearSelection, object: nil)
            return

        case 51, 117: // Delete or Backspace key
            // Post notification to trigger batched deletion in MainContentView
            // This enables undoing all deletions at once
            if !selectedRowIndexes.isEmpty {
                NotificationCenter.default.post(name: .deleteSelectedRows, object: nil)
                return
            }

        case 48: // Tab - move to next cell
            if row >= 0 && focusedColumn >= 1 {
                var nextColumn = focusedColumn + 1
                var nextRow = row

                if nextColumn >= numberOfColumns {
                    nextColumn = 1 // Skip row number column
                    nextRow += 1
                }
                if nextRow >= numberOfRows {
                    nextRow = numberOfRows - 1
                    nextColumn = numberOfColumns - 1
                }

                selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
                focusedRow = nextRow  // Update focusedRow when moving to next cell
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
    
    /// Handle Up arrow key with optional Shift for range selection
    private func handleUpArrow(currentRow: Int, isShiftHeld: Bool) {
        guard numberOfRows > 0 else { return }
        
        if currentRow == -1 {
            // No selection, select last row
            let targetRow = numberOfRows - 1
            selectionAnchor = targetRow
            selectionPivot = targetRow
            focusedRow = targetRow  // Track focused row
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            scrollRowToVisible(targetRow)
            return
        }
        
        if isShiftHeld {
            // Shift+Up: extend/shrink selection
            if selectionAnchor == -1 {
                selectionAnchor = currentRow
                selectionPivot = currentRow
            }
            
            // Use pivot for navigation, not selectedRow
            let currentPivot = selectionPivot >= 0 ? selectionPivot : currentRow
            let targetRow = max(0, currentPivot - 1)
            selectionPivot = targetRow
            
            // Select range from anchor to pivot
            let startRow = min(selectionAnchor, selectionPivot)
            let endRow = max(selectionAnchor, selectionPivot)
            let range = IndexSet(integersIn: startRow...endRow)
            selectRowIndexes(range, byExtendingSelection: false)
            scrollRowToVisible(targetRow)
        } else {
            // Normal Up: move to previous row, single selection
            let targetRow = max(0, currentRow - 1)
            selectionAnchor = targetRow
            selectionPivot = targetRow
            focusedRow = targetRow  // Track focused row
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            scrollRowToVisible(targetRow)
        }
    }
    
    /// Handle Down arrow key with optional Shift for range selection
    private func handleDownArrow(currentRow: Int, isShiftHeld: Bool) {
        guard numberOfRows > 0 else { return }
        
        if currentRow == -1 {
            // No selection, select first row
            selectionAnchor = 0
            selectionPivot = 0
            focusedRow = 0  // Track focused row
            selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            scrollRowToVisible(0)
            return
        }
        
        if isShiftHeld {
            // Shift+Down: extend/shrink selection
            if selectionAnchor == -1 {
                selectionAnchor = currentRow
                selectionPivot = currentRow
            }
            
            // Use pivot for navigation, not selectedRow
            let currentPivot = selectionPivot >= 0 ? selectionPivot : currentRow
            let targetRow = min(numberOfRows - 1, currentPivot + 1)
            selectionPivot = targetRow
            
            // Select range from anchor to pivot
            let startRow = min(selectionAnchor, selectionPivot)
            let endRow = max(selectionAnchor, selectionPivot)
            let range = IndexSet(integersIn: startRow...endRow)
            selectRowIndexes(range, byExtendingSelection: false)
            scrollRowToVisible(targetRow)
        } else {
            // Normal Down: move to next row, single selection
            let targetRow = min(numberOfRows - 1, currentRow + 1)
            selectionAnchor = targetRow
            selectionPivot = targetRow
            focusedRow = targetRow  // Track focused row
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            scrollRowToVisible(targetRow)
        }
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

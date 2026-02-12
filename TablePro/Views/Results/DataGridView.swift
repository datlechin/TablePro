//
//  DataGridView.swift
//  TablePro
//
//  High-performance NSTableView wrapper for SwiftUI.
//  Custom views extracted to separate files for maintainability.
//

import AppKit
import SwiftUI

/// Position of a cell in the grid (row, column)
struct CellPosition: Equatable {
    let row: Int
    let column: Int
}

/// Cached visual state for a row - avoids repeated changeManager lookups
struct RowVisualState {
    let isDeleted: Bool
    let isInserted: Bool
    let modifiedColumns: Set<Int>

    static let empty = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [])
}

/// High-performance table view using AppKit NSTableView
struct DataGridView: NSViewRepresentable {
    let rowProvider: InMemoryRowProvider
    @ObservedObject var changeManager: AnyChangeManager
    let isEditable: Bool
    var onCommit: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onCellEdit: ((Int, Int, String?) -> Void)?
    var onDeleteRows: ((Set<Int>) -> Void)?
    var onCopyRows: ((Set<Int>) -> Void)?
    var onPasteRows: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSort: ((Int, Bool) -> Void)?
    var onAddRow: (() -> Void)?
    var onUndoInsert: ((Int) -> Void)?
    var onFilterColumn: ((String) -> Void)?
    var getVisualState: ((Int) -> RowVisualState)?
    var dropdownColumns: Set<Int>? // Column indices that should use YES/NO dropdowns

    @Binding var selectedRowIndices: Set<Int>
    @Binding var sortState: SortState
    @Binding var editingCell: CellPosition?

    private let cellFactory = DataGridCellFactory()

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let tableView = KeyHandlingTableView()
        tableView.coordinator = context.coordinator
        tableView.style = .plain
        // Use settings for alternate row backgrounds
        let settings = AppSettingsManager.shared.dataGrid
        tableView.usesAlternatingRowBackgroundColors = settings.showAlternateRows
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        // Use settings for row height
        tableView.rowHeight = CGFloat(settings.rowHeight.rawValue)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(TableViewCoordinator.handleDoubleClick(_:))

        // Add row number column
        let rowNumberColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("__rowNumber__"))
        rowNumberColumn.title = "#"
        rowNumberColumn.width = 40
        rowNumberColumn.minWidth = 40
        rowNumberColumn.maxWidth = 60
        rowNumberColumn.isEditable = false
        rowNumberColumn.resizingMask = []
        tableView.addTableColumn(rowNumberColumn)

        // Add data columns
        for (index, columnName) in rowProvider.columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(index)"))
            column.title = columnName
            // Use optimal width calculation based on both header and cell content
            column.width = cellFactory.calculateOptimalColumnWidth(
                for: columnName,
                columnIndex: index,
                rowProvider: rowProvider
            )
            column.minWidth = 30
            column.resizingMask = .userResizingMask
            column.isEditable = isEditable
            column.sortDescriptorPrototype = NSSortDescriptor(key: "col_\(index)", ascending: true)
            tableView.addTableColumn(column)
        }

        if let headerView = tableView.headerView {
            let headerMenu = NSMenu()
            headerMenu.delegate = context.coordinator
            headerView.menu = headerMenu
        }

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.cellFactory = cellFactory

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }

        let coordinator = context.coordinator

        // Update settings-based properties dynamically
        let settings = AppSettingsManager.shared.dataGrid
        if tableView.rowHeight != CGFloat(settings.rowHeight.rawValue) {
            tableView.rowHeight = CGFloat(settings.rowHeight.rawValue)
        }
        if tableView.usesAlternatingRowBackgroundColors != settings.showAlternateRows {
            tableView.usesAlternatingRowBackgroundColors = settings.showAlternateRows
        }

        if tableView.editedRow >= 0 { return }

        let versionChanged = coordinator.lastReloadVersion != changeManager.reloadVersion
        let oldRowCount = coordinator.cachedRowCount
        let oldColumnCount = coordinator.cachedColumnCount
        let newRowCount = rowProvider.totalRowCount
        let newColumnCount = rowProvider.columns.count

        // Only do full reload if row/column count changed or columns changed
        // For cell edits (versionChanged but same count), use granular reload
        let structureChanged = oldRowCount != newRowCount || oldColumnCount != newColumnCount
        let needsFullReload = structureChanged

        coordinator.rowProvider = rowProvider
        coordinator.updateCache()
        coordinator.changeManager = changeManager
        coordinator.isEditable = isEditable
        coordinator.onCommit = onCommit
        coordinator.onRefresh = onRefresh
        coordinator.onCellEdit = onCellEdit
        coordinator.onDeleteRows = onDeleteRows  // Added: pass delete callback
        coordinator.onSort = onSort
        coordinator.onAddRow = onAddRow
        coordinator.onUndoInsert = onUndoInsert
        coordinator.onFilterColumn = onFilterColumn
        coordinator.getVisualState = getVisualState

        coordinator.rebuildVisualStateCache()

        // Check if columns changed (by name or structure)
        let currentDataColumns = tableView.tableColumns.dropFirst()
        let currentColumnNames = currentDataColumns.map { $0.title }
        let columnsChanged = !rowProvider.columns.isEmpty && (currentColumnNames != rowProvider.columns)

        // Also rebuild columns when structure changes (e.g., 0 rows → data loaded)
        // This ensures column widths are recalculated based on actual cell content
        let shouldRebuildColumns = columnsChanged || (structureChanged && !rowProvider.columns.isEmpty)

        if shouldRebuildColumns {
            let columnsToRemove = tableView.tableColumns.filter { $0.identifier.rawValue != "__rowNumber__" }
            for column in columnsToRemove {
                tableView.removeTableColumn(column)
            }

            for (index, columnName) in rowProvider.columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(index)"))
                column.title = columnName
                // Use optimal width calculation based on both header and cell content
                column.width = cellFactory.calculateOptimalColumnWidth(
                    for: columnName,
                    columnIndex: index,
                    rowProvider: rowProvider
                )
                column.minWidth = 30
                column.resizingMask = .userResizingMask
                column.isEditable = isEditable
                column.sortDescriptorPrototype = NSSortDescriptor(key: "col_\(index)", ascending: true)
                tableView.addTableColumn(column)
            }
            tableView.sizeToFit()
        } else {
            // Always sync column editability (e.g., view tabs reusing table columns)
            for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                column.isEditable = isEditable
            }
        }

        // Sync sort state
        coordinator.isSyncingSortDescriptors = true
        defer { coordinator.isSyncingSortDescriptors = false }

        if !sortState.isSorting {
            if !tableView.sortDescriptors.isEmpty {
                tableView.sortDescriptors = []
            }
        } else if let columnIndex = sortState.columnIndex,
                  columnIndex >= 0 && columnIndex < rowProvider.columns.count {
            let key = "col_\(columnIndex)"
            let ascending = sortState.direction == .ascending
            let currentDescriptor = tableView.sortDescriptors.first
            if currentDescriptor?.key != key || currentDescriptor?.ascending != ascending {
                tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            }
        }

        if needsFullReload {
            tableView.reloadData()
        } else if versionChanged {
            // Granular reload: only reload rows that changed
            let changedRows = changeManager.consumeChangedRowIndices()
            if !changedRows.isEmpty {
                // Some rows changed → granular reload for performance
                let rowIndexSet = IndexSet(changedRows)
                let columnIndexSet = IndexSet(integersIn: 0..<tableView.numberOfColumns)
                tableView.reloadData(forRowIndexes: rowIndexSet, columnIndexes: columnIndexSet)
            } else if !changeManager.hasChanges {
                // Version changed but no changed rows → likely cleared changes (refresh)
                // Do full reload to clear visual states
                tableView.reloadData()
            }
        }

        coordinator.lastReloadVersion = changeManager.reloadVersion

        // Sync selection
        let currentSelection = tableView.selectedRowIndexes
        let targetSelection = IndexSet(selectedRowIndices)
        if currentSelection != targetSelection {
            tableView.selectRowIndexes(targetSelection, byExtendingSelection: false)
        }

        // Handle editingCell
        if let cell = editingCell {
            let tableColumn = cell.column + 1
            if cell.row < tableView.numberOfRows && tableColumn < tableView.numberOfColumns {
                tableView.scrollRowToVisible(cell.row)
                DispatchQueue.main.async { [weak tableView] in
                    guard let tableView = tableView else { return }
                    tableView.selectRowIndexes(IndexSet(integer: cell.row), byExtendingSelection: false)
                    tableView.editColumn(tableColumn, row: cell.row, with: nil, select: true)
                }
            }
            DispatchQueue.main.async {
                self.editingCell = nil
            }
        }
    }

    func makeCoordinator() -> TableViewCoordinator {
        TableViewCoordinator(
            rowProvider: rowProvider,
            changeManager: changeManager,
            isEditable: isEditable,
            selectedRowIndices: $selectedRowIndices,
            onCommit: onCommit,
            onRefresh: onRefresh,
            onCellEdit: onCellEdit,
            onDeleteRows: onDeleteRows,
            onCopyRows: onCopyRows,
            onPasteRows: onPasteRows,
            onUndo: onUndo,
            onRedo: onRedo
        )
    }
}

// MARK: - Coordinator

/// Coordinator handling NSTableView delegate and data source
@MainActor
final class TableViewCoordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource,
                                  NSControlTextEditingDelegate, NSTextFieldDelegate, NSMenuDelegate
{
    var rowProvider: InMemoryRowProvider
    var changeManager: AnyChangeManager
    var isEditable: Bool
    var onCommit: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onCellEdit: ((Int, Int, String?) -> Void)?
    var onDeleteRows: ((Set<Int>) -> Void)?
    var onCopyRows: ((Set<Int>) -> Void)?
    var onPasteRows: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSort: ((Int, Bool) -> Void)?
    var onAddRow: (() -> Void)?
    var onUndoInsert: ((Int) -> Void)?
    var onFilterColumn: ((String) -> Void)?
    var getVisualState: ((Int) -> RowVisualState)?

    /// Check if undo is available
    func canUndo() -> Bool {
        changeManager.hasChanges
    }

    /// Check if redo is available
    func canRedo() -> Bool {
        changeManager.canRedo
    }

    weak var tableView: NSTableView?
    var cellFactory: DataGridCellFactory?

    // Settings observer for real-time updates
    private var settingsObserver: NSObjectProtocol?

    @Binding var selectedRowIndices: Set<Int>

    var lastReloadVersion: Int = 0
    private(set) var cachedRowCount: Int = 0
    private(set) var cachedColumnCount: Int = 0
    var isSyncingSortDescriptors: Bool = false

    private let cellIdentifier = NSUserInterfaceItemIdentifier("DataCell")
    private var rowVisualStateCache: [Int: RowVisualState] = [:]
    private var lastVisualStateCacheVersion: Int = 0
    private let largeDatasetThreshold = 5_000

    var isLargeDataset: Bool { cachedRowCount > largeDatasetThreshold }

    init(
        rowProvider: InMemoryRowProvider,
        changeManager: AnyChangeManager,
        isEditable: Bool,
        selectedRowIndices: Binding<Set<Int>>,
        onCommit: ((String) -> Void)?,
        onRefresh: (() -> Void)?,
        onCellEdit: ((Int, Int, String?) -> Void)?,
        onDeleteRows: ((Set<Int>) -> Void)?,
        onCopyRows: ((Set<Int>) -> Void)?,
        onPasteRows: (() -> Void)?,
        onUndo: (() -> Void)?,
        onRedo: (() -> Void)?
    ) {
        self.rowProvider = rowProvider
        self.changeManager = changeManager
        self.isEditable = isEditable
        self._selectedRowIndices = selectedRowIndices
        self.onCommit = onCommit
        self.onRefresh = onRefresh
        self.onCellEdit = onCellEdit
        self.onDeleteRows = onDeleteRows
        self.onCopyRows = onCopyRows
        self.onPasteRows = onPasteRows
        self.onUndo = onUndo
        self.onRedo = onRedo
        super.init()
        updateCache()

        // Subscribe to settings changes for real-time updates
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .dataGridSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            Task { @MainActor [weak self] in
                guard let self, let tableView = self.tableView else { return }
                let newRowHeight = CGFloat(AppSettingsManager.shared.dataGrid.rowHeight.rawValue)

                // Only reload if row height changed (requires full reload)
                if tableView.rowHeight != newRowHeight {
                    tableView.rowHeight = newRowHeight
                    tableView.tile()
                } else {
                    // For other settings (date format, NULL display), just reload visible rows
                    let visibleRect = tableView.visibleRect
                    let visibleRange = tableView.rows(in: visibleRect)
                    if visibleRange.length > 0 {
                        tableView.reloadData(
                            forRowIndexes: IndexSet(integersIn: visibleRange.location..<(visibleRange.location + visibleRange.length)),
                            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                        )
                    }
                }
            }
        }
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func updateCache() {
        cachedRowCount = rowProvider.totalRowCount
        cachedColumnCount = rowProvider.columns.count
    }

    // MARK: - Row Visual State Cache

    @MainActor
    func rebuildVisualStateCache() {
        let currentVersion = changeManager.reloadVersion
        guard currentVersion != lastVisualStateCacheVersion else { return }
        lastVisualStateCacheVersion = currentVersion

        rowVisualStateCache.removeAll(keepingCapacity: true)

        // If custom getVisualState provided, don't build cache (use callback instead)
        if getVisualState != nil {
            return
        }

        // Always clear cache, then rebuild if there are changes
        // This ensures deleted state is cleared when changeManager.clearChanges() is called
        guard changeManager.hasChanges else {
            // No changes → cache is now empty (cleared above)
            return
        }

        for change in changeManager.changes {
            guard let rowChange = change as? RowChange else { continue }
            let rowIndex = rowChange.rowIndex
            let isDeleted = rowChange.type == .delete
            let isInserted = rowChange.type == .insert
            let modifiedColumns: Set<Int> = rowChange.type == .update
                ? Set(rowChange.cellChanges.map { $0.columnIndex })
                : []

            rowVisualStateCache[rowIndex] = RowVisualState(
                isDeleted: isDeleted,
                isInserted: isInserted,
                modifiedColumns: modifiedColumns
            )
        }
    }

    func visualState(for row: Int) -> RowVisualState {
        // If custom callback provided, use it
        if let callback = getVisualState {
            return callback(row)
        }
        // Otherwise use cache
        return rowVisualStateCache[row] ?? .empty
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        cachedRowCount
    }

    // MARK: - Native Sorting

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSyncingSortDescriptors else { return }

        guard let sortDescriptor = tableView.sortDescriptors.first,
              let key = sortDescriptor.key,
              key.hasPrefix("col_"),
              let columnIndex = Int(key.dropFirst(4)),
              columnIndex >= 0 && columnIndex < rowProvider.columns.count else {
            return
        }

        onSort?(columnIndex, sortDescriptor.ascending)
    }

    // MARK: - NSMenuDelegate (Header Context Menu)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let tableView = tableView,
              let headerView = tableView.headerView,
              let window = tableView.window else { return }

        let mouseLocation = window.mouseLocationOutsideOfEventStream
        let pointInHeader = headerView.convert(mouseLocation, from: nil)
        let columnIndex = headerView.column(at: pointInHeader)

        guard columnIndex >= 0 && columnIndex < tableView.tableColumns.count else { return }

        let column = tableView.tableColumns[columnIndex]
        if column.identifier.rawValue == "__rowNumber__" { return }

        let copyItem = NSMenuItem(title: "Copy Column Name", action: #selector(copyColumnName(_:)), keyEquivalent: "")
        copyItem.representedObject = column.title
        copyItem.target = self
        menu.addItem(copyItem)

        let filterItem = NSMenuItem(title: "Filter with column", action: #selector(filterWithColumn(_:)), keyEquivalent: "")
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }

        let columnId = column.identifier.rawValue

        if columnId == "__rowNumber__" {
            return cellFactory?.makeRowNumberCell(
                tableView: tableView,
                row: row,
                cachedRowCount: cachedRowCount,
                visualState: visualState(for: row)
            )
        }

        guard columnId.hasPrefix("col_"), let columnIndex = Int(columnId.dropFirst(4)) else { return nil }

        guard row >= 0 && row < cachedRowCount,
              columnIndex >= 0 && columnIndex < cachedColumnCount,
              let rowData = rowProvider.row(at: row) else {
            return nil
        }

        let value = rowData.value(at: columnIndex)
        let state = visualState(for: row)

        // Get column type for date formatting
        let columnType: ColumnType? = {
            guard columnIndex < rowProvider.columnTypes.count else { return nil }
            return rowProvider.columnTypes[columnIndex]
        }()

        let tableColumnIndex = columnIndex + 1
        let isFocused: Bool = {
            guard let keyTableView = tableView as? KeyHandlingTableView,
                  keyTableView.focusedRow == row,
                  keyTableView.focusedColumn == tableColumnIndex else { return false }
            return true
        }()

        return cellFactory?.makeDataCell(
            tableView: tableView,
            row: row,
            columnIndex: columnIndex,
            value: value,
            columnType: columnType,
            visualState: state,
            isEditable: isEditable && !state.isDeleted,
            isLargeDataset: isLargeDataset,
            isFocused: isFocused,
            delegate: self
        )
    }

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

        if let keyTableView = tableView as? KeyHandlingTableView {
            if newSelection.isEmpty {
                keyTableView.focusedRow = -1
                keyTableView.focusedColumn = -1
            }
        }
    }

    // MARK: - Double-Click Popover Editors

    @objc func handleDoubleClick(_ sender: NSTableView) {
        guard isEditable else { return }

        let row = sender.clickedRow
        let column = sender.clickedColumn
        guard row >= 0, column > 0 else { return }

        let columnIndex = column - 1
        guard !changeManager.isRowDeleted(row) else { return }

        // ENUM columns use searchable dropdown popover
        if columnIndex < rowProvider.columnTypes.count,
           rowProvider.columnTypes[columnIndex].isEnumType,
           columnIndex < rowProvider.columns.count {
            let columnName = rowProvider.columns[columnIndex]
            if let values = rowProvider.columnEnumValues[columnName], !values.isEmpty {
                showEnumPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
                return
            }
        }

        // SET columns use checkbox popover
        if columnIndex < rowProvider.columnTypes.count,
           rowProvider.columnTypes[columnIndex].isSetType,
           columnIndex < rowProvider.columns.count {
            let columnName = rowProvider.columns[columnIndex]
            if let values = rowProvider.columnEnumValues[columnName], !values.isEmpty {
                showSetPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
                return
            }
        }

        // FK columns use searchable dropdown popover
        if columnIndex < rowProvider.columns.count {
            let columnName = rowProvider.columns[columnIndex]
            if let fkInfo = rowProvider.columnForeignKeys[columnName] {
                showForeignKeyPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex, fkInfo: fkInfo)
                return
            }
        }

        // Date columns use date picker popover
        if columnIndex < rowProvider.columnTypes.count,
           rowProvider.columnTypes[columnIndex].isDateType {
            showDatePickerPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
            return
        }

        // JSON columns use JSON editor popover
        if columnIndex < rowProvider.columnTypes.count,
           rowProvider.columnTypes[columnIndex].isJsonType {
            showJSONEditorPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
            return
        }

        // Regular columns — start inline editing
        sender.editColumn(column, row: row, with: nil, select: true)
    }

    // MARK: - Editing

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        guard isEditable,
              let tableColumn = tableColumn else { return false }

        let columnId = tableColumn.identifier.rawValue
        guard columnId != "__rowNumber__",
              !changeManager.isRowDeleted(row) else { return false }

        // Popover-editor columns (date/FK/JSON) are only editable via
        // double-click (handleDoubleClick). Block inline editing for them.
        if columnId.hasPrefix("col_"),
           let columnIndex = Int(columnId.dropFirst(4)) {
            if columnIndex < rowProvider.columns.count {
                let columnName = rowProvider.columns[columnIndex]
                if rowProvider.columnForeignKeys[columnName] != nil { return false }
            }
            if columnIndex < rowProvider.columnTypes.count {
                let ct = rowProvider.columnTypes[columnIndex]
                if ct.isDateType || ct.isJsonType || ct.isEnumType || ct.isSetType { return false }
            }
        }

        return true
    }

    private func showDatePickerPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard let rowData = rowProvider.row(at: row) else { return }
        let currentValue = rowData.value(at: columnIndex)
        let columnType = rowProvider.columnTypes[columnIndex]

        guard let cellView = tableView.view(atColumn: column, row: row, makeIfNecessary: false) else { return }

        DatePickerPopoverController.shared.show(
            relativeTo: cellView.bounds,
            of: cellView,
            value: currentValue,
            columnType: columnType
        ) { [weak self] newValue in
            guard let self = self else { return }
            guard let rowData = self.rowProvider.row(at: row) else { return }
            let oldValue = rowData.value(at: columnIndex)
            guard oldValue != newValue else { return }

            let columnName = self.rowProvider.columns[columnIndex]
            self.changeManager.recordCellChange(
                rowIndex: row,
                columnIndex: columnIndex,
                columnName: columnName,
                oldValue: oldValue,
                newValue: newValue,
                originalRow: rowData.values
            )

            self.rowProvider.updateValue(newValue, at: row, columnIndex: columnIndex)
            self.onCellEdit?(row, columnIndex, newValue)

            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
        }
    }

    private func showForeignKeyPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int, fkInfo: ForeignKeyInfo) {
        guard let rowData = rowProvider.row(at: row) else { return }
        let currentValue = rowData.value(at: columnIndex)

        guard let cellView = tableView.view(atColumn: column, row: row, makeIfNecessary: false) else { return }
        guard let databaseType = DatabaseManager.shared.currentSession?.connection.type else { return }

        ForeignKeyPopoverController.shared.show(
            relativeTo: cellView.bounds,
            of: cellView,
            currentValue: currentValue,
            fkInfo: fkInfo,
            databaseType: databaseType
        ) { [weak self] newValue in
            guard let self = self else { return }
            guard let rowData = self.rowProvider.row(at: row) else { return }
            let oldValue = rowData.value(at: columnIndex)
            guard oldValue != newValue else { return }

            let columnName = self.rowProvider.columns[columnIndex]
            self.changeManager.recordCellChange(
                rowIndex: row,
                columnIndex: columnIndex,
                columnName: columnName,
                oldValue: oldValue,
                newValue: newValue,
                originalRow: rowData.values
            )

            self.rowProvider.updateValue(newValue, at: row, columnIndex: columnIndex)
            self.onCellEdit?(row, columnIndex, newValue)

            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
        }
    }

    private func showJSONEditorPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard let rowData = rowProvider.row(at: row) else { return }
        let currentValue = rowData.value(at: columnIndex)

        guard let cellView = tableView.view(atColumn: column, row: row, makeIfNecessary: false) else { return }

        JSONEditorPopoverController.shared.show(
            relativeTo: cellView.bounds,
            of: cellView,
            value: currentValue
        ) { [weak self] newValue in
            guard let self = self else { return }
            guard let rowData = self.rowProvider.row(at: row) else { return }
            let oldValue = rowData.value(at: columnIndex)
            guard oldValue != newValue else { return }

            let columnName = self.rowProvider.columns[columnIndex]
            self.changeManager.recordCellChange(
                rowIndex: row,
                columnIndex: columnIndex,
                columnName: columnName,
                oldValue: oldValue,
                newValue: newValue,
                originalRow: rowData.values
            )

            self.rowProvider.updateValue(newValue, at: row, columnIndex: columnIndex)
            self.onCellEdit?(row, columnIndex, newValue)

            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
        }
    }

    private func showEnumPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard let cellView = tableView.view(atColumn: column, row: row, makeIfNecessary: false),
              let rowData = rowProvider.row(at: row) else { return }
        let columnName = rowProvider.columns[columnIndex]
        guard let allowedValues = rowProvider.columnEnumValues[columnName] else { return }

        let currentValue = rowData.value(at: columnIndex)
        let isNullable = rowProvider.columnNullable[columnName] ?? true

        EnumPopoverController.shared.show(
            relativeTo: cellView.bounds,
            of: cellView,
            currentValue: currentValue,
            allowedValues: allowedValues,
            isNullable: isNullable
        ) { [weak self] newValue in
            self?.commitPopoverEdit(tableView: tableView, row: row, column: column, columnIndex: columnIndex, newValue: newValue)
        }
    }

    private func showSetPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard let cellView = tableView.view(atColumn: column, row: row, makeIfNecessary: false),
              let rowData = rowProvider.row(at: row) else { return }
        let columnName = rowProvider.columns[columnIndex]
        guard let allowedValues = rowProvider.columnEnumValues[columnName] else { return }

        let currentValue = rowData.value(at: columnIndex)

        SetPopoverController.shared.show(
            relativeTo: cellView.bounds,
            of: cellView,
            currentValue: currentValue,
            allowedValues: allowedValues
        ) { [weak self] newValue in
            self?.commitPopoverEdit(tableView: tableView, row: row, column: column, columnIndex: columnIndex, newValue: newValue)
        }
    }

    private func commitPopoverEdit(tableView: NSTableView, row: Int, column: Int, columnIndex: Int, newValue: String?) {
        guard let rowData = rowProvider.row(at: row) else { return }
        let oldValue = rowData.value(at: columnIndex)
        guard oldValue != newValue else { return }

        let columnName = rowProvider.columns[columnIndex]
        changeManager.recordCellChange(
            rowIndex: row,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: rowData.values
        )

        rowProvider.updateValue(newValue, at: row, columnIndex: columnIndex)
        onCellEdit?(row, columnIndex, newValue)

        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard let textField = control as? NSTextField, let tableView = tableView else { return true }

        let row = tableView.row(for: textField)
        let column = tableView.column(for: textField)

        guard row >= 0, column > 0 else { return true }

        let columnIndex = column - 1
        let newValue: String? = textField.stringValue

        guard let rowData = rowProvider.row(at: row) else { return true }
        let oldValue = rowData.value(at: columnIndex)

        guard oldValue != newValue else { return true }

        let columnName = rowProvider.columns[columnIndex]
        changeManager.recordCellChange(
            rowIndex: row,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: rowData.values
        )

        rowProvider.updateValue(newValue, at: row, columnIndex: columnIndex)
        onCellEdit?(row, columnIndex, newValue)

        DispatchQueue.main.async {
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
        }

        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let tableView = tableView else { return false }

        let currentRow = tableView.row(for: control)
        let currentColumn = tableView.column(for: control)

        guard currentRow >= 0, currentColumn >= 0 else { return false }

        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            tableView.window?.makeFirstResponder(tableView)

            var nextColumn = currentColumn + 1
            var nextRow = currentRow

            if nextColumn >= tableView.numberOfColumns {
                nextColumn = 1
                nextRow += 1
            }
            if nextRow >= tableView.numberOfRows {
                nextRow = tableView.numberOfRows - 1
                nextColumn = tableView.numberOfColumns - 1
            }

            DispatchQueue.main.async {
                tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
                tableView.editColumn(nextColumn, row: nextRow, with: nil, select: true)
            }
            return true
        }

        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            tableView.window?.makeFirstResponder(tableView)

            var prevColumn = currentColumn - 1
            var prevRow = currentRow

            if prevColumn < 1 {
                prevColumn = tableView.numberOfColumns - 1
                prevRow -= 1
            }
            if prevRow < 0 {
                prevRow = 0
                prevColumn = 1
            }

            DispatchQueue.main.async {
                tableView.selectRowIndexes(IndexSet(integer: prevRow), byExtendingSelection: false)
                tableView.editColumn(prevColumn, row: prevRow, with: nil, select: true)
            }
            return true
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            tableView.window?.makeFirstResponder(tableView)
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            tableView.window?.makeFirstResponder(tableView)
            return true
        }

        return false
    }

    // MARK: - Row Actions

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
            guard let rowData = rowProvider.row(at: index) else { continue }
            let line = rowData.values.map { $0 ?? "NULL" }.joined(separator: "\t")
            lines.append(line)
        }

        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        let oldValue = rowProvider.row(at: rowIndex)?.value(at: columnIndex)
        let originalRow = rowProvider.row(at: rowIndex)?.values ?? []

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

        if let rowData = rowProvider.row(at: rowIndex) {
            let value = rowData.value(at: columnIndex) ?? "NULL"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
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
        changeManager: AnyChangeManager(dataManager: DataChangeManager()),
        isEditable: true,
        selectedRowIndices: .constant([]),
        sortState: .constant(SortState()),
        editingCell: .constant(nil as CellPosition?)
    )
    .frame(width: 600, height: 400)
}

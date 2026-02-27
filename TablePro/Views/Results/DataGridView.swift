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

/// Identity snapshot used to skip redundant updateNSView work when nothing has changed
private struct DataGridIdentity: Equatable {
    let reloadVersion: Int
    let resultVersion: Int
    let metadataVersion: Int
    let rowCount: Int
    let columnCount: Int
    let isEditable: Bool
}

/// High-performance table view using AppKit NSTableView
struct DataGridView: NSViewRepresentable {
    let rowProvider: InMemoryRowProvider
    @ObservedObject var changeManager: AnyChangeManager
    var resultVersion: Int = 0
    var metadataVersion: Int = 0
    let isEditable: Bool
    var onCommit: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onCellEdit: ((Int, Int, String?) -> Void)?
    var onDeleteRows: ((Set<Int>) -> Void)?
    var onCopyRows: ((Set<Int>) -> Void)?
    var onPasteRows: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSort: ((Int, Bool, Bool) -> Void)?
    var onAddRow: (() -> Void)?
    var onUndoInsert: ((Int) -> Void)?
    var onFilterColumn: ((String) -> Void)?
    var onNavigateFK: ((String, ForeignKeyInfo) -> Void)?
    var getVisualState: ((Int) -> RowVisualState)?
    var dropdownColumns: Set<Int>? // Column indices that should use YES/NO dropdowns
    var typePickerColumns: Set<Int>?
    var databaseType: DatabaseType?

    @Binding var selectedRowIndices: Set<Int>
    @Binding var sortState: SortState
    @Binding var editingCell: CellPosition?
    @Binding var columnLayout: ColumnLayoutState

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
        tableView.setAccessibilityLabel(String(localized: "Data grid"))
        tableView.setAccessibilityRole(.table)
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
        tableView.action = #selector(TableViewCoordinator.handleClick(_:))
        tableView.doubleAction = #selector(TableViewCoordinator.handleDoubleClick(_:))

        // Add row number column
        let rowNumberColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("__rowNumber__"))
        rowNumberColumn.title = "#"
        rowNumberColumn.width = 40
        rowNumberColumn.minWidth = 40
        rowNumberColumn.maxWidth = 60
        rowNumberColumn.isEditable = false
        rowNumberColumn.resizingMask = []
        rowNumberColumn.headerCell.setAccessibilityLabel(String(localized: "Row number"))
        tableView.addTableColumn(rowNumberColumn)

        // Add data columns (suppress resize notifications during setup)
        context.coordinator.isRebuildingColumns = true
        for (index, columnName) in rowProvider.columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(index)"))
            column.title = columnName
            column.headerCell.setAccessibilityLabel(
                String(localized: "Column: \(columnName)")
            )
            // Use optimal width calculation based on both header and cell content
            column.width = context.coordinator.cellFactory.calculateOptimalColumnWidth(
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

        // Apply saved column widths (from user resizing)
        if !columnLayout.columnWidths.isEmpty {
            for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                guard let colIndex = Self.columnIndex(from: column.identifier),
                      colIndex < rowProvider.columns.count else { continue }
                let baseName = rowProvider.columns[colIndex]
                if let savedWidth = columnLayout.columnWidths[baseName] {
                    column.width = savedWidth
                }
            }
            context.coordinator.hasUserResizedColumns = true
        }

        // Apply saved column order
        if let savedOrder = columnLayout.columnOrder {
            DataGridView.applyColumnOrder(savedOrder, to: tableView, columns: rowProvider.columns)
        }
        context.coordinator.isRebuildingColumns = false

        if let headerView = tableView.headerView {
            let headerMenu = NSMenu()
            headerMenu.delegate = context.coordinator
            headerView.menu = headerMenu
        }

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }

        let coordinator = context.coordinator

        // Don't reload while editing (field editor or overlay)
        if tableView.editedRow >= 0 { return }
        if let editor = context.coordinator.overlayEditor, editor.isActive { return }

        // Identity-based early-return BEFORE reading settings — avoids
        // AppSettingsManager access on every SwiftUI re-evaluation.
        let currentIdentity = DataGridIdentity(
            reloadVersion: changeManager.reloadVersion,
            resultVersion: resultVersion,
            metadataVersion: metadataVersion,
            rowCount: rowProvider.totalRowCount,
            columnCount: rowProvider.columns.count,
            isEditable: isEditable
        )
        if currentIdentity == coordinator.lastIdentity {
            // Only refresh closure callbacks — they capture new state on each body eval
            coordinator.onCellEdit = onCellEdit
            coordinator.onSort = onSort
            coordinator.onAddRow = onAddRow
            coordinator.onUndoInsert = onUndoInsert
            coordinator.onFilterColumn = onFilterColumn
            coordinator.onCommit = onCommit
            coordinator.onRefresh = onRefresh
            coordinator.onDeleteRows = onDeleteRows
            coordinator.getVisualState = getVisualState
            coordinator.onNavigateFK = onNavigateFK
            return
        }
        let previousIdentity = coordinator.lastIdentity
        coordinator.lastIdentity = currentIdentity

        // Update settings-based properties dynamically (after identity check)
        let settings = AppSettingsManager.shared.dataGrid
        if tableView.rowHeight != CGFloat(settings.rowHeight.rawValue) {
            tableView.rowHeight = CGFloat(settings.rowHeight.rawValue)
        }
        if tableView.usesAlternatingRowBackgroundColors != settings.showAlternateRows {
            tableView.usesAlternatingRowBackgroundColors = settings.showAlternateRows
        }

        let versionChanged = coordinator.lastReloadVersion != changeManager.reloadVersion
        let metadataChanged = previousIdentity.map { $0.metadataVersion != metadataVersion } ?? false
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
        coordinator.onNavigateFK = onNavigateFK
        coordinator.dropdownColumns = dropdownColumns
        coordinator.typePickerColumns = typePickerColumns
        coordinator.databaseType = databaseType

        coordinator.rebuildVisualStateCache()

        // Capture current column layout before any rebuilds (only if not about to rebuild)
        // Check if columns changed (by name or structure)
        let currentDataColumns = tableView.tableColumns.dropFirst()
        let currentColumnIds = currentDataColumns.map { $0.identifier.rawValue }
        let expectedColumnIds = rowProvider.columns.indices.map { "col_\($0)" }
        let columnsChanged = !rowProvider.columns.isEmpty && (currentColumnIds != expectedColumnIds)

        // Also rebuild columns when structure changes (e.g., 0 rows → data loaded)
        // This ensures column widths are recalculated based on actual cell content
        let shouldRebuildColumns = columnsChanged || (structureChanged && !rowProvider.columns.isEmpty)

        updateColumns(
            tableView: tableView,
            coordinator: coordinator,
            columnsChanged: columnsChanged,
            shouldRebuild: shouldRebuildColumns,
            structureChanged: structureChanged
        )

        syncSortDescriptors(tableView: tableView, coordinator: coordinator)

        reloadAndSyncSelection(
            tableView: tableView,
            coordinator: coordinator,
            needsFullReload: needsFullReload,
            versionChanged: versionChanged,
            metadataChanged: metadataChanged
        )
    }

    // MARK: - updateNSView Helpers

    /// Rebuild or sync table columns based on data changes
    private func updateColumns(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        columnsChanged: Bool,
        shouldRebuild: Bool,
        structureChanged: Bool
    ) {
        if shouldRebuild {
            coordinator.isRebuildingColumns = true
            defer { coordinator.isRebuildingColumns = false }

            if columnsChanged {
                // Column count changed — full rebuild (remove all, create all)
                let columnsToRemove = tableView.tableColumns.filter { $0.identifier.rawValue != "__rowNumber__" }
                for column in columnsToRemove {
                    tableView.removeTableColumn(column)
                }

                for (index, columnName) in rowProvider.columns.enumerated() {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(index)"))
                    column.title = columnName
                    column.headerCell.setAccessibilityLabel(
                        String(localized: "Column: \(columnName)")
                    )
                    if let savedWidth = columnLayout.columnWidths[columnName] {
                        column.width = savedWidth
                    } else {
                        column.width = coordinator.cellFactory.calculateOptimalColumnWidth(
                            for: columnName,
                            columnIndex: index,
                            rowProvider: rowProvider
                        )
                    }
                    column.minWidth = 30
                    column.resizingMask = .userResizingMask
                    column.isEditable = isEditable
                    column.sortDescriptorPrototype = NSSortDescriptor(key: "col_\(index)", ascending: true)
                    tableView.addTableColumn(column)
                }
            } else {
                // Same column count — lightweight in-place update (avoids remove/add overhead)
                for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                    guard let colIndex = Self.columnIndex(from: column.identifier),
                          colIndex < rowProvider.columns.count else { continue }
                    let columnName = rowProvider.columns[colIndex]
                    column.title = columnName
                    if let savedWidth = columnLayout.columnWidths[columnName] {
                        column.width = savedWidth
                    } else {
                        column.width = coordinator.cellFactory.calculateOptimalColumnWidth(
                            for: columnName,
                            columnIndex: colIndex,
                            rowProvider: rowProvider
                        )
                    }
                    column.isEditable = isEditable
                }
            }
            // Restore user-resized column widths after rebuild (only if user explicitly resized)
            if coordinator.hasUserResizedColumns, !columnLayout.columnWidths.isEmpty {
                for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                    guard let colIndex = Self.columnIndex(from: column.identifier),
                          colIndex < rowProvider.columns.count else { continue }
                    let baseName = rowProvider.columns[colIndex]
                    if let savedWidth = columnLayout.columnWidths[baseName] {
                        column.width = savedWidth
                    }
                }
            }

            // Restore saved column order after rebuild (only if user explicitly reordered)
            if coordinator.hasUserResizedColumns, let savedOrder = columnLayout.columnOrder {
                DataGridView.applyColumnOrder(savedOrder, to: tableView, columns: rowProvider.columns)
            }

            // Persist calculated widths so subsequent tab switches reuse them
            // instead of calling the expensive calculateOptimalColumnWidth.
            if !coordinator.hasUserResizedColumns {
                var newWidths: [String: CGFloat] = [:]
                for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                    guard let colIndex = Self.columnIndex(from: column.identifier),
                          colIndex < rowProvider.columns.count else { continue }
                    newWidths[rowProvider.columns[colIndex]] = column.width
                }
                if !newWidths.isEmpty && newWidths != columnLayout.columnWidths {
                    coordinator.isWritingColumnLayout = true
                    DispatchQueue.main.async {
                        coordinator.isWritingColumnLayout = false
                        self.columnLayout.columnWidths = newWidths
                    }
                }
            }
        } else {
            // Always sync column editability (e.g., view tabs reusing table columns)
            for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                column.isEditable = isEditable
            }

            // Skip layout capture when an async layout write-back is pending —
            // prevents the two-frame bounce where stale widths are applied
            // before the async block updates them.
            guard !coordinator.isWritingColumnLayout else { return }

            // Capture current column layout from user interactions (resize/reorder)
            // Only done in the non-rebuild path to avoid feedback loops
            if coordinator.hasUserResizedColumns, tableView.tableColumns.count > 1 {
                var currentWidths: [String: CGFloat] = [:]
                var currentOrder: [String] = []
                for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                    guard let colIndex = Self.columnIndex(from: column.identifier),
                          colIndex < rowProvider.columns.count else { continue }
                    let baseName = rowProvider.columns[colIndex]
                    currentWidths[baseName] = column.width
                    currentOrder.append(baseName)
                }
                let widthsChanged = !currentWidths.isEmpty && currentWidths != columnLayout.columnWidths
                let orderChanged = !currentOrder.isEmpty && columnLayout.columnOrder != currentOrder
                if widthsChanged || orderChanged {
                    coordinator.isWritingColumnLayout = true
                    DispatchQueue.main.async {
                        coordinator.isWritingColumnLayout = false
                        if widthsChanged {
                            self.columnLayout.columnWidths = currentWidths
                        }
                        if orderChanged {
                            self.columnLayout.columnOrder = currentOrder
                        }
                    }
                }
                coordinator.hasUserResizedColumns = false
            }
        }
    }

    /// Synchronize sort descriptors and indicators with the table view
    private func syncSortDescriptors(tableView: NSTableView, coordinator: TableViewCoordinator) {
        coordinator.isSyncingSortDescriptors = true
        defer { coordinator.isSyncingSortDescriptors = false }

        if !sortState.isSorting {
            if !tableView.sortDescriptors.isEmpty {
                tableView.sortDescriptors = []
            }
        } else if let firstSort = sortState.columns.first,
                  firstSort.columnIndex >= 0 && firstSort.columnIndex < rowProvider.columns.count {
            // Sync with first sort column for NSTableView's built-in sort indicators
            let key = "col_\(firstSort.columnIndex)"
            let ascending = firstSort.direction == .ascending
            let currentDescriptor = tableView.sortDescriptors.first
            if currentDescriptor?.key != key || currentDescriptor?.ascending != ascending {
                tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            }
        }

        // Update column header titles for multi-sort indicators
        Self.updateSortIndicators(tableView: tableView, sortState: sortState, columns: rowProvider.columns)
    }

    /// Reload table data as needed and synchronize selection and editing state
    private func reloadAndSyncSelection(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        needsFullReload: Bool,
        versionChanged: Bool,
        metadataChanged: Bool = false
    ) {
        if needsFullReload {
            tableView.reloadData()
        } else if metadataChanged {
            // FK metadata arrived (Phase 2) — reload all cells to show FK arrow buttons
            tableView.reloadData()
        } else if versionChanged {
            // Granular reload: only reload rows that changed
            let changedRows = changeManager.consumeChangedRowIndices()
            if !changedRows.isEmpty {
                // Some rows changed → granular reload for performance
                let rowIndexSet = IndexSet(changedRows)
                let columnIndexSet = IndexSet(integersIn: 0..<tableView.numberOfColumns)
                tableView.reloadData(forRowIndexes: rowIndexSet, columnIndexes: columnIndexSet)
            } else {
                // Version changed but no specific rows tracked → full reload
                // Covers: undo/redo operations, cleared changes (refresh), etc.
                tableView.reloadData()
            }
        }

        coordinator.lastReloadVersion = changeManager.reloadVersion

        // Sync selection
        let currentSelection = tableView.selectedRowIndexes
        let targetSelection = IndexSet(selectedRowIndices)
        if currentSelection != targetSelection {
            coordinator.isSyncingSelection = true
            tableView.selectRowIndexes(targetSelection, byExtendingSelection: false)
            coordinator.isSyncingSelection = false
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

    // MARK: - Column Layout Helpers

    /// Extract column index from a stable identifier like "col_3"
    static func columnIndex(from identifier: NSUserInterfaceItemIdentifier) -> Int? {
        let raw = identifier.rawValue
        guard raw.hasPrefix("col_") else { return nil }
        return Int(raw.dropFirst(4))
    }

    private static func applyColumnOrder(_ order: [String], to tableView: NSTableView, columns: [String]) {
        // Only apply if saved order is a permutation of current columns
        guard Set(order) == Set(columns) else { return }

        let dataColumns = tableView.tableColumns.filter { $0.identifier.rawValue != "__rowNumber__" }
        for (targetIndex, columnName) in order.enumerated() {
            guard let sourceColumn = dataColumns.first(where: { col in
                guard let idx = columnIndex(from: col.identifier), idx < columns.count else { return false }
                return columns[idx] == columnName
            }),
                  let currentIndex = tableView.tableColumns.firstIndex(of: sourceColumn) else { continue }
            let targetTableIndex = targetIndex + 1  // +1 for row number column
            if currentIndex != targetTableIndex && targetTableIndex < tableView.numberOfColumns {
                tableView.moveColumn(currentIndex, toColumn: targetTableIndex)
            }
        }
    }

    // MARK: - Sort Indicator Helpers

    /// Update column header titles to show multi-sort priority indicators (e.g., "name 1▲", "age 2▼")
    private static func updateSortIndicators(tableView: NSTableView, sortState: SortState, columns: [String]) {
        for column in tableView.tableColumns where column.identifier.rawValue.hasPrefix("col_") {
            let idString = column.identifier.rawValue
            guard let colIndex = Int(idString.dropFirst(4)),
                  colIndex < columns.count else { continue }

            let baseName = columns[colIndex]

            if let sortIndex = sortState.columns.firstIndex(where: { $0.columnIndex == colIndex }) {
                let sortCol = sortState.columns[sortIndex]
                if sortState.columns.count > 1 {
                    let indicator = " \(sortIndex + 1)\(sortCol.direction.indicator)"
                    column.title = "\(baseName)\(indicator)"
                } else {
                    // Single sort: NSTableView shows its own indicator, keep base name
                    column.title = baseName
                }
            } else {
                // Not sorted: restore base name
                column.title = baseName
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: TableViewCoordinator) {
        coordinator.overlayEditor?.dismiss(commit: false)
        if let observer = coordinator.settingsObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.settingsObserver = nil
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
    var onSort: ((Int, Bool, Bool) -> Void)?
    var onAddRow: (() -> Void)?
    var onUndoInsert: ((Int) -> Void)?
    var onFilterColumn: ((String) -> Void)?
    var onNavigateFK: ((String, ForeignKeyInfo) -> Void)?
    var getVisualState: ((Int) -> RowVisualState)?
    var dropdownColumns: Set<Int>?
    var typePickerColumns: Set<Int>?
    var databaseType: DatabaseType?

    /// Check if undo is available
    func canUndo() -> Bool {
        changeManager.hasChanges
    }

    /// Check if redo is available
    func canRedo() -> Bool {
        changeManager.canRedo
    }

    weak var tableView: NSTableView?
    let cellFactory = DataGridCellFactory()
    private(set) var overlayEditor: CellOverlayEditor?

    // Settings observer for real-time updates
    fileprivate var settingsObserver: NSObjectProtocol?

    @Binding var selectedRowIndices: Set<Int>

    fileprivate var lastIdentity: DataGridIdentity?
    var lastReloadVersion: Int = 0
    private(set) var cachedRowCount: Int = 0
    private(set) var cachedColumnCount: Int = 0
    var isSyncingSortDescriptors: Bool = false
    /// Suppresses selection delegate callbacks during programmatic selection sync
    var isSyncingSelection = false
    var isRebuildingColumns: Bool = false
    var hasUserResizedColumns: Bool = false
    /// Guards against two-frame bounce when async column layout write-back triggers updateNSView
    var isWritingColumnLayout: Bool = false

    private let cellIdentifier = NSUserInterfaceItemIdentifier("DataCell")
    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("TableRowView")
    private var pendingDropdownRow: Int = 0
    private var pendingDropdownColumn: Int = 0
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

        let isMultiSort = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        onSort?(columnIndex, sortDescriptor.ascending, isMultiSort)
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

        // Derive base column name from stable identifier (avoids sort indicator in title)
        let baseName: String = {
            if let idx = DataGridView.columnIndex(from: column.identifier),
               idx < rowProvider.columns.count {
                return rowProvider.columns[idx]
            }
            return column.title
        }()

        let copyItem = NSMenuItem(title: String(localized: "Copy Column Name"), action: #selector(copyColumnName(_:)), keyEquivalent: "")
        copyItem.representedObject = baseName
        copyItem.target = self
        menu.addItem(copyItem)

        let filterItem = NSMenuItem(title: String(localized: "Filter with column"), action: #selector(filterWithColumn(_:)), keyEquivalent: "")
        filterItem.representedObject = baseName
        filterItem.target = self
        menu.addItem(filterItem)
    }

    @objc private func copyColumnName(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        ClipboardService.shared.writeText(columnName)
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
            return cellFactory.makeRowNumberCell(
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

        let isDropdown = dropdownColumns?.contains(columnIndex) == true
        let isTypePicker = typePickerColumns?.contains(columnIndex) == true

        let isFKColumn: Bool = {
            guard columnIndex < rowProvider.columns.count else { return false }
            let columnName = rowProvider.columns[columnIndex]
            return rowProvider.columnForeignKeys[columnName] != nil
        }()

        return cellFactory.makeDataCell(
            tableView: tableView,
            row: row,
            columnIndex: columnIndex,
            value: value,
            columnType: columnType,
            visualState: state,
            isEditable: isEditable && !state.isDeleted,
            isLargeDataset: isLargeDataset,
            isFocused: isFocused,
            isDropdown: isDropdown || isTypePicker,
            isFKColumn: isFKColumn && !isDropdown && !(typePickerColumns?.contains(columnIndex) == true),
            fkArrowTarget: self,
            fkArrowAction: #selector(handleFKArrowClick(_:)),
            delegate: self
        )
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewIdentifier, owner: nil) as? TableRowViewWithMenu)
            ?? TableRowViewWithMenu()
        rowView.identifier = Self.rowViewIdentifier
        rowView.coordinator = self
        rowView.rowIndex = row
        return rowView
    }

    // MARK: - Selection

    func tableViewColumnDidResize(_ notification: Notification) {
        // Only track user-initiated resizes, not programmatic ones during column rebuilds
        guard !isRebuildingColumns else { return }
        hasUserResizedColumns = true
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard !isRebuildingColumns else { return }
        hasUserResizedColumns = true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        guard let tableView = notification.object as? NSTableView else { return }

        let newSelection = Set(tableView.selectedRowIndexes.map { $0 })
        if newSelection != selectedRowIndices {
            Task { @MainActor [weak self] in
                self?.selectedRowIndices = newSelection
            }
        }

        if let keyTableView = tableView as? KeyHandlingTableView {
            if newSelection.isEmpty {
                keyTableView.focusedRow = -1
                keyTableView.focusedColumn = -1
            }
        }
    }

    // MARK: - Click Handlers

    @objc func handleClick(_ sender: NSTableView) {
        guard isEditable else { return }

        let row = sender.clickedRow
        let column = sender.clickedColumn
        guard row >= 0, column > 0 else { return }

        let columnIndex = column - 1
        guard !changeManager.isRowDeleted(row) else { return }

        // Dropdown columns open on single click
        if let dropdownCols = dropdownColumns, dropdownCols.contains(columnIndex) {
            showDropdownMenu(tableView: sender, row: row, column: column, columnIndex: columnIndex)
        }
    }

    @objc func handleDoubleClick(_ sender: NSTableView) {
        guard isEditable else { return }

        let row = sender.clickedRow
        let column = sender.clickedColumn
        guard row >= 0, column > 0 else { return }

        let columnIndex = column - 1
        guard !changeManager.isRowDeleted(row) else { return }

        // Dropdown columns already handled by single click
        if let dropdownCols = dropdownColumns, dropdownCols.contains(columnIndex) {
            return
        }

        // Type picker columns use database-specific type popover
        if let typePickerCols = typePickerColumns, typePickerCols.contains(columnIndex) {
            showTypePickerPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
            return
        }

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

        // Multiline values use the overlay editor instead of inline field editor
        if let value = rowProvider.row(at: row)?.value(at: columnIndex),
           value.containsLineBreak {
            showOverlayEditor(tableView: sender, row: row, column: column, columnIndex: columnIndex, value: value)
            return
        }

        // Regular columns — start inline editing
        sender.editColumn(column, row: row, with: nil, select: true)
    }

    // MARK: - FK Navigation

    @objc func handleFKArrowClick(_ sender: NSButton) {
        guard let button = sender as? FKArrowButton else { return }
        let row = button.fkRow
        let columnIndex = button.fkColumnIndex

        guard row >= 0 && row < cachedRowCount,
              columnIndex >= 0 && columnIndex < rowProvider.columns.count,
              let rowData = rowProvider.row(at: row) else { return }

        let columnName = rowProvider.columns[columnIndex]
        guard let fkInfo = rowProvider.columnForeignKeys[columnName] else { return }

        let value = rowData.value(at: columnIndex)
        guard let value = value, !value.isEmpty else { return }

        onNavigateFK?(value, fkInfo)
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
            if let dropdownCols = dropdownColumns, dropdownCols.contains(columnIndex) {
                return false
            }
            if let typePickerCols = typePickerColumns, typePickerCols.contains(columnIndex) {
                return false
            }

            // Multiline values use overlay editor — block inline field editor
            if let value = rowProvider.row(at: row)?.value(at: columnIndex),
               value.containsLineBreak {
                let tableColumnIdx = tableView.column(withIdentifier: tableColumn.identifier)
                guard tableColumnIdx >= 0 else { return false }
                showOverlayEditor(tableView: tableView, row: row, column: tableColumnIdx, columnIndex: columnIndex, value: value)
                return false
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

        PopoverPresenter.show(
            relativeTo: cellView.bounds,
            of: cellView,
            contentSize: NSSize(width: 420, height: 320)
        ) { [weak self] dismiss in
            ForeignKeyPopoverContentView(
                currentValue: currentValue,
                fkInfo: fkInfo,
                databaseType: databaseType,
                onCommit: { newValue in
                    self?.commitPopoverEdit(
                        tableView: tableView,
                        row: row,
                        column: column,
                        columnIndex: columnIndex,
                        newValue: newValue
                    )
                },
                onDismiss: dismiss
            )
        }
    }

    private func showJSONEditorPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard let rowData = rowProvider.row(at: row) else { return }
        let currentValue = rowData.value(at: columnIndex)

        guard let cellView = tableView.view(atColumn: column, row: row, makeIfNecessary: false) else { return }

        PopoverPresenter.show(
            relativeTo: cellView.bounds,
            of: cellView,
            contentSize: NSSize(width: 420, height: 340)
        ) { [weak self] dismiss in
            JSONEditorContentView(
                initialValue: currentValue,
                onCommit: { newValue in
                    self?.commitPopoverEdit(
                        tableView: tableView,
                        row: row,
                        column: column,
                        columnIndex: columnIndex,
                        newValue: newValue
                    )
                },
                onDismiss: dismiss
            )
        }
    }

    private func showEnumPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard let cellView = tableView.view(atColumn: column, row: row, makeIfNecessary: false),
              let rowData = rowProvider.row(at: row) else { return }
        let columnName = rowProvider.columns[columnIndex]
        guard let allowedValues = rowProvider.columnEnumValues[columnName] else { return }

        let currentValue = rowData.value(at: columnIndex)
        let isNullable = rowProvider.columnNullable[columnName] ?? true

        // Build value list (NULL first if nullable)
        var values: [String] = []
        if isNullable {
            values.append("\u{2300} NULL")
        }
        values.append(contentsOf: allowedValues)

        PopoverPresenter.show(
            relativeTo: cellView.bounds,
            of: cellView
        ) { [weak self] dismiss in
            EnumPopoverContentView(
                allValues: values,
                currentValue: currentValue,
                isNullable: isNullable,
                onCommit: { newValue in
                    self?.commitPopoverEdit(tableView: tableView, row: row, column: column, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss
            )
        }
    }

    private func showSetPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard let cellView = tableView.view(atColumn: column, row: row, makeIfNecessary: false),
              let rowData = rowProvider.row(at: row) else { return }
        let columnName = rowProvider.columns[columnIndex]
        guard let allowedValues = rowProvider.columnEnumValues[columnName] else { return }

        let currentValue = rowData.value(at: columnIndex)

        // Parse current value to determine checked state
        let currentSet: Set<String>
        if let value = currentValue {
            currentSet = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        } else {
            currentSet = []
        }
        var selections: [String: Bool] = [:]
        for value in allowedValues {
            selections[value] = currentSet.contains(value)
        }

        PopoverPresenter.show(
            relativeTo: cellView.bounds,
            of: cellView
        ) { [weak self] dismiss in
            SetPopoverContentView(
                allowedValues: allowedValues,
                initialSelections: selections,
                onCommit: { newValue in
                    self?.commitPopoverEdit(tableView: tableView, row: row, column: column, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss
            )
        }
    }

    private func showDropdownMenu(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard let cellView = tableView.view(atColumn: column, row: row, makeIfNecessary: false),
              let rowData = rowProvider.row(at: row) else { return }

        let currentValue = rowData.value(at: columnIndex)
        pendingDropdownRow = row
        pendingDropdownColumn = columnIndex

        let menu = NSMenu()
        for option in ["YES", "NO"] {
            let item = NSMenuItem(title: option, action: #selector(dropdownMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            if option == currentValue {
                item.state = .on
            }
            menu.addItem(item)
        }

        let cellRect = cellView.bounds
        menu.popUp(positioning: nil, at: NSPoint(x: cellRect.minX, y: cellRect.maxY), in: cellView)
    }

    @objc private func dropdownMenuItemSelected(_ sender: NSMenuItem) {
        let newValue = sender.title
        guard let rowData = rowProvider.row(at: pendingDropdownRow) else { return }
        let oldValue = rowData.value(at: pendingDropdownColumn)
        guard oldValue != newValue else { return }
        onCellEdit?(pendingDropdownRow, pendingDropdownColumn, newValue)
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

    // MARK: - Overlay Editor (Multiline)

    func showOverlayEditor(tableView: NSTableView, row: Int, column: Int, columnIndex: Int, value: String) {
        if overlayEditor == nil {
            overlayEditor = CellOverlayEditor()
        }
        guard let editor = overlayEditor else { return }

        editor.onCommit = { [weak self] row, columnIndex, newValue in
            self?.commitOverlayEdit(row: row, columnIndex: columnIndex, newValue: newValue)
        }
        editor.onTabNavigation = { [weak self] row, column, forward in
            self?.handleOverlayTabNavigation(row: row, column: column, forward: forward)
        }
        editor.show(in: tableView, row: row, column: column, columnIndex: columnIndex, value: value)
    }

    private func commitOverlayEdit(row: Int, columnIndex: Int, newValue: String) {
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

        let tableColumnIndex = columnIndex + 1
        tableView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: tableColumnIndex))
    }

    private func handleOverlayTabNavigation(row: Int, column: Int, forward: Bool) {
        guard let tableView = tableView else { return }

        var nextColumn = forward ? column + 1 : column - 1
        var nextRow = row

        if forward {
            if nextColumn >= tableView.numberOfColumns {
                nextColumn = 1
                nextRow += 1
            }
            if nextRow >= tableView.numberOfRows {
                nextRow = tableView.numberOfRows - 1
                nextColumn = tableView.numberOfColumns - 1
            }
        } else {
            if nextColumn < 1 {
                nextColumn = tableView.numberOfColumns - 1
                nextRow -= 1
            }
            if nextRow < 0 {
                nextRow = 0
                nextColumn = 1
            }
        }

        tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)

        // Check if next cell is also multiline → open overlay there
        let nextColumnIndex = nextColumn - 1
        if nextColumnIndex >= 0, nextColumnIndex < rowProvider.columns.count,
           let value = rowProvider.row(at: nextRow)?.value(at: nextColumnIndex),
           value.containsLineBreak {
            showOverlayEditor(tableView: tableView, row: nextRow, column: nextColumn, columnIndex: nextColumnIndex, value: value)
        } else {
            tableView.editColumn(nextColumn, row: nextRow, with: nil, select: true)
        }
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

        Task { @MainActor in
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
        }

        (control as? CellTextField)?.restoreTruncatedDisplay()

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

            Task { @MainActor in
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

            Task { @MainActor in
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
}

// MARK: - Preview

#Preview {
    DataGridView(
        rowProvider: InMemoryRowProvider(
            rows: [
                QueryResultRow(id: 0, values: ["1", "John", "john@example.com"]),
                QueryResultRow(id: 1, values: ["2", "Jane", nil]),
                QueryResultRow(id: 2, values: ["3", "Bob", "bob@example.com"]),
            ],
            columns: ["id", "name", "email"]
        ),
        changeManager: AnyChangeManager(dataManager: DataChangeManager()),
        isEditable: true,
        selectedRowIndices: .constant([]),
        sortState: .constant(SortState()),
        editingCell: .constant(nil as CellPosition?),
        columnLayout: .constant(ColumnLayoutState())
    )
    .frame(width: 600, height: 400)
}

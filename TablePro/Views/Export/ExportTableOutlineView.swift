//
//  ExportTableOutlineView.swift
//  TablePro
//
//  High-performance NSOutlineView-based table tree for export dialog.
//  Provides native virtualization for smooth scrolling with large datasets.
//

import AppKit
import SwiftUI

// MARK: - SwiftUI Wrapper

struct ExportTableOutlineView: NSViewRepresentable {
    @Binding var databaseItems: [ExportDatabaseItem]
    let format: ExportFormat

    func makeNSView(context: Context) -> NSScrollView {
        let containerView = NSScrollView()
        containerView.hasVerticalScroller = true
        containerView.hasHorizontalScroller = false
        containerView.autohidesScrollers = true
        containerView.borderType = .noBorder

        // Create SQL format outline view
        let sqlOutlineView = createOutlineView(for: .sql, coordinator: context.coordinator)

        // Create CSV/JSON format outline view
        let csvOutlineView = createOutlineView(for: .csv, coordinator: context.coordinator)

        // Store both in coordinator
        context.coordinator.sqlOutlineView = sqlOutlineView
        context.coordinator.csvOutlineView = csvOutlineView

        // Show the appropriate one based on initial format
        let activeView = (format == .sql) ? sqlOutlineView : csvOutlineView
        containerView.documentView = activeView
        context.coordinator.outlineView = activeView

        return containerView
    }

    private func createOutlineView(for format: ExportFormat, coordinator: OutlineViewCoordinator) -> NSOutlineView {
        let outlineView = NSOutlineView()
        outlineView.style = .automatic
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = false
        outlineView.allowsColumnReordering = false
        outlineView.allowsColumnResizing = false  // Disable manual resizing
        outlineView.autoresizesOutlineColumn = false  // Disable auto-resize
        outlineView.indentationPerLevel = 16  // Reduced from 20
        outlineView.rowHeight = 24
        outlineView.headerView = nil  // Hide column headers
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing  // Prevent auto-sizing

        outlineView.delegate = coordinator
        outlineView.dataSource = coordinator

        // Configure columns for this format (never changes)
        configureColumns(for: outlineView, format: format)

        return outlineView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let oldFormat = context.coordinator.format
        context.coordinator.format = format

        // Update wrappers to sync with latest data
        context.coordinator.updateWrappers()

        // If format changed, swap to the appropriate outline view
        if oldFormat != format {
            let newOutlineView = (format == .sql) ? context.coordinator.sqlOutlineView : context.coordinator.csvOutlineView

            if let newView = newOutlineView {
                scrollView.documentView = newView
                context.coordinator.outlineView = newView

                // Reload data in the new view synchronously; updateNSView is already on the main thread
                newView.reloadData()
                context.coordinator.restoreExpansionState(in: newView)
            }
        }

        // Note: No column reconfiguration needed - we just swap pre-configured views
    }

    func makeCoordinator() -> OutlineViewCoordinator {
        OutlineViewCoordinator(databaseItems: $databaseItems, format: format)
    }

    private func configureColumns(for outlineView: NSOutlineView, format: ExportFormat) {
        if format == .sql {
            // SQL format: Name + 3 option columns
            // Total: 165 + 142 = 307px (prioritizes readability, allows scrolling)
            let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            nameColumn.title = "Name"
            nameColumn.width = 165
            nameColumn.minWidth = 165
            nameColumn.maxWidth = 165
            outlineView.addTableColumn(nameColumn)
            outlineView.outlineTableColumn = nameColumn

            let structureColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("structure"))
            structureColumn.title = "Structure"
            structureColumn.width = 54
            structureColumn.minWidth = 54
            structureColumn.maxWidth = 54
            outlineView.addTableColumn(structureColumn)

            let dropColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("drop"))
            dropColumn.title = "Drop"
            dropColumn.width = 44
            dropColumn.minWidth = 44
            dropColumn.maxWidth = 44
            outlineView.addTableColumn(dropColumn)

            let dataColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("data"))
            dataColumn.title = "Data"
            dataColumn.width = 44
            dataColumn.minWidth = 44
            dataColumn.maxWidth = 44
            outlineView.addTableColumn(dataColumn)
        } else {
            // CSV/JSON format: Single name column, truncates long names
            let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            nameColumn.title = "Name"
            nameColumn.width = 200
            nameColumn.minWidth = 200
            nameColumn.maxWidth = 200
            outlineView.addTableColumn(nameColumn)
            outlineView.outlineTableColumn = nameColumn
        }
    }
}

// MARK: - Item Wrapper (for NSOutlineView identity)

/// Wrapper class to provide stable identity for struct-based items
private final class ItemWrapper: NSObject {
    let id: UUID
    var database: ExportDatabaseItem?
    var table: ExportTableItem?

    init(_ database: ExportDatabaseItem) {
        self.id = database.id
        self.database = database
        super.init()
    }

    init(_ table: ExportTableItem) {
        self.id = table.id
        self.table = table
        super.init()
    }
}

// MARK: - Coordinator

@MainActor
final class OutlineViewCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    @Binding var databaseItems: [ExportDatabaseItem]
    var format: ExportFormat

    // Store both outline views (strong references to prevent deallocation)
    var sqlOutlineView: NSOutlineView?
    var csvOutlineView: NSOutlineView?

    // Currently active outline view
    weak var outlineView: NSOutlineView?

    private var expandedDatabases: Set<UUID> = []
    private var isUpdating: Bool = false

    // Wrapper caches for stable item identity (NSOutlineView uses === comparison)
    private var databaseWrappers: [UUID: ItemWrapper] = [:]
    private var tableWrappers: [UUID: ItemWrapper] = [:]

    init(databaseItems: Binding<[ExportDatabaseItem]>, format: ExportFormat) {
        self._databaseItems = databaseItems
        self.format = format
        self.expandedDatabases = Set(
            databaseItems.wrappedValue
                .filter { $0.isExpanded }
                .map { $0.id }
        )
        super.init()
    }

    // MARK: - Wrapper Management

    func updateWrappers() {
        // Update database wrappers
        var newDatabaseWrappers: [UUID: ItemWrapper] = [:]
        for database in databaseItems {
            if let existing = databaseWrappers[database.id] {
                existing.database = database
                newDatabaseWrappers[database.id] = existing
            } else {
                newDatabaseWrappers[database.id] = ItemWrapper(database)
            }
        }
        databaseWrappers = newDatabaseWrappers

        // Update table wrappers
        var newTableWrappers: [UUID: ItemWrapper] = [:]
        for database in databaseItems {
            for table in database.tables {
                if let existing = tableWrappers[table.id] {
                    existing.table = table
                    newTableWrappers[table.id] = existing
                } else {
                    newTableWrappers[table.id] = ItemWrapper(table)
                }
            }
        }
        tableWrappers = newTableWrappers
    }

    // MARK: - Data Source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            // Root level: return number of databases
            return databaseItems.count
        } else if let wrapper = item as? ItemWrapper, let database = wrapper.database {
            // Database level: return number of tables
            return database.tables.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            // Root level: return database wrapper
            let database = databaseItems[index]
            guard let wrapper = databaseWrappers[database.id] else {
                assertionFailure("Missing database wrapper for id \(database.id)")
                let newWrapper = ItemWrapper(database)
                databaseWrappers[database.id] = newWrapper
                return newWrapper
            }
            return wrapper
        } else if let wrapper = item as? ItemWrapper, let database = wrapper.database {
            // Database level: return table wrapper
            let table = database.tables[index]
            guard let tableWrapper = tableWrappers[table.id] else {
                assertionFailure("Missing table wrapper for id \(table.id)")
                let newWrapper = ItemWrapper(table)
                tableWrappers[table.id] = newWrapper
                return newWrapper
            }
            return tableWrapper
        }
        assertionFailure("Unexpected item type in outlineView(_:child:ofItem:): \(String(describing: item))")
        return NSObject()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let wrapper = item as? ItemWrapper, let database = wrapper.database {
            return !database.tables.isEmpty
        }
        return false
    }

    // MARK: - Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let columnId = tableColumn?.identifier.rawValue else { return nil }
        guard let wrapper = item as? ItemWrapper else { return nil }

        // Determine format based on which outline view is asking
        // (coordinator.format changes when switching tabs, but each view has a fixed format)
        let currentFormat: ExportFormat
        if outlineView === sqlOutlineView {
            currentFormat = .sql
        } else {
            currentFormat = .csv
        }

        if let database = wrapper.database {
            // Database row
            if columnId == "name" {
                return configureDatabaseCell(for: outlineView, database: database)
            }
            // For SQL format, database rows span all columns (shown in name column only)
            return nil
        } else if let table = wrapper.table {
            // Table row
            if columnId == "name" {
                return configureTableCell(for: outlineView, table: table)
            } else if currentFormat == .sql {
                // SQL option columns (Structure, Drop, Data)
                return configureSQLOptionCell(for: outlineView, table: table, column: columnId)
            }
        }

        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Prevent selection - we handle clicks via checkboxes
        false
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let wrapper = notification.userInfo?["NSObject"] as? ItemWrapper {
            expandedDatabases.insert(wrapper.id)
            // Don't update binding here to avoid triggering updateNSView
            // Expansion state is tracked locally in expandedDatabases set
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let wrapper = notification.userInfo?["NSObject"] as? ItemWrapper {
            expandedDatabases.remove(wrapper.id)
            // Don't update binding here to avoid triggering updateNSView
            // Expansion state is tracked locally in expandedDatabases set
        }
    }

    // MARK: - Cell Configuration

    private func configureDatabaseCell(for outlineView: NSOutlineView, database: ExportDatabaseItem) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("DatabaseCell")
        var cellView = outlineView.makeView(withIdentifier: identifier, owner: self) as? DatabaseRowCellView

        if cellView == nil {
            cellView = DatabaseRowCellView(frame: .zero)
            cellView?.identifier = identifier
        }

        let databaseId = database.id
        cellView?.configure(database: database) { [weak self] checkbox in
            self?.databaseCheckboxChanged(databaseId: databaseId, state: checkbox.state)
        }

        return cellView
    }

    private func configureTableCell(for outlineView: NSOutlineView, table: ExportTableItem) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("TableCell")
        var cellView = outlineView.makeView(withIdentifier: identifier, owner: self) as? TableRowCellView

        if cellView == nil {
            cellView = TableRowCellView(frame: .zero)
            cellView?.identifier = identifier
        }

        let tableId = table.id
        cellView?.configure(table: table) { [weak self] checkbox in
            self?.tableSelectionChanged(tableId: tableId, isSelected: checkbox.state == .on)
        }

        return cellView
    }

    private func configureSQLOptionCell(for outlineView: NSOutlineView, table: ExportTableItem, column: String) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SQLOptionCell_\(column)")
        var cellView = outlineView.makeView(withIdentifier: identifier, owner: self) as? SQLOptionCellView

        if cellView == nil {
            cellView = SQLOptionCellView(frame: .zero)
            cellView?.identifier = identifier
        }

        let tableId = table.id
        let isEnabled = table.isSelected

        switch column {
        case "structure":
            cellView?.configure(isChecked: table.sqlOptions.includeStructure, isEnabled: isEnabled) { [weak self] checkbox in
                self?.tableSQLOptionChanged(tableId: tableId, option: \.includeStructure, value: checkbox.state == .on)
            }
        case "drop":
            cellView?.configure(isChecked: table.sqlOptions.includeDrop, isEnabled: isEnabled) { [weak self] checkbox in
                self?.tableSQLOptionChanged(tableId: tableId, option: \.includeDrop, value: checkbox.state == .on)
            }
        case "data":
            cellView?.configure(isChecked: table.sqlOptions.includeData, isEnabled: isEnabled) { [weak self] checkbox in
                self?.tableSQLOptionChanged(tableId: tableId, option: \.includeData, value: checkbox.state == .on)
            }
        default:
            NSLog("ExportTableOutlineView: Unknown SQL option column '%@' for table id %@", column, tableId.uuidString)
            return nil
        }

        return cellView
    }

    // MARK: - Checkbox Actions

    private func databaseCheckboxChanged(databaseId: UUID, state: NSControl.StateValue) {
        guard !isUpdating else { return }
        guard let dbIndex = databaseItems.firstIndex(where: { $0.id == databaseId }) else { return }

        isUpdating = true
        defer { isUpdating = false }

        // Determine target state based on checkbox state after user click.
        // Note: The checkbox state parameter is the NEW state after NSButton processed the click.
        // - .on: User clicked to select → select all tables
        // - .off: User clicked to deselect → deselect all tables
        // - .mixed: Should not occur from user interaction (mixed state is set programmatically)
        //   If it does occur, treat as "select all" per standard macOS checkbox behavior
        let shouldSelect: Bool
        switch state {
        case .on:
            shouldSelect = true
        case .off:
            shouldSelect = false
        case .mixed:
            // When user clicks a checkbox in mixed state, select all remaining tables
            // This matches standard macOS tristate checkbox behavior
            shouldSelect = true
        default:
            // Fallback for any other state values (shouldn't occur)
            assertionFailure("Unexpected checkbox state: \(state.rawValue)")
            shouldSelect = false
        }
        // Update all child tables
        for tableIndex in databaseItems[dbIndex].tables.indices {
            databaseItems[dbIndex].tables[tableIndex].isSelected = shouldSelect
        }

        // Update wrapper data and reload only this database item
        if let outlineView = outlineView, let databaseWrapper = databaseWrappers[databaseId] {
            updateWrappers()
            outlineView.reloadItem(databaseWrapper, reloadChildren: true)
        }
    }

    private func tableSelectionChanged(tableId: UUID, isSelected: Bool) {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        // Find table in binding and update
        for dbIndex in databaseItems.indices {
            if let tableIndex = databaseItems[dbIndex].tables.firstIndex(where: { $0.id == tableId }) {
                databaseItems[dbIndex].tables[tableIndex].isSelected = isSelected

                // Update wrappers and reload affected items
                if let outlineView = outlineView {
                    updateWrappers()

                    // Reload the table row
                    if let tableWrapper = tableWrappers[tableId] {
                        outlineView.reloadItem(tableWrapper, reloadChildren: false)
                    }

                    // Also reload the parent database (for tristate checkbox update)
                    let databaseId = databaseItems[dbIndex].id
                    if let databaseWrapper = databaseWrappers[databaseId] {
                        outlineView.reloadItem(databaseWrapper, reloadChildren: false)
                    }
                }
                break
            }
        }
    }

    private func tableSQLOptionChanged(tableId: UUID, option: WritableKeyPath<SQLTableExportOptions, Bool>, value: Bool) {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        // Find table in binding and update SQL option
        for dbIndex in databaseItems.indices {
            if let tableIndex = databaseItems[dbIndex].tables.firstIndex(where: { $0.id == tableId }) {
                databaseItems[dbIndex].tables[tableIndex].sqlOptions[keyPath: option] = value

                // Update wrapper and reload only this table row
                if let outlineView = outlineView, let tableWrapper = tableWrappers[tableId] {
                    updateWrappers()
                    outlineView.reloadItem(tableWrapper, reloadChildren: false)
                }
                break
            }
        }
    }

    // MARK: - Expansion State

    func restoreExpansionState(in outlineView: NSOutlineView) {
        // Use expandedDatabases set, not database.isExpanded binding
        // (we don't update the binding to avoid triggering updateNSView)
        // Expand using wrapper objects (same instances that NSOutlineView tracks)
        for databaseId in expandedDatabases {
            if let wrapper = databaseWrappers[databaseId] {
                outlineView.expandItem(wrapper)
            }
        }
    }
}

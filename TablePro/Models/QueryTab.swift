//
//  QueryTab.swift
//  TablePro
//
//  Model for query tabs
//

import Combine
import Foundation

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a table tab is closed, with tableName as object
    static let tableTabClosed = Notification.Name("tableTabClosed")
}

/// Type of tab
enum TabType: Equatable, Codable {
    case query       // SQL editor tab
    case table       // Direct table view tab
    case createTable // Table creation tab
}

/// Minimal representation of a tab for persistence
struct PersistedTab: Codable {
    let id: UUID
    let title: String
    let query: String
    let isPinned: Bool
    let tabType: TabType
    let tableName: String?
    var isView: Bool = false
    var databaseName: String = ""  // Database context for this tab (for multi-database restore)
}

/// Stores pending changes for a tab (used to preserve state when switching tabs)
struct TabPendingChanges: Equatable {
    var changes: [RowChange]
    var deletedRowIndices: Set<Int>
    var insertedRowIndices: Set<Int>
    var modifiedCells: [Int: Set<Int>]
    var insertedRowData: [Int: [String?]]  // Lazy storage for inserted row values
    var primaryKeyColumn: String?
    var columns: [String]

    init() {
        self.changes = []
        self.deletedRowIndices = []
        self.insertedRowIndices = []
        self.modifiedCells = [:]
        self.insertedRowData = [:]
        self.primaryKeyColumn = nil
        self.columns = []
    }

    var hasChanges: Bool {
        !changes.isEmpty || !insertedRowIndices.isEmpty || !deletedRowIndices.isEmpty
    }
}

/// Sort direction for column sorting
enum SortDirection: Equatable {
    case ascending
    case descending

    var indicator: String {
        switch self {
        case .ascending: return "▲"
        case .descending: return "▼"
        }
    }

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

/// A single column in a multi-column sort
struct SortColumn: Equatable {
    var columnIndex: Int
    var direction: SortDirection
}

/// Tracks sorting state for a table (supports multi-column sort)
struct SortState: Equatable {
    var columns: [SortColumn] = []

    init() {}

    var isSorting: Bool { !columns.isEmpty }

    // Backward-compatible computed properties for single-column access
    var columnIndex: Int? { columns.first?.columnIndex }
    var direction: SortDirection { columns.first?.direction ?? .ascending }
}

/// Tracks pagination state for navigating large datasets
struct PaginationState: Equatable {
    var totalRowCount: Int?         // Total rows in table (from COUNT(*))
    var pageSize: Int               // Rows per page (passed from manager/coordinator)
    var currentPage: Int = 1         // Current page number (1-based)
    var currentOffset: Int = 0       // Current OFFSET for SQL query
    var isLoading: Bool = false      // Loading indicator

    /// Default page size constant (used when no explicit value is provided)
    /// Note: For new tabs, callers should pass AppSettingsManager.shared.dataGrid.defaultPageSize
    static let defaultPageSize = 1_000

    init(
        totalRowCount: Int? = nil,
        pageSize: Int = PaginationState.defaultPageSize,
        currentPage: Int = 1,
        currentOffset: Int = 0,
        isLoading: Bool = false
    ) {
        self.totalRowCount = totalRowCount
        self.pageSize = pageSize
        self.currentPage = currentPage
        self.currentOffset = currentOffset
        self.isLoading = isLoading
    }

    // MARK: - Computed Properties

    /// Total number of pages
    var totalPages: Int {
        guard let total = totalRowCount, total > 0 else { return 1 }
        return (total + pageSize - 1) / pageSize  // Ceiling division
    }

    /// Whether there is a next page available
    var hasNextPage: Bool {
        currentPage < totalPages
    }

    /// Whether there is a previous page available
    var hasPreviousPage: Bool {
        currentPage > 1
    }

    /// Starting row number for current page (1-based)
    var rangeStart: Int {
        currentOffset + 1
    }

    /// Ending row number for current page (1-based)
    var rangeEnd: Int {
        guard let total = totalRowCount else {
            return currentOffset + pageSize
        }
        return min(currentOffset + pageSize, total)
    }

    // MARK: - Navigation Methods

    /// Navigate to next page
    mutating func goToNextPage() {
        guard hasNextPage else { return }
        currentPage += 1
        currentOffset = (currentPage - 1) * pageSize
    }

    /// Navigate to previous page
    mutating func goToPreviousPage() {
        guard hasPreviousPage else { return }
        currentPage -= 1
        currentOffset = (currentPage - 1) * pageSize
    }

    /// Navigate to first page
    mutating func goToFirstPage() {
        currentPage = 1
        currentOffset = 0
    }

    /// Navigate to last page
    mutating func goToLastPage() {
        currentPage = totalPages
        currentOffset = (totalPages - 1) * pageSize
    }

    /// Navigate to specific page
    mutating func goToPage(_ page: Int) {
        guard page > 0 && page <= totalPages else { return }
        currentPage = page
        currentOffset = (page - 1) * pageSize
    }

    /// Reset pagination to first page
    mutating func reset() {
        currentPage = 1
        currentOffset = 0
        isLoading = false
    }

    /// Update page size (limit)
    mutating func updatePageSize(_ newSize: Int) {
        guard newSize > 0 else { return }
        pageSize = newSize
        // Recalculate current page based on current offset
        currentPage = (currentOffset / pageSize) + 1
    }

    /// Update offset directly and recalculate page
    mutating func updateOffset(_ newOffset: Int) {
        guard newOffset >= 0 else { return }
        currentOffset = newOffset
        currentPage = (currentOffset / pageSize) + 1
    }
}

/// Stores column layout (widths and order) within a tab session
struct ColumnLayoutState: Equatable {
    var columnWidths: [String: CGFloat] = [:]
    var columnOrder: [String]?
}

/// Reference-type wrapper for large result data.
/// When QueryTab (a struct) is copied via CoW, only this 8-byte reference is copied
/// instead of duplicating potentially large result arrays.
final class RowBuffer {
    var rows: [QueryResultRow]
    var columns: [String]
    var columnTypes: [ColumnType]
    var columnDefaults: [String: String?]
    var columnForeignKeys: [String: ForeignKeyInfo]
    var columnEnumValues: [String: [String]]
    var columnNullable: [String: Bool]

    init(
        rows: [QueryResultRow] = [],
        columns: [String] = [],
        columnTypes: [ColumnType] = [],
        columnDefaults: [String: String?] = [:],
        columnForeignKeys: [String: ForeignKeyInfo] = [:],
        columnEnumValues: [String: [String]] = [:],
        columnNullable: [String: Bool] = [:]
    ) {
        self.rows = rows
        self.columns = columns
        self.columnTypes = columnTypes
        self.columnDefaults = columnDefaults
        self.columnForeignKeys = columnForeignKeys
        self.columnEnumValues = columnEnumValues
        self.columnNullable = columnNullable
    }

    /// Create a deep copy of this buffer (used when explicit data duplication is needed)
    func copy() -> RowBuffer {
        RowBuffer(
            rows: rows,
            columns: columns,
            columnTypes: columnTypes,
            columnDefaults: columnDefaults,
            columnForeignKeys: columnForeignKeys,
            columnEnumValues: columnEnumValues,
            columnNullable: columnNullable
        )
    }
}

/// Represents a single tab (query or table)
struct QueryTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var query: String
    var isPinned: Bool
    var lastExecutedAt: Date?
    var tabType: TabType

    // Results — stored in a reference-type buffer to avoid CoW duplication
    // of large data when the struct is mutated (MEM-1 fix)
    var rowBuffer: RowBuffer

    // Backward-compatible computed accessors for result data
    var resultColumns: [String] {
        get { rowBuffer.columns }
        set { rowBuffer.columns = newValue }
    }

    var columnTypes: [ColumnType] {
        get { rowBuffer.columnTypes }
        set { rowBuffer.columnTypes = newValue }
    }

    var columnDefaults: [String: String?] {
        get { rowBuffer.columnDefaults }
        set { rowBuffer.columnDefaults = newValue }
    }

    var columnForeignKeys: [String: ForeignKeyInfo] {
        get { rowBuffer.columnForeignKeys }
        set { rowBuffer.columnForeignKeys = newValue }
    }

    var columnEnumValues: [String: [String]] {
        get { rowBuffer.columnEnumValues }
        set { rowBuffer.columnEnumValues = newValue }
    }

    var columnNullable: [String: Bool] {
        get { rowBuffer.columnNullable }
        set { rowBuffer.columnNullable = newValue }
    }

    var resultRows: [QueryResultRow] {
        get { rowBuffer.rows }
        set { rowBuffer.rows = newValue }
    }

    var executionTime: TimeInterval?
    var rowsAffected: Int  // Number of rows affected by non-SELECT queries
    var errorMessage: String?
    var isExecuting: Bool

    // Editing support
    var tableName: String?
    var primaryKeyColumn: String?  // Detected PK from schema (set by Phase 2 metadata)
    var isEditable: Bool
    var isView: Bool  // True for database views (read-only)
    var databaseName: String  // Database this tab was opened in (for multi-database restore)
    var showStructure: Bool  // Toggle to show structure view instead of data

    // Per-tab change tracking (preserves changes when switching tabs)
    var pendingChanges: TabPendingChanges

    // Per-tab row selection (preserves selection when switching tabs)
    var selectedRowIndices: Set<Int>

    // Per-tab sort state (column sorting)
    var sortState: SortState

    // Track if user has interacted with this tab (sort, edit, select, etc)
    // Prevents tab from being replaced when opening new tables
    var hasUserInteraction: Bool

    // Pagination state for lazy loading (table tabs only)
    var pagination: PaginationState

    // Per-tab filter state (preserves filters when switching tabs)
    var filterState: TabFilterState

    // Per-tab column layout (widths/order persist across reloads within tab session)
    var columnLayout: ColumnLayoutState

    // Version counter incremented when resultRows changes (used for sort caching)
    var resultVersion: Int

    // Table creation options (for .createTable tabs only)
    var tableCreationOptions: TableCreationOptions?

    init(
        id: UUID = UUID(),
        title: String = "Query",
        query: String = "",
        isPinned: Bool = false,
        tabType: TabType = .query,
        tableName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.query = query
        self.isPinned = isPinned
        self.tabType = tabType
        self.lastExecutedAt = nil
        self.rowBuffer = RowBuffer()
        self.executionTime = nil
        self.rowsAffected = 0
        self.errorMessage = nil
        self.isExecuting = false
        self.tableName = tableName
        self.primaryKeyColumn = nil
        self.isEditable = tabType == .table  // Table tabs are editable by default
        self.isView = false
        self.databaseName = ""
        self.showStructure = false
        self.pendingChanges = TabPendingChanges()
        self.selectedRowIndices = []
        self.sortState = SortState()
        self.hasUserInteraction = false
        self.pagination = PaginationState()
        self.filterState = TabFilterState()
        self.columnLayout = ColumnLayoutState()
        self.resultVersion = 0
        self.tableCreationOptions = nil
    }

    /// Initialize from persisted tab state (used when restoring tabs)
    init(from persisted: PersistedTab) {
        self.id = persisted.id
        self.title = persisted.title
        self.query = persisted.query
        self.isPinned = persisted.isPinned
        self.tabType = persisted.tabType
        self.tableName = persisted.tableName
        self.primaryKeyColumn = nil

        // Initialize runtime state with defaults
        self.lastExecutedAt = nil
        self.rowBuffer = RowBuffer()
        self.executionTime = nil
        self.rowsAffected = 0
        self.errorMessage = nil
        self.isExecuting = false
        self.isEditable = persisted.tabType == .table && !persisted.isView
        self.isView = persisted.isView
        self.databaseName = persisted.databaseName
        self.showStructure = false
        self.pendingChanges = TabPendingChanges()
        self.selectedRowIndices = []
        self.sortState = SortState()
        self.hasUserInteraction = false
        self.pagination = PaginationState()
        self.filterState = TabFilterState()
        self.columnLayout = ColumnLayoutState()
        self.resultVersion = 0
        self.tableCreationOptions = nil
    }

    /// Maximum query size to persist (500KB). Queries larger than this are typically
    /// imported SQL dumps — serializing them to JSON blocks the main thread.
    private static let maxPersistableQuerySize = 500_000

    /// Convert tab to persisted format for storage
    func toPersistedTab() -> PersistedTab {
        // Truncate very large queries to prevent JSON encoding from blocking main thread
        let persistedQuery: String
        if (query as NSString).length > Self.maxPersistableQuerySize {
            persistedQuery = ""
        } else {
            persistedQuery = query
        }

        return PersistedTab(
            id: id,
            title: title,
            query: persistedQuery,
            isPinned: isPinned,
            tabType: tabType,
            tableName: tableName,
            isView: isView,
            databaseName: databaseName
        )
    }

    static func == (lhs: QueryTab, rhs: QueryTab) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.isPinned == rhs.isPinned
            && lhs.isExecuting == rhs.isExecuting
            && lhs.errorMessage == rhs.errorMessage
            && lhs.executionTime == rhs.executionTime
            && lhs.resultVersion == rhs.resultVersion
            && lhs.metadataVersion == rhs.metadataVersion
            && lhs.pagination == rhs.pagination
            && lhs.sortState == rhs.sortState
            && lhs.showStructure == rhs.showStructure
            && lhs.isEditable == rhs.isEditable
            && lhs.isView == rhs.isView
            && lhs.tabType == rhs.tabType
            && lhs.rowsAffected == rhs.rowsAffected
    }
}

/// Manager for query tabs
@MainActor
final class QueryTabManager: ObservableObject {
    @Published var tabs: [QueryTab] = []
    @Published var selectedTabId: UUID?

    var selectedTab: QueryTab? {
        guard let id = selectedTabId else { return tabs.first }
        return tabs.first { $0.id == id }
    }

    var selectedTabIndex: Int? {
        guard let id = selectedTabId else { return nil }
        return tabs.firstIndex { $0.id == id }
    }

    init() {
        // Start with no tabs - shows empty state
        tabs = []
        selectedTabId = nil
    }

    // MARK: - Tab Management

    func addTab(initialQuery: String? = nil, title: String? = nil, databaseName: String = "") {
        let queryCount = tabs.count(where: { $0.tabType == .query })
        let tabTitle = title ?? "Query \(queryCount + 1)"
        var newTab = QueryTab(title: tabTitle, tabType: .query)

        // If initialQuery provided, use it; otherwise tab starts empty
        if let query = initialQuery {
            newTab.query = query
            newTab.hasUserInteraction = true  // Mark as having content
        }

        newTab.databaseName = databaseName
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addTableTab(tableName: String, databaseType: DatabaseType = .mysql, databaseName: String = "") {
        // Check if table tab already exists (match on databaseName)
        if let existingTab = tabs.first(where: {
            $0.tabType == .table && $0.tableName == tableName && $0.databaseName == databaseName
        }) {
            selectedTabId = existingTab.id
            return
        }

        let quotedName = databaseType.quoteIdentifier(tableName)
        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        var newTab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(quotedName) LIMIT \(pageSize);",
            tabType: .table,
            tableName: tableName
        )
        newTab.pagination = PaginationState(pageSize: pageSize)
        newTab.databaseName = databaseName
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    /// Add a new "Create Table" tab
    /// - Parameters:
    ///   - databaseName: The database/schema name to create the table in
    ///   - databaseType: The type of database (MySQL, PostgreSQL, SQLite)
    func addCreateTableTab(databaseName: String, databaseType: DatabaseType) {
        let createTableCount = tabs.count(where: { $0.tabType == .createTable })

        // Initialize with one default column (id INT AUTO_INCREMENT PRIMARY KEY)
        var options = TableCreationOptions()
        options.databaseName = databaseName
        options.tableName = "new_table"

        // Add default ID column
        let idColumn = ColumnDefinition(
            name: "id",
            dataType: "INT",
            notNull: true,
            autoIncrement: true
        )
        options.columns = [idColumn]
        options.primaryKeyColumns = ["id"]

        var newTab = QueryTab(
            title: "New Table \(createTableCount + 1)",
            tabType: .createTable
        )
        newTab.tableCreationOptions = options
        newTab.hasUserInteraction = false  // Not yet interacted with

        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    /// Smart table tab opening (TablePlus-style behavior)
    /// - If clicking the same table: just switch to it
    /// - If current tab is a clean table tab (no changes): replace it
    /// - If current tab has pending changes or is a query tab: create new tab
    /// - Returns: true if query needs to be executed (new/replaced tab), false if just switching
    @discardableResult
    func TableProTabSmart(
        tableName: String, hasUnsavedChanges: Bool, databaseType: DatabaseType = .mysql,
        isView: Bool = false, databaseName: String = ""
    ) -> Bool {
        // 1. If a tab for this table already exists, just switch to it
        if let existingTab = tabs.first(where: {
            $0.tabType == .table && $0.tableName == tableName && $0.databaseName == databaseName
        }) {
            if selectedTabId != existingTab.id {
                selectedTabId = existingTab.id
            }
            return false  // No need to run query, data already loaded
        }

        let quotedName = databaseType.quoteIdentifier(tableName)
        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize

        // 2. Try to reuse the current tab if it's a clean table tab (opt-in via Settings > Tabs)
        if AppSettingsManager.shared.tabs.reuseCleanTableTab,
           let selectedId = selectedTabId,
           let selectedIndex = tabs.firstIndex(where: { $0.id == selectedId }),
           tabs[selectedIndex].tabType == .table,
           !tabs[selectedIndex].isPinned,
           !hasUnsavedChanges,
           !tabs[selectedIndex].hasUserInteraction
        {
            // Replace the current table tab instead of creating a new one.
            // Assign a fresh RowBuffer to avoid aliasing the old buffer (MEM-1 safety).
            tabs[selectedIndex].rowBuffer = RowBuffer()
            tabs[selectedIndex].title = tableName
            tabs[selectedIndex].tableName = tableName
            tabs[selectedIndex].query = "SELECT * FROM \(quotedName) LIMIT \(pageSize);"
            tabs[selectedIndex].resultVersion += 1
            tabs[selectedIndex].executionTime = nil
            tabs[selectedIndex].errorMessage = nil
            tabs[selectedIndex].lastExecutedAt = nil
            tabs[selectedIndex].showStructure = false
            tabs[selectedIndex].sortState = SortState()
            tabs[selectedIndex].selectedRowIndices = []
            tabs[selectedIndex].pendingChanges = TabPendingChanges()
            tabs[selectedIndex].hasUserInteraction = false
            tabs[selectedIndex].isView = isView
            tabs[selectedIndex].isEditable = !isView
            tabs[selectedIndex].filterState = TabFilterState()
            tabs[selectedIndex].columnLayout = ColumnLayoutState()
            tabs[selectedIndex].pagination = PaginationState(pageSize: pageSize)
            tabs[selectedIndex].databaseName = databaseName
            return true  // Need to run query for new table
        }

        // 3. Otherwise, create a new tab
        var newTab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(quotedName) LIMIT \(pageSize);",
            tabType: .table,
            tableName: tableName
        )
        newTab.isView = isView
        newTab.isEditable = !isView
        newTab.pagination = PaginationState(pageSize: pageSize)
        newTab.databaseName = databaseName
        tabs.append(newTab)
        selectedTabId = newTab.id
        return true  // Need to run query for new tab
    }

    func closeTab(_ tab: QueryTab) {
        // Pinned tabs cannot be closed
        guard !tab.isPinned else { return }

        // Capture table info BEFORE removing
        let isTableTab = tab.tabType == .table
        let tableName = tab.tableName

        if let index = tabs.firstIndex(of: tab) {
            tabs.remove(at: index)

            // Select another tab if we closed the selected one
            if selectedTabId == tab.id {
                if tabs.isEmpty {
                    // No tabs left - clear selection (shows empty state)
                    selectedTabId = nil
                } else {
                    // Select nearest remaining tab
                    selectedTabId = tabs[max(0, index - 1)].id
                }
            }
        }

        // Notify when table tab is closed so sidebar selection can be cleared
        if isTableTab, let name = tableName {
            NotificationCenter.default.post(name: .tableTabClosed, object: name)
        }
    }

    func selectTab(_ tab: QueryTab) {
        selectedTabId = tab.id
    }

    func updateTab(_ tab: QueryTab) {
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index] = tab
        }
    }

    func togglePin(_ tab: QueryTab) {
        if let index = tabs.firstIndex(of: tab) {
            tabs[index].isPinned.toggle()
        }
    }

    func duplicateTab(_ tab: QueryTab) {
        // MEM-2 fix: Don't deep-copy result data — the duplicate tab starts with
        // an empty RowBuffer. The user can re-execute the query if data is needed.
        var newTab = QueryTab(
            title: "\(tab.title) (copy)",
            query: tab.query
        )
        newTab.tabType = tab.tabType
        newTab.tableName = tab.tableName
        newTab.databaseName = tab.databaseName

        if let index = tabs.firstIndex(of: tab) {
            tabs.insert(newTab, at: index + 1)
        } else {
            tabs.append(newTab)
        }
        selectedTabId = newTab.id
    }
}

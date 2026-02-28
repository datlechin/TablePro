//
//  TableTabContentView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 24/12/25.
//

import SwiftUI

/// Content view for table tabs (results only, no editor)
struct TableTabContentView: View {
    let tab: QueryTab
    let connection: DatabaseConnection
    let changeManager: DataChangeManager
    let filterStateManager: FilterStateManager
    let toolbarState: ConnectionToolbarState
    @Binding var selectedRowIndices: Set<Int>
    @Binding var editingCell: CellPosition?

    // Callbacks
    let onCommit: (String) -> Void
    let onRefresh: () -> Void
    let onCellEdit: (Int, Int, String?) -> Void
    let onSort: (Int, Bool, Bool) -> Void
    let onAddRow: () -> Void
    let onUndoInsert: (Int) -> Void
    let onFilterColumn: (String) -> Void
    let onApplyFilters: ([TableFilter]) -> Void
    let onClearFilters: () -> Void
    let onQuickSearch: (String) -> Void
    let sortedRows: [QueryResultRow]

    // Pagination callbacks
    let onFirstPage: () -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLastPage: () -> Void
    let onLimitChange: (Int) -> Void
    let onOffsetChange: (Int) -> Void
    let onPaginationGo: () -> Void
    let onDismissError: () -> Void

    @Binding var sortState: SortState
    @Binding var showStructure: Bool
    @Binding var columnLayout: ColumnLayoutState

    // Cached row provider — avoids recreation on every SwiftUI render.
    // Recreated only when tab.resultVersion changes (data refresh, sort, filter, pagination).
    @State private var rowProvider: InMemoryRowProvider?
    @State private var lastResultVersion: Int = -1
    @State private var cachedChangeManager: AnyChangeManager?

    /// Creates a new InMemoryRowProvider from the current tab and row data.
    private func makeRowProvider() -> InMemoryRowProvider {
        InMemoryRowProvider(
            rows: sortedRows,
            columns: tab.resultColumns,
            columnDefaults: tab.columnDefaults,
            columnTypes: tab.columnTypes,
            columnEnumValues: tab.columnEnumValues,
            columnNullable: tab.columnNullable
        )
    }

    /// Returns the cached AnyChangeManager, creating it on first access.
    private var currentChangeManager: AnyChangeManager {
        if let existing = cachedChangeManager {
            return existing
        }
        return AnyChangeManager(dataManager: changeManager)
    }

    /// Returns the current row provider, creating it on first access.
    private var currentRowProvider: InMemoryRowProvider {
        if let existing = rowProvider, lastResultVersion == tab.resultVersion {
            return existing
        }
        // First render or version mismatch — create inline and schedule state update
        return makeRowProvider()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Show structure view or data view based on toggle
            if showStructure, let tableName = tab.tableName {
                TableStructureView(tableName: tableName, connection: connection, toolbarState: toolbarState)
                    .id(tableName)
                    .frame(maxHeight: .infinity)
            } else {
                // Filter panel (collapsible, above data grid)
                if filterStateManager.isVisible && tab.tabType == .table {
                    FilterPanelView(
                        filterState: filterStateManager,
                        columns: tab.resultColumns,
                        primaryKeyColumn: changeManager.primaryKeyColumn,
                        databaseType: connection.type,
                        onApply: onApplyFilters,
                        onUnset: onClearFilters,
                        onQuickSearch: onQuickSearch
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    Divider()
                }

                DataGridView(
                    rowProvider: currentRowProvider,
                    changeManager: currentChangeManager,
                    resultVersion: tab.resultVersion,
                    isEditable: tab.isEditable && !tab.isView,
                    onCommit: onCommit,
                    onRefresh: onRefresh,
                    onCellEdit: onCellEdit,
                    onSort: onSort,
                    onAddRow: onAddRow,
                    onUndoInsert: onUndoInsert,
                    onFilterColumn: onFilterColumn,
                    databaseType: connection.type,
                    selectedRowIndices: $selectedRowIndices,
                    sortState: $sortState,
                    editingCell: $editingCell,
                    columnLayout: $columnLayout
                )
                .frame(maxHeight: .infinity, alignment: .top)
            }

            // Status bar
            MainStatusBarView(
                tab: tab,
                filterStateManager: filterStateManager,
                selectedRowIndices: selectedRowIndices,
                showStructure: $showStructure,
                onFirstPage: onFirstPage,
                onPreviousPage: onPreviousPage,
                onNextPage: onNextPage,
                onLastPage: onLastPage,
                onLimitChange: onLimitChange,
                onOffsetChange: onOffsetChange,
                onPaginationGo: onPaginationGo
            )
        }
        .animation(.easeInOut(duration: 0.2), value: tab.errorMessage)
        .onAppear {
            let provider = makeRowProvider()
            rowProvider = provider
            lastResultVersion = tab.resultVersion
            cachedChangeManager = AnyChangeManager(dataManager: changeManager)
        }
        .onChange(of: tab.resultVersion) { _, newVersion in
            let provider = makeRowProvider()
            rowProvider = provider
            lastResultVersion = newVersion
        }
    }
}

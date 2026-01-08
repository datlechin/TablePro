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
    @Binding var selectedRowIndices: Set<Int>
    @Binding var editingCell: CellPosition?

    // Callbacks
    let onCommit: (String) -> Void
    let onRefresh: () -> Void
    let onCellEdit: (Int, Int, String?) -> Void
    let onSort: (Int, Bool) -> Void
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

    var body: some View {
        VStack(spacing: 0) {
            // Error banner (if query failed)
            if let errorMessage = tab.errorMessage, !errorMessage.isEmpty {
                InlineErrorBanner(message: errorMessage, onDismiss: onDismissError)
            }

            // Show structure view or data view based on toggle
            if showStructure, let tableName = tab.tableName {
                TableStructureView(tableName: tableName, connection: connection)
                    .frame(maxHeight: .infinity)
            } else {
                DataGridView(
                    rowProvider: InMemoryRowProvider(
                        rows: sortedRows,
                        columns: tab.resultColumns,
                        columnDefaults: tab.columnDefaults
                    ),
                    changeManager: changeManager,
                    isEditable: tab.isEditable,
                    onCommit: onCommit,
                    onRefresh: onRefresh,
                    onCellEdit: onCellEdit,
                    onSort: onSort,
                    onAddRow: onAddRow,
                    onUndoInsert: onUndoInsert,
                    onFilterColumn: onFilterColumn,
                    selectedRowIndices: $selectedRowIndices,
                    sortState: $sortState,
                    editingCell: $editingCell
                )
                .frame(maxHeight: .infinity, alignment: .top)
            }

            // Filter panel (collapsible, at bottom)
            if filterStateManager.isVisible && tab.tabType == .table {
                Divider()
                FilterPanelView(
                    filterState: filterStateManager,
                    columns: tab.resultColumns,
                    primaryKeyColumn: changeManager.primaryKeyColumn,
                    databaseType: connection.type,
                    onApply: onApplyFilters,
                    onUnset: onClearFilters,
                    onQuickSearch: onQuickSearch
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
    }
}

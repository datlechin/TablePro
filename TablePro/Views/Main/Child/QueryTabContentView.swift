//
//  QueryTabContentView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 24/12/25.
//

import SwiftUI

/// Content view for query tabs (editor + results split)
struct QueryTabContentView: View {
    let tab: QueryTab
    let connection: DatabaseConnection
    let changeManager: DataChangeManager
    let filterStateManager: FilterStateManager
    @Binding var queryText: String
    @Binding var cursorPosition: Int
    @Binding var selectedRowIndices: Set<Int>
    @Binding var editingCell: CellPosition?

    let schemaProvider: SQLSchemaProvider
    let onExecute: () -> Void

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
        VSplitView {
            // Query Editor (top)
            VStack(spacing: 0) {
                QueryEditorView(
                    queryText: $queryText,
                    cursorPosition: $cursorPosition,
                    onExecute: onExecute,
                    schemaProvider: schemaProvider
                )
            }
            .frame(minHeight: 100, idealHeight: 200)

            // Results Table (bottom)
            TableTabContentView(
                tab: tab,
                connection: connection,
                changeManager: changeManager,
                filterStateManager: filterStateManager,
                selectedRowIndices: $selectedRowIndices,
                editingCell: $editingCell,
                onCommit: onCommit,
                onRefresh: onRefresh,
                onCellEdit: onCellEdit,
                onSort: onSort,
                onAddRow: onAddRow,
                onUndoInsert: onUndoInsert,
                onFilterColumn: onFilterColumn,
                onApplyFilters: onApplyFilters,
                onClearFilters: onClearFilters,
                onQuickSearch: onQuickSearch,
                sortedRows: sortedRows,
                onFirstPage: onFirstPage,
                onPreviousPage: onPreviousPage,
                onNextPage: onNextPage,
                onLastPage: onLastPage,
                onLimitChange: onLimitChange,
                onOffsetChange: onOffsetChange,
                onPaginationGo: onPaginationGo,
                onDismissError: onDismissError,
                sortState: $sortState,
                showStructure: $showStructure
            )
            .frame(minHeight: 150)
        }
    }
}

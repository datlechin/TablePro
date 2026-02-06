//
//  MainEditorContentView.swift
//  OpenTable
//
//  Main editor content view containing tab bar and tab content.
//  Extracted from MainContentView for better separation.
//

import SwiftUI

/// Cache for sorted query result rows to avoid re-sorting on every SwiftUI body evaluation
private struct SortedRowsCache {
    let rows: [QueryResultRow]
    let columnIndex: Int
    let direction: SortDirection
    let resultVersion: Int
}

/// Main editor content with tab bar and content switching
struct MainEditorContentView: View {
    // MARK: - Dependencies

    @ObservedObject var tabManager: QueryTabManager
    @ObservedObject var coordinator: MainContentCoordinator
    @ObservedObject var changeManager: DataChangeManager
    @ObservedObject var filterStateManager: FilterStateManager
    let connection: DatabaseConnection

    // MARK: - Bindings

    @Binding var selectedRowIndices: Set<Int>
    @Binding var editingCell: CellPosition?

    // MARK: - Callbacks

    let onCellEdit: (Int, Int, String?) -> Void
    let onSort: (Int, Bool) -> Void
    let onAddRow: () -> Void
    let onUndoInsert: (Int) -> Void
    let onFilterColumn: (String) -> Void
    let onApplyFilters: ([TableFilter]) -> Void
    let onClearFilters: () -> Void
    let onQuickSearch: (String) -> Void
    let onCommit: (String) -> Void
    let onRefresh: () -> Void

    // Pagination callbacks
    let onFirstPage: () -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLastPage: () -> Void
    let onLimitChange: (Int) -> Void
    let onOffsetChange: (Int) -> Void
    let onPaginationGo: () -> Void

    // MARK: - Sort Cache

    @State private var sortCache: [UUID: SortedRowsCache] = [:]

    // MARK: - Environment

    @EnvironmentObject private var appState: AppState

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar - only show when there are tabs
            if !tabManager.tabs.isEmpty {
                NativeTabBar(tabManager: tabManager)
                Divider()
            }

            // Content for selected tab
            if let tab = tabManager.selectedTab {
                tabContent(for: tab)
            } else {
                emptyStateView
            }

            // Global History Panel
            if appState.isHistoryPanelVisible {
                Divider()
                HistoryPanelView()
                    .frame(height: 300)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.isHistoryPanelVisible)
        .onChange(of: tabManager.tabs.count) { _ in
            // Clean up sort cache for closed tabs
            let openTabIds = Set(tabManager.tabs.map(\.id))
            sortCache = sortCache.filter { openTabIds.contains($0.key) }
            coordinator.cleanupSortCache(openTabIds: openTabIds)
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func tabContent(for tab: QueryTab) -> some View {
        switch tab.tabType {
        case .query:
            queryTabContent(tab: tab)
        case .table:
            tableTabContent(tab: tab)
        case .createTable:
            createTableTabContent(tab: tab)
        }
    }

    // MARK: - Query Tab Content

    @ViewBuilder
    private func queryTabContent(tab: QueryTab) -> some View {
        VSplitView {
            // Query Editor (top)
            VStack(spacing: 0) {
                QueryEditorView(
                    queryText: queryTextBinding(for: tab),
                    cursorPosition: $coordinator.cursorPosition,
                    onExecute: { coordinator.runQuery() },
                    schemaProvider: coordinator.schemaProvider
                )
            }
            .frame(minHeight: 100, idealHeight: 200)

            // Results (bottom)
            resultsSection(tab: tab)
                .frame(minHeight: 150)
        }
    }

    private func queryTextBinding(for tab: QueryTab) -> Binding<String> {
        Binding(
            get: { tab.query },
            set: { newValue in
                guard let index = tabManager.selectedTabIndex,
                      index < tabManager.tabs.count else { return }

                tabManager.tabs[index].query = newValue
                coordinator.tabPersistence.saveLastQuery(newValue)

                if !coordinator.tabPersistence.isRestoringTabs && !coordinator.tabPersistence.isDismissing {
                    coordinator.tabPersistence.saveTabsDebounced(
                        tabs: tabManager.tabs,
                        selectedTabId: tabManager.selectedTabId
                    )
                }
            }
        )
    }

    // MARK: - Table Tab Content

    @ViewBuilder
    private func tableTabContent(tab: QueryTab) -> some View {
        resultsSection(tab: tab)
    }

    // MARK: - Create Table Tab Content

    @ViewBuilder
    private func createTableTabContent(tab: QueryTab) -> some View {
        if tab.tableCreationOptions != nil {
            CreateTableView(
                options: createTableOptionsBinding(for: tab),
                databaseType: connection.type,
                onCancel: {
                    // Close this tab
                    tabManager.closeTab(tab)
                },
                onCreate: { options in
                    coordinator.createTable(options)
                }
            )
        } else {
            // Fallback if options are missing
            Text("Table creation options not available")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func createTableOptionsBinding(for tab: QueryTab) -> Binding<TableCreationOptions> {
        Binding(
            get: { tab.tableCreationOptions ?? TableCreationOptions() },
            set: { newValue in
                guard let index = tabManager.selectedTabIndex,
                      index < tabManager.tabs.count else { return }

                tabManager.tabs[index].tableCreationOptions = newValue
            }
        )
    }

    // MARK: - Results Section

    @ViewBuilder
    private func resultsSection(tab: QueryTab) -> some View {
        VStack(spacing: 0) {
            if tab.showStructure, let tableName = tab.tableName {
                TableStructureView(tableName: tableName, connection: connection)
                    .frame(maxHeight: .infinity)
            } else if tab.resultColumns.isEmpty && tab.errorMessage == nil && tab.lastExecutedAt != nil && !tab.isExecuting {
                QuerySuccessView(
                    rowsAffected: tab.rowsAffected,
                    executionTime: tab.executionTime
                )
            } else {
                dataGridView(tab: tab)
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

            statusBar(tab: tab)
        }
        .frame(minHeight: 150)
        .animation(.easeInOut(duration: 0.2), value: filterStateManager.isVisible)
        .animation(.easeInOut(duration: 0.2), value: tab.errorMessage)
    }

    @ViewBuilder
    private func dataGridView(tab: QueryTab) -> some View {
        DataGridView(
            rowProvider: InMemoryRowProvider(
                rows: sortedRows(for: tab),
                columns: tab.resultColumns,
                columnDefaults: tab.columnDefaults,
                columnTypes: tab.columnTypes
            ),
            changeManager: AnyChangeManager(dataManager: changeManager),
            isEditable: tab.isEditable,
            onCommit: onCommit,
            onRefresh: onRefresh,
            onCellEdit: onCellEdit,
            onSort: onSort,
            onAddRow: onAddRow,
            onUndoInsert: onUndoInsert,
            onFilterColumn: onFilterColumn,
            selectedRowIndices: $selectedRowIndices,
            sortState: sortStateBinding(for: tab),
            editingCell: $editingCell
        )
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sortedRows(for tab: QueryTab) -> [QueryResultRow] {
        // Table tabs: Don't apply client-side sorting (handled via SQL ORDER BY)
        if tab.tabType == .table {
            return tab.resultRows
        }

        // Query tabs: Apply client-side sorting
        guard let columnIndex = tab.sortState.columnIndex,
              columnIndex < tab.resultColumns.count else {
            return tab.resultRows
        }

        // Check coordinator's async sort cache (for large datasets sorted on background thread)
        if let cached = coordinator.querySortCache[tab.id],
           cached.columnIndex == columnIndex,
           cached.direction == tab.sortState.direction,
           cached.resultVersion == tab.resultVersion {
            return cached.rows
        }

        // For large datasets sorted async, return unsorted until cache is ready
        if tab.resultRows.count > 10_000 {
            return tab.resultRows
        }

        // Small dataset: sort synchronously with view-level cache
        if let cached = sortCache[tab.id],
           cached.columnIndex == columnIndex,
           cached.direction == tab.sortState.direction,
           cached.resultVersion == tab.resultVersion {
            return cached.rows
        }

        let sorted = tab.resultRows.sorted { row1, row2 in
            let val1 = row1.values[columnIndex] ?? ""
            let val2 = row2.values[columnIndex] ?? ""

            if tab.sortState.direction == .ascending {
                return val1.localizedStandardCompare(val2) == .orderedAscending
            } else {
                return val1.localizedStandardCompare(val2) == .orderedDescending
            }
        }

        // Cache the result
        sortCache[tab.id] = SortedRowsCache(
            rows: sorted,
            columnIndex: columnIndex,
            direction: tab.sortState.direction,
            resultVersion: tab.resultVersion
        )

        return sorted
    }

    private func sortStateBinding(for tab: QueryTab) -> Binding<SortState> {
        Binding(
            get: { tab.sortState },
            set: { newValue in
                if let index = tabManager.selectedTabIndex {
                    tabManager.tabs[index].sortState = newValue
                }
            }
        )
    }

    // MARK: - Status Bar

    private func statusBar(tab: QueryTab) -> some View {
        MainStatusBarView(
            tab: tab,
            filterStateManager: filterStateManager,
            selectedRowIndices: selectedRowIndices,
            showStructure: showStructureBinding(for: tab),
            onFirstPage: onFirstPage,
            onPreviousPage: onPreviousPage,
            onNextPage: onNextPage,
            onLastPage: onLastPage,
            onLimitChange: onLimitChange,
            onOffsetChange: onOffsetChange,
            onPaginationGo: onPaginationGo
        )
    }

    private func showStructureBinding(for tab: QueryTab) -> Binding<Bool> {
        Binding(
            get: { tab.showStructure },
            set: { newValue in
                Task { @MainActor in
                    if let index = tabManager.selectedTabIndex {
                        tabManager.tabs[index].showStructure = newValue
                    }
                }
            }
        )
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "tablecells")
                .font(.system(size: 56))
                .foregroundStyle(.quaternary)
                .symbolRenderingMode(.hierarchical)

            // Title
            Text("No tabs open")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)

            // Helpful instructions with keyboard shortcuts
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("⌘T")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.1))
                        )
                    Text("Open SQL Editor")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 6) {
                    Text("Click a table")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Text("to view data")
                        .font(.callout)
                        .foregroundStyle(.quaternary)
                }

                HStack(spacing: 6) {
                    Text("⌘K")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.1))
                        )
                    Text("Switch Database")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

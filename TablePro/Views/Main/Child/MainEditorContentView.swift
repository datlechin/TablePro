//
//  MainEditorContentView.swift
//  TablePro
//
//  Main editor content view containing tab bar and tab content.
//  Extracted from MainContentView for better separation.
//

import AppKit
import CodeEditSourceEditor
import os
import SwiftUI

private let editorContentLogger = Logger(subsystem: "com.TablePro", category: "MainEditorContentView")

/// Cache for sorted query result rows to avoid re-sorting on every SwiftUI body evaluation
private struct SortedRowsCache {
    let sortedIndices: [Int]
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
    let windowId: UUID
    let connectionId: UUID

    // MARK: - Bindings

    @Binding var selectedRowIndices: Set<Int>
    @Binding var editingCell: CellPosition?

    // MARK: - Callbacks

    let onCellEdit: (Int, Int, String?) -> Void
    let onSort: (Int, Bool, Bool) -> Void
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

    // Per-tab row provider cache — avoids recreation on every SwiftUI render.
    @State private var tabRowProviders: [UUID: InMemoryRowProvider] = [:]
    @State private var tabProviderVersions: [UUID: Int] = [:]
    @State private var tabProviderMetaVersions: [UUID: Int] = [:]
    @State private var cachedChangeManager: AnyChangeManager?

    // Native macOS window tabs — no LRU tracking needed (single tab per window)

    // MARK: - Environment

    @EnvironmentObject private var appState: AppState

    /// Returns the cached AnyChangeManager, creating it on first access.
    private var currentChangeManager: AnyChangeManager {
        if let existing = cachedChangeManager {
            return existing
        }
        // Fallback before onAppear initializes cachedChangeManager.
        // Safe: onAppear fires before any user interaction needs it.
        return AnyChangeManager(dataManager: changeManager)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Native macOS window tabs replace the custom tab bar.
            // Each window-tab contains a single tab — no ZStack keep-alive needed.
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
        .onChange(of: tabManager.tabs.count) {
            // Clean up caches for closed tabs
            let openTabIds = Set(tabManager.tabs.map(\.id))
            sortCache = sortCache.filter { openTabIds.contains($0.key) }
            coordinator.cleanupSortCache(openTabIds: openTabIds)
            tabRowProviders = tabRowProviders.filter { openTabIds.contains($0.key) }
            tabProviderVersions = tabProviderVersions.filter { openTabIds.contains($0.key) }
            tabProviderMetaVersions = tabProviderMetaVersions.filter { openTabIds.contains($0.key) }
        }
        .onChange(of: tabManager.tabs.map(\.id)) { _, newIds in
            let openTabIds = Set(newIds)
            sortCache = sortCache.filter { openTabIds.contains($0.key) }
            coordinator.cleanupSortCache(openTabIds: openTabIds)
            tabRowProviders = tabRowProviders.filter { openTabIds.contains($0.key) }
            tabProviderVersions = tabProviderVersions.filter { openTabIds.contains($0.key) }
            tabProviderMetaVersions = tabProviderMetaVersions.filter { openTabIds.contains($0.key) }
        }
        .onChange(of: tabManager.selectedTabId) {
            updateHasQueryText()
        }
        .onAppear {
            updateHasQueryText()
            cachedChangeManager = AnyChangeManager(dataManager: changeManager)
            if let tab = tabManager.selectedTab {
                let provider = makeRowProvider(for: tab)
                tabRowProviders[tab.id] = provider
                tabProviderVersions[tab.id] = tab.resultVersion
                tabProviderMetaVersions[tab.id] = tab.metadataVersion
            }
        }
        .onChange(of: tabManager.selectedTab?.resultVersion) { _, newVersion in
            guard let tab = tabManager.selectedTab, newVersion != nil else { return }
            let provider = makeRowProvider(for: tab)
            tabRowProviders[tab.id] = provider
            tabProviderVersions[tab.id] = tab.resultVersion
            tabProviderMetaVersions[tab.id] = tab.metadataVersion
        }
        .onChange(of: tabManager.selectedTab?.metadataVersion) { _, _ in
            guard let tab = tabManager.selectedTab else { return }
            let provider = makeRowProvider(for: tab)
            tabRowProviders[tab.id] = provider
            tabProviderVersions[tab.id] = tab.resultVersion
            tabProviderMetaVersions[tab.id] = tab.metadataVersion
        }
        .onChange(of: tabManager.selectedTabId) { _, newId in
            guard let newId, let tab = tabManager.selectedTab else { return }

            // Cache provider for new tab if not already cached
            if tabProviderVersions[newId] != tab.resultVersion
                || tabProviderMetaVersions[newId] != tab.metadataVersion {
                let provider = makeRowProvider(for: tab)
                tabRowProviders[newId] = provider
                tabProviderVersions[newId] = tab.resultVersion
                tabProviderMetaVersions[newId] = tab.metadataVersion
            }
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
                    cursorPositions: $coordinator.cursorPositions,
                    onExecute: { coordinator.runQuery() },
                    schemaProvider: coordinator.schemaProvider,
                    databaseType: coordinator.connection.type,
                    onCloseTab: {
                        NSApp.keyWindow?.close()
                    },
                    onExecuteQuery: { coordinator.runQuery() }
                )
            }
            .frame(minHeight: 100, idealHeight: 200)

            // Results (bottom)
            resultsSection(tab: tab)
                .frame(minHeight: 150)
        }
    }

    private func updateHasQueryText() {
        if let tab = tabManager.selectedTab, tab.tabType == .query {
            appState.hasQueryText = !tab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            appState.hasQueryText = false
        }
    }

    /// Maximum query size to persist (500KB). Queries larger than this are typically
    /// imported SQL dumps — serializing 40MB to JSON + writing to UserDefaults
    /// blocks the main thread for 10-30+ seconds, freezing the app.
    private static let maxPersistableQuerySize = 500_000

    private func queryTextBinding(for tab: QueryTab) -> Binding<String> {
        let tabId = tab.id
        return Binding(
            get: { tab.query },
            set: { newValue in
                // Find this tab by ID, not by selectedTabIndex. During tab switch,
                // flushTextUpdate() fires on the OLD tab's EditorCoordinator when
                // selectedTabIndex already points to the NEW tab — writing to
                // selectedTabIndex would overwrite the new tab's query.
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
                      index < tabManager.tabs.count else { return }

                tabManager.tabs[index].query = newValue
                AppState.shared.hasQueryText = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                // Skip persistence for very large queries (e.g., imported SQL dumps).
                // JSON-encoding 40MB + writing to UserDefaults freezes the main thread.
                let queryLength = (newValue as NSString).length
                guard queryLength < Self.maxPersistableQuerySize else { return }

                coordinator.tabPersistence.saveLastQueryDebounced(newValue)

                if !coordinator.tabPersistence.isRestoringTabs && !coordinator.tabPersistence.isDismissing {
                    NativeTabRegistry.shared.update(
                        windowId: windowId,
                        connectionId: connectionId,
                        tabs: tabManager.tabs.map { $0.toSnapshot() },
                        selectedTabId: tabManager.selectedTabId
                    )
                    let combinedTabs = NativeTabRegistry.shared.allTabs(for: connectionId)
                    coordinator.tabPersistence.saveTabsDebounced(
                        tabs: combinedTabs,
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
                    // Close the create-table window
                    NSApp.keyWindow?.close()
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
                TableStructureView(tableName: tableName, connection: connection, toolbarState: coordinator.toolbarState)
                    .id(tableName)
                    .frame(maxHeight: .infinity)
            } else if tab.resultColumns.isEmpty && tab.errorMessage == nil && tab.lastExecutedAt != nil && !tab.isExecuting {
                QuerySuccessView(
                    rowsAffected: tab.rowsAffected,
                    executionTime: tab.executionTime
                )
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

                dataGridView(tab: tab)
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
            rowProvider: rowProvider(for: tab),
            changeManager: currentChangeManager,
            resultVersion: tab.resultVersion,
            metadataVersion: tab.metadataVersion,
            isEditable: tab.isEditable && !tab.isView && !connection.isReadOnly,
            onCommit: onCommit,
            onRefresh: onRefresh,
            onCellEdit: onCellEdit,
            onUndo: { [binding = _selectedRowIndices, coordinator] in
                var indices = binding.wrappedValue
                coordinator.undoLastChange(selectedRowIndices: &indices)
                binding.wrappedValue = indices
            },
            onRedo: { [coordinator] in
                coordinator.redoLastChange()
            },
            onSort: onSort,
            onAddRow: onAddRow,
            onUndoInsert: onUndoInsert,
            onFilterColumn: onFilterColumn,
            onNavigateFK: { [coordinator] value, fkInfo in
                coordinator.navigateToFKReference(value: value, fkInfo: fkInfo)
            },
            databaseType: connection.type,
            selectedRowIndices: $selectedRowIndices,
            sortState: sortStateBinding(for: tab),
            editingCell: $editingCell,
            columnLayout: columnLayoutBinding(for: tab)
        )
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func rowProvider(for tab: QueryTab) -> InMemoryRowProvider {
        if let cached = tabRowProviders[tab.id],
           tabProviderVersions[tab.id] == tab.resultVersion,
           tabProviderMetaVersions[tab.id] == tab.metadataVersion {
            return cached
        }
        return makeRowProvider(for: tab)
    }

    private func makeRowProvider(for tab: QueryTab) -> InMemoryRowProvider {
        InMemoryRowProvider(
            rows: sortedRows(for: tab),
            columns: tab.resultColumns,
            columnDefaults: tab.columnDefaults,
            columnTypes: tab.columnTypes,
            columnForeignKeys: tab.columnForeignKeys,
            columnEnumValues: tab.columnEnumValues,
            columnNullable: tab.columnNullable
        )
    }

    private func sortedRows(for tab: QueryTab) -> [QueryResultRow] {
        guard !tab.rowBuffer.isEvicted else { return [] }

        // Table tabs: Don't apply client-side sorting (handled via SQL ORDER BY)
        if tab.tabType == .table {
            return tab.resultRows
        }

        // Query tabs: Apply client-side sorting
        guard tab.sortState.isSorting else {
            return tab.resultRows
        }

        // Check coordinator's async sort cache (for large datasets sorted on background thread)
        // The cache stores index permutation to avoid duplicating all row data.
        if let cached = coordinator.querySortCache[tab.id],
           cached.columnIndex == (tab.sortState.columnIndex ?? -1),
           cached.direction == tab.sortState.direction,
           cached.resultVersion == tab.resultVersion {
            return cached.sortedIndices.map { tab.resultRows[$0] }
        }

        // For large datasets sorted async, return unsorted until cache is ready
        if tab.resultRows.count > 10_000 {
            return tab.resultRows
        }

        // Small dataset: sort synchronously with view-level cache
        if let cached = sortCache[tab.id],
           cached.columnIndex == (tab.sortState.columnIndex ?? -1),
           cached.direction == tab.sortState.direction,
           cached.resultVersion == tab.resultVersion {
            return cached.sortedIndices.map { tab.resultRows[$0] }
        }

        let sortColumns = tab.sortState.columns
        let indices = Array(tab.resultRows.indices)
        let sortedIndices = indices.sorted { idx1, idx2 in
            let row1 = tab.resultRows[idx1]
            let row2 = tab.resultRows[idx2]
            for sortCol in sortColumns {
                let val1 = sortCol.columnIndex < row1.values.count
                    ? (row1.values[sortCol.columnIndex] ?? "") : ""
                let val2 = sortCol.columnIndex < row2.values.count
                    ? (row2.values[sortCol.columnIndex] ?? "") : ""
                let result = val1.localizedStandardCompare(val2)
                if result == .orderedSame { continue }
                return sortCol.direction == .ascending
                    ? result == .orderedAscending
                    : result == .orderedDescending
            }
            return false
        }

        // Cache the result
        sortCache[tab.id] = SortedRowsCache(
            sortedIndices: sortedIndices,
            columnIndex: tab.sortState.columnIndex ?? -1,
            direction: tab.sortState.direction,
            resultVersion: tab.resultVersion
        )

        return sortedIndices.map { tab.resultRows[$0] }
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

    private func columnLayoutBinding(for tab: QueryTab) -> Binding<ColumnLayoutState> {
        Binding(
            get: { tab.columnLayout },
            set: { newValue in
                if let index = tabManager.selectedTabIndex {
                    tabManager.tabs[index].columnLayout = newValue
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
                                .fill(Color(nsColor: .quaternaryLabelColor))
                        )
                    Text(connection.type == .mongodb ? "Open MQL Editor" : "Open SQL Editor")
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
                                .fill(Color(nsColor: .quaternaryLabelColor))
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

//
//  MainContentNotificationHandler.swift
//  TablePro
//
//  Consolidates all notification handlers for MainContentView.
//  Uses Combine for cleaner subscription management.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Handles all NotificationCenter subscriptions for MainContentView
@MainActor
final class MainContentNotificationHandler: ObservableObject {
    // MARK: - Dependencies

    private weak var coordinator: MainContentCoordinator?
    private let filterStateManager: FilterStateManager
    private let connection: DatabaseConnection

    // MARK: - Bindings

    private let selectedRowIndices: Binding<Set<Int>>
    private let selectedTables: Binding<Set<TableInfo>>
    private let pendingTruncates: Binding<Set<String>>
    private let pendingDeletes: Binding<Set<String>>
    private let tableOperationOptions: Binding<[String: TableOperationOptions]>
    private let isInspectorPresented: Binding<Bool>
    private let editingCell: Binding<CellPosition?>
    private let showDatabaseSwitcher: Binding<Bool>

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(
        coordinator: MainContentCoordinator,
        filterStateManager: FilterStateManager,
        connection: DatabaseConnection,
        selectedRowIndices: Binding<Set<Int>>,
        selectedTables: Binding<Set<TableInfo>>,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        isInspectorPresented: Binding<Bool>,
        editingCell: Binding<CellPosition?>,
        showDatabaseSwitcher: Binding<Bool>
    ) {
        self.coordinator = coordinator
        self.filterStateManager = filterStateManager
        self.connection = connection
        self.selectedRowIndices = selectedRowIndices
        self.selectedTables = selectedTables
        self.pendingTruncates = pendingTruncates
        self.pendingDeletes = pendingDeletes
        self.tableOperationOptions = tableOperationOptions
        self.isInspectorPresented = isInspectorPresented
        self.editingCell = editingCell
        self.showDatabaseSwitcher = showDatabaseSwitcher

        setupObservers()
    }

    // MARK: - Observer Setup

    private func setupObservers() {
        setupRowOperationObservers()
        setupTabOperationObservers()
        setupFilterOperationObservers()
        setupDataOperationObservers()
        setupUIOperationObservers()
        setupDatabaseOperationObservers()
        setupUndoRedoObservers()
        setupWindowObservers()
    }

    // MARK: - Row Operations

    private func setupRowOperationObservers() {
        NotificationCenter.default.publisher(for: .addNewRow)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleAddNewRow()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .deleteSelectedRows)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleDeleteSelectedRows()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .duplicateRow)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleDuplicateRow()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .copySelectedRows)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleCopySelectedRows()
            }
            .store(in: &cancellables)
    }

    private func handleAddNewRow() {
        var indices = selectedRowIndices.wrappedValue
        var cell = editingCell.wrappedValue
        coordinator?.addNewRow(selectedRowIndices: &indices, editingCell: &cell)
        selectedRowIndices.wrappedValue = indices
        editingCell.wrappedValue = cell
    }

    private func handleDeleteSelectedRows() {
        let indices = selectedRowIndices.wrappedValue
        if !indices.isEmpty {
            var mutableIndices = indices
            coordinator?.deleteSelectedRows(indices: indices, selectedRowIndices: &mutableIndices)
            selectedRowIndices.wrappedValue = mutableIndices
        } else if !selectedTables.wrappedValue.isEmpty {
            var updatedDeletes = pendingDeletes.wrappedValue
            var updatedTruncates = pendingTruncates.wrappedValue

            for table in selectedTables.wrappedValue {
                updatedTruncates.remove(table.name)
                if updatedDeletes.contains(table.name) {
                    updatedDeletes.remove(table.name)
                } else {
                    updatedDeletes.insert(table.name)
                }
            }

            pendingTruncates.wrappedValue = updatedTruncates
            pendingDeletes.wrappedValue = updatedDeletes
        }
    }

    private func handleDuplicateRow() {
        let indices = selectedRowIndices.wrappedValue
        guard let selectedIndex = indices.first, indices.count == 1 else { return }

        var mutableIndices = indices
        var cell = editingCell.wrappedValue
        coordinator?.duplicateSelectedRow(index: selectedIndex, selectedRowIndices: &mutableIndices, editingCell: &cell)
        selectedRowIndices.wrappedValue = mutableIndices
        editingCell.wrappedValue = cell
    }

    private func handleCopySelectedRows() {
        let indices = selectedRowIndices.wrappedValue
        coordinator?.copySelectedRowsToClipboard(indices: indices)
    }

    // MARK: - Tab Operations

    private func setupTabOperationObservers() {
        NotificationCenter.default.publisher(for: .newTab)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleNewTab()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .closeCurrentTab)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.coordinator?.handleCloseAction()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .loadQueryIntoEditor)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleLoadQueryIntoEditor(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .tableTabClosed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleTableTabClosed(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .showAllTables)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.coordinator?.showAllTablesMetadata()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .createTable)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleCreateTable()
            }
            .store(in: &cancellables)
    }

    private func handleNewTab() {
        guard let coordinator = coordinator else { return }
        let lastQuery = coordinator.tabPersistence.loadLastQuery()
        coordinator.tabManager.addTab(initialQuery: lastQuery)
    }

    private func handleLoadQueryIntoEditor(_ notification: Notification) {
        guard let query = notification.object as? String,
              let coordinator = coordinator,
              let tabIndex = coordinator.tabManager.selectedTabIndex,
              tabIndex < coordinator.tabManager.tabs.count else { return }

        coordinator.tabManager.tabs[tabIndex].query = query
        coordinator.tabManager.tabs[tabIndex].hasUserInteraction = true
    }

    private func handleTableTabClosed(_ notification: Notification) {
        if let tableName = notification.object as? String {
            selectedTables.wrappedValue = selectedTables.wrappedValue.filter { $0.name != tableName }
        }
    }

    private func handleCreateTable() {
        guard let coordinator = coordinator else { return }

        // Get current database name from the connection
        let currentDatabase = connection.database

        coordinator.tabManager.addCreateTableTab(
            databaseName: currentDatabase,
            databaseType: connection.type
        )
    }

    // MARK: - Filter Operations

    private func setupFilterOperationObservers() {
        NotificationCenter.default.publisher(for: .toggleFilterPanel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let coordinator = self?.coordinator,
                      coordinator.tabManager.selectedTab?.tabType == .table else { return }
                self?.filterStateManager.toggle()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .applyAllFilters)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleApplyAllFilters()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .duplicateFilter)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleDuplicateFilter()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .removeFilter)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleRemoveFilter()
            }
            .store(in: &cancellables)
    }

    private func handleApplyAllFilters() {
        if filterStateManager.hasSelectedFilters {
            filterStateManager.applySelectedFilters()
            coordinator?.applyFilters(filterStateManager.appliedFilters)
        }
    }

    private func handleDuplicateFilter() {
        if filterStateManager.isVisible, let focusedFilter = filterStateManager.focusedFilter {
            filterStateManager.duplicateFilter(focusedFilter)
        }
    }

    private func handleRemoveFilter() {
        if filterStateManager.isVisible, let focusedFilter = filterStateManager.focusedFilter {
            filterStateManager.removeFilter(focusedFilter)
        }
    }

    // MARK: - Data Operations

    private func setupDataOperationObservers() {
        NotificationCenter.default.publisher(for: .refreshData)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleRefreshData()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .refreshAll)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleRefreshAll()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .saveChanges)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleSaveChanges()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .exportTables)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleExportTables()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .importTables)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleImportTables()
            }
            .store(in: &cancellables)
    }

    private func handleRefreshData() {
        coordinator?.handleRefresh(
            pendingTruncates: pendingTruncates.wrappedValue,
            pendingDeletes: pendingDeletes.wrappedValue
        )
    }

    private func handleRefreshAll() {
        coordinator?.handleRefreshAll(
            pendingTruncates: pendingTruncates.wrappedValue,
            pendingDeletes: pendingDeletes.wrappedValue
        )
    }

    private func handleSaveChanges() {
        var truncates = pendingTruncates.wrappedValue
        var deletes = pendingDeletes.wrappedValue
        var options = tableOperationOptions.wrappedValue
        coordinator?.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )
        pendingTruncates.wrappedValue = truncates
        pendingDeletes.wrappedValue = deletes
        tableOperationOptions.wrappedValue = options
    }

    private func handleExportTables() {
        coordinator?.showExportDialog = true
    }

    private func handleImportTables() {
        // Open file picker first, then show dialog with selected file
        let panel = NSOpenPanel()
        var contentTypes: [UTType] = []
        if let sqlType = UTType(filenameExtension: "sql") {
            contentTypes.append(sqlType)
        }
        if let gzType = UTType(filenameExtension: "gz") {
            contentTypes.append(gzType)
        }
        if !contentTypes.isEmpty {
            panel.allowedContentTypes = contentTypes
        }
        panel.allowsMultipleSelection = false
        panel.message = "Select SQL file to import"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            // Store the selected file URL and show dialog
            self?.coordinator?.importFileURL = url
            self?.coordinator?.showImportDialog = true
        }
    }

    // MARK: - UI Operations

    private func setupUIOperationObservers() {
        NotificationCenter.default.publisher(for: .clearSelection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleClearSelection()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .toggleHistoryPanel)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                AppState.shared.isHistoryPanelVisible.toggle()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .toggleRightSidebar)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleToggleRightSidebar()
            }
            .store(in: &cancellables)
    }

    private func handleClearSelection() {
        selectedRowIndices.wrappedValue.removeAll()
        selectedTables.wrappedValue.removeAll()
        if filterStateManager.isVisible {
            filterStateManager.close()
        }
    }

    private func handleToggleRightSidebar() {
        isInspectorPresented.wrappedValue.toggle()
        if isInspectorPresented.wrappedValue,
           let tableName = coordinator?.tabManager.selectedTab?.tableName,
           coordinator?.tableMetadata?.tableName != tableName {
            Task {
                await coordinator?.loadTableMetadata(tableName: tableName)
            }
        }
    }

    // MARK: - Database Operations

    private func setupDatabaseOperationObservers() {
        NotificationCenter.default.publisher(for: .databaseDidConnect)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleDatabaseDidConnect()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openDatabaseSwitcher)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.showDatabaseSwitcher.wrappedValue = true
            }
            .store(in: &cancellables)
    }

    private func handleDatabaseDidConnect() {
        Task {
            await coordinator?.loadSchema()
            if let driver = DatabaseManager.shared.activeDriver {
                coordinator?.toolbarState.databaseVersion = driver.serverVersion
            }
        }
    }

    // MARK: - Undo/Redo

    private func setupUndoRedoObservers() {
        NotificationCenter.default.publisher(for: .undoChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                var indices = self?.selectedRowIndices.wrappedValue ?? []
                self?.coordinator?.undoLastChange(selectedRowIndices: &indices)
                self?.selectedRowIndices.wrappedValue = indices
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .redoChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.coordinator?.redoLastChange()
            }
            .store(in: &cancellables)
    }

    // MARK: - Window Operations

    private func setupWindowObservers() {
        NotificationCenter.default.publisher(for: .mainWindowWillClose)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let coordinator = self?.coordinator else { return }
                coordinator.tabPersistence.handleWindowClose(
                    tabs: coordinator.tabManager.tabs,
                    selectedTabId: coordinator.tabManager.selectedTabId
                )
            }
            .store(in: &cancellables)
    }
}

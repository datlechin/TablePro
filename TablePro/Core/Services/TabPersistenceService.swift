//
//  TabPersistenceService.swift
//  TablePro
//
//  Service responsible for persisting and restoring tab state.
//  Handles debounced saving, restoration from disk, and window close handling.
//

import Combine
import Foundation

/// Service for managing tab state persistence
@MainActor
final class TabPersistenceService: ObservableObject {
    // MARK: - Constants

    private static let saveDebounceDelay: UInt64 = 500_000_000  // 500ms in nanoseconds
    private static let connectionCheckDelay: UInt64 = 100_000_000  // 100ms in nanoseconds
    private static let maxConnectionRetries = 50  // Max retries for connection check (5 seconds total)

    // MARK: - State

    /// Indicates tabs are being restored (prevents circular sync)
    @Published private(set) var isRestoringTabs = false

    /// Indicates view is being dismissed (prevents saving during teardown)
    @Published private(set) var isDismissing = false

    /// Flag to track if a tab was just restored (prevents duplicate lazy load)
    @Published private(set) var justRestoredTab = false

    // MARK: - Private State

    private var saveDebounceTask: Task<Void, Never>?
    private let connectionId: UUID

    // MARK: - Initialization

    init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    // MARK: - Save Operations

    /// Save tabs with debouncing to prevent rapid successive saves
    /// - Parameters:
    ///   - tabs: Current tabs array
    ///   - selectedTabId: Currently selected tab ID
    func saveTabsDebounced(tabs: [QueryTab], selectedTabId: UUID?) {
        guard !isRestoringTabs, !isDismissing else { return }

        // Cancel previous debounce task
        saveDebounceTask?.cancel()

        // Capture current state to prevent stale data
        let tabsToSave = tabs
        let selectedId = selectedTabId

        // Create new debounce task
        saveDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.saveDebounceDelay)

            guard !Task.isCancelled, !isDismissing else { return }

            TabStateStorage.shared.saveTabState(
                connectionId: connectionId,
                tabs: tabsToSave,
                selectedTabId: selectedId
            )
        }
    }

    /// Immediately save tabs without debouncing
    /// - Parameters:
    ///   - tabs: Current tabs array
    ///   - selectedTabId: Currently selected tab ID
    func saveTabsImmediately(tabs: [QueryTab], selectedTabId: UUID?) {
        guard !isRestoringTabs, !isDismissing else { return }

        TabStateStorage.shared.saveTabState(
            connectionId: connectionId,
            tabs: tabs,
            selectedTabId: selectedTabId
        )
    }

    /// Handle window close - flush any pending saves
    /// - Parameters:
    ///   - tabs: Current tabs array
    ///   - selectedTabId: Currently selected tab ID
    func handleWindowClose(tabs: [QueryTab], selectedTabId: UUID?) {
        // Set flag to prevent further saves
        isDismissing = true

        // Cancel debounce task and save immediately
        saveDebounceTask?.cancel()

        TabStateStorage.shared.saveTabState(
            connectionId: connectionId,
            tabs: tabs,
            selectedTabId: selectedTabId
        )
    }

    /// Flush pending debounced save before tab switch
    /// - Parameters:
    ///   - tabs: Current tabs array
    ///   - selectedTabId: Currently selected tab ID
    func flushPendingSave(tabs: [QueryTab], selectedTabId: UUID?) {
        guard let task = saveDebounceTask, !task.isCancelled else { return }

        task.cancel()
        saveTabsImmediately(tabs: tabs, selectedTabId: selectedTabId)
    }

    // MARK: - Restore Operations

    /// Result of tab restoration
    struct RestoreResult {
        let tabs: [QueryTab]
        let selectedTabId: UUID?
        let source: RestoreSource

        enum RestoreSource {
            case disk
            case session
            case none
        }
    }

    /// Restore tabs from storage (disk first, then session fallback)
    /// - Returns: RestoreResult with tabs and source
    func restoreTabs() -> RestoreResult {
        isRestoringTabs = true
        defer { isRestoringTabs = false }

        // Try disk storage first (persists across app restarts)
        if let savedState = TabStateStorage.shared.loadTabState(connectionId: connectionId),
           !savedState.tabs.isEmpty {
            let restoredTabs = savedState.tabs.map { QueryTab(from: $0) }
            return RestoreResult(
                tabs: restoredTabs,
                selectedTabId: savedState.selectedTabId,
                source: .disk
            )
        }

        // Fallback to session (persists during app session only)
        if let sessionId = DatabaseManager.shared.currentSessionId,
           let session = DatabaseManager.shared.activeSessions[sessionId],
           !session.tabs.isEmpty {
            return RestoreResult(
                tabs: session.tabs,
                selectedTabId: session.selectedTabId,
                source: .session
            )
        }

        return RestoreResult(tabs: [], selectedTabId: nil, source: .none)
    }

    /// Wait for database connection to be established before executing query
    /// - Parameter onReady: Callback when connection is ready
    func waitForConnectionAndExecute(onReady: @escaping () -> Void) async {
        var retryCount = 0

        while retryCount < Self.maxConnectionRetries {
            guard !isDismissing else { break }

            if let session = DatabaseManager.shared.currentSession,
               session.isConnected {
                // Small delay to ensure everything is initialized
                try? await Task.sleep(nanoseconds: Self.connectionCheckDelay)
                await MainActor.run {
                    justRestoredTab = true
                    onReady()
                }
                break
            }

            try? await Task.sleep(nanoseconds: Self.connectionCheckDelay)
            retryCount += 1
        }
    }

    /// Reset the just restored flag
    func clearJustRestoredFlag() {
        justRestoredTab = false
    }

    /// Mark restoration as starting
    func beginRestoration() {
        isRestoringTabs = true
    }

    /// Mark restoration as complete
    func endRestoration() {
        isRestoringTabs = false
    }

    // MARK: - Session Sync

    /// Sync tabs to session for in-memory persistence
    /// - Parameters:
    ///   - tabs: Current tabs array
    ///   - selectedTabId: Currently selected tab ID
    func syncToSession(tabs: [QueryTab], selectedTabId: UUID?) {
        guard !isRestoringTabs, !isDismissing else { return }

        if let sessionId = DatabaseManager.shared.currentSessionId {
            DatabaseManager.shared.updateSession(sessionId) { session in
                session.tabs = tabs
                session.selectedTabId = selectedTabId
            }
        }
    }

    /// Clear saved state when all tabs are closed
    func clearSavedState() {
        TabStateStorage.shared.clearTabState(connectionId: connectionId)
    }

    /// Load last query for this connection (TablePlus-style)
    func loadLastQuery() -> String? {
        TabStateStorage.shared.loadLastQuery(for: connectionId)
    }

    /// Save last query for this connection
    func saveLastQuery(_ query: String) {
        TabStateStorage.shared.saveLastQuery(query, for: connectionId)
    }
}

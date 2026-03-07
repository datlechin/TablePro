//
//  TabPersistenceCoordinator.swift
//  TablePro
//
//  Explicit-save coordinator for tab state persistence.
//  Replaces debounced/flag-based TabPersistenceService with direct save calls.
//

import Foundation
import Observation
import os

/// Result of tab restoration from disk
internal struct RestoreResult {
    let tabs: [QueryTab]
    let selectedTabId: UUID?
    let source: RestoreSource

    enum RestoreSource {
        case disk
        case none
    }
}

/// Coordinator for persisting and restoring tab state.
/// All saves are explicit: no debounce timers, no onChange-driven saves,
/// no isDismissing/isRestoringTabs flag state machine.
@MainActor @Observable
internal final class TabPersistenceCoordinator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TabPersistenceCoordinator")

    private static let maxPersistableQuerySize = 500_000

    let connectionId: UUID

    init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    // MARK: - Save

    /// Save tab state to disk. Called explicitly at named business events
    /// (tab switch, window close, quit, etc.).
    internal func saveNow(tabs: [QueryTab], selectedTabId: UUID?) {
        let persisted = tabs.map { convertToPersistedTab($0) }
        let connId = connectionId
        let selectedId = selectedTabId

        Self.logger.info(
            "saveNow -- \(persisted.count) tabs, selectedTabId=\(selectedId?.uuidString ?? "nil", privacy: .public)"
        )

        Task {
            await TabDiskActor.shared.save(connectionId: connId, tabs: persisted, selectedTabId: selectedId)
        }
    }

    /// Save pre-aggregated tabs for the quit path, where the caller has already
    /// collected and converted tabs from all windows for this connection.
    internal func saveNow(allTabs: [PersistedTab], selectedTabId: UUID?) {
        let connId = connectionId
        let selectedId = selectedTabId

        Self.logger.info(
            "saveNow (allTabs) -- \(allTabs.count) tabs, selectedTabId=\(selectedId?.uuidString ?? "nil", privacy: .public)"
        )

        Task {
            await TabDiskActor.shared.save(connectionId: connId, tabs: allTabs, selectedTabId: selectedId)
        }
    }

    /// Synchronous save for `applicationWillTerminate` where no run loop
    /// remains to service async Tasks. Bypasses the actor and writes directly.
    internal func saveNowSync(tabs: [QueryTab], selectedTabId: UUID?) {
        let persisted = tabs.map { convertToPersistedTab($0) }

        Self.logger.info(
            "saveNowSync -- \(persisted.count) tabs, selectedTabId=\(selectedTabId?.uuidString ?? "nil", privacy: .public)"
        )

        TabDiskActor.saveSync(connectionId: connectionId, tabs: persisted, selectedTabId: selectedTabId)
    }

    // MARK: - Clear

    /// Clear all saved state for this connection (user closed all tabs).
    internal func clearSavedState() {
        let connId = connectionId
        Self.logger.info("clearSavedState -- connectionId=\(connId)")

        Task {
            await TabDiskActor.shared.clear(connectionId: connId)
        }
    }

    // MARK: - Restore

    /// Restore tabs from disk. Called once at window creation.
    internal func restoreFromDisk() async -> RestoreResult {
        Self.logger.info("restoreFromDisk -- connectionId=\(self.connectionId)")

        guard let state = await TabDiskActor.shared.load(connectionId: connectionId) else {
            Self.logger.info("restoreFromDisk -> no disk state (none)")
            return RestoreResult(tabs: [], selectedTabId: nil, source: .none)
        }

        guard !state.tabs.isEmpty else {
            Self.logger.info("restoreFromDisk -> empty tabs on disk (none)")
            return RestoreResult(tabs: [], selectedTabId: nil, source: .none)
        }

        let restoredTabs = state.tabs.map { QueryTab(from: $0) }
        let tabNames = restoredTabs.map { $0.tableName ?? "query" }.joined(separator: ", ")
        Self.logger.info(
            "restoreFromDisk -> disk: \(restoredTabs.count) tabs [\(tabNames, privacy: .public)], selectedTabId=\(state.selectedTabId?.uuidString ?? "nil", privacy: .public)"
        )

        return RestoreResult(
            tabs: restoredTabs,
            selectedTabId: state.selectedTabId,
            source: .disk
        )
    }

    // MARK: - Last Query

    /// Save the editor's last query text for this connection.
    internal func saveLastQuery(_ query: String) {
        let connId = connectionId
        Task {
            await TabDiskActor.shared.saveLastQuery(query, for: connId)
        }
    }

    /// Load the editor's last query text for this connection.
    internal func loadLastQuery() async -> String? {
        await TabDiskActor.shared.loadLastQuery(for: connectionId)
    }

    // MARK: - Private

    private func convertToPersistedTab(_ tab: QueryTab) -> PersistedTab {
        let persistedQuery: String
        if (tab.query as NSString).length > Self.maxPersistableQuerySize {
            persistedQuery = ""
        } else {
            persistedQuery = tab.query
        }

        return PersistedTab(
            id: tab.id,
            title: tab.title,
            query: persistedQuery,
            tabType: tab.tabType,
            tableName: tab.tableName,
            isView: tab.isView,
            databaseName: tab.databaseName
        )
    }
}

//
//  TabStateStorage.swift
//  TablePro
//
//  Service for persisting tab state per connection
//

import Foundation

/// Represents persisted tab state for a connection
struct TabState: Codable {
    let tabs: [PersistedTab]
    let selectedTabId: UUID?
}

/// Service for persisting tab state per connection
final class TabStateStorage {
    static let shared = TabStateStorage()

    private let defaults = UserDefaults.standard
    private let tabStateKeyPrefix = "com.TablePro.tabs."

    private init() {}

    // MARK: - Public API

    /// Save tab state for a connection
    func saveTabState(connectionId: UUID, tabs: [QueryTab], selectedTabId: UUID?) {
        let persistedTabs = tabs.map { $0.toPersistedTab() }
        let tabState = TabState(tabs: persistedTabs, selectedTabId: selectedTabId)

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(tabState)
            let key = tabStateKey(for: connectionId)
            defaults.set(data, forKey: key)
        } catch {
            // Silent failure - encoding errors are rare and non-critical
        }
    }

    /// Load tab state for a connection
    func loadTabState(connectionId: UUID) -> TabState? {
        let key = tabStateKey(for: connectionId)

        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(TabState.self, from: data)
        } catch {
            // Silent failure - decoding errors return nil
            return nil
        }
    }

    /// Clear tab state for a connection
    func clearTabState(connectionId: UUID) {
        let key = tabStateKey(for: connectionId)
        defaults.removeObject(forKey: key)
    }

    // MARK: - Last Query Memory (TablePlus-style)

    /// Save the last query text for a connection (persists across tab close/open)
    func saveLastQuery(_ query: String, for connectionId: UUID) {
        let key = "com.TablePro.lastquery.\(connectionId.uuidString)"

        // Only save non-empty queries (trimmed to avoid saving whitespace-only queries)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    /// Load the last query text for a connection
    func loadLastQuery(for connectionId: UUID) -> String? {
        let key = "com.TablePro.lastquery.\(connectionId.uuidString)"
        return defaults.string(forKey: key)
    }

    // MARK: - Private Helpers

    private func tabStateKey(for connectionId: UUID) -> String {
        "\(tabStateKeyPrefix)\(connectionId.uuidString)"
    }
}

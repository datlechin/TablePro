//
//  FilterSettingsStorage.swift
//  TablePro
//
//  Persistent storage for filter settings and last-used filters
//

import Foundation

/// Default column selection for new filters
enum FilterDefaultColumn: String, CaseIterable, Identifiable, Codable {
    case rawSQL = "rawSQL"
    case primaryKey = "primaryKey"
    case anyColumn = "anyColumn"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rawSQL: return "Raw SQL"
        case .primaryKey: return "Primary Key"
        case .anyColumn: return "Any Column"
        }
    }
}

/// Default operator for new filters
enum FilterDefaultOperator: String, CaseIterable, Identifiable, Codable {
    case equal = "equal"
    case contains = "contains"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .equal: return "Equal (=)"
        case .contains: return "Contains"
        }
    }

    func toFilterOperator() -> FilterOperator {
        switch self {
        case .equal: return .equal
        case .contains: return .contains
        }
    }
}

/// Default panel state when opening a table
enum FilterPanelDefaultState: String, CaseIterable, Identifiable, Codable {
    case restoreLast = "restoreLast"
    case alwaysShow = "alwaysShow"
    case alwaysHide = "alwaysHide"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .restoreLast: return "Restore Last Filter"
        case .alwaysShow: return "Always Show"
        case .alwaysHide: return "Always Hide"
        }
    }
}

/// Settings for filter behavior
struct FilterSettings: Codable, Equatable {
    var defaultColumn: FilterDefaultColumn
    var defaultOperator: FilterDefaultOperator
    var panelState: FilterPanelDefaultState

    init(
        defaultColumn: FilterDefaultColumn = .anyColumn,
        defaultOperator: FilterDefaultOperator = .equal,
        panelState: FilterPanelDefaultState = .alwaysHide
    ) {
        self.defaultColumn = defaultColumn
        self.defaultOperator = defaultOperator
        self.panelState = panelState
    }
}

/// Persistent storage for filter settings and per-table last-used filters
final class FilterSettingsStorage {
    static let shared = FilterSettingsStorage()

    private let settingsKey = "com.TablePro.filter.settings"
    private let lastFiltersKeyPrefix = "com.TablePro.filter.lastFilters."
    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Settings

    /// Load filter settings
    func loadSettings() -> FilterSettings {
        guard let data = defaults.data(forKey: settingsKey) else {
            return FilterSettings()
        }

        do {
            return try JSONDecoder().decode(FilterSettings.self, from: data)
        } catch {
            print("Failed to decode filter settings: \(error)")
            return FilterSettings()
        }
    }

    /// Save filter settings
    func saveSettings(_ settings: FilterSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: settingsKey)
        } catch {
            print("Failed to encode filter settings: \(error)")
        }
    }

    // MARK: - Per-Table Last Filters

    /// Load last-used filters for a specific table
    func loadLastFilters(for tableName: String) -> [TableFilter] {
        let key = lastFiltersKeyPrefix + sanitizeTableName(tableName)

        guard let data = defaults.data(forKey: key) else {
            return []
        }

        do {
            return try JSONDecoder().decode([TableFilter].self, from: data)
        } catch {
            print("Failed to decode last filters for \(tableName): \(error)")
            return []
        }
    }

    /// Save last-used filters for a specific table
    func saveLastFilters(_ filters: [TableFilter], for tableName: String) {
        let key = lastFiltersKeyPrefix + sanitizeTableName(tableName)

        // Only save non-empty filter configurations
        guard !filters.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }

        do {
            let data = try JSONEncoder().encode(filters)
            defaults.set(data, forKey: key)
        } catch {
            print("Failed to encode last filters for \(tableName): \(error)")
        }
    }

    /// Clear last filters for a specific table
    func clearLastFilters(for tableName: String) {
        let key = lastFiltersKeyPrefix + sanitizeTableName(tableName)
        defaults.removeObject(forKey: key)
    }

    /// Clear all stored last filters
    func clearAllLastFilters() {
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix(lastFiltersKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Helpers

    /// Sanitize table name for use as UserDefaults key
    private func sanitizeTableName(_ tableName: String) -> String {
        // Replace special characters that might cause issues in keys
        tableName
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }
}

//
//  RedisPlugin.swift
//  RedisDriverPlugin
//
//  Redis database driver plugin using hiredis (Redis C client library)
//

import Foundation
import os
import TableProPluginKit

// MARK: - Plugin Entry Point

final class RedisPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Redis Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Redis support via hiredis"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Redis"
    static let databaseDisplayName = "Redis"
    static let iconName = "cylinder.fill"
    static let defaultPort = 6379
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "redisDatabase",
            label: String(localized: "Database Index"),
            defaultValue: "0",
            fieldType: .stepper(range: ConnectionField.IntRange(0...15))
        ),
    ]
    static let additionalDatabaseTypeIds: [String] = []

    // MARK: - UI/Capability Metadata

    static let requiresAuthentication = false
    static let urlSchemes: [String] = ["redis"]
    static let brandColorHex = "#DC382D"
    static let queryLanguageName = "Redis CLI"
    static let editorLanguage: EditorLanguage = .bash
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = false
    static let supportsImport = false
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let defaultGroupName = "db0"
    static let columnTypesByCategory: [String: [String]] = [
        "String": ["string"],
        "List": ["list"],
        "Set": ["set"],
        "Sorted Set": ["zset"],
        "Hash": ["hash"],
        "Stream": ["stream"],
        "HyperLogLog": ["hyperloglog"],
        "Bitmap": ["bitmap"],
        "Geospatial": ["geo"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = nil

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        RedisPluginDriver(config: config)
    }
}

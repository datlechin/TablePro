//
//  MongoDBPlugin.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class MongoDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "MongoDB Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "MongoDB support via libmongoc C driver"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "MongoDB"
    static let databaseDisplayName = "MongoDB"
    static let iconName = "leaf.fill"
    static let defaultPort = 27017
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(id: "mongoAuthSource", label: "Auth Database", placeholder: "admin"),
        ConnectionField(
            id: "mongoReadPreference",
            label: "Read Preference",
            fieldType: .dropdown(options: [
                .init(value: "", label: "Default"),
                .init(value: "primary", label: "Primary"),
                .init(value: "primaryPreferred", label: "Primary Preferred"),
                .init(value: "secondary", label: "Secondary"),
                .init(value: "secondaryPreferred", label: "Secondary Preferred"),
                .init(value: "nearest", label: "Nearest"),
            ])
        ),
        ConnectionField(
            id: "mongoWriteConcern",
            label: "Write Concern",
            fieldType: .dropdown(options: [
                .init(value: "", label: "Default"),
                .init(value: "majority", label: "Majority"),
                .init(value: "1", label: "1"),
                .init(value: "2", label: "2"),
                .init(value: "3", label: "3"),
            ])
        ),
    ]

    // MARK: - UI/Capability Metadata

    static let requiresAuthentication = false
    static let urlSchemes: [String] = ["mongodb", "mongodb+srv"]
    static let brandColorHex = "#00ED63"
    static let queryLanguageName = "MQL"
    static let editorLanguage: EditorLanguage = .javascript
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let systemDatabaseNames: [String] = ["admin", "local", "config"]
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let columnTypesByCategory: [String: [String]] = [
        "String": ["string", "objectId", "regex"],
        "Number": ["int", "long", "double", "decimal"],
        "Date": ["date", "timestamp"],
        "Binary": ["binData"],
        "Boolean": ["bool"],
        "Array": ["array"],
        "Object": ["object"],
        "Null": ["null"],
        "Other": ["javascript", "minKey", "maxKey"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = nil

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        MongoDBPluginDriver(config: config)
    }
}

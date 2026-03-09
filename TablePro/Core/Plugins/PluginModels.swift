//
//  PluginModels.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct PluginEntry: Identifiable {
    let id: String
    let bundle: Bundle
    let url: URL
    let source: PluginSource
    let name: String
    let version: String
    let pluginDescription: String
    let capabilities: [PluginCapability]
    var isEnabled: Bool
}

enum PluginSource {
    case builtIn
    case userInstalled
}

extension PluginEntry {
    var driverPlugin: (any DriverPlugin.Type)? {
        bundle.principalClass as? any DriverPlugin.Type
    }

    var iconName: String {
        driverPlugin?.iconName ?? "puzzlepiece"
    }

    var databaseTypeId: String? {
        driverPlugin?.databaseTypeId
    }

    var additionalTypeIds: [String] {
        driverPlugin?.additionalDatabaseTypeIds ?? []
    }

    var defaultPort: Int? {
        driverPlugin?.defaultPort
    }

    var exportPlugin: (any ExportFormatPlugin.Type)? {
        bundle.principalClass as? any ExportFormatPlugin.Type
    }
}

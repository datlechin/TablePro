//
//  TableTemplateStorage.swift
//  TablePro
//
//  Storage for table creation templates
//

import Foundation

/// Manages saving and loading table creation templates
final class TableTemplateStorage {
    static let shared = TableTemplateStorage()

    private let templatesKey = "saved_table_templates"
    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Storage Location

    private var templatesURL: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Unable to access application support directory")
        }
        let appFolder = appSupport.appendingPathComponent("TablePro", isDirectory: true)

        // Create directory if needed
        if !fileManager.fileExists(atPath: appFolder.path) {
            try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)
        }

        return appFolder.appendingPathComponent("table_templates.json")
    }

    // MARK: - Save/Load

    /// Save a table template
    func saveTemplate(name: String, options: TableCreationOptions, triggeredBySync: Bool = false) throws {
        var templates = try loadTemplates()
        templates[name] = options

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(templates)
        try data.write(to: templatesURL)

        // Push to iCloud if sync enabled (skip when applying remote data)
        if !triggeredBySync {
            Task { @MainActor in
                SyncCoordinator.shared.didUpdateTemplates(templates)
            }
        }
    }

    /// Load all templates
    func loadTemplates() throws -> [String: TableCreationOptions] {
        guard fileManager.fileExists(atPath: templatesURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: templatesURL)
        let decoder = JSONDecoder()
        return try decoder.decode([String: TableCreationOptions].self, from: data)
    }

    /// Delete a template
    func deleteTemplate(name: String, triggeredBySync: Bool = false) throws {
        var templates = try loadTemplates()
        templates.removeValue(forKey: name)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(templates)
        try data.write(to: templatesURL)

        // Push to iCloud if sync enabled (skip when applying remote data)
        if !triggeredBySync {
            Task { @MainActor in
                SyncCoordinator.shared.didUpdateTemplates(templates)
            }
        }
    }

    /// Get template names
    func getTemplateNames() -> [String] {
        do {
            let templates = try loadTemplates()
            return Array(templates.keys).sorted()
        } catch {
            return []
        }
    }

    /// Load specific template
    func loadTemplate(name: String) throws -> TableCreationOptions? {
        let templates = try loadTemplates()
        return templates[name]
    }
}

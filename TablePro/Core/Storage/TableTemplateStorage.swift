//
//  TableTemplateStorage.swift
//  TablePro
//
//  Storage for table creation templates
//

import Foundation

enum StorageError: LocalizedError {
    case directoryUnavailable

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable:
            return "Unable to access application support directory"
        }
    }
}

/// Manages saving and loading table creation templates
final class TableTemplateStorage {
    static let shared = TableTemplateStorage()

    private let templatesKey = "saved_table_templates"
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        return enc
    }()
    private let decoder = JSONDecoder()

    private let templatesURL: URL?

    private init() {
        if let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            let appFolder = appSupport.appendingPathComponent("TablePro", isDirectory: true)

            // Create directory if needed
            if !fileManager.fileExists(atPath: appFolder.path) {
                try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)
            }

            templatesURL = appFolder.appendingPathComponent("table_templates.json")
        } else {
            templatesURL = nil
        }
    }

    // MARK: - Save/Load

    /// Save a table template
    func saveTemplate(name: String, options: TableCreationOptions) throws {
        var templates = try loadTemplates()
        templates[name] = options

        let data = try encoder.encode(templates)
        guard let url = templatesURL else { throw StorageError.directoryUnavailable }
        try data.write(to: url)
    }

    /// Load all templates
    func loadTemplates() throws -> [String: TableCreationOptions] {
        guard let url = templatesURL, fileManager.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode([String: TableCreationOptions].self, from: data)
    }

    /// Delete a template
    func deleteTemplate(name: String) throws {
        var templates = try loadTemplates()
        templates.removeValue(forKey: name)

        let data = try encoder.encode(templates)
        guard let url = templatesURL else { throw StorageError.directoryUnavailable }
        try data.write(to: url)
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

//
//  ThemeStorage.swift
//  TablePro
//
//  File I/O for theme JSON files.
//  Built-in themes loaded from app bundle, user themes from Application Support.
//

import Foundation
import os

struct ThemeStorage {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeStorage")

    private static let userThemesDirectory: URL = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("TablePro/Themes", isDirectory: true)
        }
        return appSupport.appendingPathComponent("TablePro/Themes", isDirectory: true)
    }()

    private static let bundledThemesDirectory: URL? = {
        Bundle.main.resourceURL?.appendingPathComponent("Themes", isDirectory: true)
    }()

    private static let registryThemesDirectory: URL = {
        userThemesDirectory.appendingPathComponent("Registry", isDirectory: true)
    }()

    // MARK: - Load All Themes

    static func loadAllThemes() -> [ThemeDefinition] {
        var themes: [ThemeDefinition] = []

        // Load built-in themes from app bundle
        if let bundleDir = bundledThemesDirectory {
            themes.append(contentsOf: loadThemes(from: bundleDir, isBuiltIn: true))
        }

        // If no bundled themes loaded, use compiled presets as fallback
        if themes.isEmpty {
            themes = ThemePresets.allBuiltIn
        }

        // Load registry themes
        ensureRegistryDirectory()
        themes.append(contentsOf: loadThemes(from: registryThemesDirectory, isBuiltIn: false))

        // Load user themes
        ensureUserDirectory()
        themes.append(contentsOf: loadThemes(from: userThemesDirectory, isBuiltIn: false))

        return themes
    }

    // MARK: - Load Single Theme

    static func loadTheme(id: String) -> ThemeDefinition? {
        // Try user directory first (user overrides)
        let userFile = userThemesDirectory.appendingPathComponent("\(id).json")
        if let theme = loadTheme(from: userFile) {
            return theme
        }

        // Try registry directory
        let registryFile = registryThemesDirectory.appendingPathComponent("\(id).json")
        if let theme = loadTheme(from: registryFile) {
            return theme
        }

        // Try bundle
        if let bundleDir = bundledThemesDirectory {
            let bundleFile = bundleDir.appendingPathComponent("\(id).json")
            if let theme = loadTheme(from: bundleFile) {
                return theme
            }
        }

        // Fallback to compiled presets
        return ThemePresets.allBuiltIn.first { $0.id == id }
    }

    // MARK: - Save User Theme

    static func saveUserTheme(_ theme: ThemeDefinition) throws {
        ensureUserDirectory()
        let url = userThemesDirectory.appendingPathComponent("\(theme.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(theme)
        try data.write(to: url, options: .atomic)
        logger.info("Saved user theme: \(theme.id)")
    }

    // MARK: - Delete User Theme

    static func deleteUserTheme(id: String) throws {
        let url = userThemesDirectory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        logger.info("Deleted user theme: \(id)")
    }

    // MARK: - Save Registry Theme

    static func saveRegistryTheme(_ theme: ThemeDefinition) throws {
        ensureRegistryDirectory()
        let url = registryThemesDirectory.appendingPathComponent("\(theme.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(theme)
        try data.write(to: url, options: .atomic)
        logger.info("Saved registry theme: \(theme.id)")
    }

    // MARK: - Delete Registry Theme

    static func deleteRegistryTheme(id: String) throws {
        let url = registryThemesDirectory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        logger.info("Deleted registry theme: \(id)")
    }

    // MARK: - Registry Meta

    private static let registryMetaURL: URL = {
        registryThemesDirectory.appendingPathComponent("registry-meta.json")
    }()

    static func loadRegistryMeta() -> RegistryThemeMeta {
        guard FileManager.default.fileExists(atPath: registryMetaURL.path) else {
            return RegistryThemeMeta()
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: registryMetaURL)
            return try decoder.decode(RegistryThemeMeta.self, from: data)
        } catch {
            logger.error("Failed to load registry meta: \(error)")
            return RegistryThemeMeta()
        }
    }

    static func saveRegistryMeta(_ meta: RegistryThemeMeta) throws {
        ensureRegistryDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        try data.write(to: registryMetaURL, options: .atomic)
    }

    // MARK: - Import / Export

    static func importTheme(from sourceURL: URL) throws -> ThemeDefinition {
        let data = try Data(contentsOf: sourceURL)
        var theme = try JSONDecoder().decode(ThemeDefinition.self, from: data)

        // Ensure imported themes get a user prefix if they have a built-in ID
        if theme.isBuiltIn || theme.isRegistry {
            theme.id = "user.\(UUID().uuidString.lowercased().prefix(8))"
        }

        try saveUserTheme(theme)
        return theme
    }

    static func exportTheme(_ theme: ThemeDefinition, to destinationURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(theme)
        try data.write(to: destinationURL, options: .atomic)
        logger.info("Exported theme: \(theme.id) to \(destinationURL.lastPathComponent)")
    }

    // MARK: - Active Theme Persistence

    private static let activeThemeKey = "com.TablePro.settings.activeThemeId"

    static func loadActiveThemeId() -> String {
        UserDefaults.standard.string(forKey: activeThemeKey) ?? "tablepro.default-light"
    }

    static func saveActiveThemeId(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeThemeKey)
    }

    // MARK: - Helpers

    private static func ensureUserDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: userThemesDirectory.path) {
            do {
                try fm.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create user themes directory: \(error)")
            }
        }
    }

    private static func ensureRegistryDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: registryThemesDirectory.path) {
            do {
                try fm.createDirectory(at: registryThemesDirectory, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create registry themes directory: \(error)")
            }
        }
    }

    private static func loadThemes(from directory: URL, isBuiltIn: Bool) -> [ThemeDefinition] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        do {
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }

            return files.compactMap { loadTheme(from: $0) }
        } catch {
            logger.error("Failed to list themes in \(directory.lastPathComponent): \(error)")
            return []
        }
    }

    private static func loadTheme(from url: URL) -> ThemeDefinition? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ThemeDefinition.self, from: data)
        } catch {
            logger.error("Failed to load theme from \(url.lastPathComponent): \(error)")
            return nil
        }
    }
}

//
//  ThemeRegistryInstaller.swift
//  TablePro
//
//  Handles install/uninstall/update of themes from the plugin registry.
//  Themes are pure JSON (no executable code, no .tableplugin bundles).
//

import CryptoKit
import Foundation
import os

@MainActor
@Observable
internal final class ThemeRegistryInstaller {
    static let shared = ThemeRegistryInstaller()

    @ObservationIgnored private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeRegistryInstaller")

    private init() {}

    // MARK: - Install

    func install(
        _ plugin: RegistryPlugin,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        if let minAppVersion = plugin.minAppVersion {
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            if appVersion.compare(minAppVersion, options: .numeric) == .orderedAscending {
                throw PluginError.incompatibleWithCurrentApp(minimumRequired: minAppVersion)
            }
        }

        guard !isInstalled(plugin.id) else {
            throw PluginError.pluginConflict(existingName: plugin.name)
        }

        let resolved = try plugin.resolvedBinary()

        guard let downloadURL = URL(string: resolved.url) else {
            throw PluginError.downloadFailed("Invalid download URL")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let session = RegistryClient.shared.session
        let (tempDownloadURL, response) = try await session.download(from: downloadURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PluginError.downloadFailed("HTTP \(statusCode)")
        }

        progress(0.5)

        // Verify SHA-256
        let downloadedData = try Data(contentsOf: tempDownloadURL)
        let digest = SHA256.hash(data: downloadedData)
        let hexChecksum = digest.map { String(format: "%02x", $0) }.joined()

        if hexChecksum != resolved.sha256.lowercased() {
            throw PluginError.checksumMismatch
        }

        progress(0.7)

        // Extract ZIP off main thread
        let extractDir = tempDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let zipPath = tempDir.appendingPathComponent("theme.zip")
        try FileManager.default.moveItem(at: tempDownloadURL, to: zipPath)

        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-xk", zipPath.path, extractDir.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw PluginError.installFailed("Failed to extract theme archive")
            }
        }.value

        // Find all JSON files in extracted directory
        let jsonFiles = try findJsonFiles(in: extractDir)
        guard !jsonFiles.isEmpty else {
            throw PluginError.installFailed("No theme files found in archive")
        }

        progress(0.9)

        // Decode all themes first to validate before writing any files
        let decoder = JSONDecoder()
        var decodedThemes: [ThemeDefinition] = []

        for jsonURL in jsonFiles {
            let data = try Data(contentsOf: jsonURL)
            var theme = try decoder.decode(ThemeDefinition.self, from: data)

            // Rewrite ID to registry namespace using full original ID (dots replaced with hyphens)
            let sanitizedId = theme.id.replacingOccurrences(of: ".", with: "-")
            theme.id = "registry.\(plugin.id).\(sanitizedId)"

            decodedThemes.append(theme)
        }

        // All decoded successfully — now write atomically
        var installedThemes: [InstalledRegistryTheme] = []

        for theme in decodedThemes {
            try ThemeStorage.saveRegistryTheme(theme)

            installedThemes.append(InstalledRegistryTheme(
                id: theme.id,
                registryPluginId: plugin.id,
                version: plugin.version,
                installedDate: Date()
            ))
        }

        // Update meta
        var meta = ThemeStorage.loadRegistryMeta()
        meta.installed.append(contentsOf: installedThemes)
        try ThemeStorage.saveRegistryMeta(meta)

        ThemeEngine.shared.reloadAvailableThemes()
        progress(1.0)

        Self.logger.info("Installed \(installedThemes.count) theme(s) from registry plugin: \(plugin.id)")
    }

    // MARK: - Uninstall

    func uninstall(registryPluginId: String) throws {
        var meta = ThemeStorage.loadRegistryMeta()
        let themesToRemove = meta.installed.filter { $0.registryPluginId == registryPluginId }

        // Update meta first so state is always consistent even if file cleanup fails
        meta.installed.removeAll { $0.registryPluginId == registryPluginId }
        try ThemeStorage.saveRegistryMeta(meta)

        // Best-effort file cleanup
        for entry in themesToRemove {
            do {
                try ThemeStorage.deleteRegistryTheme(id: entry.id)
            } catch {
                Self.logger.warning("Failed to delete registry theme file \(entry.id): \(error)")
            }
        }

        ThemeEngine.shared.reloadAvailableThemes()

        // Fall back if the active theme was uninstalled
        let activeId = ThemeEngine.shared.activeTheme.id
        if themesToRemove.contains(where: { $0.id == activeId }) {
            ThemeEngine.shared.activateTheme(id: "tablepro.default-light")
        }

        Self.logger.info("Uninstalled registry themes for plugin: \(registryPluginId)")
    }

    // MARK: - Update

    func update(
        _ plugin: RegistryPlugin,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let activeId = ThemeEngine.shared.activeTheme.id
        try uninstall(registryPluginId: plugin.id)
        try await install(plugin, progress: progress)

        // Re-activate if the user had a theme from this plugin active
        if ThemeEngine.shared.availableThemes.contains(where: { $0.id == activeId }) {
            ThemeEngine.shared.activateTheme(id: activeId)
        }
    }

    // MARK: - Query

    func isInstalled(_ registryPluginId: String) -> Bool {
        let meta = ThemeStorage.loadRegistryMeta()
        return meta.installed.contains { $0.registryPluginId == registryPluginId }
    }

    func installedVersion(for registryPluginId: String) -> String? {
        let meta = ThemeStorage.loadRegistryMeta()
        return meta.installed.first { $0.registryPluginId == registryPluginId }?.version
    }

    func availableUpdates(manifest: RegistryManifest) -> [RegistryPlugin] {
        let meta = ThemeStorage.loadRegistryMeta()
        let installedVersions = Dictionary(
            meta.installed.map { ($0.registryPluginId, $0.version) },
            uniquingKeysWith: { first, _ in first }
        )

        return manifest.plugins.filter { plugin in
            guard plugin.category == .theme,
                  let installed = installedVersions[plugin.id] else { return false }
            return plugin.version.compare(installed, options: .numeric) == .orderedDescending
        }
    }

    // MARK: - Helpers

    private func findJsonFiles(in directory: URL) throws -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "json" &&
                fileURL.lastPathComponent != "registry-meta.json" {
                results.append(fileURL)
            }
        }

        return results
    }
}

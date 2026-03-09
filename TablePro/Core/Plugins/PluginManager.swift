//
//  PluginManager.swift
//  TablePro
//

import Foundation
import os
import Security
import TableProPluginKit

@MainActor @Observable
final class PluginManager {
    static let shared = PluginManager()
    static let currentPluginKitVersion = 1

    private(set) var plugins: [PluginEntry] = []

    private(set) var driverPlugins: [String: any DriverPlugin] = [:]

    private(set) var exportPlugins: [String: any ExportFormatPlugin] = [:]

    private var builtInPluginsDir: URL? { Bundle.main.builtInPlugInsURL }

    private var userPluginsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TablePro/Plugins", isDirectory: true)
    }

    var disabledPluginIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "disabledPlugins") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "disabledPlugins") }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginManager")

    private init() {}

    // MARK: - Loading

    func loadAllPlugins() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: userPluginsDir.path) {
            do {
                try fm.createDirectory(at: userPluginsDir, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create user plugins directory: \(error.localizedDescription)")
            }
        }

        if let builtInDir = builtInPluginsDir {
            loadPlugins(from: builtInDir, source: .builtIn)
        }

        loadPlugins(from: userPluginsDir, source: .userInstalled)

        Self.logger.info("Loaded \(self.plugins.count) plugin(s): \(self.driverPlugins.count) driver(s), \(self.exportPlugins.count) export format(s)")
    }

    private func loadPlugins(from directory: URL, source: PluginSource) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for itemURL in contents where itemURL.pathExtension == "tableplugin" {
            do {
                _ = try loadPlugin(at: itemURL, source: source)
            } catch {
                Self.logger.error("Failed to load plugin at \(itemURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private func loadPlugin(at url: URL, source: PluginSource) throws -> PluginEntry {
        guard let bundle = Bundle(url: url) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }

        let infoPlist = bundle.infoDictionary ?? [:]

        let pluginKitVersion = infoPlist["TableProPluginKitVersion"] as? Int ?? 0
        if pluginKitVersion > Self.currentPluginKitVersion {
            throw PluginError.incompatibleVersion(
                required: pluginKitVersion,
                current: Self.currentPluginKitVersion
            )
        }

        if let minAppVersion = infoPlist["TableProMinAppVersion"] as? String {
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            if appVersion.compare(minAppVersion, options: .numeric) == .orderedAscending {
                throw PluginError.appVersionTooOld(minimumRequired: minAppVersion, currentApp: appVersion)
            }
        }

        if source == .userInstalled {
            try verifyCodeSignature(bundle: bundle)
        }

        guard bundle.load() else {
            throw PluginError.invalidBundle("Bundle failed to load executable")
        }

        guard let principalClass = bundle.principalClass as? any TableProPlugin.Type else {
            throw PluginError.invalidBundle("Principal class does not conform to TableProPlugin")
        }

        let bundleId = bundle.bundleIdentifier ?? url.lastPathComponent
        let disabled = disabledPluginIds

        let entry = PluginEntry(
            id: bundleId,
            bundle: bundle,
            url: url,
            source: source,
            name: principalClass.pluginName,
            version: principalClass.pluginVersion,
            pluginDescription: principalClass.pluginDescription,
            capabilities: principalClass.capabilities,
            isEnabled: !disabled.contains(bundleId)
        )

        plugins.append(entry)

        if entry.isEnabled {
            let instance = principalClass.init()
            registerCapabilities(instance, pluginId: bundleId)
        }

        Self.logger.info("Loaded plugin '\(entry.name)' v\(entry.version) [\(source == .builtIn ? "built-in" : "user")]")

        return entry
    }

    // MARK: - Capability Registration

    private func registerCapabilities(_ instance: any TableProPlugin, pluginId: String) {
        if let driver = instance as? any DriverPlugin {
            let typeId = type(of: driver).databaseTypeId
            driverPlugins[typeId] = driver
            for additionalId in type(of: driver).additionalDatabaseTypeIds {
                driverPlugins[additionalId] = driver
            }
            Self.logger.debug("Registered driver plugin '\(pluginId)' for database type '\(typeId)'")
        }

        if let exportPlugin = instance as? any ExportFormatPlugin {
            let formatId = type(of: exportPlugin).formatId
            exportPlugins[formatId] = exportPlugin
            Self.logger.debug("Registered export plugin '\(pluginId)' for format '\(formatId)'")
        }
    }

    private func unregisterCapabilities(pluginId: String) {
        driverPlugins = driverPlugins.filter { _, value in
            guard let entry = plugins.first(where: { $0.id == pluginId }) else { return true }
            if let principalClass = entry.bundle.principalClass as? any DriverPlugin.Type {
                let allTypeIds = Set([principalClass.databaseTypeId] + principalClass.additionalDatabaseTypeIds)
                return !allTypeIds.contains(type(of: value).databaseTypeId)
            }
            return true
        }

        exportPlugins = exportPlugins.filter { _, value in
            guard let entry = plugins.first(where: { $0.id == pluginId }) else { return true }
            if let principalClass = entry.bundle.principalClass as? any ExportFormatPlugin.Type {
                return principalClass.formatId != type(of: value).formatId
            }
            return true
        }
    }

    // MARK: - Enable / Disable

    func setEnabled(_ enabled: Bool, pluginId: String) {
        guard let index = plugins.firstIndex(where: { $0.id == pluginId }) else { return }

        plugins[index].isEnabled = enabled

        var disabled = disabledPluginIds
        if enabled {
            disabled.remove(pluginId)
        } else {
            disabled.insert(pluginId)
        }
        disabledPluginIds = disabled

        if enabled {
            if let principalClass = plugins[index].bundle.principalClass as? any TableProPlugin.Type {
                let instance = principalClass.init()
                registerCapabilities(instance, pluginId: pluginId)
            }
        } else {
            unregisterCapabilities(pluginId: pluginId)
        }

        Self.logger.info("Plugin '\(pluginId)' \(enabled ? "enabled" : "disabled")")
    }

    // MARK: - Install / Uninstall

    func installPlugin(from zipURL: URL) async throws -> PluginEntry {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, tempDir.path]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PluginError.installFailed(
                        "Failed to extract archive (ditto exit code \(proc.terminationStatus))"
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        guard let extracted = try fm.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first(where: { $0.pathExtension == "tableplugin" }) else {
            throw PluginError.installFailed("No .tableplugin bundle found in archive")
        }

        guard let extractedBundle = Bundle(url: extracted) else {
            throw PluginError.invalidBundle("Cannot create bundle from extracted plugin")
        }

        try verifyCodeSignature(bundle: extractedBundle)

        let newBundleId = extractedBundle.bundleIdentifier ?? extracted.lastPathComponent
        if let existing = plugins.first(where: { $0.id == newBundleId }), existing.source == .builtIn {
            throw PluginError.pluginConflict(existingName: existing.name)
        }

        let destURL = userPluginsDir.appendingPathComponent(extracted.lastPathComponent)

        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }
        try fm.copyItem(at: extracted, to: destURL)

        let entry = try loadPlugin(at: destURL, source: .userInstalled)

        Self.logger.info("Installed plugin '\(entry.name)' v\(entry.version)")
        return entry
    }

    func uninstallPlugin(id: String) throws {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else {
            throw PluginError.notFound
        }

        let entry = plugins[index]

        guard entry.source == .userInstalled else {
            throw PluginError.cannotUninstallBuiltIn
        }

        unregisterCapabilities(pluginId: id)
        entry.bundle.unload()
        plugins.remove(at: index)

        let fm = FileManager.default
        if fm.fileExists(atPath: entry.url.path) {
            try fm.removeItem(at: entry.url)
        }

        var disabled = disabledPluginIds
        disabled.remove(id)
        disabledPluginIds = disabled

        Self.logger.info("Uninstalled plugin '\(id)'")
    }

    // MARK: - Code Signature Verification

    // TODO: Replace with actual team identifier
    private static let signingTeamId = "YOURTEAMID"

    private func createSigningRequirement() -> SecRequirement? {
        var requirement: SecRequirement?
        let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"\(Self.signingTeamId)\"" as CFString
        SecRequirementCreateWithString(requirementString, SecCSFlags(), &requirement)
        return requirement
    }

    private func verifyCodeSignature(bundle: Bundle) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            bundle.bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        )

        guard createStatus == errSecSuccess, let code = staticCode else {
            throw PluginError.signatureInvalid(
                detail: Self.describeOSStatus(createStatus)
            )
        }

        let requirement = createSigningRequirement()

        let checkStatus = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            requirement
        )

        guard checkStatus == errSecSuccess else {
            throw PluginError.signatureInvalid(
                detail: Self.describeOSStatus(checkStatus)
            )
        }
    }

    private static func describeOSStatus(_ status: OSStatus) -> String {
        switch status {
        case -67_062: return "bundle is not signed"
        case -67_061: return "code signature is invalid"
        case -67_030: return "code signature has been modified or corrupted"
        case -67_013: return "signing certificate has expired"
        case -67_058: return "code signature is missing required fields"
        case -67_028: return "resource envelope has been modified"
        default: return "verification failed (OSStatus \(status))"
        }
    }
}

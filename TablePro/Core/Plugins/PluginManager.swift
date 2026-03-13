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
    private static let disabledPluginsKey = "com.TablePro.disabledPlugins"
    private static let legacyDisabledPluginsKey = "disabledPlugins"

    private(set) var plugins: [PluginEntry] = []

    private(set) var isInstalling = false

    private static let needsRestartKey = "com.TablePro.needsRestart"

    private var _needsRestart: Bool = UserDefaults.standard.bool(
        forKey: needsRestartKey
    ) {
        didSet { UserDefaults.standard.set(_needsRestart, forKey: Self.needsRestartKey) }
    }

    var needsRestart: Bool { _needsRestart }

    private(set) var driverPlugins: [String: any DriverPlugin] = [:]

    private(set) var exportPlugins: [String: any ExportFormatPlugin] = [:]

    private(set) var importPlugins: [String: any ImportFormatPlugin] = [:]

    private(set) var pluginInstances: [String: any TableProPlugin] = [:]

    private var builtInPluginsDir: URL? { Bundle.main.builtInPlugInsURL }

    private var userPluginsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TablePro/Plugins", isDirectory: true)
    }

    var disabledPluginIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.disabledPluginsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.disabledPluginsKey) }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginManager")

    private var pendingPluginURLs: [(url: URL, source: PluginSource)] = []

    private init() {}

    private func migrateDisabledPluginsKey() {
        let defaults = UserDefaults.standard
        if let legacy = defaults.stringArray(forKey: Self.legacyDisabledPluginsKey) {
            if defaults.stringArray(forKey: Self.disabledPluginsKey) == nil {
                defaults.set(legacy, forKey: Self.disabledPluginsKey)
            }
            defaults.removeObject(forKey: Self.legacyDisabledPluginsKey)
        }
    }

    // MARK: - Loading

    /// Discover and load all plugins. Discovery is synchronous (reads Info.plist),
    /// then bundle loading is deferred to the next run loop iteration so it doesn't block app launch.
    func loadPlugins() {
        migrateDisabledPluginsKey()
        discoverAllPlugins()
        Task { @MainActor in
            self.loadPendingPlugins(clearRestartFlag: true)
        }
    }

    private func discoverAllPlugins() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: userPluginsDir.path) {
            do {
                try fm.createDirectory(at: userPluginsDir, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create user plugins directory: \(error.localizedDescription)")
            }
        }

        if let builtInDir = builtInPluginsDir {
            discoverPlugins(from: builtInDir, source: .builtIn)
        }

        discoverPlugins(from: userPluginsDir, source: .userInstalled)

        Self.logger.info("Discovered \(self.pendingPluginURLs.count) plugin(s), will load on first use")
    }

    /// Load all discovered but not-yet-loaded plugin bundles.
    /// Safety fallback for code paths that need plugins before the deferred Task completes.
    func loadPendingPlugins(clearRestartFlag: Bool = false) {
        guard !pendingPluginURLs.isEmpty else { return }
        let pending = pendingPluginURLs
        pendingPluginURLs.removeAll()

        for entry in pending {
            do {
                try loadPlugin(at: entry.url, source: entry.source)
            } catch {
                Self.logger.error("Failed to load plugin at \(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        validateDependencies()
        if clearRestartFlag {
            _needsRestart = false
        }
        Self.logger.info("Loaded \(self.plugins.count) plugin(s): \(self.driverPlugins.count) driver(s), \(self.exportPlugins.count) export format(s), \(self.importPlugins.count) import format(s)")
    }

    private func discoverPlugins(from directory: URL, source: PluginSource) {
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
                try discoverPlugin(at: itemURL, source: source)
            } catch {
                Self.logger.error("Failed to discover plugin at \(itemURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func discoverPlugin(at url: URL, source: PluginSource) throws {
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

        pendingPluginURLs.append((url: url, source: source))
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
        validateCapabilityDeclarations(principalClass, pluginId: bundleId)

        if entry.isEnabled {
            let instance = principalClass.init()
            registerCapabilities(instance, pluginId: bundleId)
        }

        Self.logger.info("Loaded plugin '\(entry.name)' v\(entry.version) [\(source == .builtIn ? "built-in" : "user")]")

        return entry
    }

    // MARK: - Capability Registration

    private func registerCapabilities(_ instance: any TableProPlugin, pluginId: String) {
        pluginInstances[pluginId] = instance
        let declared = Set(type(of: instance).capabilities)

        if let driver = instance as? any DriverPlugin {
            if !declared.contains(.databaseDriver) {
                Self.logger.warning("Plugin '\(pluginId)' conforms to DriverPlugin but does not declare .databaseDriver capability — registering anyway")
            }
            let typeId = type(of: driver).databaseTypeId
            driverPlugins[typeId] = driver
            for additionalId in type(of: driver).additionalDatabaseTypeIds {
                driverPlugins[additionalId] = driver
            }
            Self.logger.debug("Registered driver plugin '\(pluginId)' for database type '\(typeId)'")
        }

        if let exportPlugin = instance as? any ExportFormatPlugin {
            if !declared.contains(.exportFormat) {
                Self.logger.warning("Plugin '\(pluginId)' conforms to ExportFormatPlugin but does not declare .exportFormat capability — registering anyway")
            }
            let formatId = type(of: exportPlugin).formatId
            exportPlugins[formatId] = exportPlugin
            Self.logger.debug("Registered export plugin '\(pluginId)' for format '\(formatId)'")
        }

        if let importPlugin = instance as? any ImportFormatPlugin {
            if !declared.contains(.importFormat) {
                Self.logger.warning("Plugin '\(pluginId)' conforms to ImportFormatPlugin but does not declare .importFormat capability — registering anyway")
            }
            let formatId = type(of: importPlugin).formatId
            importPlugins[formatId] = importPlugin
            Self.logger.debug("Registered import plugin '\(pluginId)' for format '\(formatId)'")
        }
    }

    private func validateCapabilityDeclarations(_ pluginType: any TableProPlugin.Type, pluginId: String) {
        let declared = Set(pluginType.capabilities)
        let isDriver = pluginType is any DriverPlugin.Type
        let isExporter = pluginType is any ExportFormatPlugin.Type
        let isImporter = pluginType is any ImportFormatPlugin.Type

        if declared.contains(.databaseDriver) && !isDriver {
            Self.logger.warning("Plugin '\(pluginId)' declares .databaseDriver but does not conform to DriverPlugin")
        }
        if declared.contains(.exportFormat) && !isExporter {
            Self.logger.warning("Plugin '\(pluginId)' declares .exportFormat but does not conform to ExportFormatPlugin")
        }
        if declared.contains(.importFormat) && !isImporter {
            Self.logger.warning("Plugin '\(pluginId)' declares .importFormat but does not conform to ImportFormatPlugin")
        }
    }

    private func replaceExistingPlugin(bundleId: String) {
        guard let existingIndex = plugins.firstIndex(where: { $0.id == bundleId }) else { return }
        // Order matters: unregisterCapabilities reads from `plugins` to find the principal class
        unregisterCapabilities(pluginId: bundleId)
        plugins[existingIndex].bundle.unload()
        plugins.remove(at: existingIndex)
    }

    private func unregisterCapabilities(pluginId: String) {
        pluginInstances.removeValue(forKey: pluginId)
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

        importPlugins = importPlugins.filter { _, value in
            guard let entry = plugins.first(where: { $0.id == pluginId }) else { return true }
            if let principalClass = entry.bundle.principalClass as? any ImportFormatPlugin.Type {
                return principalClass.formatId != type(of: value).formatId
            }
            return true
        }
    }

    // MARK: - Available Database Types

    /// All database types with loaded plugins, ordered by display name.
    var availableDatabaseTypes: [DatabaseType] {
        var types: [DatabaseType] = []
        for entry in plugins where entry.isEnabled {
            if let typeId = entry.databaseTypeId {
                types.append(DatabaseType(rawValue: typeId))
            }
            for additionalId in entry.additionalTypeIds {
                types.append(DatabaseType(rawValue: additionalId))
            }
        }
        return types.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Driver Availability

    func isDriverAvailable(for databaseType: DatabaseType) -> Bool {
        // Safety fallback: loads pending plugins if the deferred startup Task hasn't completed yet
        loadPendingPlugins()
        return driverPlugins[databaseType.pluginTypeId] != nil
    }

    func isDriverLoaded(for databaseType: DatabaseType) -> Bool {
        driverPlugins[databaseType.pluginTypeId] != nil
    }

    func sqlDialect(for databaseType: DatabaseType) -> SQLDialectDescriptor? {
        loadPendingPlugins()
        guard let plugin = driverPlugins[databaseType.pluginTypeId] else { return nil }
        return Swift.type(of: plugin).sqlDialect
    }

    func statementCompletions(for databaseType: DatabaseType) -> [CompletionEntry] {
        loadPendingPlugins()
        guard let plugin = driverPlugins[databaseType.pluginTypeId] else { return [] }
        return Swift.type(of: plugin).statementCompletions
    }

    func additionalConnectionFields(for databaseType: DatabaseType) -> [ConnectionField] {
        loadPendingPlugins()
        guard let plugin = driverPlugins[databaseType.pluginTypeId] else { return [] }
        return Swift.type(of: plugin).additionalConnectionFields
    }

    func installMissingPlugin(
        for databaseType: DatabaseType,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let pluginTypeId = databaseType.pluginTypeId

        if let existingEntry = plugins.first(where: { entry in
            entry.databaseTypeId == pluginTypeId || entry.additionalTypeIds.contains(pluginTypeId)
        }) {
            if !existingEntry.isEnabled {
                setEnabled(true, pluginId: existingEntry.id)
                loadPendingPlugins()
            }
            if driverPlugins[pluginTypeId] != nil {
                Self.logger.info("Re-enabled existing plugin '\(existingEntry.name)' for '\(databaseType.rawValue)'")
                return
            }
            Self.logger.warning("Plugin '\(existingEntry.id)' exists but driver not registered, reinstalling")
            if existingEntry.source == .userInstalled {
                try? uninstallPlugin(id: existingEntry.id)
            }
        }

        let registryClient = RegistryClient.shared
        await registryClient.fetchManifest()

        guard let manifest = registryClient.manifest else {
            throw PluginError.downloadFailed(String(localized: "Could not fetch plugin registry"))
        }

        guard let registryPlugin = manifest.plugins.first(where: { plugin in
            plugin.databaseTypeIds?.contains(pluginTypeId) == true
        }) else {
            throw PluginError.notFound
        }

        let entry = try await installFromRegistry(registryPlugin, progress: progress)
        Self.logger.info("Installed missing plugin '\(entry.name)' for database type '\(databaseType.rawValue)'")
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

    func installPlugin(from url: URL) async throws -> PluginEntry {
        guard !isInstalling else {
            throw PluginError.installFailed("Another plugin installation is already in progress")
        }
        isInstalling = true
        defer { isInstalling = false }

        if url.pathExtension == "tableplugin" {
            return try installBundle(from: url)
        } else {
            return try await installFromZip(from: url)
        }
    }

    private func installBundle(from url: URL) throws -> PluginEntry {
        guard let sourceBundle = Bundle(url: url) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }

        try verifyCodeSignature(bundle: sourceBundle)

        let newBundleId = sourceBundle.bundleIdentifier ?? url.lastPathComponent
        if let existing = plugins.first(where: { $0.id == newBundleId }), existing.source == .builtIn {
            throw PluginError.pluginConflict(existingName: existing.name)
        }

        replaceExistingPlugin(bundleId: newBundleId)

        let fm = FileManager.default
        let destURL = userPluginsDir.appendingPathComponent(url.lastPathComponent)

        if url.standardizedFileURL != destURL.standardizedFileURL {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: url, to: destURL)
        }

        let entry = try loadPlugin(at: destURL, source: .userInstalled)

        Self.logger.info("Installed plugin '\(entry.name)' v\(entry.version)")
        return entry
    }

    private func installFromZip(from url: URL) async throws -> PluginEntry {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", url.path, tempDir.path]

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

        let extractedBundles = try fm.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "tableplugin" }

        guard !extractedBundles.isEmpty else {
            throw PluginError.installFailed("No .tableplugin bundle found in archive")
        }

        var lastEntry: PluginEntry?
        for extracted in extractedBundles {
            guard let extractedBundle = Bundle(url: extracted) else {
                throw PluginError.invalidBundle("Cannot create bundle from extracted plugin '\(extracted.lastPathComponent)'")
            }

            try verifyCodeSignature(bundle: extractedBundle)

            let newBundleId = extractedBundle.bundleIdentifier ?? extracted.lastPathComponent
            if let existing = plugins.first(where: { $0.id == newBundleId }), existing.source == .builtIn {
                throw PluginError.pluginConflict(existingName: existing.name)
            }

            replaceExistingPlugin(bundleId: newBundleId)

            let destURL = userPluginsDir.appendingPathComponent(extracted.lastPathComponent)

            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: extracted, to: destURL)

            let entry = try loadPlugin(at: destURL, source: .userInstalled)
            Self.logger.info("Installed plugin '\(entry.name)' v\(entry.version)")
            lastEntry = entry
        }

        guard let entry = lastEntry else {
            throw PluginError.installFailed("No .tableplugin bundle found in archive")
        }
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

        PluginSettingsStorage(pluginId: id).removeAll()

        var disabled = disabledPluginIds
        disabled.remove(id)
        disabledPluginIds = disabled

        Self.logger.info("Uninstalled plugin '\(id)'")
        _needsRestart = true
    }

    // MARK: - Dependency Validation

    private func validateDependencies() {
        let loadedIds = Set(plugins.map(\.id))
        for plugin in plugins where plugin.isEnabled {
            guard let principalClass = plugin.bundle.principalClass as? any TableProPlugin.Type else { continue }
            let deps = principalClass.dependencies
            for dep in deps {
                if !loadedIds.contains(dep) {
                    Self.logger.warning("Plugin '\(plugin.id)' requires '\(dep)' which is not installed")
                } else if let depEntry = plugins.first(where: { $0.id == dep }), !depEntry.isEnabled {
                    Self.logger.warning("Plugin '\(plugin.id)' requires '\(dep)' which is disabled")
                }
            }
        }
    }

    // MARK: - Code Signature Verification

    private static let signingTeamId = "D7HJ5TFYCU"

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

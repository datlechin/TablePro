//
//  SyncCoordinator.swift
//  TablePro
//
//  Central coordinator for iCloud sync operations.
//  Bridges between local storage singletons and the sync engine.
//

import Combine
import Foundation
import os

/// Coordinates sync between local storage and iCloud
@MainActor
final class SyncCoordinator: ObservableObject {
    static let shared = SyncCoordinator()

    // MARK: - Published State

    @Published private(set) var isEnabled = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published var pendingConflicts: [SyncConflict] = []

    // MARK: - Private

    private let engine: SyncEngine
    private let deviceId: String
    private let deviceName: String
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Flag to prevent push when applying remote data
    private(set) var isSyncingFromRemote = false

    private static let logger = Logger(subsystem: "com.TablePro", category: "Sync")

    // MARK: - Sync Keys (stored in NSUbiquitousKeyValueStore)

    private enum SyncKey {
        static let connections = "sync.connections"
        static let tags = "sync.tags"
        static let settingsGeneral = "sync.settings.general"
        static let settingsAppearance = "sync.settings.appearance"
        static let settingsEditor = "sync.settings.editor"
        static let settingsDataGrid = "sync.settings.dataGrid"
        static let settingsHistory = "sync.settings.history"
        static let templates = "sync.templates"

        /// Map sync keys to data types
        static func dataType(for key: String) -> SyncDataType? {
            switch key {
            case connections: return .connections
            case tags: return .tags
            case settingsGeneral: return .generalSettings
            case settingsAppearance: return .appearanceSettings
            case settingsEditor: return .editorSettings
            case settingsDataGrid: return .dataGridSettings
            case settingsHistory: return .historySettings
            case templates: return .templates
            default: return nil
            }
        }

        /// All sync keys
        static let all = [
            connections, tags,
            settingsGeneral, settingsAppearance, settingsEditor, settingsDataGrid, settingsHistory,
            templates,
        ]
    }

    /// Keys for tracking last-synced state (stored locally in UserDefaults)
    private enum LocalKey {
        static let prefix = "com.TablePro.sync.lastSynced."
        static let lastSyncDate = "com.TablePro.sync.lastSyncDate"
        static let deviceId = "com.TablePro.sync.deviceId"

        static func lastSynced(for syncKey: String) -> String {
            prefix + syncKey
        }
    }

    // MARK: - Initialization

    init(engine: SyncEngine = ICloudSyncEngine()) {
        self.engine = engine
        self.deviceId = Self.loadOrCreateDeviceId()
        self.deviceName = Host.current().localizedName ?? "Unknown Mac"

        // Load last sync date
        if let timestamp = defaults.object(forKey: LocalKey.lastSyncDate) as? Date {
            self.lastSyncDate = timestamp
        }
    }

    // MARK: - Enable / Disable

    /// Enable iCloud sync and perform initial push
    func enable() {
        guard engine.isAvailable else {
            Self.logger.warning("Cannot enable sync: iCloud unavailable")
            return
        }

        isEnabled = true
        engine.startObserving { [weak self] changedKeys in
            Task { @MainActor in
                self?.handleRemoteChanges(changedKeys)
            }
        }

        // Push all local data to iCloud
        performInitialPush()

        Self.logger.info("iCloud sync enabled")
    }

    /// Disable iCloud sync
    func disable() {
        isEnabled = false
        engine.stopObserving()
        pendingConflicts.removeAll()
        Self.logger.info("iCloud sync disabled")
    }

    // MARK: - Push Methods (called by storage layers)

    /// Called when connections are saved locally
    func didUpdateConnections(_ connections: [DatabaseConnection]) {
        guard isEnabled, !isSyncingFromRemote else { return }
        pushData(connections, forKey: SyncKey.connections)
    }

    /// Called when tags are saved locally
    func didUpdateTags(_ tags: [ConnectionTag]) {
        guard isEnabled, !isSyncingFromRemote else { return }
        pushData(tags, forKey: SyncKey.tags)
    }

    /// Called when general settings are saved locally
    func didUpdateGeneralSettings(_ settings: GeneralSettings) {
        guard isEnabled, !isSyncingFromRemote else { return }
        // Strip iCloudSyncEnabled to prevent sync loop
        var syncable = settings
        syncable.iCloudSyncEnabled = false
        pushData(syncable, forKey: SyncKey.settingsGeneral)
    }

    /// Called when appearance settings are saved locally
    func didUpdateAppearanceSettings(_ settings: AppearanceSettings) {
        guard isEnabled, !isSyncingFromRemote else { return }
        pushData(settings, forKey: SyncKey.settingsAppearance)
    }

    /// Called when editor settings are saved locally
    func didUpdateEditorSettings(_ settings: EditorSettings) {
        guard isEnabled, !isSyncingFromRemote else { return }
        pushData(settings, forKey: SyncKey.settingsEditor)
    }

    /// Called when data grid settings are saved locally
    func didUpdateDataGridSettings(_ settings: DataGridSettings) {
        guard isEnabled, !isSyncingFromRemote else { return }
        pushData(settings, forKey: SyncKey.settingsDataGrid)
    }

    /// Called when history settings are saved locally
    func didUpdateHistorySettings(_ settings: HistorySettings) {
        guard isEnabled, !isSyncingFromRemote else { return }
        pushData(settings, forKey: SyncKey.settingsHistory)
    }

    /// Called when table templates are saved locally
    func didUpdateTemplates(_ templates: [String: TableCreationOptions]) {
        guard isEnabled, !isSyncingFromRemote else { return }
        pushData(templates, forKey: SyncKey.templates)
    }

    // MARK: - Conflict Resolution

    /// Resolve a pending conflict with the user's choice
    func resolveConflict(_ conflict: SyncConflict, resolution: ConflictResolution) {
        switch resolution {
        case .keepLocal:
            // Re-push local data to overwrite remote
            repushLocalData(forKey: conflict.syncKey)

        case .keepRemote:
            // Apply remote data locally
            applyRemoteData(conflict.remoteData, forKey: conflict.syncKey)
        }

        pendingConflicts.removeAll { $0.id == conflict.id }
        Self.logger.info("Resolved conflict for \(conflict.syncKey): \(String(describing: resolution))")
    }

    // MARK: - Private: Push

    private func pushData<T: Codable>(_ value: T, forKey key: String) {
        do {
            let payload = try encoder.encode(value)
            let envelope = SyncEnvelope(
                payload: payload,
                modifiedAt: Date(),
                deviceId: deviceId,
                deviceName: deviceName
            )
            let data = try encoder.encode(envelope)
            engine.write(data, forKey: key)
            engine.synchronize()

            // Save last-synced state locally for conflict detection
            saveLastSyncedData(payload, forKey: key)
            updateLastSyncDate()

            Self.logger.debug("Pushed \(key) to iCloud")
        } catch {
            Self.logger.error("Failed to push \(key): \(error.localizedDescription)")
        }
    }

    private func performInitialPush() {
        isSyncing = true
        defer { isSyncing = false }

        // Push connections
        let connections = ConnectionStorage.shared.loadConnections()
        pushData(connections, forKey: SyncKey.connections)

        // Push tags
        let tags = TagStorage.shared.loadTags()
        pushData(tags, forKey: SyncKey.tags)

        // Push settings (strip iCloudSyncEnabled)
        let settingsManager = AppSettingsManager.shared
        var generalSettings = settingsManager.general
        generalSettings.iCloudSyncEnabled = false
        pushData(generalSettings, forKey: SyncKey.settingsGeneral)
        pushData(settingsManager.appearance, forKey: SyncKey.settingsAppearance)
        pushData(settingsManager.editor, forKey: SyncKey.settingsEditor)
        pushData(settingsManager.dataGrid, forKey: SyncKey.settingsDataGrid)
        pushData(settingsManager.history, forKey: SyncKey.settingsHistory)

        // Push templates
        if let templates = try? TableTemplateStorage.shared.loadTemplates() {
            pushData(templates, forKey: SyncKey.templates)
        }

        Self.logger.info("Initial push completed")
    }

    private func repushLocalData(forKey key: String) {
        switch key {
        case SyncKey.connections:
            let connections = ConnectionStorage.shared.loadConnections()
            pushData(connections, forKey: key)
        case SyncKey.tags:
            let tags = TagStorage.shared.loadTags()
            pushData(tags, forKey: key)
        case SyncKey.settingsGeneral:
            var settings = AppSettingsManager.shared.general
            settings.iCloudSyncEnabled = false
            pushData(settings, forKey: key)
        case SyncKey.settingsAppearance:
            pushData(AppSettingsManager.shared.appearance, forKey: key)
        case SyncKey.settingsEditor:
            pushData(AppSettingsManager.shared.editor, forKey: key)
        case SyncKey.settingsDataGrid:
            pushData(AppSettingsManager.shared.dataGrid, forKey: key)
        case SyncKey.settingsHistory:
            pushData(AppSettingsManager.shared.history, forKey: key)
        case SyncKey.templates:
            if let templates = try? TableTemplateStorage.shared.loadTemplates() {
                pushData(templates, forKey: key)
            }
        default:
            break
        }
    }

    // MARK: - Private: Pull / Merge

    private func handleRemoteChanges(_ changedKeys: [String]) {
        guard isEnabled else { return }

        for key in changedKeys {
            guard SyncKey.dataType(for: key) != nil else { continue }
            processRemoteChange(forKey: key)
        }
    }

    private func processRemoteChange(forKey key: String) {
        guard let data = engine.read(forKey: key) else { return }

        do {
            let envelope = try decoder.decode(SyncEnvelope.self, from: data)

            // Ignore our own changes echoed back
            guard envelope.deviceId != deviceId else { return }

            // Load last-synced state to detect if local has changed
            let lastSyncedData = loadLastSyncedData(forKey: key)
            let currentLocalData = loadCurrentLocalData(forKey: key)

            if let currentLocalData, envelope.payload != currentLocalData {
                // Local and remote data differ
                let localChanged = lastSyncedData == nil || currentLocalData != lastSyncedData

                if localChanged {
                    // Local modified since last sync (or first sync with existing data) → conflict
                    guard let dataType = SyncKey.dataType(for: key) else { return }

                    let conflict = SyncConflict(
                        syncKey: key,
                        dataType: dataType,
                        remoteTimestamp: envelope.modifiedAt,
                        remoteDeviceName: envelope.deviceName,
                        remoteData: envelope.payload
                    )
                    pendingConflicts.append(conflict)
                    Self.logger.info("Conflict detected for \(key)")
                    return
                }
            }

            // No conflict: auto-apply remote data
            applyRemoteData(envelope.payload, forKey: key)
            saveLastSyncedData(envelope.payload, forKey: key)
            updateLastSyncDate()

            Self.logger.debug("Auto-applied remote \(key)")
        } catch {
            Self.logger.error("Failed to decode remote \(key): \(error.localizedDescription)")
        }
    }

    private func applyRemoteData(_ payload: Data, forKey key: String) {
        // Set flag to prevent AppSettingsManager didSet hooks from pushing back
        isSyncingFromRemote = true
        defer { isSyncingFromRemote = false }

        do {
            switch key {
            case SyncKey.connections:
                let connections = try decoder.decode([DatabaseConnection].self, from: payload)
                ConnectionStorage.shared.saveConnections(connections, triggeredBySync: true)
                NotificationCenter.default.post(name: .iCloudSyncDidUpdateData, object: nil)

            case SyncKey.tags:
                let tags = try decoder.decode([ConnectionTag].self, from: payload)
                TagStorage.shared.saveTags(tags, triggeredBySync: true)
                NotificationCenter.default.post(name: .iCloudSyncDidUpdateData, object: nil)

            case SyncKey.settingsGeneral:
                var settings = try decoder.decode(GeneralSettings.self, from: payload)
                // Preserve local iCloudSyncEnabled toggle
                settings.iCloudSyncEnabled = AppSettingsManager.shared.general.iCloudSyncEnabled
                AppSettingsManager.shared.general = settings

            case SyncKey.settingsAppearance:
                let settings = try decoder.decode(AppearanceSettings.self, from: payload)
                AppSettingsManager.shared.appearance = settings

            case SyncKey.settingsEditor:
                let settings = try decoder.decode(EditorSettings.self, from: payload)
                AppSettingsManager.shared.editor = settings

            case SyncKey.settingsDataGrid:
                let settings = try decoder.decode(DataGridSettings.self, from: payload)
                AppSettingsManager.shared.dataGrid = settings

            case SyncKey.settingsHistory:
                let settings = try decoder.decode(HistorySettings.self, from: payload)
                AppSettingsManager.shared.history = settings

            case SyncKey.templates:
                let templates = try decoder.decode([String: TableCreationOptions].self, from: payload)
                for (name, options) in templates {
                    try TableTemplateStorage.shared.saveTemplate(
                        name: name, options: options, triggeredBySync: true
                    )
                }

            default:
                break
            }
        } catch {
            Self.logger.error("Failed to apply remote \(key): \(error.localizedDescription)")
        }

        saveLastSyncedData(payload, forKey: key)
    }

    // MARK: - Private: Local State Tracking

    /// Save what we last synced for three-way conflict detection
    private func saveLastSyncedData(_ data: Data, forKey key: String) {
        defaults.set(data, forKey: LocalKey.lastSynced(for: key))
    }

    /// Load last-synced state for conflict detection
    private func loadLastSyncedData(forKey key: String) -> Data? {
        defaults.data(forKey: LocalKey.lastSynced(for: key))
    }

    /// Load current local data for a sync key (for conflict comparison)
    private func loadCurrentLocalData(forKey key: String) -> Data? {
        do {
            switch key {
            case SyncKey.connections:
                let connections = ConnectionStorage.shared.loadConnections()
                return try encoder.encode(connections)
            case SyncKey.tags:
                let tags = TagStorage.shared.loadTags()
                return try encoder.encode(tags)
            case SyncKey.settingsGeneral:
                var settings = AppSettingsManager.shared.general
                settings.iCloudSyncEnabled = false
                return try encoder.encode(settings)
            case SyncKey.settingsAppearance:
                return try encoder.encode(AppSettingsManager.shared.appearance)
            case SyncKey.settingsEditor:
                return try encoder.encode(AppSettingsManager.shared.editor)
            case SyncKey.settingsDataGrid:
                return try encoder.encode(AppSettingsManager.shared.dataGrid)
            case SyncKey.settingsHistory:
                return try encoder.encode(AppSettingsManager.shared.history)
            case SyncKey.templates:
                let templates = try TableTemplateStorage.shared.loadTemplates()
                return try encoder.encode(templates)
            default:
                return nil
            }
        } catch {
            Self.logger.error("Failed to load local data for \(key): \(error.localizedDescription)")
            return nil
        }
    }

    private func updateLastSyncDate() {
        lastSyncDate = Date()
        defaults.set(lastSyncDate, forKey: LocalKey.lastSyncDate)
    }

    // MARK: - Private: Device ID

    private static func loadOrCreateDeviceId() -> String {
        let key = LocalKey.deviceId
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}

// MARK: - Sync Notification

internal extension Notification.Name {
    /// Posted when iCloud sync applies remote data that changes local storage
    static let iCloudSyncDidUpdateData = Notification.Name("iCloudSyncDidUpdateData")
}

//
//  SyncCoordinator.swift
//  TablePro
//
//  Orchestrates sync: license gating, scheduling, push/pull coordination
//

import CloudKit
import Foundation
import Observation
import os

/// Central coordinator for iCloud sync
@MainActor @Observable
final class SyncCoordinator {
    static let shared = SyncCoordinator()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncCoordinator")

    private(set) var syncStatus: SyncStatus = .disabled(.userDisabled)
    private(set) var lastSyncDate: Date?
    private(set) var iCloudAccountAvailable: Bool = false

    @ObservationIgnored private let engine = CloudKitSyncEngine()
    @ObservationIgnored private let changeTracker = SyncChangeTracker.shared
    @ObservationIgnored private let metadataStorage = SyncMetadataStorage.shared
    @ObservationIgnored private let conflictResolver = ConflictResolver.shared
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    private init() {
        lastSyncDate = metadataStorage.lastSyncDate
    }

    deinit {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        syncTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Call from AppDelegate at launch
    func start() {
        observeAccountChanges()
        observeLocalChanges()

        // If local storage is empty (fresh install or wiped), clear the sync token
        // to force a full fetch instead of a delta that returns nothing
        if ConnectionStorage.shared.loadConnections().isEmpty {
            metadataStorage.clearSyncToken()
            Self.logger.info("No local connections — cleared sync token for full fetch")
        }

        Task {
            await checkAccountStatus()
            evaluateStatus()

            if syncStatus.isEnabled {
                await syncNow()
            }
        }
    }

    /// Called when the app comes to the foreground
    func syncIfNeeded() {
        guard syncStatus.isEnabled, !syncStatus.isSyncing else { return }

        Task {
            await syncNow()
        }
    }

    /// Manual full sync (push then pull)
    func syncNow() async {
        guard canSync() else {
            print("[Sync] syncNow: canSync() returned false, skipping")
            return
        }

        syncStatus = .syncing

        do {
            try await engine.ensureZoneExists()
            await performPush()
            await performPull()

            lastSyncDate = Date()
            metadataStorage.lastSyncDate = lastSyncDate
            syncStatus = .idle

            Self.logger.info("Sync completed successfully")
        } catch {
            let syncError = SyncError.from(error)
            syncStatus = .error(syncError)
            Self.logger.error("Sync failed: \(error.localizedDescription)")
        }
    }

    /// Triggered by remote push notification
    func handleRemoteNotification() {
        guard syncStatus.isEnabled else { return }

        Task {
            await performPull()
        }
    }

    /// Called when user enables sync in settings
    func enableSync() {
        print("[Sync] enableSync() called")

        // Clear token to force a full fetch on first sync after enabling
        metadataStorage.clearSyncToken()

        // Mark ALL existing local data as dirty so it gets pushed on first sync
        markAllLocalDataDirty()
        print("[Sync] enableSync() dirty marking done, dirty connections: \(changeTracker.dirtyRecords(for: .connection))")

        Task {
            await checkAccountStatus()
            evaluateStatus()

            if syncStatus.isEnabled {
                await syncNow()
            }
        }
    }

    /// Marks all existing local data as dirty so it will be pushed on the next sync.
    /// Called when sync is first enabled to upload existing connections/groups/tags/settings.
    private func markAllLocalDataDirty() {
        let connections = ConnectionStorage.shared.loadConnections()
        for connection in connections {
            changeTracker.markDirty(.connection, id: connection.id.uuidString)
        }

        let groups = GroupStorage.shared.loadGroups()
        for group in groups {
            changeTracker.markDirty(.group, id: group.id.uuidString)
        }

        let tags = TagStorage.shared.loadTags()
        for tag in tags {
            changeTracker.markDirty(.tag, id: tag.id.uuidString)
        }

        // Mark all settings categories as dirty
        for category in ["general", "appearance", "editor", "dataGrid", "history", "tabs", "keyboard", "ai"] {
            changeTracker.markDirty(.settings, id: category)
        }

        print("[Sync] Marked all local data dirty: \(connections.count) connections, \(groups.count) groups, \(tags.count) tags, 8 settings categories")
    }

    /// Called when user disables sync in settings
    func disableSync() {
        syncTask?.cancel()
        syncStatus = .disabled(.userDisabled)
    }

    // MARK: - Status

    private func evaluateStatus() {
        let licenseManager = LicenseManager.shared

        // Check license
        guard licenseManager.isFeatureAvailable(.iCloudSync) else {
            switch licenseManager.status {
            case .expired:
                syncStatus = .disabled(.licenseExpired)
            default:
                syncStatus = .disabled(.licenseRequired)
            }
            return
        }

        // Check sync settings
        let syncSettings = AppSettingsStorage.shared.loadSync()
        guard syncSettings.enabled else {
            syncStatus = .disabled(.userDisabled)
            return
        }

        // Check iCloud account
        guard iCloudAccountAvailable else {
            syncStatus = .disabled(.noAccount)
            return
        }

        // If we were in an error or disabled state, transition to idle
        if !syncStatus.isSyncing {
            syncStatus = .idle
        }
    }

    private func canSync() -> Bool {
        let licenseManager = LicenseManager.shared
        guard licenseManager.isFeatureAvailable(.iCloudSync) else {
            Self.logger.trace("Sync skipped: license not available")
            return false
        }

        let syncSettings = AppSettingsStorage.shared.loadSync()
        guard syncSettings.enabled else {
            Self.logger.trace("Sync skipped: disabled by user")
            return false
        }

        guard iCloudAccountAvailable else {
            Self.logger.trace("Sync skipped: no iCloud account")
            return false
        }

        return true
    }

    // MARK: - Push

    private func performPush() async {
        let settings = AppSettingsStorage.shared.loadSync()
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        let zoneID = await engine.zoneID
        print("[Sync] performPush: syncConnections=\(settings.syncConnections), dirty connections=\(changeTracker.dirtyRecords(for: .connection))")

        // Collect dirty connections
        if settings.syncConnections {
            let dirtyConnectionIds = changeTracker.dirtyRecords(for: .connection)
            if !dirtyConnectionIds.isEmpty {
                let connections = ConnectionStorage.shared.loadConnections()
                for id in dirtyConnectionIds {
                    if let connection = connections.first(where: { $0.id.uuidString == id }) {
                        recordsToSave.append(
                            SyncRecordMapper.toCKRecord(connection, in: zoneID)
                        )
                    }
                }
            }

            // Collect deletion tombstones
            for tombstone in metadataStorage.tombstones(for: .connection) {
                recordIDsToDelete.append(
                    SyncRecordMapper.recordID(type: .connection, id: tombstone.id, in: zoneID)
                )
            }
        }

        // Collect dirty groups and tags
        if settings.syncGroupsAndTags {
            collectDirtyGroups(into: &recordsToSave, deletions: &recordIDsToDelete, zoneID: zoneID)
            collectDirtyTags(into: &recordsToSave, deletions: &recordIDsToDelete, zoneID: zoneID)
        }

        // Collect dirty settings
        if settings.syncSettings {
            let dirtySettingsIds = changeTracker.dirtyRecords(for: .settings)
            for category in dirtySettingsIds {
                if let data = settingsData(for: category) {
                    recordsToSave.append(
                        SyncRecordMapper.toCKRecord(category: category, settingsData: data, in: zoneID)
                    )
                }
            }
        }

        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return }

        do {
            try await engine.push(records: recordsToSave, deletions: recordIDsToDelete)

            // Clear dirty flags on success
            for type in SyncRecordType.allCases {
                changeTracker.clearAllDirty(type)
            }

            // Clear tombstones for pushed deletions
            for type in SyncRecordType.allCases {
                for tombstone in metadataStorage.tombstones(for: type) {
                    metadataStorage.removeTombstone(type: type, id: tombstone.id)
                }
            }

            print("[Sync] Push completed: \(recordsToSave.count) saved, \(recordIDsToDelete.count) deleted")
        } catch let error as CKError where error.code == .serverRecordChanged {
            Self.logger.warning("Server record changed during push — conflicts detected")
            handlePushConflicts(error)
        } catch {
            Self.logger.error("Push failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pull

    private func performPull() async {
        let token = metadataStorage.loadSyncToken()
        print("[Sync] Pull starting, token: \(token == nil ? "nil (full fetch)" : "present (delta)")")

        do {
            let result = try await engine.pull(since: token)

            print("[Sync] Pull fetched: \(result.changedRecords.count) changed, \(result.deletedRecordIDs.count) deleted")

            for record in result.changedRecords {
                print("[Sync]   Pulled record: \(record.recordType)/\(record.recordID.recordName)")
            }

            if let newToken = result.newToken {
                metadataStorage.saveSyncToken(newToken)
            }

            applyRemoteChanges(result)

            Self.logger.info(
                "Pull completed: \(result.changedRecords.count) changed, \(result.deletedRecordIDs.count) deleted"
            )
        } catch {
            Self.logger.error("Pull failed: \(error.localizedDescription)")
        }
    }

    private func applyRemoteChanges(_ result: PullResult) {
        let settings = AppSettingsStorage.shared.loadSync()

        // Suppress change tracking during remote apply to avoid sync loops
        changeTracker.isSuppressed = true
        defer {
            changeTracker.isSuppressed = false
        }

        var connectionsChanged = false
        var groupsOrTagsChanged = false

        for record in result.changedRecords {
            switch record.recordType {
            case SyncRecordType.connection.rawValue where settings.syncConnections:
                applyRemoteConnection(record)
                connectionsChanged = true
            case SyncRecordType.group.rawValue where settings.syncGroupsAndTags:
                applyRemoteGroup(record)
                groupsOrTagsChanged = true
            case SyncRecordType.tag.rawValue where settings.syncGroupsAndTags:
                applyRemoteTag(record)
                groupsOrTagsChanged = true
            case SyncRecordType.settings.rawValue where settings.syncSettings:
                applyRemoteSettings(record)
            default:
                break
            }
        }

        for recordID in result.deletedRecordIDs {
            let recordName = recordID.recordName
            if recordName.hasPrefix("Connection_") { connectionsChanged = true }
            if recordName.hasPrefix("Group_") || recordName.hasPrefix("Tag_") { groupsOrTagsChanged = true }
            applyRemoteDeletion(recordID)
        }

        // Notify UI so views refresh with pulled data
        if connectionsChanged || groupsOrTagsChanged {
            NotificationCenter.default.post(name: .connectionUpdated, object: nil)
        }
    }

    private func applyRemoteConnection(_ record: CKRecord) {
        guard let remoteConnection = SyncRecordMapper.toConnection(record) else { return }

        var connections = ConnectionStorage.shared.loadConnections()
        if let index = connections.firstIndex(where: { $0.id == remoteConnection.id }) {
            // Check for conflict: if local is also dirty, queue conflict
            if changeTracker.dirtyRecords(for: .connection).contains(remoteConnection.id.uuidString) {
                let localRecord = SyncRecordMapper.toCKRecord(
                    connections[index],
                    in: CKRecordZone.ID(
                        zoneName: "TableProSync",
                        ownerName: CKCurrentUserDefaultName
                    )
                )
                let conflict = SyncConflict(
                    recordType: .connection,
                    entityName: remoteConnection.name,
                    localRecord: localRecord,
                    serverRecord: record,
                    localModifiedAt: (localRecord["modifiedAtLocal"] as? Date) ?? Date(),
                    serverModifiedAt: (record["modifiedAtLocal"] as? Date) ?? Date()
                )
                conflictResolver.addConflict(conflict)
                return
            }
            connections[index] = remoteConnection
        } else {
            connections.append(remoteConnection)
        }
        ConnectionStorage.shared.saveConnections(connections)
    }

    private func applyRemoteGroup(_ record: CKRecord) {
        guard let remoteGroup = SyncRecordMapper.toGroup(record) else { return }

        var groups = GroupStorage.shared.loadGroups()
        if let index = groups.firstIndex(where: { $0.id == remoteGroup.id }) {
            groups[index] = remoteGroup
        } else {
            groups.append(remoteGroup)
        }
        GroupStorage.shared.saveGroups(groups)
    }

    private func applyRemoteTag(_ record: CKRecord) {
        guard let remoteTag = SyncRecordMapper.toTag(record) else { return }

        var tags = TagStorage.shared.loadTags()
        if let index = tags.firstIndex(where: { $0.id == remoteTag.id }) {
            tags[index] = remoteTag
        } else {
            tags.append(remoteTag)
        }
        TagStorage.shared.saveTags(tags)
    }

    private func applyRemoteSettings(_ record: CKRecord) {
        guard let category = SyncRecordMapper.settingsCategory(from: record),
              let data = SyncRecordMapper.settingsData(from: record)
        else { return }
        applySettingsData(data, for: category)
    }

    private func applyRemoteDeletion(_ recordID: CKRecord.ID) {
        let recordName = recordID.recordName

        if recordName.hasPrefix("Connection_") {
            let uuidString = String(recordName.dropFirst("Connection_".count))
            if let uuid = UUID(uuidString: uuidString) {
                var connections = ConnectionStorage.shared.loadConnections()
                connections.removeAll { $0.id == uuid }
                ConnectionStorage.shared.saveConnections(connections)
            }
        }
        if recordName.hasPrefix("Group_") {
            let uuidString = String(recordName.dropFirst("Group_".count))
            if let uuid = UUID(uuidString: uuidString) {
                var groups = GroupStorage.shared.loadGroups()
                groups.removeAll { $0.id == uuid }
                GroupStorage.shared.saveGroups(groups)
            }
        }

        if recordName.hasPrefix("Tag_") {
            let uuidString = String(recordName.dropFirst("Tag_".count))
            if let uuid = UUID(uuidString: uuidString) {
                var tags = TagStorage.shared.loadTags()
                tags.removeAll { $0.id == uuid }
                TagStorage.shared.saveTags(tags)
            }
        }
    }

    // MARK: - Observers

    private func observeAccountChanges() {
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await checkAccountStatus()
                evaluateStatus()

                // If account changed, clear metadata and re-sync
                let currentAccountId = metadataStorage.lastAccountId
                if let newAccountId = try? await self.currentAccountId(),
                   currentAccountId != nil, currentAccountId != newAccountId {
                    Self.logger.warning("iCloud account changed, clearing sync metadata")
                    metadataStorage.clearAll()
                    metadataStorage.lastAccountId = newAccountId
                }
            }
        }
    }

    private func observeLocalChanges() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .syncChangeTracked,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard syncStatus.isEnabled, !syncStatus.isSyncing else { return }
                // Debounce: schedule sync after a short delay
                syncTask?.cancel()
                syncTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    await self.syncNow()
                }
            }
        }
    }

    // MARK: - Account

    private func checkAccountStatus() async {
        do {
            let status = try await engine.checkAccountStatus()
            iCloudAccountAvailable = (status == .available)

            if iCloudAccountAvailable {
                if let accountId = try? await currentAccountId() {
                    metadataStorage.lastAccountId = accountId
                }
            }
        } catch {
            iCloudAccountAvailable = false
            Self.logger.warning("Failed to check iCloud account: \(error.localizedDescription)")
        }
    }

    private func currentAccountId() async throws -> String? {
        let container = CKContainer(identifier: "iCloud.com.TablePro")
        let userRecordID = try await container.userRecordID()
        return userRecordID.recordName
    }

    // MARK: - Conflict Handling

    private func handlePushConflicts(_ error: CKError) {
        guard let partialErrors = error.partialErrorsByItemID else { return }

        for (_, itemError) in partialErrors {
            guard let ckError = itemError as? CKError,
                  ckError.code == .serverRecordChanged,
                  let serverRecord = ckError.serverRecord,
                  let clientRecord = ckError.clientRecord
            else { continue }

            let recordType = serverRecord.recordType
            let entityName = (serverRecord["name"] as? String) ?? recordType

            let syncRecordType: SyncRecordType
            switch recordType {
            case SyncRecordType.connection.rawValue: syncRecordType = .connection
            case SyncRecordType.group.rawValue: syncRecordType = .group
            case SyncRecordType.tag.rawValue: syncRecordType = .tag
            case SyncRecordType.settings.rawValue: syncRecordType = .settings
            case SyncRecordType.queryHistory.rawValue: syncRecordType = .queryHistory
            default: continue
            }

            let conflict = SyncConflict(
                recordType: syncRecordType,
                entityName: entityName,
                localRecord: clientRecord,
                serverRecord: serverRecord,
                localModifiedAt: (clientRecord["modifiedAtLocal"] as? Date) ?? Date(),
                serverModifiedAt: (serverRecord["modifiedAtLocal"] as? Date) ?? Date()
            )
            conflictResolver.addConflict(conflict)
        }
    }

    // MARK: - Settings Helpers

    private func settingsData(for category: String) -> Data? {
        let storage = AppSettingsStorage.shared
        let encoder = JSONEncoder()

        switch category {
        case "general": return try? encoder.encode(storage.loadGeneral())
        case "appearance": return try? encoder.encode(storage.loadAppearance())
        case "editor": return try? encoder.encode(storage.loadEditor())
        case "dataGrid": return try? encoder.encode(storage.loadDataGrid())
        case "history": return try? encoder.encode(storage.loadHistory())
        case "tabs": return try? encoder.encode(storage.loadTabs())
        case "keyboard": return try? encoder.encode(storage.loadKeyboard())
        case "ai": return try? encoder.encode(storage.loadAI())
        default: return nil
        }
    }

    private func applySettingsData(_ data: Data, for category: String) {
        let storage = AppSettingsStorage.shared
        let manager = AppSettingsManager.shared
        let decoder = JSONDecoder()

        switch category {
        case "general":
            if let settings = try? decoder.decode(GeneralSettings.self, from: data) {
                manager.general = settings
            }
        case "appearance":
            if let settings = try? decoder.decode(AppearanceSettings.self, from: data) {
                manager.appearance = settings
            }
        case "editor":
            if let settings = try? decoder.decode(EditorSettings.self, from: data) {
                manager.editor = settings
            }
        case "dataGrid":
            if let settings = try? decoder.decode(DataGridSettings.self, from: data) {
                manager.dataGrid = settings
            }
        case "history":
            if let settings = try? decoder.decode(HistorySettings.self, from: data) {
                manager.history = settings
            }
        case "tabs":
            if let settings = try? decoder.decode(TabSettings.self, from: data) {
                manager.tabs = settings
            }
        case "keyboard":
            if let settings = try? decoder.decode(KeyboardSettings.self, from: data) {
                manager.keyboard = settings
            }
        case "ai":
            if let settings = try? decoder.decode(AISettings.self, from: data) {
                manager.ai = settings
            }
        default:
            break
        }
    }

    // MARK: - Group/Tag Collection Helpers

    private func collectDirtyGroups(
        into records: inout [CKRecord],
        deletions: inout [CKRecord.ID],
        zoneID: CKRecordZone.ID
    ) {
        // Will be fully wired in Phase C when GroupStorage integration is added
        for tombstone in metadataStorage.tombstones(for: .group) {
            deletions.append(
                SyncRecordMapper.recordID(type: .group, id: tombstone.id, in: zoneID)
            )
        }
    }

    private func collectDirtyTags(
        into records: inout [CKRecord],
        deletions: inout [CKRecord.ID],
        zoneID: CKRecordZone.ID
    ) {
        // Will be fully wired in Phase C when TagStorage integration is added
        for tombstone in metadataStorage.tombstones(for: .tag) {
            deletions.append(
                SyncRecordMapper.recordID(type: .tag, id: tombstone.id, in: zoneID)
            )
        }
    }
}

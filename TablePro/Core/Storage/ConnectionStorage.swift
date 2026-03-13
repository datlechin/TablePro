//
//  ConnectionStorage.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import os
import Security

/// Service for persisting database connections
final class ConnectionStorage {
    static let shared = ConnectionStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionStorage")

    private let connectionsKey = "com.TablePro.connections"
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// In-memory cache to avoid re-decoding JSON from UserDefaults on every access
    private var cachedConnections: [DatabaseConnection]?

    private init() {}

    // MARK: - Connection CRUD

    /// Load all saved connections
    func loadConnections() -> [DatabaseConnection] {
        if let cached = cachedConnections { return cached }

        guard let data = defaults.data(forKey: connectionsKey) else {
            return []
        }

        do {
            let storedConnections = try decoder.decode([StoredConnection].self, from: data)

            let connections = storedConnections.map { stored in
                stored.toConnection()
            }
            cachedConnections = connections
            return connections
        } catch {
            Self.logger.error("Failed to load connections: \(error)")
            return []
        }
    }

    /// Save all connections
    func saveConnections(_ connections: [DatabaseConnection]) {
        cachedConnections = connections

        let storedConnections = connections.map { StoredConnection(from: $0) }

        do {
            let data = try encoder.encode(storedConnections)
            defaults.set(data, forKey: connectionsKey)
        } catch {
            Self.logger.error("Failed to save connections: \(error)")
        }
    }

    /// Add a new connection
    func addConnection(_ connection: DatabaseConnection, password: String? = nil) {
        var connections = loadConnections()
        connections.append(connection)
        saveConnections(connections)

        if let password = password, !password.isEmpty {
            savePassword(password, for: connection.id)
        }
    }

    /// Update an existing connection
    func updateConnection(_ connection: DatabaseConnection, password: String? = nil) {
        var connections = loadConnections()
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
            saveConnections(connections)

            if let password = password {
                if password.isEmpty {
                    deletePassword(for: connection.id)
                } else {
                    savePassword(password, for: connection.id)
                }
            }
        }
    }

    /// Delete a connection
    func deleteConnection(_ connection: DatabaseConnection) {
        var connections = loadConnections()
        connections.removeAll { $0.id == connection.id }
        saveConnections(connections)
        deletePassword(for: connection.id)
        deleteSSHPassword(for: connection.id)
        deleteKeyPassphrase(for: connection.id)
    }

    /// Duplicate a connection with a new UUID and "(Copy)" suffix
    /// Copies all passwords from source connection to the duplicate
    func duplicateConnection(_ connection: DatabaseConnection) -> DatabaseConnection {
        let newId = UUID()

        // Create duplicate with new ID and "(Copy)" suffix
        let duplicate = DatabaseConnection(
            id: newId,
            name: "\(connection.name) (Copy)",
            host: connection.host,
            port: connection.port,
            database: connection.database,
            username: connection.username,
            type: connection.type,
            sshConfig: connection.sshConfig,
            sslConfig: connection.sslConfig,
            color: connection.color,
            tagId: connection.tagId,
            groupId: connection.groupId,
            safeModeLevel: connection.safeModeLevel,
            aiPolicy: connection.aiPolicy,
            redisDatabase: connection.redisDatabase,
            startupCommands: connection.startupCommands,
            additionalFields: connection.additionalFields.isEmpty ? nil : connection.additionalFields
        )

        // Save the duplicate connection
        var connections = loadConnections()
        connections.append(duplicate)
        saveConnections(connections)

        // Copy all passwords from source to duplicate
        if let password = loadPassword(for: connection.id) {
            savePassword(password, for: newId)
        }
        if let sshPassword = loadSSHPassword(for: connection.id) {
            saveSSHPassword(sshPassword, for: newId)
        }
        if let keyPassphrase = loadKeyPassphrase(for: connection.id) {
            saveKeyPassphrase(keyPassphrase, for: newId)
        }

        return duplicate
    }

    // MARK: - Keychain (Password Storage)

    // Thread safety note (SVC-15): SecItemCopyMatching is synchronous but all call sites
    // are already off the main thread:
    //   - MySQLDriver.connect() / PostgreSQLDriver.connect() — non-@MainActor async funcs
    //   - DatabaseManager — uses Task.detached for SSH/key passphrase loads
    //   - ConnectionFormView — single-item lookup during form population (negligible latency)
    // No async wrapper is needed; adding one would add complexity without measurable benefit.

    /// Upsert a value into the Keychain: tries SecItemAdd first, falls back to SecItemUpdate
    /// on duplicate. Returns true on success.
    @discardableResult
    private func keychainUpsert(key: String, data: Data) -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.TablePro",
            kSecAttrAccount as String: key,
        ]

        let addQuery = baseQuery.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) { _, new in new }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            // Item already exists — update it
            let updateAttrs: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
            if updateStatus != errSecSuccess {
                Self.logger.error("Failed to update Keychain item '\(key)': OSStatus \(updateStatus)")
                return false
            }
            return true
        } else if addStatus != errSecSuccess {
            Self.logger.error("Failed to add Keychain item '\(key)': OSStatus \(addStatus)")
            return false
        }
        return true
    }

    /// Save password to Keychain
    func savePassword(_ password: String, for connectionId: UUID) {
        let key = "com.TablePro.password.\(connectionId.uuidString)"
        guard let data = password.data(using: .utf8) else { return }
        keychainUpsert(key: key, data: data)
    }

    /// Load password from Keychain
    func loadPassword(for connectionId: UUID) -> String? {
        let key = "com.TablePro.password.\(connectionId.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.TablePro",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return password
    }

    /// Delete password from Keychain
    func deletePassword(for connectionId: UUID) {
        let key = "com.TablePro.password.\(connectionId.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.TablePro",
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - SSH Password Storage

    /// Save SSH password to Keychain
    func saveSSHPassword(_ password: String, for connectionId: UUID) {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"
        guard let data = password.data(using: .utf8) else { return }
        keychainUpsert(key: key, data: data)
    }

    /// Load SSH password from Keychain
    func loadSSHPassword(for connectionId: UUID) -> String? {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.TablePro",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return password
    }

    /// Delete SSH password from Keychain
    func deleteSSHPassword(for connectionId: UUID) {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.TablePro",
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Key Passphrase Storage

    /// Save private key passphrase to Keychain
    func saveKeyPassphrase(_ passphrase: String, for connectionId: UUID) {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"
        guard let data = passphrase.data(using: .utf8) else { return }
        keychainUpsert(key: key, data: data)
    }

    /// Load private key passphrase from Keychain
    func loadKeyPassphrase(for connectionId: UUID) -> String? {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.TablePro",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let passphrase = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return passphrase
    }

    /// Delete private key passphrase from Keychain
    func deleteKeyPassphrase(for connectionId: UUID) {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.TablePro",
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Stored Connection (Codable wrapper)

private struct StoredConnection: Codable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let database: String
    let username: String
    let type: String

    // SSH Configuration
    let sshEnabled: Bool
    let sshHost: String
    let sshPort: Int
    let sshUsername: String
    let sshAuthMethod: String
    let sshPrivateKeyPath: String
    let sshUseSSHConfig: Bool
    let sshAgentSocketPath: String

    // SSL Configuration
    let sslMode: String
    let sslCaCertificatePath: String
    let sslClientCertificatePath: String
    let sslClientKeyPath: String

    // Color, Tag, and Group
    let color: String
    let tagId: String?
    let groupId: String?

    // Safe mode level
    let safeModeLevel: String

    // AI policy
    let aiPolicy: String?

    // MongoDB-specific
    let mongoAuthSource: String?
    let mongoReadPreference: String?
    let mongoWriteConcern: String?

    // Redis-specific
    let redisDatabase: Int?

    // MSSQL schema
    let mssqlSchema: String?

    // Oracle service name
    let oracleServiceName: String?

    // Startup commands
    let startupCommands: String?

    // Plugin-driven additional fields
    let additionalFields: [String: String]?

    init(from connection: DatabaseConnection) {
        self.id = connection.id
        self.name = connection.name
        self.host = connection.host
        self.port = connection.port
        self.database = connection.database
        self.username = connection.username
        self.type = connection.type.rawValue

        // SSH Configuration
        self.sshEnabled = connection.sshConfig.enabled
        self.sshHost = connection.sshConfig.host
        self.sshPort = connection.sshConfig.port
        self.sshUsername = connection.sshConfig.username
        self.sshAuthMethod = connection.sshConfig.authMethod.rawValue
        self.sshPrivateKeyPath = connection.sshConfig.privateKeyPath
        self.sshUseSSHConfig = connection.sshConfig.useSSHConfig
        self.sshAgentSocketPath = connection.sshConfig.agentSocketPath

        // SSL Configuration
        self.sslMode = connection.sslConfig.mode.rawValue
        self.sslCaCertificatePath = connection.sslConfig.caCertificatePath
        self.sslClientCertificatePath = connection.sslConfig.clientCertificatePath
        self.sslClientKeyPath = connection.sslConfig.clientKeyPath

        // Color, Tag, and Group
        self.color = connection.color.rawValue
        self.tagId = connection.tagId?.uuidString
        self.groupId = connection.groupId?.uuidString

        // Safe mode level
        self.safeModeLevel = connection.safeModeLevel.rawValue

        // AI policy
        self.aiPolicy = connection.aiPolicy?.rawValue

        // MongoDB-specific
        self.mongoAuthSource = connection.mongoAuthSource
        self.mongoReadPreference = connection.mongoReadPreference
        self.mongoWriteConcern = connection.mongoWriteConcern

        // Redis-specific
        self.redisDatabase = connection.redisDatabase

        // MSSQL schema
        self.mssqlSchema = connection.mssqlSchema

        // Oracle service name
        self.oracleServiceName = connection.oracleServiceName

        // Startup commands
        self.startupCommands = connection.startupCommands

        // Plugin-driven additional fields
        self.additionalFields = connection.additionalFields.isEmpty ? nil : connection.additionalFields
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, username, type
        case sshEnabled, sshHost, sshPort, sshUsername, sshAuthMethod, sshPrivateKeyPath
        case sshUseSSHConfig, sshAgentSocketPath
        case sslMode, sslCaCertificatePath, sslClientCertificatePath, sslClientKeyPath
        case color, tagId, groupId
        case safeModeLevel
        case isReadOnly // Legacy key for migration reading only
        case aiPolicy
        case mongoAuthSource, mongoReadPreference, mongoWriteConcern, redisDatabase
        case mssqlSchema, oracleServiceName, startupCommands
        case additionalFields
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(database, forKey: .database)
        try container.encode(username, forKey: .username)
        try container.encode(type, forKey: .type)
        try container.encode(sshEnabled, forKey: .sshEnabled)
        try container.encode(sshHost, forKey: .sshHost)
        try container.encode(sshPort, forKey: .sshPort)
        try container.encode(sshUsername, forKey: .sshUsername)
        try container.encode(sshAuthMethod, forKey: .sshAuthMethod)
        try container.encode(sshPrivateKeyPath, forKey: .sshPrivateKeyPath)
        try container.encode(sshUseSSHConfig, forKey: .sshUseSSHConfig)
        try container.encode(sshAgentSocketPath, forKey: .sshAgentSocketPath)
        try container.encode(sslMode, forKey: .sslMode)
        try container.encode(sslCaCertificatePath, forKey: .sslCaCertificatePath)
        try container.encode(sslClientCertificatePath, forKey: .sslClientCertificatePath)
        try container.encode(sslClientKeyPath, forKey: .sslClientKeyPath)
        try container.encode(color, forKey: .color)
        try container.encodeIfPresent(tagId, forKey: .tagId)
        try container.encodeIfPresent(groupId, forKey: .groupId)
        try container.encode(safeModeLevel, forKey: .safeModeLevel)
        try container.encodeIfPresent(aiPolicy, forKey: .aiPolicy)
        try container.encodeIfPresent(redisDatabase, forKey: .redisDatabase)
        try container.encodeIfPresent(startupCommands, forKey: .startupCommands)
        try container.encodeIfPresent(additionalFields, forKey: .additionalFields)
    }

    // Custom decoder to handle migration from old format
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        database = try container.decode(String.self, forKey: .database)
        username = try container.decode(String.self, forKey: .username)
        type = try container.decode(String.self, forKey: .type)

        sshEnabled = try container.decode(Bool.self, forKey: .sshEnabled)
        sshHost = try container.decode(String.self, forKey: .sshHost)
        sshPort = try container.decode(Int.self, forKey: .sshPort)
        sshUsername = try container.decode(String.self, forKey: .sshUsername)
        sshAuthMethod = try container.decode(String.self, forKey: .sshAuthMethod)
        sshPrivateKeyPath = try container.decode(String.self, forKey: .sshPrivateKeyPath)
        sshUseSSHConfig = try container.decode(Bool.self, forKey: .sshUseSSHConfig)
        sshAgentSocketPath = try container.decodeIfPresent(String.self, forKey: .sshAgentSocketPath) ?? ""

        // SSL Configuration (migration: use defaults if missing)
        sslMode = try container.decodeIfPresent(String.self, forKey: .sslMode) ?? SSLMode.disabled.rawValue
        sslCaCertificatePath = try container.decodeIfPresent(String.self, forKey: .sslCaCertificatePath) ?? ""
        sslClientCertificatePath = try container.decodeIfPresent(
            String.self, forKey: .sslClientCertificatePath
        ) ?? ""
        sslClientKeyPath = try container.decodeIfPresent(String.self, forKey: .sslClientKeyPath) ?? ""

        // Migration: use defaults if fields are missing
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? ConnectionColor.none.rawValue
        tagId = try container.decodeIfPresent(String.self, forKey: .tagId)
        groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
        // Migration: read new safeModeLevel first, fall back to old isReadOnly boolean
        if let levelString = try container.decodeIfPresent(String.self, forKey: .safeModeLevel) {
            safeModeLevel = levelString
        } else {
            let wasReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
            safeModeLevel = wasReadOnly ? SafeModeLevel.readOnly.rawValue : SafeModeLevel.silent.rawValue
        }
        aiPolicy = try container.decodeIfPresent(String.self, forKey: .aiPolicy)
        mongoAuthSource = try container.decodeIfPresent(String.self, forKey: .mongoAuthSource)
        mongoReadPreference = try container.decodeIfPresent(String.self, forKey: .mongoReadPreference)
        mongoWriteConcern = try container.decodeIfPresent(String.self, forKey: .mongoWriteConcern)
        redisDatabase = try container.decodeIfPresent(Int.self, forKey: .redisDatabase)
        mssqlSchema = try container.decodeIfPresent(String.self, forKey: .mssqlSchema)
        oracleServiceName = try container.decodeIfPresent(String.self, forKey: .oracleServiceName)
        startupCommands = try container.decodeIfPresent(String.self, forKey: .startupCommands)
        additionalFields = try container.decodeIfPresent([String: String].self, forKey: .additionalFields)
    }

    func toConnection() -> DatabaseConnection {
        let sshConfig = SSHConfiguration(
            enabled: sshEnabled,
            host: sshHost,
            port: sshPort,
            username: sshUsername,
            authMethod: SSHAuthMethod(rawValue: sshAuthMethod) ?? .password,
            privateKeyPath: sshPrivateKeyPath,
            useSSHConfig: sshUseSSHConfig,
            agentSocketPath: sshAgentSocketPath
        )

        let sslConfig = SSLConfiguration(
            mode: SSLMode(rawValue: sslMode) ?? .disabled,
            caCertificatePath: sslCaCertificatePath,
            clientCertificatePath: sslClientCertificatePath,
            clientKeyPath: sslClientKeyPath
        )

        let parsedColor = ConnectionColor(rawValue: color) ?? .none
        let parsedTagId = tagId.flatMap { UUID(uuidString: $0) }
        let parsedGroupId = groupId.flatMap { UUID(uuidString: $0) }
        let parsedAIPolicy = aiPolicy.flatMap { AIConnectionPolicy(rawValue: $0) }

        // Merge legacy named keys into additionalFields as fallback
        let mergedFields: [String: String]? = {
            var fields = additionalFields ?? [:]
            if fields["mongoAuthSource"] == nil, let v = mongoAuthSource { fields["mongoAuthSource"] = v }
            if fields["mongoReadPreference"] == nil, let v = mongoReadPreference {
                fields["mongoReadPreference"] = v
            }
            if fields["mongoWriteConcern"] == nil, let v = mongoWriteConcern {
                fields["mongoWriteConcern"] = v
            }
            if fields["mssqlSchema"] == nil, let v = mssqlSchema { fields["mssqlSchema"] = v }
            if fields["oracleServiceName"] == nil, let v = oracleServiceName {
                fields["oracleServiceName"] = v
            }
            return fields.isEmpty ? nil : fields
        }()

        return DatabaseConnection(
            id: id,
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: DatabaseType(rawValue: type),
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: parsedColor,
            tagId: parsedTagId,
            groupId: parsedGroupId,
            safeModeLevel: SafeModeLevel(rawValue: safeModeLevel) ?? .silent,
            aiPolicy: parsedAIPolicy,
            redisDatabase: redisDatabase,
            startupCommands: startupCommands,
            additionalFields: mergedFields
        )
    }
}

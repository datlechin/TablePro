//
//  DatabaseManager.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Combine
import Foundation

extension Notification.Name {
    static let databaseDidConnect = Notification.Name("databaseDidConnect")
}

/// Manages database connections and active drivers
@MainActor
final class DatabaseManager: ObservableObject {
    static let shared = DatabaseManager()

    /// All active connection sessions
    @Published private(set) var activeSessions: [UUID: ConnectionSession] = [:]

    /// Currently selected session ID (displayed in UI)
    @Published private(set) var currentSessionId: UUID?

    /// Current session (computed from currentSessionId)
    var currentSession: ConnectionSession? {
        guard let sessionId = currentSessionId else { return nil }
        return activeSessions[sessionId]
    }

    /// Current driver (for convenience)
    var activeDriver: DatabaseDriver? {
        currentSession?.driver
    }

    /// Current connection status
    var status: ConnectionStatus {
        currentSession?.status ?? .disconnected
    }

    private init() {}

    // MARK: - Session Management

    /// Connect to a database and create/switch to its session
    /// If connection already has a session, switches to it instead
    func connectToSession(_ connection: DatabaseConnection) async throws {
        // Check if session already exists
        if activeSessions[connection.id] != nil {
            // Session exists, just switch to it
            switchToSession(connection.id)
            return
        }

        // Create new session
        var session = ConnectionSession(connection: connection)
        session.status = .connecting
        activeSessions[connection.id] = session
        currentSessionId = connection.id

        // Create SSH tunnel if needed
        var effectiveConnection = connection
        if connection.sshConfig.enabled {
            let sshPassword = ConnectionStorage.shared.loadSSHPassword(for: connection.id)
            let keyPassphrase = ConnectionStorage.shared.loadKeyPassphrase(for: connection.id)

            do {
                let tunnelPort = try await SSHTunnelManager.shared.createTunnel(
                    connectionId: connection.id,
                    sshHost: connection.sshConfig.host,
                    sshPort: connection.sshConfig.port,
                    sshUsername: connection.sshConfig.username,
                    authMethod: connection.sshConfig.authMethod,
                    privateKeyPath: connection.sshConfig.privateKeyPath,
                    keyPassphrase: keyPassphrase,
                    sshPassword: sshPassword,
                    remoteHost: connection.host,
                    remotePort: connection.port
                )

                // Create a modified connection that uses the tunnel
                effectiveConnection = DatabaseConnection(
                    id: connection.id,
                    name: connection.name,
                    host: "127.0.0.1",
                    port: tunnelPort,
                    database: connection.database,
                    username: connection.username,
                    type: connection.type,
                    sshConfig: SSHConfiguration()  // Disable SSH for actual driver
                )
            } catch {
                // Remove failed session
                activeSessions.removeValue(forKey: connection.id)
                currentSessionId = nil
                throw error
            }
        }

        // Create appropriate driver with effective connection
        let driver = DatabaseDriverFactory.createDriver(for: effectiveConnection)

        do {
            try await driver.connect()

            // Update session with successful connection
            session.driver = driver
            session.status = driver.status
            activeSessions[connection.id] = session

            // Restore tab state if it exists
            if let tabState = TabStateStorage.shared.loadTabState(connectionId: connection.id) {
                let restoredTabs = tabState.tabs.map { QueryTab(from: $0) }
                activeSessions[connection.id]?.tabs = restoredTabs
                activeSessions[connection.id]?.selectedTabId = tabState.selectedTabId
            }

            // Post notification for reliable delivery
            NotificationCenter.default.post(name: .databaseDidConnect, object: nil)
        } catch {
            // Close tunnel if connection failed
            if connection.sshConfig.enabled {
                Task {
                    try? await SSHTunnelManager.shared.closeTunnel(connectionId: connection.id)
                }
            }

            // Remove failed session completely so UI returns to Welcome window
            activeSessions.removeValue(forKey: connection.id)

            // Clear current session if this was it
            if currentSessionId == connection.id {
                // Switch to another session if available, otherwise clear
                if let nextSessionId = activeSessions.keys.first {
                    currentSessionId = nextSessionId
                } else {
                    currentSessionId = nil
                }
            }

            throw error
        }
    }

    /// Switch to an existing session
    func switchToSession(_ sessionId: UUID) {
        guard var session = activeSessions[sessionId] else { return }
        currentSessionId = sessionId

        // Mark session as active
        session.markActive()
        activeSessions[sessionId] = session
    }

    /// Disconnect a specific session
    func disconnectSession(_ sessionId: UUID) async {
        guard let session = activeSessions[sessionId] else { return }

        // Close SSH tunnel if exists
        if session.connection.sshConfig.enabled {
            try? await SSHTunnelManager.shared.closeTunnel(connectionId: session.connection.id)
        }

        session.driver?.disconnect()
        activeSessions.removeValue(forKey: sessionId)

        // If this was the current session, switch to another or clear
        if currentSessionId == sessionId {
            if let nextSessionId = activeSessions.keys.first {
                switchToSession(nextSessionId)
            } else {
                // No more sessions
                currentSessionId = nil
            }
        }
    }

    /// Disconnect all sessions
    func disconnectAll() async {
        for sessionId in activeSessions.keys {
            await disconnectSession(sessionId)
        }
    }

    /// Update session state (for preserving UI state)
    func updateSession(_ sessionId: UUID, update: (inout ConnectionSession) -> Void) {
        guard var session = activeSessions[sessionId] else { return }
        update(&session)
        activeSessions[sessionId] = session
    }

    // MARK: - Query Execution (uses current session)

    /// Execute a query on the current session
    func execute(query: String) async throws -> QueryResult {
        guard let driver = activeDriver else {
            throw DatabaseError.notConnected
        }

        return try await driver.execute(query: query)
    }

    /// Fetch tables from the current session
    func fetchTables() async throws -> [TableInfo] {
        guard let driver = activeDriver else {
            throw DatabaseError.notConnected
        }

        return try await driver.fetchTables()
    }

    /// Fetch columns for a table from the current session
    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        guard let driver = activeDriver else {
            throw DatabaseError.notConnected
        }

        return try await driver.fetchColumns(table: table)
    }

    /// Test a connection without keeping it open
    func testConnection(_ connection: DatabaseConnection, sshPassword: String? = nil) async throws
    -> Bool
    {
        // Create SSH tunnel if needed
        var tunnelPort: Int?
        if connection.sshConfig.enabled {
            let sshPwd = sshPassword ?? ConnectionStorage.shared.loadSSHPassword(for: connection.id)
            let keyPassphrase = ConnectionStorage.shared.loadKeyPassphrase(for: connection.id)
            tunnelPort = try await SSHTunnelManager.shared.createTunnel(
                connectionId: connection.id,
                sshHost: connection.sshConfig.host,
                sshPort: connection.sshConfig.port,
                sshUsername: connection.sshConfig.username,
                authMethod: connection.sshConfig.authMethod,
                privateKeyPath: connection.sshConfig.privateKeyPath,
                keyPassphrase: keyPassphrase,
                sshPassword: sshPwd,
                remoteHost: connection.host,
                remotePort: connection.port
            )
        }

        defer {
            // Close tunnel after test
            if connection.sshConfig.enabled {
                Task {
                    try? await SSHTunnelManager.shared.closeTunnel(connectionId: connection.id)
                }
            }
        }

        // Create connection with tunnel port if applicable
        let testConnection: DatabaseConnection
        if let port = tunnelPort {
            testConnection = DatabaseConnection(
                id: connection.id,
                name: connection.name,
                host: "127.0.0.1",
                port: port,
                database: connection.database,
                username: connection.username,
                type: connection.type,
                sshConfig: SSHConfiguration()  // Disable SSH for the actual driver connection
            )
        } else {
            testConnection = connection
        }

        let driver = DatabaseDriverFactory.createDriver(for: testConnection)
        return try await driver.testConnection()
    }
}

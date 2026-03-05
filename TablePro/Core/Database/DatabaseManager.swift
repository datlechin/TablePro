//
//  DatabaseManager.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import Observation
import os

extension Notification.Name {
    static let databaseDidConnect = Notification.Name("databaseDidConnect")
}

/// Manages database connections and active drivers
@MainActor @Observable
final class DatabaseManager {
    static let shared = DatabaseManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseManager")

    /// All active connection sessions
    private(set) var activeSessions: [UUID: ConnectionSession] = [:] {
        didSet { sessionVersion &+= 1 }
    }

    /// Monotonically increasing counter; incremented on every mutation of activeSessions.
    /// Used by views for `.onChange` since `[UUID: ConnectionSession]` is not `Equatable`.
    private(set) var sessionVersion: Int = 0

    /// Currently selected session ID (displayed in UI)
    private(set) var currentSessionId: UUID?

    /// Health monitors for active connections (MySQL/PostgreSQL only)
    private var healthMonitors: [UUID: ConnectionHealthMonitor] = [:]

    /// Dedicated lightweight drivers used exclusively for health-check pings.
    /// Separate from the main driver so pings never queue behind long-running user queries.
    private var pingDrivers: [UUID: DatabaseDriver] = [:]

    /// Current session (computed from currentSessionId)
    var currentSession: ConnectionSession? {
        guard let sessionId = currentSessionId else { return nil }
        return activeSessions[sessionId]
    }

    /// Current driver (for convenience)
    var activeDriver: DatabaseDriver? {
        currentSession?.driver
    }

    /// Dedicated driver for metadata queries (columns, FKs, count).
    /// Runs on a separate serial queue so metadata fetches don't block the main query.
    var activeMetadataDriver: DatabaseDriver? {
        currentSession?.metadataDriver
    }

    /// Resolve the driver for a specific connection (session-scoped, no global state)
    func driver(for connectionId: UUID) -> DatabaseDriver? {
        activeSessions[connectionId]?.driver
    }

    /// Resolve the metadata driver for a specific connection
    func metadataDriver(for connectionId: UUID) -> DatabaseDriver? {
        activeSessions[connectionId]?.metadataDriver
    }

    /// Resolve a session by explicit connection ID
    func session(for connectionId: UUID) -> ConnectionSession? {
        activeSessions[connectionId]
    }

    /// Current connection status
    var status: ConnectionStatus {
        currentSession?.status ?? .disconnected
    }

    private init() {
        // Observe SSH tunnel failures
        NotificationCenter.default.addObserver(
            forName: .sshTunnelDied,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let connectionId = notification.userInfo?["connectionId"] as? UUID else { return }
            guard let self else { return }

            Task { @MainActor in
                await self.handleSSHTunnelDied(connectionId: connectionId)
            }
        }
    }

    // MARK: - Session Management

    /// Connect to a database and create/switch to its session
    /// If connection already has a session, switches to it instead
    func connectToSession(_ connection: DatabaseConnection) async throws {
        // Check if session already exists and is connected
        if let existing = activeSessions[connection.id], existing.driver != nil {
            // Session is fully connected, just switch to it
            switchToSession(connection.id)
            return
        }

        // Create new session (or reuse a prepared one)
        if activeSessions[connection.id] == nil {
            var session = ConnectionSession(connection: connection)
            session.status = .connecting
            activeSessions[connection.id] = session
        }
        currentSessionId = connection.id

        // Create SSH tunnel if needed and build effective connection
        let effectiveConnection: DatabaseConnection
        do {
            effectiveConnection = try await buildEffectiveConnection(for: connection)
        } catch {
            // Remove failed session
            activeSessions.removeValue(forKey: connection.id)
            currentSessionId = nil
            throw error
        }

        // Create appropriate driver with effective connection
        let driver = DatabaseDriverFactory.createDriver(for: effectiveConnection)

        do {
            try await driver.connect()

            // Apply query timeout from settings
            let timeoutSeconds = AppSettingsManager.shared.general.queryTimeoutSeconds
            if timeoutSeconds > 0 {
                try await driver.applyQueryTimeout(timeoutSeconds)
            }

            // Initialize schema for PostgreSQL/Redshift connections
            if let pgDriver = driver as? PostgreSQLDriver {
                activeSessions[connection.id]?.currentSchema = pgDriver.currentSchema
            } else if let rsDriver = driver as? RedshiftDriver {
                activeSessions[connection.id]?.currentSchema = rsDriver.currentSchema
            } else if connection.type == .redis {
                // Redis defaults to db0 on connect; SELECT the configured database if non-default
                let initialDb = connection.redisDatabase ?? Int(connection.database) ?? 0
                if initialDb != 0 {
                    try? await (driver as? RedisDriver)?.selectDatabase(initialDb)
                }
                activeSessions[connection.id]?.currentDatabase = String(initialDb)
            } else if connection.type == .mssql,
                      connection.database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let mssqlDriver = driver as? MSSQLDriver {
                if let savedDb = AppSettingsStorage.shared.loadLastDatabase(for: connection.id) {
                    try? await mssqlDriver.switchDatabase(to: savedDb)
                    activeSessions[connection.id]?.currentDatabase = savedDb
                }
            }

            // Batch all session mutations into a single write to fire objectWillChange once
            if var session = activeSessions[connection.id] {
                session.driver = driver
                session.status = driver.status
                session.effectiveConnection = effectiveConnection

                // Restore tab state if it exists (offload file I/O from main thread)
                let connId = connection.id
                let tabState = await Task.detached(priority: .userInitiated) {
                    TabStateStorage.shared.loadTabState(connectionId: connId)
                }.value
                if let tabState {
                    session.tabs = tabState.tabs.map { QueryTab(from: $0) }
                    session.selectedTabId = tabState.selectedTabId
                }

                activeSessions[connection.id] = session  // Single write, single publish
            }

            // Save as last connection for "Reopen Last Session" feature
            AppSettingsStorage.shared.saveLastConnectionId(connection.id)

            // Post notification for reliable delivery
            NotificationCenter.default.post(name: .databaseDidConnect, object: nil)

            // Start health monitoring for network databases (skip SQLite)
            if connection.type != .sqlite {
                await startHealthMonitor(for: connection.id)
            }

            // Create a dedicated metadata connection in the background so Phase 2
            // metadata queries (columns, FKs, count) run in parallel with main queries.
            let metaConnection = effectiveConnection
            let metaConnectionId = connection.id
            let metaTimeout = AppSettingsManager.shared.general.queryTimeoutSeconds
            Task { [weak self] in
                guard let self else { return }
                do {
                    let metaDriver = DatabaseDriverFactory.createDriver(for: metaConnection)
                    try await metaDriver.connect()
                    if metaTimeout > 0 {
                        try? await metaDriver.applyQueryTimeout(metaTimeout)
                    }
                    // Sync schema on metadata driver for PostgreSQL/Redshift
                    if let savedSchema = self.activeSessions[metaConnectionId]?.currentSchema {
                        if let pgMetaDriver = metaDriver as? PostgreSQLDriver {
                            try? await pgMetaDriver.switchSchema(to: savedSchema)
                        } else if let rsMetaDriver = metaDriver as? RedshiftDriver {
                            try? await rsMetaDriver.switchSchema(to: savedSchema)
                        }
                    }
                    activeSessions[metaConnectionId]?.metadataDriver = metaDriver
                } catch {
                    // Non-fatal: Phase 2 falls back to main driver if metadata driver unavailable
                    Self.logger.warning("Metadata connection failed: \(error.localizedDescription)")
                }
            }
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

        // Stop health monitoring
        await stopHealthMonitor(for: sessionId)

        session.metadataDriver?.disconnect()
        session.driver?.disconnect()
        activeSessions.removeValue(forKey: sessionId)

        // Clean up shared schema cache for this connection
        MainContentCoordinator.clearSharedSchema(for: sessionId)

        // If this was the current session, switch to another or clear
        if currentSessionId == sessionId {
            if let nextSessionId = activeSessions.keys.first {
                switchToSession(nextSessionId)
            } else {
                // No more sessions - clear current session and last connection ID
                currentSessionId = nil
                AppSettingsStorage.shared.saveLastConnectionId(nil)
            }
        }
    }

    /// Disconnect all sessions
    func disconnectAll() async {
        // Stop all health monitors
        for sessionId in healthMonitors.keys {
            await stopHealthMonitor(for: sessionId)
        }

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

    #if DEBUG
    /// Test-only: inject a session for unit testing without real database connections
    internal func injectSession(_ session: ConnectionSession, for connectionId: UUID) {
        activeSessions[connectionId] = session
    }

    /// Test-only: remove an injected session
    internal func removeSession(for connectionId: UUID) {
        activeSessions.removeValue(forKey: connectionId)
    }
    #endif

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
        // Build effective connection (creates SSH tunnel if needed)
        let testConnection = try await buildEffectiveConnection(
            for: connection,
            sshPasswordOverride: sshPassword
        )

        defer {
            // Close tunnel after test
            if connection.sshConfig.enabled {
                Task {
                    try? await SSHTunnelManager.shared.closeTunnel(connectionId: connection.id)
                }
            }
        }

        let driver = DatabaseDriverFactory.createDriver(for: testConnection)
        return try await driver.testConnection()
    }

    // MARK: - SSH Tunnel Helper

    /// Build an effective connection for the given database connection.
    /// If SSH tunneling is enabled, creates a tunnel and returns a modified connection
    /// pointing at localhost with the tunnel port. Otherwise returns the original connection.
    ///
    /// - Parameters:
    ///   - connection: The original database connection configuration.
    ///   - sshPasswordOverride: Optional SSH password to use instead of the stored one (for test connections).
    /// - Returns: A connection suitable for the database driver (SSH disabled, pointing at tunnel if applicable).
    private func buildEffectiveConnection(
        for connection: DatabaseConnection,
        sshPasswordOverride: String? = nil
    ) async throws -> DatabaseConnection {
        guard connection.sshConfig.enabled else {
            return connection
        }

        // Load Keychain credentials off the main thread to avoid blocking UI
        let connectionId = connection.id
        let (storedSshPassword, keyPassphrase) = await Task.detached {
            let pwd = ConnectionStorage.shared.loadSSHPassword(for: connectionId)
            let phrase = ConnectionStorage.shared.loadKeyPassphrase(for: connectionId)
            return (pwd, phrase)
        }.value

        let sshPassword = sshPasswordOverride ?? storedSshPassword

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

        // Adapt SSL config for tunnel: SSH already authenticates the server,
        // remote environment and aren't readable locally, so strip them and
        // use at least .preferred so libpq negotiates SSL when the server
        // requires it (SSH already authenticates the server itself).
        var tunnelSSL = connection.sslConfig
        if tunnelSSL.isEnabled {
            if tunnelSSL.verifiesCertificate {
                tunnelSSL.mode = .required
            }
            tunnelSSL.caCertificatePath = ""
            tunnelSSL.clientCertificatePath = ""
            tunnelSSL.clientKeyPath = ""
        }

        return DatabaseConnection(
            id: connection.id,
            name: connection.name,
            host: "127.0.0.1",
            port: tunnelPort,
            database: connection.database,
            username: connection.username,
            type: connection.type,
            sshConfig: SSHConfiguration(),
            sslConfig: tunnelSSL
        )
    }

    // MARK: - Health Monitoring

    /// Start health monitoring for a connection
    private func startHealthMonitor(for connectionId: UUID) async {
        // Stop any existing monitor
        await stopHealthMonitor(for: connectionId)

        // Create a dedicated lightweight driver for pings so they never
        // queue behind long-running user queries on the main driver.
        if let session = activeSessions[connectionId] {
            let connectionForPing = session.effectiveConnection ?? session.connection
            let dedicatedPingDriver = DatabaseDriverFactory.createDriver(for: connectionForPing)
            do {
                try await dedicatedPingDriver.connect()
                pingDrivers[connectionId] = dedicatedPingDriver
            } catch {
                Self.logger.warning(
                    "Failed to create dedicated ping driver, will fall back to main driver")
            }
        }

        let monitor = ConnectionHealthMonitor(
            connectionId: connectionId,
            pingHandler: { [weak self] in
                guard let self else { return false }
                // Prefer the dedicated ping driver so pings are never blocked
                // by long-running user queries on the main driver.
                let pingDriver = await self.pingDrivers[connectionId]
                let driver: DatabaseDriver
                if let pingDriver {
                    driver = pingDriver
                } else if let mainDriver = await self.activeSessions[connectionId]?.driver {
                    driver = mainDriver
                } else {
                    return false
                }
                do {
                    _ = try await driver.execute(query: "SELECT 1")
                    return true
                } catch {
                    return false
                }
            },
            reconnectHandler: { [weak self] in
                guard let self else { return false }
                guard let session = await self.activeSessions[connectionId] else { return false }
                do {
                    let driver = try await self.reconnectDriver(for: session)
                    await self.updateSession(connectionId) { session in
                        session.driver = driver
                        session.status = .connected
                    }

                    // Also reconnect the dedicated ping driver so future pings
                    // don't fail immediately after a successful main reconnect.
                    let connectionForPing = session.effectiveConnection ?? session.connection
                    let newPingDriver = DatabaseDriverFactory.createDriver(for: connectionForPing)
                    try await newPingDriver.connect()
                    await self.replacePingDriver(newPingDriver, for: connectionId)

                    return true
                } catch {
                    return false
                }
            },
            onStateChanged: { [weak self] id, state in
                guard let self else { return }
                await MainActor.run {
                    switch state {
                    case .healthy:
                        // Skip no-op write — avoid firing @Published when status is already .connected
                        if let session = self.activeSessions[id], !session.isConnected {
                            self.updateSession(id) { session in
                                session.status = .connected
                            }
                        }
                    case .reconnecting(let attempt):
                        Self.logger.info("Reconnecting session \(id) (attempt \(attempt)/3)")
                        self.updateSession(id) { session in
                            session.status = .connecting
                        }
                    case .failed:
                        Self.logger.error(
                            "Health monitoring failed for session \(id) after 3 retries")
                        self.updateSession(id) { session in
                            session.status = .error(String(localized: "Connection lost"))
                            session.clearCachedData()
                        }
                    case .checking:
                        break  // No UI update needed
                    }
                }
            }
        )

        healthMonitors[connectionId] = monitor
        await monitor.startMonitoring()
    }

    /// Creates a fresh driver, connects, and applies timeout for the given session.
    /// Uses the session's effective connection (SSH-tunneled if applicable).
    private func reconnectDriver(for session: ConnectionSession) async throws -> DatabaseDriver {
        // Disconnect existing driver
        session.driver?.disconnect()

        // Use effective connection (tunneled) if available, otherwise original
        let connectionForDriver = session.effectiveConnection ?? session.connection
        let driver = DatabaseDriverFactory.createDriver(for: connectionForDriver)
        try await driver.connect()

        // Apply timeout
        let timeoutSeconds = AppSettingsManager.shared.general.queryTimeoutSeconds
        if timeoutSeconds > 0 {
            try await driver.applyQueryTimeout(timeoutSeconds)
        }

        // Restore schema for PostgreSQL/Redshift if session had a non-default schema
        if let savedSchema = session.currentSchema {
            if let pgDriver = driver as? PostgreSQLDriver {
                try? await pgDriver.switchSchema(to: savedSchema)
            } else if let rsDriver = driver as? RedshiftDriver {
                try? await rsDriver.switchSchema(to: savedSchema)
            }
        }

        // Restore database for MSSQL if session had a non-default database
        if let savedDatabase = session.currentDatabase,
           let mssqlDriver = driver as? MSSQLDriver {
            try? await mssqlDriver.switchDatabase(to: savedDatabase)
        }

        return driver
    }

    /// Replace the dedicated ping driver for a connection, disconnecting the old one.
    private func replacePingDriver(_ newDriver: DatabaseDriver, for connectionId: UUID) {
        pingDrivers[connectionId]?.disconnect()
        pingDrivers[connectionId] = newDriver
    }

    /// Stop health monitoring for a connection
    private func stopHealthMonitor(for connectionId: UUID) async {
        if let monitor = healthMonitors.removeValue(forKey: connectionId) {
            await monitor.stopMonitoring()
        }

        // Disconnect and remove the dedicated ping driver
        if let pingDriver = pingDrivers.removeValue(forKey: connectionId) {
            pingDriver.disconnect()
        }
    }

    /// Reconnect the current session (called from toolbar Reconnect button)
    func reconnectCurrentSession() async {
        guard let sessionId = currentSessionId else { return }
        await reconnectSession(sessionId)
    }

    /// Reconnect a specific session by ID
    func reconnectSession(_ sessionId: UUID) async {
        guard let session = activeSessions[sessionId] else { return }

        Self.logger.info("Manual reconnect requested for: \(session.connection.name)")

        // Update status to connecting
        updateSession(sessionId) { session in
            session.status = .connecting
        }

        // Stop existing health monitor
        await stopHealthMonitor(for: sessionId)

        do {
            // Disconnect existing drivers
            session.metadataDriver?.disconnect()
            session.driver?.disconnect()

            // Recreate SSH tunnel if needed and build effective connection
            let effectiveConnection = try await buildEffectiveConnection(for: session.connection)

            // Create new driver and connect
            let driver = DatabaseDriverFactory.createDriver(for: effectiveConnection)
            try await driver.connect()

            // Apply timeout
            let timeoutSeconds = AppSettingsManager.shared.general.queryTimeoutSeconds
            if timeoutSeconds > 0 {
                try await driver.applyQueryTimeout(timeoutSeconds)
            }

            // Restore schema for PostgreSQL/Redshift if session had a non-default schema
            if let savedSchema = activeSessions[sessionId]?.currentSchema {
                if let pgDriver = driver as? PostgreSQLDriver {
                    try? await pgDriver.switchSchema(to: savedSchema)
                } else if let rsDriver = driver as? RedshiftDriver {
                    try? await rsDriver.switchSchema(to: savedSchema)
                }
            }

            // Restore database for MSSQL if session had a non-default database
            if let savedDatabase = activeSessions[sessionId]?.currentDatabase,
               let mssqlDriver = driver as? MSSQLDriver {
                try? await mssqlDriver.switchDatabase(to: savedDatabase)
            }

            // Update session
            updateSession(sessionId) { session in
                session.driver = driver
                session.status = .connected
                session.effectiveConnection = effectiveConnection
            }

            // Recreate metadata connection in background
            let metaConnection = effectiveConnection
            let metaConnectionId = sessionId
            let metaTimeout = AppSettingsManager.shared.general.queryTimeoutSeconds
            Task { [weak self] in
                guard let self else { return }
                do {
                    let metaDriver = DatabaseDriverFactory.createDriver(for: metaConnection)
                    try await metaDriver.connect()
                    if metaTimeout > 0 {
                        try? await metaDriver.applyQueryTimeout(metaTimeout)
                    }
                    // Restore schema on metadata driver too
                    if let savedSchema = self.activeSessions[metaConnectionId]?.currentSchema {
                        if let pgMetaDriver = metaDriver as? PostgreSQLDriver {
                            try? await pgMetaDriver.switchSchema(to: savedSchema)
                        } else if let rsMetaDriver = metaDriver as? RedshiftDriver {
                            try? await rsMetaDriver.switchSchema(to: savedSchema)
                        }
                    }
                    // Restore database on metadata driver too for MSSQL
                    if let savedDatabase = self.activeSessions[metaConnectionId]?.currentDatabase,
                       let mssqlMetaDriver = metaDriver as? MSSQLDriver {
                        try? await mssqlMetaDriver.switchDatabase(to: savedDatabase)
                    }
                    activeSessions[metaConnectionId]?.metadataDriver = metaDriver
                } catch {
                    Self.logger.warning(
                        "Metadata reconnection failed: \(error.localizedDescription)")
                }
            }

            // Restart health monitoring
            if session.connection.type != .sqlite {
                await startHealthMonitor(for: sessionId)
            }

            // Post connection notification for schema reload
            NotificationCenter.default.post(name: .databaseDidConnect, object: nil)

            Self.logger.info("Manual reconnect succeeded for: \(session.connection.name)")
        } catch {
            Self.logger.error("Manual reconnect failed: \(error.localizedDescription)")
            updateSession(sessionId) { session in
                session.status = .error(
                    String(localized: "Reconnect failed: \(error.localizedDescription)"))
                session.clearCachedData()
            }
        }
    }

    // MARK: - SSH Tunnel Recovery

    /// Handle SSH tunnel death by attempting reconnection
    private func handleSSHTunnelDied(connectionId: UUID) async {
        guard let session = activeSessions[connectionId] else { return }

        Self.logger.warning("SSH tunnel died for connection: \(session.connection.name)")

        // Mark connection as reconnecting
        updateSession(connectionId) { session in
            session.status = .connecting
        }

        // Wait a bit before attempting reconnection (give VPN time to reconnect)
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds

        do {
            // Attempt to reconnect
            try await connectToSession(session.connection)
            Self.logger.info("Successfully reconnected SSH tunnel for: \(session.connection.name)")
        } catch {
            Self.logger.error("Failed to reconnect SSH tunnel: \(error.localizedDescription)")

            // Mark as error and release stale cached data
            updateSession(connectionId) { session in
                session.status = .error("SSH tunnel disconnected. Click to reconnect.")
                session.clearCachedData()
            }
        }
    }

    // MARK: - Schema Changes

    /// Execute schema changes (ALTER TABLE, CREATE INDEX, etc.) in a transaction
    func executeSchemaChanges(
        tableName: String,
        changes: [SchemaChange],
        databaseType: DatabaseType
    ) async throws {
        guard let sessionId = currentSessionId else {
            throw DatabaseError.notConnected
        }
        try await executeSchemaChanges(
            tableName: tableName,
            changes: changes,
            databaseType: databaseType,
            connectionId: sessionId
        )
    }

    /// Execute schema changes using an explicit connection ID (session-scoped)
    func executeSchemaChanges(
        tableName: String,
        changes: [SchemaChange],
        databaseType: DatabaseType,
        connectionId: UUID
    ) async throws {
        guard let driver = driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }

        // For PostgreSQL PK modification, query the actual constraint name
        let pkConstraintName = await fetchPrimaryKeyConstraintName(
            tableName: tableName,
            databaseType: databaseType,
            changes: changes,
            driver: driver
        )

        // Generate SQL statements
        let generator = SchemaStatementGenerator(
            tableName: tableName,
            databaseType: databaseType,
            primaryKeyConstraintName: pkConstraintName
        )
        let statements = try generator.generate(changes: changes)

        // Execute in transaction
        try await driver.beginTransaction()

        do {
            for stmt in statements {
                _ = try await driver.execute(query: stmt.sql)
            }

            try await driver.commitTransaction()

            // Post notification to refresh UI
            NotificationCenter.default.post(name: .refreshData, object: nil)
        } catch {
            // Rollback on error
            try? await driver.rollbackTransaction()
            throw DatabaseError.queryFailed("Schema change failed: \(error.localizedDescription)")
        }
    }

    /// Query the actual primary key constraint name for PostgreSQL.
    /// Returns nil if the database is not PostgreSQL, no PK modification is pending,
    /// or the query fails (caller falls back to `{table}_pkey` convention).
    private func fetchPrimaryKeyConstraintName(
        tableName: String,
        databaseType: DatabaseType,
        changes: [SchemaChange],
        driver: DatabaseDriver
    ) async -> String? {
        // Only needed for PostgreSQL PK modifications
        guard databaseType == .postgresql || databaseType == .redshift else { return nil }
        guard
            changes.contains(where: {
                if case .modifyPrimaryKey = $0 { return true }
                return false
            })
        else {
            return nil
        }

        // Query the actual constraint name from pg_constraint
        let escapedTable = tableName.replacingOccurrences(of: "'", with: "''")
        let schema: String
        if let pgDriver = driver as? PostgreSQLDriver {
            schema = pgDriver.escapedSchema
        } else if let rsDriver = driver as? RedshiftDriver {
            schema = rsDriver.escapedSchema
        } else {
            schema = "public"
        }
        let query = """
            SELECT con.conname
            FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
            WHERE rel.relname = '\(escapedTable)'
              AND nsp.nspname = '\(schema)'
              AND con.contype = 'p'
            LIMIT 1
            """

        do {
            let result = try await driver.execute(query: query)
            if let row = result.rows.first, let name = row[0], !name.isEmpty {
                return name
            }
        } catch {
            // Query failed - fall back to convention in SchemaStatementGenerator
            Self.logger.warning(
                "Failed to query PK constraint name for '\(tableName)': \(error.localizedDescription)"
            )
        }

        return nil
    }
}

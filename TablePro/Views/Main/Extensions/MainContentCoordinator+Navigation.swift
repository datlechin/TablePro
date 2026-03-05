//
//  MainContentCoordinator+Navigation.swift
//  TablePro
//
//  Table tab opening and database switching operations for MainContentCoordinator
//

import AppKit
import Foundation
import os

private let navigationLogger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator+Navigation")

extension MainContentCoordinator {
    // MARK: - Table Tab Opening

    func openTableTab(_ tableName: String, showStructure: Bool = false, isView: Bool = false) {
        // Get current database name from active session (may differ from connection default after Cmd+K switch)
        let currentDatabase: String
        if connection.type == .redis {
            // Extract db index from table name "db3" → "3"
            guard tableName.hasPrefix("db"), Int(String(tableName.dropFirst(2))) != nil else {
                return
            }
            currentDatabase = String(tableName.dropFirst(2))
        } else if let session = DatabaseManager.shared.session(for: connectionId) {
            currentDatabase = session.activeDatabase
        } else {
            currentDatabase = connection.database
        }

        // Fast path: if this table is already the active tab in the same database, skip all work
        if let current = tabManager.selectedTab,
           current.tabType == .table,
           current.tableName == tableName,
           current.databaseName == currentDatabase {
            if showStructure, let idx = tabManager.selectedTabIndex {
                tabManager.tabs[idx].showStructure = true
            }
            return
        }

        // During database switch, update the existing tab in-place instead of
        // opening a new native window tab.
        if isSwitchingDatabase {
            if tabManager.tabs.isEmpty {
                tabManager.addTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase
                )
            }
            return
        }

        // Check if another native window tab already has this table open — switch to it
        if let keyWindow = NSApp.keyWindow {
            let tabbedWindows = keyWindow.tabbedWindows ?? [keyWindow]
            for window in tabbedWindows where window.title == tableName {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }

        // If no tabs exist (empty state), add a table tab directly
        if tabManager.tabs.isEmpty {
            tabManager.addTableTab(
                tableName: tableName,
                databaseType: connection.type,
                databaseName: currentDatabase
            )
            if let tabIndex = tabManager.selectedTabIndex {
                tabManager.tabs[tabIndex].isView = isView
                tabManager.tabs[tabIndex].isEditable = !isView
                tabManager.tabs[tabIndex].pagination.reset()
                AppState.shared.isCurrentTabEditable = !isView && tableName.isEmpty == false
                toolbarState.isTableTab = true
            }
            runQuery()
            return
        }

        // Redis databases navigate in-place (replace current tab) rather than
        // opening new native window tabs, matching TablePlus behavior.
        if connection.type == .redis {
            if tabManager.replaceTabContent(
                tableName: tableName,
                databaseType: .redis,
                databaseName: currentDatabase
            ) {
                if let tabIndex = tabManager.selectedTabIndex {
                    tabManager.tabs[tabIndex].pagination.reset()
                    toolbarState.isTableTab = true
                }
                if let dbIndex = Int(currentDatabase) {
                    selectRedisDatabaseAndQuery(dbIndex)
                }
            }
            return
        }

        // If current tab has unsaved changes, open in a new native tab instead of replacing
        if changeManager.hasChanges {
            let payload = EditorTabPayload(
                connectionId: connection.id,
                tabType: .table,
                tableName: tableName,
                databaseName: currentDatabase,
                isView: isView,
                showStructure: showStructure
            )
            WindowOpener.shared.openNativeTab(payload)
            return
        }

        // Default: open table in a new native tab
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: tableName,
            databaseName: currentDatabase,
            isView: isView,
            showStructure: showStructure
        )
        WindowOpener.shared.openNativeTab(payload)
    }

    func showAllTablesMetadata() {
        let sql: String
        switch connection.type {
        case .postgresql:
            let schema: String
            if let pgDriver = DatabaseManager.shared.driver(for: connectionId) as? PostgreSQLDriver {
                schema = pgDriver.escapedSchema
            } else {
                schema = "public"
            }
            sql = """
            SELECT
                schemaname as schema,
                relname as name,
                'TABLE' as kind,
                n_live_tup as estimated_rows,
                pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as total_size,
                pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) as data_size,
                pg_size_pretty(pg_indexes_size(schemaname||'.'||relname)) as index_size,
                obj_description((schemaname||'.'||relname)::regclass) as comment
            FROM pg_stat_user_tables
            WHERE schemaname = '\(schema)'
            ORDER BY relname
            """
        case .redshift:
            let schema: String
            if let rsDriver = DatabaseManager.shared.driver(for: connectionId) as? RedshiftDriver {
                schema = rsDriver.escapedSchema
            } else {
                schema = "public"
            }
            sql = """
            SELECT
                schema,
                "table" as name,
                'TABLE' as kind,
                tbl_rows as estimated_rows,
                size as size_mb,
                pct_used,
                unsorted,
                stats_off
            FROM svv_table_info
            WHERE schema = '\(schema)'
            ORDER BY "table"
            """
        case .mysql, .mariadb:
            sql = """
            SELECT
                TABLE_SCHEMA as `schema`,
                TABLE_NAME as name,
                TABLE_TYPE as kind,
                IFNULL(CCSA.CHARACTER_SET_NAME, '') as charset,
                TABLE_COLLATION as collation,
                TABLE_ROWS as estimated_rows,
                CONCAT(ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2), ' MB') as total_size,
                CONCAT(ROUND(DATA_LENGTH / 1024 / 1024, 2), ' MB') as data_size,
                CONCAT(ROUND(INDEX_LENGTH / 1024 / 1024, 2), ' MB') as index_size,
                TABLE_COMMENT as comment
            FROM information_schema.TABLES
            LEFT JOIN information_schema.COLLATION_CHARACTER_SET_APPLICABILITY CCSA
                ON TABLE_COLLATION = CCSA.COLLATION_NAME
            WHERE TABLE_SCHEMA = DATABASE()
            ORDER BY TABLE_NAME
            """
        case .sqlite:
            sql = """
            SELECT
                '' as schema,
                name,
                type as kind,
                '' as charset,
                '' as collation,
                '' as estimated_rows,
                '' as total_size,
                '' as data_size,
                '' as index_size,
                '' as comment
            FROM sqlite_master
            WHERE type IN ('table', 'view')
            AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        case .mssql:
            sql = """
            SELECT
                s.name as schema_name,
                t.name as name,
                CASE WHEN v.object_id IS NOT NULL THEN 'VIEW' ELSE 'TABLE' END as kind,
                p.rows as estimated_rows,
                CAST(ROUND(SUM(a.total_pages) * 8 / 1024.0, 2) AS VARCHAR) + ' MB' as total_size
            FROM sys.tables t
            INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
            INNER JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0, 1)
            INNER JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
            INNER JOIN sys.allocation_units a ON p.partition_id = a.container_id
            LEFT JOIN sys.views v ON t.object_id = v.object_id
            GROUP BY s.name, t.name, p.rows, v.object_id
            ORDER BY t.name
            """
        case .mongodb:
            tabManager.addTab(
                initialQuery: "db.runCommand({\"listCollections\": 1, \"nameOnly\": false})",
                databaseName: connection.database
            )
            runQuery()
            return
        case .redis:
            tabManager.addTab(
                initialQuery: "SCAN 0 MATCH * COUNT 100",
                databaseName: connection.database
            )
            runQuery()
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            initialQuery: sql
        )
        WindowOpener.shared.openNativeTab(payload)
    }

    // MARK: - Database Switching

    /// Close all sibling native window-tabs except the current key window.
    /// Each table opened via WindowOpener creates a separate NSWindow in the same
    /// tab group. Clearing `tabManager.tabs` only affects the in-app state of the
    /// *current* window — other NSWindows remain open with stale content.
    private func closeSiblingNativeWindows() {
        guard let keyWindow = NSApp.keyWindow else { return }
        let siblings = keyWindow.tabbedWindows ?? []
        for sibling in siblings where sibling !== keyWindow {
            sibling.close()
        }
    }

    /// Switch to a different database (called from database switcher)
    func switchDatabase(to database: String) async {
        isSwitchingDatabase = true
        defer {
            isSwitchingDatabase = false
        }

        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            return
        }

        do {
            // For MySQL/MariaDB, use USE command
            if connection.type == .mysql || connection.type == .mariadb {
                _ = try await driver.execute(query: "USE `\(database)`")

                // Also switch metadata driver's database
                if let metaDriver = DatabaseManager.shared.metadataDriver(for: connectionId) {
                    _ = try? await metaDriver.execute(query: "USE `\(database)`")
                }

                // Update session with new database
                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentDatabase = database
                    session.tables = []          // triggers SidebarView.loadTables() via onChange
                }

                // Update toolbar state
                toolbarState.databaseName = database

                // Close sibling native window-tabs and clear in-app tabs —
                // previous database's tables/queries are no longer valid
                closeSiblingNativeWindows()
                tabManager.tabs = []
                tabManager.selectedTabId = nil

                // Reload schema for autocomplete.
                // session.tables was cleared above, which triggers SidebarView.loadTables() via onChange.
                await loadSchema()
            } else if connection.type == .postgresql || connection.type == .redshift {
                // PostgreSQL: switch schema (not database — PG database switching requires reconnection)
                if let pgDriver = driver as? PostgreSQLDriver {
                    try await pgDriver.switchSchema(to: database)
                } else if let rsDriver = driver as? RedshiftDriver {
                    try await rsDriver.switchSchema(to: database)
                } else {
                    return
                }

                // Also switch metadata driver's schema
                if let pgMeta = DatabaseManager.shared.metadataDriver(for: connectionId) as? PostgreSQLDriver {
                    try? await pgMeta.switchSchema(to: database)
                } else if let rsMeta = DatabaseManager.shared.metadataDriver(for: connectionId) as? RedshiftDriver {
                    try? await rsMeta.switchSchema(to: database)
                }

                // Update session
                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentSchema = database
                    session.tables = []  // triggers SidebarView.loadTables() via onChange
                }

                // Update toolbar state
                toolbarState.databaseName = database

                // Close sibling native window-tabs and clear in-app tabs —
                // previous schema's tables/queries are no longer valid
                closeSiblingNativeWindows()
                tabManager.tabs = []
                tabManager.selectedTabId = nil

                // Reload schema for autocomplete
                await loadSchema()

                // Force sidebar reload — posting .refreshData ensures loadTables() runs
                // even when session.tables was already [] (e.g. switching from empty schema back to public)
                NotificationCenter.default.post(name: .refreshData, object: nil)
            } else if connection.type == .mssql {
                if let mssqlDriver = driver as? MSSQLDriver {
                    try await mssqlDriver.switchDatabase(to: database)
                }

                if let mssqlMeta = DatabaseManager.shared.metadataDriver(for: connectionId) as? MSSQLDriver {
                    try? await mssqlMeta.switchDatabase(to: database)
                }

                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentDatabase = database
                    session.currentSchema = "dbo"
                    session.tables = []
                }
                AppSettingsStorage.shared.saveLastDatabase(database, for: connectionId)

                toolbarState.databaseName = database

                closeSiblingNativeWindows()
                tabManager.tabs = []
                tabManager.selectedTabId = nil

                await loadSchema()

                NotificationCenter.default.post(name: .refreshData, object: nil)
            } else if connection.type == .mongodb {
                // MongoDB: update the driver's connection so fetchTables/execute use the new database
                if let mongoDriver = driver as? MongoDBDriver {
                    mongoDriver.switchDatabase(to: database)
                }

                // Also update metadata driver if present
                if let metaDriver = DatabaseManager.shared.metadataDriver(for: connectionId) as? MongoDBDriver {
                    metaDriver.switchDatabase(to: database)
                }

                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentDatabase = database
                    session.tables = []
                }

                toolbarState.databaseName = database

                // Close sibling native window-tabs and clear in-app tabs —
                // previous database's collections are no longer valid
                closeSiblingNativeWindows()
                tabManager.tabs = []
                tabManager.selectedTabId = nil

                await loadSchema()

                NotificationCenter.default.post(name: .refreshData, object: nil)
            } else if connection.type == .redis {
                // Redis: SELECT <db index> to switch logical database
                guard let dbIndex = Int(database) else { return }

                if let redisDriver = driver as? RedisDriver {
                    try await redisDriver.selectDatabase(dbIndex)
                }

                if let metaRedisDriver = DatabaseManager.shared.metadataDriver(for: connectionId) as? RedisDriver {
                    try? await metaRedisDriver.selectDatabase(dbIndex)
                }

                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentDatabase = database
                    session.tables = []
                }

                toolbarState.databaseName = database

                closeSiblingNativeWindows()
                tabManager.tabs = []
                tabManager.selectedTabId = nil

                await loadSchema()

                NotificationCenter.default.post(name: .refreshData, object: nil)
            }
        } catch {
            navigationLogger.error("Failed to switch database: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Database Switch Failed"),
                message: error.localizedDescription,
                window: NSApplication.shared.keyWindow
            )
        }
    }

    // MARK: - Redis Database Selection

    /// Select a Redis database index and then run the query.
    /// Redis sidebar clicks go through openTableTab (sync), so we need a Task
    /// to call the async selectDatabase before executing the query.
    private func selectRedisDatabaseAndQuery(_ dbIndex: Int) {
        let connId = connectionId
        let database = String(dbIndex)
        Task { @MainActor in
            do {
                if let redisDriver = DatabaseManager.shared.driver(for: connId) as? RedisDriver {
                    try await redisDriver.selectDatabase(dbIndex)
                }
            } catch {
                navigationLogger.error("Failed to SELECT Redis db\(dbIndex): \(error.localizedDescription, privacy: .public)")
                return
            }
            if let metaRedisDriver = DatabaseManager.shared.metadataDriver(for: connId) as? RedisDriver {
                try? await metaRedisDriver.selectDatabase(dbIndex)
            }
            DatabaseManager.shared.updateSession(connId) { session in
                session.currentDatabase = database
            }
            toolbarState.databaseName = database
            executeTableTabQueryDirectly()
        }
    }
}

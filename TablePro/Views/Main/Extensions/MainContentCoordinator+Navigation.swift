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

        // If no tabs exist (empty state), add a table tab directly.
        // In preview mode, mark it as preview so subsequent clicks replace it.
        if tabManager.tabs.isEmpty {
            if AppSettingsManager.shared.tabs.enablePreviewTabs {
                tabManager.addPreviewTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase
                )
                if let wid = windowId {
                    WindowLifecycleMonitor.shared.setPreview(true, for: wid)
                    WindowLifecycleMonitor.shared.window(for: wid)?.subtitle = "\(connection.name) — Preview"
                }
            } else {
                tabManager.addTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase
                )
            }
            if let tabIndex = tabManager.selectedTabIndex {
                tabManager.tabs[tabIndex].isView = isView
                tabManager.tabs[tabIndex].isEditable = !isView
                tabManager.tabs[tabIndex].pagination.reset()
                AppState.shared.isCurrentTabEditable = !isView && tableName.isEmpty == false
                toolbarState.isTableTab = true
            }
            // Redis needs selectRedisDatabaseAndQuery to ensure the correct
            // database is SELECTed and session state is updated before querying.
            if connection.type == .redis, let dbIndex = Int(currentDatabase) {
                selectRedisDatabaseAndQuery(dbIndex)
            } else {
                runQuery()
            }
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

        // Preview tab mode: reuse or create a preview tab instead of a new native window
        if AppSettingsManager.shared.tabs.enablePreviewTabs {
            openPreviewTab(tableName, isView: isView, databaseName: currentDatabase, showStructure: showStructure)
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

    // MARK: - Preview Tabs

    func openPreviewTab(
        _ tableName: String, isView: Bool = false,
        databaseName: String = "", showStructure: Bool = false
    ) {
        // Check if a preview window already exists for this connection
        if let preview = WindowLifecycleMonitor.shared.previewWindow(for: connectionId) {
            if let previewCoordinator = Self.coordinator(for: preview.windowId) {
                // Skip if preview tab already shows this table
                if let current = previewCoordinator.tabManager.selectedTab,
                   current.tableName == tableName,
                   current.databaseName == databaseName {
                    preview.window.makeKeyAndOrderFront(nil)
                    return
                }
                previewCoordinator.tabManager.replaceTabContent(
                    tableName: tableName,
                    databaseType: connection.type,
                    isView: isView,
                    databaseName: databaseName,
                    isPreview: true
                )
                if let tabIndex = previewCoordinator.tabManager.selectedTabIndex {
                    previewCoordinator.tabManager.tabs[tabIndex].showStructure = showStructure
                    previewCoordinator.tabManager.tabs[tabIndex].pagination.reset()
                    AppState.shared.isCurrentTabEditable = !isView && !tableName.isEmpty
                    previewCoordinator.toolbarState.isTableTab = true
                }
                preview.window.makeKeyAndOrderFront(nil)
                previewCoordinator.runQuery()
                return
            }
        }

        // No preview window exists but current tab is already a preview: replace in-place
        if let selectedTab = tabManager.selectedTab, selectedTab.isPreview {
            // Skip if already showing this table
            if selectedTab.tableName == tableName, selectedTab.databaseName == databaseName {
                return
            }
            tabManager.replaceTabContent(
                tableName: tableName,
                databaseType: connection.type,
                isView: isView,
                databaseName: databaseName,
                isPreview: true
            )
            if let tabIndex = tabManager.selectedTabIndex {
                tabManager.tabs[tabIndex].showStructure = showStructure
                tabManager.tabs[tabIndex].pagination.reset()
                AppState.shared.isCurrentTabEditable = !isView && !tableName.isEmpty
                toolbarState.isTableTab = true
            }
            runQuery()
            return
        }

        // No preview tab anywhere: create a new native preview tab
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: tableName,
            databaseName: databaseName,
            isView: isView,
            showStructure: showStructure,
            isPreview: true
        )
        WindowOpener.shared.openNativeTab(payload)
    }

    func promotePreviewTab() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabManager.tabs[tabIndex].isPreview else { return }
        tabManager.tabs[tabIndex].isPreview = false

        if let wid = windowId {
            WindowLifecycleMonitor.shared.setPreview(false, for: wid)
            WindowLifecycleMonitor.shared.window(for: wid)?.subtitle = connection.name
        }
    }

    func showAllTablesMetadata() {
        guard let sql = allTablesMetadataSQL() else { return }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            initialQuery: sql
        )
        WindowOpener.shared.openNativeTab(payload)
    }

    // swiftlint:disable:next function_body_length
    private func allTablesMetadataSQL() -> String? {
        let dbType = connection.type
        if dbType == .postgresql {
            let schema = (DatabaseManager.shared.driver(for: connectionId) as? SchemaSwitchable)?.escapedSchema ?? "public"
            return """
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
        } else if dbType == .redshift {
            let schema = (DatabaseManager.shared.driver(for: connectionId) as? SchemaSwitchable)?.escapedSchema ?? "public"
            return """
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
        } else if dbType == .clickhouse {
            return """
            SELECT
                database as `schema`,
                name,
                engine as kind,
                total_rows as estimated_rows,
                formatReadableSize(total_bytes) as total_size,
                comment
            FROM system.tables
            WHERE database = currentDatabase()
            ORDER BY name
            """
        } else if dbType == .mysql || dbType == .mariadb {
            return """
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
        } else if dbType == .sqlite {
            return """
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
        } else if dbType == .mssql {
            return """
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
        } else if dbType == .oracle {
            let schema = (DatabaseManager.shared.driver(for: connectionId) as? SchemaSwitchable)?.escapedSchema ?? "SYSTEM"
            return """
            SELECT
                OWNER as schema_name,
                TABLE_NAME as name,
                'TABLE' as kind,
                NUM_ROWS as estimated_rows
            FROM ALL_TABLES
            WHERE OWNER = '\(schema)'
            ORDER BY TABLE_NAME
            """
        } else if dbType == .duckdb {
            let schema = (DatabaseManager.shared.driver(for: connectionId) as? SchemaSwitchable)?.escapedSchema ?? "main"
            return """
            SELECT
                table_schema as schema_name,
                table_name as name,
                table_type as kind
            FROM information_schema.tables
            WHERE table_schema = '\(schema)'
            ORDER BY table_name
            """
        } else if dbType == .mongodb {
            tabManager.addTab(
                initialQuery: "db.runCommand({\"listCollections\": 1, \"nameOnly\": false})",
                databaseName: connection.database
            )
            runQuery()
            return nil
        } else if dbType == .redis {
            tabManager.addTab(
                initialQuery: "SCAN 0 MATCH * COUNT 100",
                databaseName: connection.database
            )
            runQuery()
            return nil
        }
        return nil
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

        // Clear stale filter state from previous database/schema
        filterStateManager.clearAll()

        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            return
        }

        // Snapshot current state for rollback on failure
        let previousDatabase = toolbarState.databaseName

        // Immediately clear UI state so the sidebar shows a loading spinner
        // instead of stale tables from the previous database/schema.
        toolbarState.databaseName = database
        closeSiblingNativeWindows()
        tabManager.tabs = []
        tabManager.selectedTabId = nil
        DatabaseManager.shared.updateSession(connectionId) { session in
            session.tables = []
        }
        // Yield so SwiftUI renders the empty/loading state before async work begins
        await Task.yield()

        do {
            // For MySQL/MariaDB/ClickHouse, use USE command
            if connection.type == .mysql || connection.type == .mariadb || connection.type == .clickhouse {
                _ = try await driver.execute(query: "USE `\(database)`")

                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentDatabase = database
                }

                await loadSchema()

                reloadSidebar()
            } else if connection.type == .postgresql {
                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.connection.database = database
                    session.currentDatabase = database
                    session.currentSchema = nil
                }

                await DatabaseManager.shared.reconnectSession(connectionId)

                await loadSchema()

                reloadSidebar()
            } else if connection.type == .redshift {
                guard let schemaDriver = driver as? SchemaSwitchable else { return }
                try await schemaDriver.switchSchema(to: database)

                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentSchema = database
                }

                await loadSchema()

                reloadSidebar()
            } else if connection.type == .oracle {
                guard let schemaDriver = driver as? SchemaSwitchable else { return }
                try await schemaDriver.switchSchema(to: database)

                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentSchema = database
                }

                await loadSchema()

                reloadSidebar()
            } else if connection.type == .mssql {
                if let adapter = driver as? PluginDriverAdapter {
                    try await adapter.switchDatabase(to: database)
                }

                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentDatabase = database
                    session.currentSchema = "dbo"
                }
                AppSettingsStorage.shared.saveLastDatabase(database, for: connectionId)

                await loadSchema()

                reloadSidebar()
            } else if connection.type == .mongodb {
                if let adapter = driver as? PluginDriverAdapter {
                    try await adapter.switchDatabase(to: database)
                }

                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentDatabase = database
                }

                await loadSchema()

                reloadSidebar()
            } else if connection.type == .redis {
                guard let dbIndex = Int(database) else { return }

                if let adapter = driver as? PluginDriverAdapter {
                    try await adapter.switchDatabase(to: String(dbIndex))
                }

                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentDatabase = database
                }

                await loadSchema()

                reloadSidebar()
            }
        } catch {
            // Restore toolbar to previous database on failure
            toolbarState.databaseName = previousDatabase
            // Reload previous tables so sidebar isn't left empty
            reloadSidebar()

            navigationLogger.error("Failed to switch database: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Database Switch Failed"),
                message: error.localizedDescription,
                window: NSApplication.shared.keyWindow
            )
        }
    }

    /// Switch to a different PostgreSQL schema (used for URL-based schema selection)
    func switchSchema(to schema: String) async {
        guard connection.type == .postgresql else { return }
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }

        // Clear stale filter state from previous schema
        filterStateManager.clearAll()

        // Snapshot current state for rollback on failure
        let previousSchema = toolbarState.databaseName

        // Immediately clear UI state so sidebar shows loading state
        toolbarState.databaseName = schema
        closeSiblingNativeWindows()
        tabManager.tabs = []
        tabManager.selectedTabId = nil
        DatabaseManager.shared.updateSession(connectionId) { session in
            session.tables = []
        }
        await Task.yield()

        do {
            guard let schemaDriver = driver as? SchemaSwitchable else { return }
            try await schemaDriver.switchSchema(to: schema)

            DatabaseManager.shared.updateSession(connectionId) { session in
                session.currentSchema = schema
            }

            await loadSchema()

            reloadSidebar()
        } catch {
            // Restore toolbar to previous schema on failure
            toolbarState.databaseName = previousSchema
            reloadSidebar()

            navigationLogger.error("Failed to switch schema: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Schema Switch Failed"),
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
                if let adapter = DatabaseManager.shared.driver(for: connId) as? PluginDriverAdapter {
                    try await adapter.switchDatabase(to: String(dbIndex))
                }
            } catch {
                navigationLogger.error("Failed to SELECT Redis db\(dbIndex): \(error.localizedDescription, privacy: .public)")
                return
            }
            DatabaseManager.shared.updateSession(connId) { session in
                session.currentDatabase = database
            }
            toolbarState.databaseName = database
            executeTableTabQueryDirectly()
        }
    }
}

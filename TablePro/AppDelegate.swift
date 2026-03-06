//
//  AppDelegate.swift
//  TablePro
//
//  Window configuration using AppKit-native approach
//

import AppKit
import os
import SwiftUI

/// AppDelegate handles window lifecycle events using proper AppKit patterns.
/// This is the correct way to configure window appearance on macOS, rather than
/// using SwiftUI view hacks which can be unreliable.
///
/// **Why this approach is better:**
/// 1. **Proper lifecycle management**: NSApplicationDelegate receives window events at the right time
/// 2. **Stable and reliable**: AppKit APIs are mature and well-documented
/// 3. **Separation of concerns**: Window configuration is separate from SwiftUI views
/// 4. **Future-proof**: Works reliably across macOS Ventura/Sonoma and future versions
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AppDelegate")
    /// Track windows that have been configured to avoid re-applying styles (which causes flicker)
    private var configuredWindows = Set<ObjectIdentifier>()

    /// URLs queued for opening when no database connection is active yet
    private var queuedFileURLs: [URL] = []

    /// True while handling a file-open event with an active connection.
    /// Prevents SwiftUI from showing the welcome window as a side-effect.
    private var isHandlingFileOpen = false

    /// Counter tracking outstanding file-open suppressions.
    /// Incremented when a file-open starts, decremented by each delayed
    /// cleanup pass.  While > 0 the welcome window is suppressed.
    private var fileOpenSuppressionCount = 0

    private static let databaseURLSchemes: Set<String> = [
        "postgresql", "postgres", "mysql", "mariadb", "sqlite",
        "mongodb", "redis", "rediss", "redshift"
    ]

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let welcomeItem = NSMenuItem(
            title: String(localized: "Show Welcome Window"),
            action: #selector(showWelcomeFromDock),
            keyEquivalent: ""
        )
        welcomeItem.target = self
        menu.addItem(welcomeItem)

        // Add connections submenu
        let connections = ConnectionStorage.shared.loadConnections()
        if !connections.isEmpty {
            let connectionsItem = NSMenuItem(title: String(localized: "Open Connection"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            for connection in connections {
                let item = NSMenuItem(
                    title: connection.name,
                    action: #selector(connectFromDock(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = connection.id
                if let original = NSImage(named: connection.type.iconName) {
                    let resized = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                        original.draw(in: rect)
                        return true
                    }
                    item.image = resized
                }
                submenu.addItem(item)
            }

            connectionsItem.submenu = submenu
            menu.addItem(connectionsItem)
        }

        return menu
    }

    @objc
    private func showWelcomeFromDock() {
        openWelcomeWindow()
    }

    @objc
    private func connectFromDock(_ sender: NSMenuItem) {
        guard let connectionId = sender.representedObject as? UUID else { return }
        let connections = ConnectionStorage.shared.loadConnections()
        guard let connection = connections.first(where: { $0.id == connectionId }) else { return }

        // Open main window and connect (same flow as auto-reconnect)
        NotificationCenter.default.post(name: .openMainWindow, object: connection.id)

        Task { @MainActor in
            do {
                try await DatabaseManager.shared.connectToSession(connection)

                // Close welcome window on successful connection
                for window in NSApp.windows where self.isWelcomeWindow(window) {
                    window.close()
                }
            } catch {
                Self.logger.error("Dock connection failed for '\(connection.name)': \(error.localizedDescription)")

                // Connection failed - close main window, reopen welcome
                for window in NSApp.windows where self.isMainWindow(window) {
                    window.close()
                }
                self.openWelcomeWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When the app already has visible windows (e.g. main connection window),
        // return false to prevent SwiftUI from creating the default welcome window.
        // The welcome window should only appear when explicitly requested
        // (e.g. via dock menu or after closing the main window).
        if flag {
            // Bring the topmost relevant window to front instead
            for window in NSApp.windows where isMainWindow(window) {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Handle deep links
        let deeplinkURLs = urls.filter { $0.scheme == "tablepro" }
        if !deeplinkURLs.isEmpty {
            Task { @MainActor in
                for url in deeplinkURLs {
                    self.handleDeeplink(url)
                }
            }
        }

        // Handle database connection URLs (e.g. postgresql://user@host/db)
        let databaseURLs = urls.filter { url in
            guard let scheme = url.scheme?.lowercased() else { return false }
            let baseScheme = scheme.replacingOccurrences(of: "+ssh", with: "")
            return Self.databaseURLSchemes.contains(baseScheme)
        }
        if !databaseURLs.isEmpty {
            Task { @MainActor in
                for url in databaseURLs {
                    self.handleDatabaseURL(url)
                }
            }
        }

        // Handle SQL files (existing logic unchanged)
        let sqlURLs = urls.filter { $0.pathExtension.lowercased() == "sql" }
        guard !sqlURLs.isEmpty else { return }

        if DatabaseManager.shared.currentSession != nil {
            // Suppress any welcome window that SwiftUI may create as a
            // side-effect of the app being activated by the file-open event.
            isHandlingFileOpen = true
            fileOpenSuppressionCount += 1

            // Already connected — bring main window to front and open files
            for window in NSApp.windows where isMainWindow(window) {
                window.makeKeyAndOrderFront(nil)
            }
            // Close welcome window if it's already open
            for window in NSApp.windows where isWelcomeWindow(window) {
                window.close()
            }
            NotificationCenter.default.post(name: .openSQLFiles, object: sqlURLs)

            // SwiftUI may asynchronously create a welcome window after this
            // method returns (scene restoration on activation).  Schedule
            // multiple cleanup passes so we catch windows that appear late.
            scheduleWelcomeWindowSuppression()
        } else {
            // Not connected — queue and show welcome window
            queuedFileURLs.append(contentsOf: sqlURLs)
            openWelcomeWindow()
        }
    }

    @MainActor
    private func handleDeeplink(_ url: URL) {
        guard let action = DeeplinkHandler.parse(url) else { return }

        switch action {
        case .connect(let name):
            connectViaDeeplink(connectionName: name)

        case .openTable(let name, let table, let database):
            connectViaDeeplink(connectionName: name) { connectionId in
                EditorTabPayload(connectionId: connectionId, tabType: .table,
                                 tableName: table, databaseName: database)
            }

        case .openQuery(let name, let sql):
            connectViaDeeplink(connectionName: name) { connectionId in
                EditorTabPayload(connectionId: connectionId, tabType: .query,
                                 initialQuery: sql)
            }

        case .importConnection(let name, let host, let port, let type, let username, let database):
            handleImportDeeplink(name: name, host: host, port: port, type: type,
                                 username: username, database: database)
        }
    }

    @MainActor
    private func connectViaDeeplink(
        connectionName: String,
        makePayload: (@Sendable (UUID) -> EditorTabPayload)? = nil
    ) {
        guard let connection = DeeplinkHandler.resolveConnection(named: connectionName) else {
            Self.logger.error("Deep link: no connection named '\(connectionName, privacy: .public)'")
            AlertHelper.showErrorSheet(
                title: String(localized: "Connection Not Found"),
                message: String(localized: "No saved connection named \"\(connectionName)\"."),
                window: NSApp.keyWindow
            )
            return
        }

        // Already connected — open tab directly
        if DatabaseManager.shared.activeSessions[connection.id]?.driver != nil {
            if let payload = makePayload?(connection.id) {
                WindowOpener.shared.openNativeTab(payload)
            } else {
                for window in NSApp.windows where isMainWindow(window) {
                    window.makeKeyAndOrderFront(nil)
                    return
                }
            }
            return
        }

        // Not connected — same pattern as connectFromDock
        NotificationCenter.default.post(name: .openMainWindow, object: connection.id)

        Task { @MainActor in
            do {
                try await DatabaseManager.shared.connectToSession(connection)
                for window in NSApp.windows where self.isWelcomeWindow(window) {
                    window.close()
                }
                if let payload = makePayload?(connection.id) {
                    WindowOpener.shared.openNativeTab(payload)
                }
            } catch {
                Self.logger.error("Deep link connect failed: \(error.localizedDescription)")
                for window in NSApp.windows where self.isMainWindow(window) {
                    window.close()
                }
                self.openWelcomeWindow()
                AlertHelper.showErrorSheet(
                    title: String(localized: "Connection Failed"),
                    message: error.localizedDescription,
                    window: NSApp.keyWindow
                )
            }
        }
    }

    @MainActor
    private func handleImportDeeplink(
        name: String, host: String, port: Int,
        type: DatabaseType, username: String, database: String
    ) {
        let connection = DatabaseConnection(
            name: name, host: host, port: port,
            database: database, username: username, type: type
        )
        ConnectionStorage.shared.addConnection(connection)
        NotificationCenter.default.post(name: .connectionUpdated, object: nil)

        if let openWindow = WindowOpener.shared.openWindow {
            openWindow(id: "connection-form", value: connection.id)
        }
    }

    @MainActor
    private func handleDatabaseURL(_ url: URL) {
        let result = ConnectionURLParser.parse(url.absoluteString)
        guard case .success(let parsed) = result else {
            Self.logger.error("Failed to parse database URL: \(url.absoluteString, privacy: .public)")
            return
        }

        // Try to find a matching saved connection
        let connections = ConnectionStorage.shared.loadConnections()
        let matchedConnection = connections.first { conn in
            conn.type == parsed.type
                && conn.host == parsed.host
                && (parsed.port == nil || conn.port == parsed.port)
                && conn.database == parsed.database
                && (parsed.username.isEmpty || conn.username == parsed.username)
        }

        let connection: DatabaseConnection
        if let matched = matchedConnection {
            connection = matched
        } else {
            // Create a transient connection (not saved to storage)
            var sshConfig = SSHConfiguration()
            if let sshHost = parsed.sshHost {
                sshConfig.enabled = true
                sshConfig.host = sshHost
                sshConfig.port = parsed.sshPort ?? 22
                sshConfig.username = parsed.sshUsername ?? ""
                if parsed.usePrivateKey == true {
                    sshConfig.authMethod = .privateKey
                }
            }

            var sslConfig = SSLConfiguration()
            if let sslMode = parsed.sslMode {
                sslConfig.mode = sslMode
            }

            var color: ConnectionColor = .none
            if let hex = parsed.statusColor {
                color = ConnectionURLParser.connectionColor(fromHex: hex)
            }

            var tagId: UUID?
            if let envName = parsed.envTag {
                tagId = ConnectionURLParser.tagId(fromEnvName: envName)
            }

            connection = DatabaseConnection(
                name: parsed.connectionName ?? parsed.suggestedName,
                host: parsed.host,
                port: parsed.port ?? parsed.type.defaultPort,
                database: parsed.database,
                username: parsed.username,
                type: parsed.type,
                sshConfig: sshConfig,
                sslConfig: sslConfig,
                color: color,
                tagId: tagId,
                redisDatabase: parsed.redisDatabase
            )
        }

        // Store password in Keychain if provided
        if !parsed.password.isEmpty {
            ConnectionStorage.shared.savePassword(parsed.password, for: connection.id)
        }

        // If already connected to this connection, just handle post-connect actions
        if DatabaseManager.shared.activeSessions[connection.id]?.driver != nil {
            handlePostConnectionActions(parsed, connectionId: connection.id)
            for window in NSApp.windows where isMainWindow(window) {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

        // Connect using the same pattern as connectViaDeeplink
        NotificationCenter.default.post(name: .openMainWindow, object: connection.id)

        Task { @MainActor in
            do {
                try await DatabaseManager.shared.connectToSession(connection)
                for window in NSApp.windows where self.isWelcomeWindow(window) {
                    window.close()
                }
                self.handlePostConnectionActions(parsed, connectionId: connection.id)
            } catch {
                Self.logger.error("Database URL connect failed: \(error.localizedDescription)")
                for window in NSApp.windows where self.isMainWindow(window) {
                    window.close()
                }
                self.openWelcomeWindow()
                AlertHelper.showErrorSheet(
                    title: String(localized: "Connection Failed"),
                    message: error.localizedDescription,
                    window: NSApp.keyWindow
                )
            }
        }
    }

    @MainActor
    private func handlePostConnectionActions(_ parsed: ParsedConnectionURL, connectionId: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))

            // Switch schema if specified (PostgreSQL/Redshift only)
            if let schema = parsed.schema,
               parsed.type == .postgresql || parsed.type == .redshift {
                NotificationCenter.default.post(
                    name: .switchSchemaFromURL,
                    object: nil,
                    userInfo: ["connectionId": connectionId, "schema": schema]
                )
                try? await Task.sleep(for: .milliseconds(500))
            }

            // Open table/view if specified
            if let tableName = parsed.tableName {
                let payload = EditorTabPayload(
                    connectionId: connectionId,
                    tabType: .table,
                    tableName: tableName,
                    isView: parsed.isView
                )
                WindowOpener.shared.openNativeTab(payload)

                // Apply filter after table loads
                if parsed.filterColumn != nil || parsed.filterCondition != nil {
                    try? await Task.sleep(for: .milliseconds(800))
                    NotificationCenter.default.post(
                        name: .applyURLFilter,
                        object: nil,
                        userInfo: [
                            "connectionId": connectionId,
                            "column": parsed.filterColumn as Any,
                            "operation": parsed.filterOperation as Any,
                            "value": parsed.filterValue as Any,
                            "condition": parsed.filterCondition as Any
                        ]
                    )
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enable native macOS window tabbing (Finder/Safari-style tabs)
        NSWindow.allowsAutomaticWindowTabbing = true

        // Start license periodic validation
        Task { @MainActor in
            LicenseManager.shared.startPeriodicValidation()
        }

        // Start anonymous usage analytics heartbeat
        AnalyticsService.shared.startPeriodicHeartbeat()

        // Pre-warm query history storage on background thread
        // (avoids blocking main thread on first access due to queue.sync in init)
        Task.detached(priority: .background) {
            _ = QueryHistoryStorage.shared
        }

        // Configure windows after app launch
        configureWelcomeWindow()

        // Check startup behavior setting
        let settings = AppSettingsStorage.shared.loadGeneral()
        let shouldReopenLast = settings.startupBehavior == .reopenLast

        if shouldReopenLast, let lastConnectionId = AppSettingsStorage.shared.loadLastConnectionId() {
            // Try to auto-reconnect to last session
            attemptAutoReconnect(connectionId: lastConnectionId)
        } else {
            // Normal startup: close any restored main windows
            closeRestoredMainWindows()
        }

        // Observe for new windows being created
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        // Observe for main window being closed
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        // Observe window visibility changes to suppress the welcome
        // window even when it becomes visible without becoming key
        // (e.g. SwiftUI restores it in the background during file-open).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeOcclusionState(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )

        // Observe database connection to flush queued .sql files
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDatabaseDidConnect),
            name: .databaseDidConnect,
            object: nil
        )
    }

    private func scheduleWelcomeWindowSuppression() {
        Task { @MainActor [weak self] in
            // Single check after a short delay for window creation
            try? await Task.sleep(for: .milliseconds(300))
            self?.closeWelcomeWindowIfMainExists()
            // One final check after windows settle
            try? await Task.sleep(for: .milliseconds(700))
            guard let self else { return }
            self.closeWelcomeWindowIfMainExists()
            self.fileOpenSuppressionCount = max(0, self.fileOpenSuppressionCount - 1)
            if self.fileOpenSuppressionCount == 0 {
                self.isHandlingFileOpen = false
            }
        }
    }

    /// Close the welcome window if a connected main window is present.
    private func closeWelcomeWindowIfMainExists() {
        let hasMainWindow = NSApp.windows.contains { isMainWindow($0) && $0.isVisible }
        guard hasMainWindow else { return }
        for window in NSApp.windows where isWelcomeWindow(window) {
            window.close()
        }
    }

    @objc
    private func handleDatabaseDidConnect() {
        guard !queuedFileURLs.isEmpty else { return }
        let urls = queuedFileURLs
        queuedFileURLs.removeAll()
        postSQLFilesWhenReady(urls: urls)
    }

    private func postSQLFilesWhenReady(urls: [URL]) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            if !NSApp.windows.contains(where: { self?.isMainWindow($0) == true && $0.isKeyWindow }) {
                Self.logger.warning("postSQLFilesWhenReady: no key main window, posting anyway")
            }
            NotificationCenter.default.post(name: .openSQLFiles, object: urls)
        }
    }

    /// Attempt to auto-reconnect to the last used connection
    private func attemptAutoReconnect(connectionId: UUID) {
        // Load connections and find the one we want
        let connections = ConnectionStorage.shared.loadConnections()
        guard let connection = connections.first(where: { $0.id == connectionId }) else {
            // Connection was deleted, fall back to welcome window
            AppSettingsStorage.shared.saveLastConnectionId(nil)
            closeRestoredMainWindows()
            openWelcomeWindow()
            return
        }

        // Open main window first, then attempt connection
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Open main window via notification FIRST (before closing welcome window)
            // The OpenWindowHandler in welcome window will process this
            NotificationCenter.default.post(name: .openMainWindow, object: connection.id)

            // Connect in background and handle result
            Task { @MainActor in
                do {
                    try await DatabaseManager.shared.connectToSession(connection)

                    // Connection successful - close welcome window
                    for window in NSApp.windows where self.isWelcomeWindow(window) {
                        window.close()
                    }
                } catch {
                    // Log the error for debugging
                    Self.logger.error("Auto-reconnect failed for '\(connection.name)': \(error.localizedDescription)")

                    // Connection failed - close main window and show welcome
                    for window in NSApp.windows where self.isMainWindow(window) {
                        window.close()
                    }

                    self.openWelcomeWindow()
                }
            }
        }
    }

    /// Close any macOS-restored main windows
    private func closeRestoredMainWindows() {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue.contains("main") == true {
                window.close()
            }
        }
    }

    @objc
    private func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isHandlingFileOpen else { return }

        // When the welcome window becomes visible during a file-open
        // event, close it so the user sees the main connection window.
        if isWelcomeWindow(window),
           window.occlusionState.contains(.visible),
           NSApp.windows.contains(where: { isMainWindow($0) && $0.isVisible }) {
            // Defer to next run-loop cycle so AppKit finishes ordering
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isWelcomeWindow(window), window.isVisible {
                    window.close()
                }
            }
        }
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        // Clean up window tracking
        configuredWindows.remove(ObjectIdentifier(window))

        // Check if main window is being closed
        if isMainWindow(window) {
            // Count remaining main windows (excluding the one being closed).
            // We cannot rely on `window.tabbedWindows?.count` because AppKit
            // may have already detached the closing window from its tab group
            // by the time `willClose` fires, making the count unreliable.
            let remainingMainWindows = NSApp.windows.filter {
                $0 !== window && isMainWindow($0) && $0.isVisible
            }.count

            if remainingMainWindows == 0 {
                // Last main window closing → save tabs and return to welcome screen.
                // Per-connection disconnect is handled by each MainContentView's
                // onDisappear (via NativeTabRegistry check), so we don't disconnectAll here.
                NotificationCenter.default.post(name: .mainWindowWillClose, object: nil)

                // Reopen welcome window on next run loop after the close finishes
                DispatchQueue.main.async {
                    self.openWelcomeWindow()
                }
            }
            // If not the last tab, just let the window close naturally —
            // macOS handles removing the tab from the tab group.
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save tab state synchronously before app terminates (backup mechanism)
        saveAllTabStates()
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Save tab state for all active sessions using combined state from all native window-tabs
    @MainActor
    private func saveAllTabStates() {
        // Collect tabs from NativeTabRegistry (authoritative source for native window tabs)
        let registryConnectionIds = NativeTabRegistry.shared.connectionIds()

        for connectionId in registryConnectionIds {
            let combinedTabs = NativeTabRegistry.shared.allTabs(for: connectionId)
            let selectedTabId = NativeTabRegistry.shared.selectedTabId(for: connectionId)

            if combinedTabs.isEmpty {
                TabStateStorage.shared.clearTabState(connectionId: connectionId)
            } else {
                TabStateStorage.shared.saveTabState(
                    connectionId: connectionId,
                    tabs: combinedTabs,
                    selectedTabId: selectedTabId
                )
            }
        }

        // Also save for any active sessions not covered by the registry
        // (e.g., sessions whose windows haven't appeared yet)
        for (connectionId, session) in DatabaseManager.shared.activeSessions
            where !registryConnectionIds.contains(connectionId)
        {
            if session.tabs.isEmpty {
                TabStateStorage.shared.clearTabState(connectionId: connectionId)
            } else {
                TabStateStorage.shared.saveTabState(
                    connectionId: connectionId,
                    tabs: session.tabs.map { $0.toSnapshot() },
                    selectedTabId: session.selectedTabId
                )
            }
        }
    }

    private func isMainWindow(_ window: NSWindow) -> Bool {
        // Main window has identifier containing "main" (from WindowGroup(id: "main"))
        // This excludes temporary windows like context menus, panels, popovers, etc.
        guard let identifier = window.identifier?.rawValue else { return false }
        return identifier.contains("main")
    }

    private func openWelcomeWindow() {
        // Check if welcome window already exists and is visible
        for window in NSApp.windows where isWelcomeWindow(window) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // If no welcome window exists, we need to create one via SwiftUI's openWindow
        // Post a notification that SwiftUI can handle
        NotificationCenter.default.post(name: .openWelcomeWindow, object: nil)
    }

    @objc
    private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let windowId = ObjectIdentifier(window)

        // If we're handling a file-open with an active connection, suppress
        // any welcome window that SwiftUI creates as part of app activation.
        if isWelcomeWindow(window) && isHandlingFileOpen {
            window.close()
            // Ensure the main window gets focus instead
            for mainWin in NSApp.windows where isMainWindow(mainWin) {
                mainWin.makeKeyAndOrderFront(nil)
            }
            return
        }

        // Configure welcome window when it becomes key (only once)
        if isWelcomeWindow(window) && !configuredWindows.contains(windowId) {
            configureWelcomeWindowStyle(window)
            configuredWindows.insert(windowId)
        }

        // Configure connection form window when it becomes key (only once)
        if isConnectionFormWindow(window) && !configuredWindows.contains(windowId) {
            configureConnectionFormWindowStyle(window)
            configuredWindows.insert(windowId)
        }

        // Configure native tabbing for main windows (only once per window).
        // Must be synchronous — tabbingMode must be set before the window
        // is displayed so macOS merges it into the existing tab group.
        if isMainWindow(window) && !configuredWindows.contains(windowId) {
            window.tabbingMode = .preferred
            // Use the pending connectionId from WindowOpener (set by openNativeTab)
            // to assign the correct per-connection tabbingIdentifier immediately,
            // so macOS merges the window into the right tab group.
            let pendingId = MainActor.assumeIsolated { WindowOpener.shared.consumePendingConnectionId() }
            let existingIdentifier = NSApp.windows
                .first { $0 !== window && isMainWindow($0) && $0.isVisible }?
                .tabbingIdentifier
            window.tabbingIdentifier = TabbingIdentifierResolver.resolve(
                pendingConnectionId: pendingId,
                existingIdentifier: existingIdentifier
            )
            configuredWindows.insert(windowId)
        }

        // Note: Right panel uses overlay style (not .inspector()) — no split view configuration needed
    }

    private func configureWelcomeWindow() {
        // Wait for SwiftUI to create the welcome window, then configure it
        Task { @MainActor [weak self] in
            for _ in 0 ..< 5 {
                guard let self else { return }
                let found = NSApp.windows.contains(where: { self.isWelcomeWindow($0) })
                if found {
                    for window in NSApp.windows where self.isWelcomeWindow(window) {
                        self.configureWelcomeWindowStyle(window)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func isWelcomeWindow(_ window: NSWindow) -> Bool {
        // Check by window identifier or title
        window.identifier?.rawValue == "welcome" ||
            window.title.lowercased().contains("welcome")
    }

    private func configureWelcomeWindowStyle(_ window: NSWindow) {
        // Remove miniaturize (yellow) button functionality
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        // Remove zoom (green) button functionality
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // Remove these capabilities from the window's style mask
        // This prevents the actions even if buttons were visible
        window.styleMask.remove(.miniaturizable)

        // Prevent full screen
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)

        // Keep the window non-resizable (already set via SwiftUI, but reinforce here)
        if window.styleMask.contains(.resizable) {
            window.styleMask.remove(.resizable)
        }

        // Enable behind-window translucency (frosted glass effect)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
    }

    private func isConnectionFormWindow(_ window: NSWindow) -> Bool {
        // Check by window identifier
        // WindowGroup uses "connection-form-X" format for identifiers
        window.identifier?.rawValue.contains("connection-form") == true
    }

    private func configureConnectionFormWindowStyle(_ window: NSWindow) {
        // Disable miniaturize (yellow) and zoom (green) buttons
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        // Remove these capabilities from the window's style mask
        window.styleMask.remove(.miniaturizable)

        // Prevent full screen
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)

        // Keep connection form above welcome window
        window.level = .floating
    }
}

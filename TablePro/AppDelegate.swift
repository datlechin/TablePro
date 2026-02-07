//
//  AppDelegate.swift
//  TablePro
//
//  Window configuration using AppKit-native approach
//

import AppKit
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
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Track windows that have been configured to avoid re-applying styles (which causes flicker)
    private var configuredWindows = Set<ObjectIdentifier>()

    /// URLs queued for opening when no database connection is active yet
    private var queuedFileURLs: [URL] = []

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let welcomeItem = NSMenuItem(
            title: "Show Welcome Window",
            action: #selector(showWelcomeFromDock),
            keyEquivalent: ""
        )
        welcomeItem.target = self
        menu.addItem(welcomeItem)

        // Add connections submenu
        let connections = ConnectionStorage.shared.loadConnections()
        if !connections.isEmpty {
            let connectionsItem = NSMenuItem(title: "Open Connection", action: nil, keyEquivalent: "")
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
        NotificationCenter.default.post(name: .openMainWindow, object: nil)

        Task { @MainActor in
            do {
                try await DatabaseManager.shared.connectToSession(connection)

                // Close welcome window on successful connection
                for window in NSApp.windows where self.isWelcomeWindow(window) {
                    window.close()
                }
            } catch {
                print("[AppDelegate] Dock connection failed for '\(connection.name)': \(error.localizedDescription)")

                // Connection failed - close main window, reopen welcome
                for window in NSApp.windows where self.isMainWindow(window) {
                    window.close()
                }
                self.openWelcomeWindow()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let sqlURLs = urls.filter { $0.pathExtension.lowercased() == "sql" }
        guard !sqlURLs.isEmpty else { return }

        if DatabaseManager.shared.currentSession != nil {
            // Already connected — bring main window to front and open files
            for window in NSApp.windows where isMainWindow(window) {
                window.makeKeyAndOrderFront(nil)
            }
            // Close welcome window if it's open (user doesn't need it)
            for window in NSApp.windows where isWelcomeWindow(window) {
                window.close()
            }
            NotificationCenter.default.post(name: .openSQLFiles, object: sqlURLs)
        } else {
            // Not connected — queue and show welcome window
            queuedFileURLs.append(contentsOf: sqlURLs)
            openWelcomeWindow()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start license periodic validation
        Task { @MainActor in
            LicenseManager.shared.startPeriodicValidation()
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

        // Observe database connection to flush queued .sql files
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDatabaseDidConnect),
            name: .databaseDidConnect,
            object: nil
        )
    }

    @objc
    private func handleDatabaseDidConnect() {
        guard !queuedFileURLs.isEmpty else { return }
        let urls = queuedFileURLs
        queuedFileURLs.removeAll()

        // Small delay to allow coordinator/tab manager to finish setup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            // Open main window via notification FIRST (before closing welcome window)
            // The OpenWindowHandler in welcome window will process this
            NotificationCenter.default.post(name: .openMainWindow, object: nil)

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
                    print("[AppDelegate] Auto-reconnect failed for '\(connection.name)': \(error.localizedDescription)")

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in NSApp.windows where window.identifier?.rawValue.contains("main") == true {
                window.close()
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
            // CRITICAL: Post notification FIRST to allow MainContentView to flush pending saves
            // This ensures query text is saved before SwiftUI tears down the view
            NotificationCenter.default.post(name: .mainWindowWillClose, object: nil)

            // Allow run loop to process notification handlers synchronously
            // This is more elegant than Thread.sleep as it processes pending events
            // rather than blocking the main thread entirely
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

            // NOTE: We do NOT call saveAllTabStates() here because:
            // 1. MainContentView already flushed the correct state via the notification above
            // 2. By this point, SwiftUI may have torn down views and session.tabs could be stale/empty
            // 3. Saving again would risk overwriting the good state with bad/empty state

            // Disconnect sessions asynchronously (after save is complete)
            Task { @MainActor in
                await DatabaseManager.shared.disconnectAll()
            }

            // Reopen welcome window after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.openWelcomeWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save tab state synchronously before app terminates (backup mechanism)
        saveAllTabStates()
    }

    /// Save tab state for all active sessions
    @MainActor
    private func saveAllTabStates() {
        for (connectionId, session) in DatabaseManager.shared.activeSessions {
            if session.tabs.isEmpty {
                TabStateStorage.shared.clearTabState(connectionId: connectionId)
            } else {
                TabStateStorage.shared.saveTabState(
                    connectionId: connectionId,
                    tabs: session.tabs,
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
    }

    private func configureWelcomeWindow() {
        // Find and configure the welcome window after a brief delay to ensure SwiftUI has created it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            for window in NSApp.windows where self?.isWelcomeWindow(window) == true {
                self?.configureWelcomeWindowStyle(window)
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
        if !window.styleMask.contains(.resizable) == false {
            window.styleMask.remove(.resizable)
        }
    }

    private func isConnectionFormWindow(_ window: NSWindow) -> Bool {
        // Check by window identifier or title
        // WindowGroup uses "connection-form-X" format for identifiers
        window.identifier?.rawValue.contains("connection-form") == true ||
            window.title == "Connection"
    }

    private func configureConnectionFormWindowStyle(_ window: NSWindow) {
        // Remove miniaturize (yellow) button functionality
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        // Remove zoom (green) button functionality
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // Remove these capabilities from the window's style mask
        window.styleMask.remove(.miniaturizable)

        // Prevent full screen
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)

        // Inset titlebar - make traffic light part of content area
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        // Keep connection form above welcome window (floating but allows interaction with other windows)
        window.level = .floating
    }
}

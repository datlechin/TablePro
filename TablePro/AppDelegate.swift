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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure windows after app launch
        configureWelcomeWindow()

        // Close any restored main windows (no active connection on fresh launch)
        // macOS may restore window state from previous session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in NSApp.windows where window.identifier?.rawValue.contains("main") == true {
                window.close()
            }
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

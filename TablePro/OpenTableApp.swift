//
//  TableProApp.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import CodeEditTextView
import Combine
import Sparkle
import SwiftUI

// MARK: - App State for Menu Commands

final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var isConnected: Bool = false
    @Published var isCurrentTabEditable: Bool = false  // True when current tab is an editable table
    @Published var hasRowSelection: Bool = false  // True when rows are selected in data grid
    @Published var hasTableSelection: Bool = false  // True when tables are selected in sidebar
    @Published var isHistoryPanelVisible: Bool = false  // Global history panel visibility
}

// MARK: - Pasteboard Commands

/// Custom Commands struct for pasteboard operations
struct PasteboardCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("x", modifiers: .command)

            Button("Copy") {
                // Check if user is editing text in a cell (firstResponder is NSTextView field editor)
                if let firstResponder = NSApp.keyWindow?.firstResponder,
                   firstResponder is NSTextView {
                    // User is editing text - let standard copy handle selected text
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                } else if appState.hasRowSelection {
                    // Copy entire rows when rows are selected
                    NotificationCenter.default.post(name: .copySelectedRows, object: nil)
                } else if appState.hasTableSelection {
                    // Copy table names when tables are selected
                    NotificationCenter.default.post(name: .copyTableNames, object: nil)
                } else {
                    // Fallback to standard copy
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Paste") {
                // Check if user is editing text in a cell (firstResponder is NSTextView field editor)
                if let firstResponder = NSApp.keyWindow?.firstResponder,
                   firstResponder is NSTextView {
                    // User is editing text - let standard paste handle it
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else if appState.isCurrentTabEditable {
                    // Paste rows when in editable table tab
                    NotificationCenter.default.post(name: .pasteRows, object: nil)
                } else {
                    // Fallback to standard paste
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut("v", modifiers: .command)

            Button("Delete") {
                // Check if first responder is the history panel's table view
                // History panel uses responder chain for delete actions
                // Data grid uses notifications for batched undo support
                if let firstResponder = NSApp.keyWindow?.firstResponder {
                    // Check class name to identify HistoryTableView
                    let className = String(describing: type(of: firstResponder))
                    if className.contains("HistoryTableView") {
                        // Let history panel handle via responder chain
                        NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: nil)
                        return
                    }
                }

                // For data grid and other views, use notification for batched undo
                NotificationCenter.default.post(name: .deleteSelectedRows, object: nil)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!appState.isCurrentTabEditable && !appState.hasTableSelection)

            Divider()

            Button("Select All") {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("a", modifiers: .command)

            Button("Clear Selection") {
                // Use responder chain - cancelOperation is the standard ESC action
                NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
    }
}

// MARK: - App

@main
struct TableProApp: App {
    // Connect AppKit delegate for proper window configuration
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    @StateObject private var appState = AppState.shared
    @StateObject private var dbManager = DatabaseManager.shared
    @StateObject private var settingsManager = AppSettingsManager.shared
    @StateObject private var updaterBridge = UpdaterBridge()

    init() {
        // Perform startup cleanup of query history if auto-cleanup is enabled
        Task { @MainActor in
            QueryHistoryManager.shared.performStartupCleanup()
        }

        // Start iCloud sync if previously enabled
        Task { @MainActor in
            if AppSettingsManager.shared.general.iCloudSyncEnabled {
                SyncCoordinator.shared.enable()
            }
        }
    }

    /// Get tint color from settings (nil for system default)
    private var accentTint: Color? {
        settingsManager.appearance.accentColor.tintColor
    }

    var body: some Scene {
        // Welcome Window - opens on launch
        Window("Welcome to TablePro", id: "welcome") {
            WelcomeWindowView()
                .tint(accentTint)
                .background(OpenWindowHandler())  // Handle window notifications from startup
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 700, height: 450)

        // Connection Form Window - opens when creating/editing a connection
        WindowGroup("Connection", id: "connection-form", for: UUID?.self) { $connectionId in
            ConnectionFormView(connectionId: connectionId ?? nil)
                .tint(accentTint)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Main Window - opens when connecting to database
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appState)
                .background(OpenWindowHandler())
                .tint(accentTint)
            // ESC key handling now uses native .onExitCommand and cancelOperation(_:)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1_200, height: 800)

        // Settings Window - opens with Cmd+,
        Settings {
            SettingsView()
                .environmentObject(updaterBridge)
                .tint(accentTint)
        }

        .commands {
            // Check for Updates menu item (after "About TablePro")
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterBridge: updaterBridge)
            }

            // MARK: - Keyboard Shortcut Architecture
            //
            // This app uses a hybrid approach for keyboard shortcuts:
            //
            // 1. **Responder Chain** (Apple Standard):
            //    - Standard actions: copy, paste, undo, delete, cancelOperation (ESC)
            //    - Context-aware: First responder handles action appropriately
            //    - Used for: Edit menu operations, ESC key
            //
            // 2. **NotificationCenter** (For specific use cases):
            //    - Data operations needing batched undo: addNewRow, deleteSelectedRows, saveChanges
            //    - UI state broadcasts: View menu toggles (multiple listeners)
            //    - Cross-layer coordination: File menu operations (window management)
            //
            // Migration from custom ESC system → native cancelOperation(_:) completed in Phase 4

            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Connection...") {
                    NotificationCenter.default.post(name: .newConnection, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .newTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!appState.isConnected)

                Button("New Table...") {
                    NotificationCenter.default.post(name: .createTable, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!appState.isConnected)

                Button("Open Database...") {
                    NotificationCenter.default.post(name: .openDatabaseSwitcher, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!appState.isConnected)

                Divider()

                Button("Save Changes") {
                    NotificationCenter.default.post(name: .saveChanges, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!appState.isConnected)

                Button("Close Tab") {
                    // Check if key window is the main window
                    let keyWindow = NSApp.keyWindow
                    let isMainWindowKey = keyWindow?.identifier?.rawValue.contains("main") == true

                    if appState.isConnected && isMainWindowKey {
                        NotificationCenter.default.post(name: .closeCurrentTab, object: nil)
                    } else {
                        // Close the focused window (connection form, welcome, etc.)
                        keyWindow?.close()
                    }
                }
                .keyboardShortcut("w", modifiers: .command)

                Divider()

                Button("Refresh") {
                    NotificationCenter.default.post(name: .refreshData, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!appState.isConnected)

                Divider()

                Button("Export...") {
                    NotificationCenter.default.post(name: .exportTables, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!appState.isConnected)

                Button("Import...") {
                    NotificationCenter.default.post(name: .importTables, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!appState.isConnected)
            }

            // Edit menu - Undo/Redo (smart handling for both text editor and data grid)
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    // Check if first responder is a text view (SQL editor)
                    if let firstResponder = NSApp.keyWindow?.firstResponder,
                       firstResponder is NSTextView || firstResponder is TextView {
                        // Let native text view undo handle it
                        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                    } else {
                        // Data grid undo
                        NotificationCenter.default.post(name: .undoChange, object: nil)
                    }
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo") {
                    // Check if first responder is a text view (SQL editor)
                    if let firstResponder = NSApp.keyWindow?.firstResponder,
                       firstResponder is NSTextView || firstResponder is TextView {
                        // Let native text view redo handle it
                        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                    } else {
                        // Data grid redo
                        NotificationCenter.default.post(name: .redoChange, object: nil)
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            // Edit menu - pasteboard commands with FocusedValue support
            PasteboardCommands(appState: appState)

            // Edit menu - row operations (after pasteboard)
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Add Row") {
                    NotificationCenter.default.post(name: .addNewRow, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!appState.isCurrentTabEditable)

                Button("Duplicate Row") {
                    NotificationCenter.default.post(name: .duplicateRow, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!appState.isCurrentTabEditable)

                Divider()

                // Table operations (work when tables selected in sidebar)
                Button("Truncate Table") {
                    NotificationCenter.default.post(name: .truncateTables, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .option)
                .disabled(!appState.hasTableSelection)
            }

            // View menu - using NotificationCenter for UI state broadcasts
            // Note: These are UI state changes that multiple views need to know about,
            // so NotificationCenter is the appropriate pattern here (not responder chain)
            CommandGroup(after: .sidebar) {
                Button("Toggle Table Browser") {
                    NotificationCenter.default.post(name: .toggleTableBrowser, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!appState.isConnected)

                Button("Toggle Inspector") {
                    NotificationCenter.default.post(name: .toggleRightSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!appState.isConnected)

                Divider()

                Button("Toggle Filters") {
                    NotificationCenter.default.post(name: .toggleFilterPanel, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!appState.isConnected)

                Button("Toggle History") {
                    NotificationCenter.default.post(name: .toggleHistoryPanel, object: nil)
                }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(!appState.isConnected)
            }

            // Tab navigation shortcuts
            CommandGroup(after: .windowArrangement) {
                // Tab switching by number (Cmd+1 through Cmd+9)
                ForEach(1...9, id: \.self) { number in
                    Button("Select Tab \(number)") {
                        NotificationCenter.default.post(
                            name: .selectTabByNumber,
                            object: number
                        )
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(number))),
                        modifiers: .command
                    )
                    .disabled(!appState.isConnected)
                }

                Divider()

                // Previous tab (Cmd+Shift+[)
                Button("Show Previous Tab") {
                    NotificationCenter.default.post(name: .previousTab, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!appState.isConnected)

                // Next tab (Cmd+Shift+])
                Button("Show Next Tab") {
                    NotificationCenter.default.post(name: .nextTab, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!appState.isConnected)

                // Previous tab (Cmd+Option+Left)
                Button("Previous Tab") {
                    NotificationCenter.default.post(name: .previousTab, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!appState.isConnected)

                // Next tab (Cmd+Option+Right)
                Button("Next Tab") {
                    NotificationCenter.default.post(name: .nextTab, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!appState.isConnected)
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newConnection = Notification.Name("newConnection")
    static let newTab = Notification.Name("newTab")
    static let closeCurrentTab = Notification.Name("closeCurrentTab")
    static let deselectConnection = Notification.Name("deselectConnection")
    static let saveChanges = Notification.Name("saveChanges")
    static let saveStructureChanges = Notification.Name("saveStructureChanges")
    static let refreshData = Notification.Name("refreshData")
    static let refreshAll = Notification.Name("refreshAll")
    static let toggleTableBrowser = Notification.Name("toggleTableBrowser")
    static let showAllTables = Notification.Name("showAllTables")
    static let toggleRightSidebar = Notification.Name("toggleRightSidebar")
    static let deleteSelectedRows = Notification.Name("deleteSelectedRows")
    static let addNewRow = Notification.Name("addNewRow")
    static let duplicateRow = Notification.Name("duplicateRow")
    static let copyTableNames = Notification.Name("copyTableNames")
    static let truncateTables = Notification.Name("truncateTables")
    static let copySelectedRows = Notification.Name("copySelectedRows")
    static let pasteRows = Notification.Name("pasteRows")
    static let clearSelection = Notification.Name("clearSelection")
    static let undoChange = Notification.Name("undoChange")
    static let redoChange = Notification.Name("redoChange")
    static let openWelcomeWindow = Notification.Name("openWelcomeWindow")

    // Filter notifications
    static let toggleFilterPanel = Notification.Name("toggleFilterPanel")
    static let applyAllFilters = Notification.Name("applyAllFilters")
    static let duplicateFilter = Notification.Name("duplicateFilter")
    static let removeFilter = Notification.Name("removeFilter")

    // History panel notifications
    static let toggleHistoryPanel = Notification.Name("toggleHistoryPanel")

    // Database switcher notifications
    static let openDatabaseSwitcher = Notification.Name("openDatabaseSwitcher")

    // Table creation notifications
    static let createTable = Notification.Name("createTable")

    // Table structure notifications
    static let showTableStructure = Notification.Name("showTableStructure")

    // Export notifications
    static let exportTables = Notification.Name("exportTables")

    // Import notifications
    static let importTables = Notification.Name("importTables")

    // Tab navigation notifications
    static let selectTabByNumber = Notification.Name("selectTabByNumber")
    static let previousTab = Notification.Name("previousTab")
    static let nextTab = Notification.Name("nextTab")

    // File opening notifications
    static let openSQLFiles = Notification.Name("openSQLFiles")

    // Window lifecycle notifications
    static let mainWindowWillClose = Notification.Name("mainWindowWillClose")
    static let openMainWindow = Notification.Name("openMainWindow")

    // License notifications
    static let licenseStatusDidChange = Notification.Name("licenseStatusDidChange")
}

// MARK: - Check for Updates

/// Menu bar button that triggers Sparkle update check
struct CheckForUpdatesView: View {
    @ObservedObject var updaterBridge: UpdaterBridge

    var body: some View {
        Button("Check for Updates...") {
            updaterBridge.checkForUpdates()
        }
        .disabled(!updaterBridge.canCheckForUpdates)
    }
}

// MARK: - Open Window Handler

/// Helper view that listens for window open notifications
private struct OpenWindowHandler: View {
    @Environment(\.openWindow)
    private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .openWelcomeWindow)) { _ in
                openWindow(id: "welcome")
            }
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                openWindow(id: "main")
            }
    }
}

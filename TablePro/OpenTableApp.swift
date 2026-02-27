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

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var isConnected: Bool = false
    @Published var isReadOnly: Bool = false  // True when current connection is read-only
    @Published var isCurrentTabEditable: Bool = false  // True when current tab is an editable table
    @Published var hasRowSelection: Bool = false  // True when rows are selected in data grid
    @Published var hasTableSelection: Bool = false  // True when tables are selected in sidebar
    @Published var isHistoryPanelVisible: Bool = false  // Global history panel visibility
    @Published var hasQueryText: Bool = false  // True when current editor has non-empty query
    @Published var hasStructureChanges: Bool = false  // True when structure view has pending schema changes
}

// MARK: - Pasteboard Commands

/// Custom Commands struct for pasteboard operations
struct PasteboardCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var settingsManager: AppSettingsManager
    @FocusedObject var actions: MainContentCommandActions?

    /// Build a SwiftUI KeyboardShortcut from keyboard settings
    private func shortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        settingsManager.keyboard.keyboardShortcut(for: action)
    }

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .cut))

            Button("Copy") {
                // Check if user is editing text in a cell (firstResponder is NSTextView field editor)
                if let firstResponder = NSApp.keyWindow?.firstResponder,
                   firstResponder is NSTextView {
                    // User is editing text - let standard copy handle selected text
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                } else if appState.hasRowSelection {
                    // Copy entire rows when rows are selected
                    actions?.copySelectedRows()
                } else if appState.hasTableSelection {
                    // Copy table names when tables are selected
                    NotificationCenter.default.post(name: .copyTableNames, object: nil)
                } else {
                    // Fallback to standard copy
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .copy))

            Button("Copy with Headers") {
                actions?.copySelectedRowsWithHeaders()
            }
            .optionalKeyboardShortcut(shortcut(for: .copyWithHeaders))
            .disabled(!appState.hasRowSelection)

            Button("Paste") {
                // Check if user is editing text in a cell (firstResponder is NSTextView field editor)
                if let firstResponder = NSApp.keyWindow?.firstResponder,
                   firstResponder is NSTextView {
                    // User is editing text - let standard paste handle it
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else if appState.isCurrentTabEditable {
                    // Paste rows when in editable table tab
                    actions?.pasteRows()
                } else {
                    // Fallback to standard paste
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .paste))

            Button("Delete") {
                actions?.deleteSelectedRows()
            }
            .optionalKeyboardShortcut(shortcut(for: .delete))
            .disabled(!appState.isCurrentTabEditable && !appState.hasTableSelection)

            Divider()

            Button("Select All") {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .selectAll))

            Button("Clear Selection") {
                // Use responder chain - cancelOperation is the standard ESC action
                NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .clearSelection))
        }
    }
}

// MARK: - App Menu Commands

/// All menu commands extracted into a separate Commands struct so that AppState
/// changes only re-evaluate the menu items — NOT the Scene body / WindowGroups.
struct AppMenuCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var settingsManager: AppSettingsManager
    var updaterBridge: UpdaterBridge
    @FocusedObject var actions: MainContentCommandActions?

    private func shortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        settingsManager.keyboard.keyboardShortcut(for: action)
    }

    var body: some Commands {
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
        //
        // 2. **@FocusedObject** (Menu → single handler):
        //    - Most menu commands call MainContentCommandActions directly
        //    - Clean method calls, no global event bus
        //
        // 3. **NotificationCenter** (Multi-listener broadcasts only):
        //    - refreshData (Sidebar + Coordinator + StructureView)
        //    - Legitimate broadcasts where multiple views respond

        // File menu
        CommandGroup(replacing: .newItem) {
            Button("New Connection...") {
                NotificationCenter.default.post(name: .newConnection, object: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .newConnection))
        }

        CommandGroup(after: .newItem) {
            Button("New Tab") {
                actions?.newTab()
            }
            .optionalKeyboardShortcut(shortcut(for: .newTab))
            .disabled(!appState.isConnected)

            Button("New Table...") {
                actions?.createTable()
            }
            .optionalKeyboardShortcut(shortcut(for: .newTable))
            .disabled(!appState.isConnected || appState.isReadOnly)

            Button("New View...") {
                actions?.createView()
            }
            .disabled(!appState.isConnected || appState.isReadOnly)

            Button("Open Database...") {
                actions?.openDatabaseSwitcher()
            }
            .optionalKeyboardShortcut(shortcut(for: .openDatabase))
            .disabled(!appState.isConnected)

            Button("Switch Connection...") {
                NotificationCenter.default.post(name: .openConnectionSwitcher, object: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .switchConnection))
            .disabled(!appState.isConnected)

            Divider()

            Button("Save Changes") {
                actions?.saveChanges()
            }
            .optionalKeyboardShortcut(shortcut(for: .saveChanges))
            .disabled(!appState.isConnected || appState.isReadOnly)

            Button("Preview SQL") {
                actions?.previewSQL()
            }
            .optionalKeyboardShortcut(shortcut(for: .previewSQL))
            .disabled(!appState.isConnected)

            Button("Close Tab") {
                if let actions {
                    actions.closeTab()
                } else {
                    NSApp.keyWindow?.close()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .closeTab))

            Divider()

            Button("Refresh") {
                NotificationCenter.default.post(name: .refreshData, object: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .refresh))
            .disabled(!appState.isConnected)

            Button("Explain Query") {
                actions?.explainQuery()
            }
            .optionalKeyboardShortcut(shortcut(for: .explainQuery))
            .disabled(!appState.isConnected || !appState.hasQueryText)

            Divider()

            Button("Export...") {
                actions?.exportTables()
            }
            .optionalKeyboardShortcut(shortcut(for: .export))
            .disabled(!appState.isConnected)

            Button("Import...") {
                actions?.importTables()
            }
            .optionalKeyboardShortcut(shortcut(for: .importData))
            .disabled(!appState.isConnected || appState.isReadOnly)
        }

        // Edit menu - Undo/Redo (smart handling for both text editor and data grid)
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                // Check if first responder is a text view (SQL editor)
                if let firstResponder = NSApp.keyWindow?.firstResponder,
                   firstResponder is NSTextView || firstResponder is TextView {
                    // Send undo: (with colon) through responder chain —
                    // CodeEditTextView.TextView responds to undo: via @objc func undo(_:)
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    // Data grid undo
                    actions?.undoChange()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .undo))

            Button("Redo") {
                // Check if first responder is a text view (SQL editor)
                if let firstResponder = NSApp.keyWindow?.firstResponder,
                   firstResponder is NSTextView || firstResponder is TextView {
                    // Send redo: (with colon) through responder chain
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                } else {
                    // Data grid redo
                    actions?.redoChange()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .redo))
        }

        // Edit menu - pasteboard commands with FocusedValue support
        PasteboardCommands(appState: appState, settingsManager: settingsManager)

        // Edit menu - row operations (after pasteboard)
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Add Row") {
                actions?.addNewRow()
            }
            .optionalKeyboardShortcut(shortcut(for: .addRow))
            .disabled(!appState.isCurrentTabEditable || appState.isReadOnly)

            Button("Duplicate Row") {
                actions?.duplicateRow()
            }
            .optionalKeyboardShortcut(shortcut(for: .duplicateRow))
            .disabled(!appState.isCurrentTabEditable || appState.isReadOnly)

            Divider()

            // Table operations (work when tables selected in sidebar)
            Button("Truncate Table") {
                NotificationCenter.default.post(name: .truncateTables, object: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .truncateTable))
            .disabled(!appState.hasTableSelection || appState.isReadOnly)
        }

        // View menu
        CommandGroup(after: .sidebar) {
            Button("Toggle Table Browser") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleTableBrowser))
            .disabled(!appState.isConnected)

            Button("Toggle Inspector") {
                actions?.toggleRightSidebar()
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleInspector))
            .disabled(!appState.isConnected)

            Divider()

            Button("Toggle Filters") {
                actions?.toggleFilterPanel()
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleFilters))
            .disabled(!appState.isConnected)

            Button("Toggle History") {
                actions?.toggleHistoryPanel()
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleHistory))
            .disabled(!appState.isConnected)
        }

        // Tab navigation shortcuts — native macOS window tabs
        CommandGroup(after: .windowArrangement) {
            // Tab switching by number (Cmd+1 through Cmd+9)
            ForEach(1...9, id: \.self) { number in
                Button("Select Tab \(number)") {
                    actions?.selectTab(number: number)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(number))),
                    modifiers: .command
                )
                .disabled(!appState.isConnected)
            }

            Divider()

            // Previous tab (Cmd+Shift+[) — delegate to native macOS tab switching
            Button("Show Previous Tab") {
                NSApp.sendAction(#selector(NSWindow.selectPreviousTab(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .showPreviousTabBrackets))
            .disabled(!appState.isConnected)

            // Next tab (Cmd+Shift+]) — delegate to native macOS tab switching
            Button("Show Next Tab") {
                NSApp.sendAction(#selector(NSWindow.selectNextTab(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .showNextTabBrackets))
            .disabled(!appState.isConnected)

            // Previous tab (Cmd+Option+Left)
            Button("Previous Tab") {
                NSApp.sendAction(#selector(NSWindow.selectPreviousTab(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .previousTabArrows))
            .disabled(!appState.isConnected)

            // Next tab (Cmd+Option+Right)
            Button("Next Tab") {
                NSApp.sendAction(#selector(NSWindow.selectNextTab(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .nextTabArrows))
            .disabled(!appState.isConnected)
        }
    }
}

// MARK: - App

@main
struct TableProApp: App {
    // Connect AppKit delegate for proper window configuration
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    @StateObject private var settingsManager = AppSettingsManager.shared
    @StateObject private var updaterBridge = UpdaterBridge()

    init() {
        // Perform startup cleanup of query history if auto-cleanup is enabled
        Task { @MainActor in
            QueryHistoryManager.shared.performStartupCleanup()
        }
    }

    /// Get tint color from settings (nil for system default)
    private var accentTint: Color? {
        settingsManager.appearance.accentColor.tintColor
    }

    var body: some Scene {
        // Welcome Window - opens on launch (must be first Window scene so SwiftUI
        // restores it by default when clicking the dock icon)
        Window("Welcome to TablePro", id: "welcome") {
            WelcomeWindowView()
                .tint(accentTint)
                .background(OpenWindowHandler())  // Handle window notifications from startup
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 700, height: 450)

        // Connection Form Window - opens when creating/editing a connection
        WindowGroup(id: "connection-form", for: UUID?.self) { $connectionId in
            ConnectionFormView(connectionId: connectionId ?? nil)
                .tint(accentTint)
        }
        .windowResizability(.contentSize)

        // Main Window - opens when connecting to database
        // Each native window-tab gets its own ContentView with independent state.
        WindowGroup(id: "main", for: EditorTabPayload.self) { $payload in
            ContentView(payload: payload)
                .environmentObject(AppState.shared)
                .background(OpenWindowHandler())
                .tint(accentTint)
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
            AppMenuCommands(
                appState: AppState.shared,
                settingsManager: AppSettingsManager.shared,
                updaterBridge: updaterBridge
            )
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    // Connection lifecycle
    static let newConnection = Notification.Name("newConnection")
    static let deselectConnection = Notification.Name("deselectConnection")
    static let openConnectionSwitcher = Notification.Name("openConnectionSwitcher")
    static let reconnectDatabase = Notification.Name("reconnectDatabase")

    // Multi-listener broadcasts (Sidebar + Coordinator + StructureView)
    static let refreshData = Notification.Name("refreshData")
    static let refreshAll = Notification.Name("refreshAll")

    // Data operations (still posted by DataGrid / context menus / StructureView subscribers)
    static let deleteSelectedRows = Notification.Name("deleteSelectedRows")
    static let addNewRow = Notification.Name("addNewRow")
    static let duplicateRow = Notification.Name("duplicateRow")
    static let copySelectedRows = Notification.Name("copySelectedRows")
    static let pasteRows = Notification.Name("pasteRows")
    static let undoChange = Notification.Name("undoChange")
    static let redoChange = Notification.Name("redoChange")
    static let clearSelection = Notification.Name("clearSelection")

    // Tab operations
    static let showAllTables = Notification.Name("showAllTables")
    static let newQueryTab = Notification.Name("newQueryTab")

    // Sidebar operations (still posted by SidebarView / ConnectionStatusView)
    static let sidebarShouldFocus = Notification.Name("sidebarShouldFocus")
    static let copyTableNames = Notification.Name("copyTableNames")
    static let truncateTables = Notification.Name("truncateTables")
    static let exportTables = Notification.Name("exportTables")
    static let importTables = Notification.Name("importTables")
    static let openDatabaseSwitcher = Notification.Name("openDatabaseSwitcher")

    // Structure view / sidebar operations (still posted by SidebarView, QueryEditorView)
    static let createTable = Notification.Name("createTable")
    static let createView = Notification.Name("createView")
    static let explainQuery = Notification.Name("explainQuery")
    static let saveStructureChanges = Notification.Name("saveStructureChanges")
    static let previewStructureSQL = Notification.Name("previewStructureSQL")
    static let showTableStructure = Notification.Name("showTableStructure")
    static let editViewDefinition = Notification.Name("editViewDefinition")

    // Filter notifications
    static let applyAllFilters = Notification.Name("applyAllFilters")
    static let duplicateFilter = Notification.Name("duplicateFilter")
    static let removeFilter = Notification.Name("removeFilter")

    // File opening notifications
    static let openSQLFiles = Notification.Name("openSQLFiles")

    // Window lifecycle notifications
    static let mainWindowWillClose = Notification.Name("mainWindowWillClose")
    static let openMainWindow = Notification.Name("openMainWindow")
    static let openWelcomeWindow = Notification.Name("openWelcomeWindow")

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
            .onAppear {
                // Store openWindow action for imperative access (e.g., from MainContentCommandActions)
                WindowOpener.shared.openWindow = openWindow
            }
            .onReceive(NotificationCenter.default.publisher(for: .openWelcomeWindow)) { _ in
                openWindow(id: "welcome")
            }
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { notification in
                if let payload = notification.object as? EditorTabPayload {
                    openWindow(id: "main", value: payload)
                } else if let connectionId = notification.object as? UUID {
                    // Legacy: connection ID only — open default query tab
                    openWindow(id: "main", value: EditorTabPayload(connectionId: connectionId))
                }
            }
    }
}

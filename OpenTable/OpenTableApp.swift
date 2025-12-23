//
//  OpenTableApp.swift
//  OpenTable
//
//  Main application entry point with menu commands.
//  Keyboard shortcuts follow macOS Human Interface Guidelines.
//  See KeyboardShortcuts.swift for centralized shortcut definitions.
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Combine
import SwiftUI

// MARK: - App State for Menu Commands

final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var isConnected: Bool = false
    @Published var isCurrentTabEditable: Bool = false  // True when current tab is an editable table
    @Published var hasRowSelection: Bool = false  // True when rows are selected in data grid
    @Published var hasTableSelection: Bool = false  // True when tables are selected in sidebar
    @Published var isHistoryPanelVisible: Bool = false  // Global history panel visibility
    @Published var isQueryTabActive: Bool = false  // True when current tab is a query tab
}

// MARK: - App

@main
struct OpenTableApp: App {
    // Connect AppKit delegate for proper window configuration
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @StateObject private var appState = AppState.shared
    @StateObject private var dbManager = DatabaseManager.shared

    var body: some Scene {
        // Welcome Window - opens on launch
        Window("Welcome to OpenTable", id: "welcome") {
            WelcomeWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 700, height: 450)
        
        // Connection Form Window - opens when creating/editing a connection
        WindowGroup("Connection", id: "connection-form", for: UUID?.self) { $connectionId in
            ConnectionFormView(connectionId: connectionId ?? nil)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        
        // Main Window - opens when connecting to database
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appState)
                .background(OpenWindowHandler())
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // MARK: - File Menu
            CommandGroup(replacing: .newItem) {
                Button("New Connection...") {
                    NotificationCenter.default.post(name: .newConnection, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.newConnection)
            }

            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .newTab, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.newTab)
                .disabled(!appState.isConnected)

                Divider()

                Button("Save Changes") {
                    NotificationCenter.default.post(name: .saveChanges, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.saveChanges)
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
                .keyboardShortcut(KeyboardShortcuts.closeTab)

                Divider()

                Button("Refresh") {
                    NotificationCenter.default.post(name: .refreshData, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.refresh)
                .disabled(!appState.isConnected)
            }
            
            // MARK: - Edit Menu - Undo/Redo
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: .undoChange, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.undo)
                
                Button("Redo") {
                    NotificationCenter.default.post(name: .redoChange, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.redo)
            }
            
            // MARK: - Edit Menu - Pasteboard
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.cut)
                
                Button("Copy") {
                    if appState.hasRowSelection {
                        NotificationCenter.default.post(name: .copySelectedRows, object: nil)
                    } else if appState.hasTableSelection {
                        NotificationCenter.default.post(name: .copyTableNames, object: nil)
                    } else {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    }
                }
                .keyboardShortcut(KeyboardShortcuts.copy)
                
                Button("Paste") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.paste)
                
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
                .keyboardShortcut(KeyboardShortcuts.delete)
                .disabled(!appState.isCurrentTabEditable && !appState.hasTableSelection)
                
                Divider()
                
                Button("Select All") {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.selectAll)
                
                Button("Clear Selection") {
                    NotificationCenter.default.post(name: .clearSelection, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.clearSelection)
            }
            
            // MARK: - Edit Menu - Row Operations
            CommandGroup(after: .pasteboard) {
                Divider()
                
                Button("Add Row") {
                    NotificationCenter.default.post(name: .addNewRow, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.addRow)
                .disabled(!appState.isCurrentTabEditable)

                Button("Duplicate Row") {
                    NotificationCenter.default.post(name: .duplicateRow, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.duplicateRow)
                .disabled(!appState.isCurrentTabEditable)

                Divider()
                
                // Table operations (work when tables selected in sidebar)
                Button("Truncate Table") {
                    NotificationCenter.default.post(name: .truncateTables, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.truncateTable)
                .disabled(!appState.hasTableSelection)
            }

            // MARK: - View Menu
            CommandGroup(after: .sidebar) {
                Button("Toggle Table Browser") {
                    NotificationCenter.default.post(name: .toggleTableBrowser, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.toggleSidebar)
                .disabled(!appState.isConnected)

                Button("Toggle Inspector") {
                    NotificationCenter.default.post(name: .toggleRightSidebar, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.toggleInspector)
                .disabled(!appState.isConnected)

                Divider()

                Button("Toggle Filters") {
                    NotificationCenter.default.post(name: .toggleFilterPanel, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.toggleFilters)
                .disabled(!appState.isConnected)
                
                Button("Toggle History") {
                    NotificationCenter.default.post(name: .toggleHistoryPanel, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.toggleHistory)
                .disabled(!appState.isConnected)
            }
            
            // MARK: - Query Menu (Custom)
            CommandMenu("Query") {
                Button("Execute Query") {
                    NotificationCenter.default.post(name: .executeQuery, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.executeQuery)
                .disabled(!appState.isConnected)
                
                Button("Format Query") {
                    NotificationCenter.default.post(name: .formatQuery, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.formatQuery)
                .disabled(!appState.isConnected)
                
                Divider()
                
                Button("Clear Query") {
                    NotificationCenter.default.post(name: .clearQuery, object: nil)
                }
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
    static let refreshData = Notification.Name("refreshData")
    static let refreshAll = Notification.Name("refreshAll")
    static let toggleTableBrowser = Notification.Name("toggleTableBrowser")
    static let showAllTables = Notification.Name("showAllTables")
    static let toggleRightSidebar = Notification.Name("toggleRightSidebar")
    static let executeQuery = Notification.Name("executeQuery")
    static let formatQuery = Notification.Name("formatQuery")
    static let clearQuery = Notification.Name("clearQuery")
    static let deleteSelectedRows = Notification.Name("deleteSelectedRows")
    static let addNewRow = Notification.Name("addNewRow")
    static let duplicateRow = Notification.Name("duplicateRow")
    static let copyTableNames = Notification.Name("copyTableNames")
    static let truncateTables = Notification.Name("truncateTables")
    static let copySelectedRows = Notification.Name("copySelectedRows")
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
}

// MARK: - Open Window Handler

/// Helper view that listens for openWelcomeWindow notification
private struct OpenWindowHandler: View {
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .openWelcomeWindow)) { _ in
                openWindow(id: "welcome")
            }
    }
}

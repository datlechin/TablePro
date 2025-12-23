//
//  OpenTableApp.swift
//  OpenTable
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
            }
            
            // Edit menu - Undo/Redo (replace the standard undo/redo)
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: .undoChange, object: nil)
                }
                .keyboardShortcut("z", modifiers: .command)
                
                Button("Redo") {
                    NotificationCenter.default.post(name: .redoChange, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            
            // Edit menu - replace pasteboard to add our Delete with shortcut
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x", modifiers: .command)
                
                Button("Copy") {
                    if appState.hasRowSelection {
                        NotificationCenter.default.post(name: .copySelectedRows, object: nil)
                    } else if appState.hasTableSelection {
                        NotificationCenter.default.post(name: .copyTableNames, object: nil)
                    } else {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("c", modifiers: .command)
                
                Button("Paste") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
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
                    NotificationCenter.default.post(name: .clearSelection, object: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            
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

            // View menu
            CommandGroup(after: .sidebar) {
                Button("Toggle Table Browser") {
                    NotificationCenter.default.post(name: .toggleTableBrowser, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!appState.isConnected)

                Button("Toggle Inspector") {
                    NotificationCenter.default.post(name: .toggleRightSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
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
                .keyboardShortcut("h", modifiers: [.command, .shift])
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

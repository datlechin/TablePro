//
//  ContentView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import os
import SwiftUI

struct ContentView: View {
    private static let logger = Logger(subsystem: "com.tablepro", category: "ContentView")

    @StateObject private var dbManager = DatabaseManager.shared
    @State private var connections: [DatabaseConnection] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showNewConnectionSheet = false
    @State private var showEditConnectionSheet = false
    @State private var connectionToEdit: DatabaseConnection?
    @State private var connectionToDelete: DatabaseConnection?
    @State private var showDeleteConfirmation = false
    @State private var showUnsavedChangesAlert = false
    @State private var pendingCloseSessionId: UUID?
    @State private var hasLoaded = false
    @State private var escapeKeyMonitor: Any?
    @State private var isInspectorPresented = false  // Right sidebar (inspector) visibility

    @Environment(\.openWindow)
    private var openWindow
    @Environment(\.dismissWindow)
    private var dismissWindow
    @EnvironmentObject private var appState: AppState

    private let storage = ConnectionStorage.shared

    // Get current session from database manager
    private var currentSession: ConnectionSession? {
        dbManager.currentSession
    }

    // Get all sessions as array
    private var sessions: [ConnectionSession] {
        Array(dbManager.activeSessions.values)
    }

    var body: some View {
        mainContent
            .frame(minWidth: 900, minHeight: 600)
            .confirmationDialog(
                "Delete Connection",
                isPresented: $showDeleteConfirmation,
                presenting: connectionToDelete
            ) { connection in
                Button("Delete", role: .destructive) {
                    deleteConnection(connection)
                }
                Button("Cancel", role: .cancel) {}
            } message: { connection in
                Text("Are you sure you want to delete \"\(connection.name)\"?")
            }
            .alert(
                "Unsaved Changes",
                isPresented: $showUnsavedChangesAlert
            ) {
                Button("Cancel", role: .cancel) {
                    pendingCloseSessionId = nil
                }
                Button("Close Without Saving", role: .destructive) {
                    if let sessionId = pendingCloseSessionId {
                        Task {
                            await dbManager.disconnectSession(sessionId)
                        }
                    }
                    pendingCloseSessionId = nil
                }
            } message: {
                Text("This connection has unsaved changes. Are you sure you want to close it?")
            }
            .onAppear {
                loadConnections()
                setupEscapeKeyMonitor()
            }
            .onDisappear {
                removeEscapeKeyMonitor()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in
                openWindow(id: "connection-form", value: nil as UUID?)
            }
            .onReceive(NotificationCenter.default.publisher(for: .deselectConnection)) { _ in
                if let sessionId = dbManager.currentSessionId {
                    Task {
                        await dbManager.disconnectSession(sessionId)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleTableBrowser)) { _ in
                guard currentSession != nil else { return }
                Task { @MainActor in
                    withAnimation {
                        // Toggle left sidebar (2-column layout: sidebar + detail)
                        if columnVisibility == .all {
                            columnVisibility = .detailOnly
                        } else {
                            columnVisibility = .all
                        }
                    }
                }
            }
            // Right sidebar toggle is handled by MainContentView (has the binding)
            .onChange(of: dbManager.currentSessionId) { _, newSessionId in
                Task { @MainActor in
                    withAnimation {
                        columnVisibility = newSessionId == nil ? .detailOnly : .all
                    }
                    AppState.shared.isConnected = newSessionId != nil

                    // When all sessions are closed, return to Welcome window
                    if newSessionId == nil {
                        openWindow(id: "welcome")
                        dismissWindow(id: "main")
                    }
                }
            }
    }

    // MARK: - View Components

    @ViewBuilder
    private var mainContent: some View {
        if let currentSession = currentSession {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                // MARK: - Sidebar (Left) - Table Browser
                VStack(spacing: 0) {
                    if !sessions.isEmpty {
                        ConnectionSidebarHeader(
                            sessions: sessions,
                            currentSessionId: dbManager.currentSessionId,
                            savedConnections: connections,
                            onSelectSession: { sessionId in
                                Task { @MainActor in
                                    saveCurrentSessionState()
                                    dbManager.switchToSession(sessionId)
                                }
                            },
                            onOpenConnection: { connection in
                                Task { @MainActor in
                                    connectToDatabase(connection)
                                }
                            },
                            onNewConnection: {
                                openWindow(id: "connection-form", value: nil as UUID?)
                            }
                        )
                    }

                    SidebarView(
                        tables: sessionTablesBinding,
                        selectedTables: sessionSelectedTablesBinding,
                        activeTableName: currentSession.selectedTables.first?.name,
                        onTablePro: { _ in },
                        onShowAllTables: {
                            showAllTablesMetadata()
                        },
                        pendingTruncates: sessionPendingTruncatesBinding,
                        pendingDeletes: sessionPendingDeletesBinding,
                        tableOperationOptions: sessionTableOperationOptionsBinding,
                        databaseType: currentSession.connection.type
                    )
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
            } detail: {
                // MARK: - Detail (Main workspace with optional right sidebar)
                MainContentView(
                    connection: currentSession.connection,
                    tables: sessionTablesBinding,
                    selectedTables: sessionSelectedTablesBinding,
                    pendingTruncates: sessionPendingTruncatesBinding,
                    pendingDeletes: sessionPendingDeletesBinding,
                    tableOperationOptions: sessionTableOperationOptionsBinding,
                    isInspectorPresented: $isInspectorPresented
                )
                .id(currentSession.id)
            }
        } else {
            // No active session yet - show loading while connecting
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Connecting...")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar(.hidden)
        }
    }

    // Removed: newConnectionSheet and editConnectionSheet helpers
    // Connection forms are now handled by the separate connection-form window

    // MARK: - Session State Bindings

    /// Generic helper to create bindings that update session state
    private func createSessionBinding<T>(
        get: @escaping (ConnectionSession) -> T,
        set: @escaping (inout ConnectionSession, T) -> Void,
        defaultValue: T
    ) -> Binding<T> {
        Binding(
            get: {
                guard let session = currentSession else {
                    return defaultValue
                }
                return get(session)
            },
            set: { newValue in
                guard let sessionId = dbManager.currentSessionId else { return }
                Task { @MainActor in
                    dbManager.updateSession(sessionId) { session in
                        set(&session, newValue)
                    }
                }
            }
        )
    }

    private var sessionTablesBinding: Binding<[TableInfo]> {
        createSessionBinding(
            get: { $0.tables },
            set: { $0.tables = $1 },
            defaultValue: []
        )
    }

    private var sessionSelectedTablesBinding: Binding<Set<TableInfo>> {
        createSessionBinding(
            get: { $0.selectedTables },
            set: { $0.selectedTables = $1 },
            defaultValue: []
        )
    }

    private var sessionPendingTruncatesBinding: Binding<Set<String>> {
        createSessionBinding(
            get: { $0.pendingTruncates },
            set: { $0.pendingTruncates = $1 },
            defaultValue: []
        )
    }

    private var sessionPendingDeletesBinding: Binding<Set<String>> {
        createSessionBinding(
            get: { $0.pendingDeletes },
            set: { $0.pendingDeletes = $1 },
            defaultValue: []
        )
    }

    private var sessionTableOperationOptionsBinding: Binding<[String: TableOperationOptions]> {
        createSessionBinding(
            get: { $0.tableOperationOptions },
            set: { $0.tableOperationOptions = $1 },
            defaultValue: [:]
        )
    }

    // MARK: - Actions

    private func connectToDatabase(_ connection: DatabaseConnection) {
        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                Self.logger.error("Failed to connect: \(error.localizedDescription)")
            }
        }
    }

    private func handleCloseSession(_ sessionId: UUID) {
        Task {
            await dbManager.disconnectSession(sessionId)
        }
    }

    private func saveCurrentSessionState() {
        // State is automatically saved through bindings
    }

    // MARK: - Persistence

    private func loadConnections() {
        guard !hasLoaded else { return }

        let saved = storage.loadConnections()
        if saved.isEmpty {
            connections = DatabaseConnection.sampleConnections
            storage.saveConnections(connections)
        } else {
            connections = saved
        }
        hasLoaded = true
    }

    private func deleteConnection(_ connection: DatabaseConnection) {
        if dbManager.activeSessions[connection.id] != nil {
            Task {
                await dbManager.disconnectSession(connection.id)
            }
        }

        connections.removeAll { $0.id == connection.id }
        storage.deleteConnection(connection)
        storage.saveConnections(connections)
    }

    // MARK: - Escape Key Monitor

    private func setupEscapeKeyMonitor() {
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape key code is 53
            if event.keyCode == 53 {
                // CRITICAL: Check if completion window is visible first
                if let frontmostWindow = NSApp.keyWindow,
                   frontmostWindow.level == .popUpMenu,
                   frontmostWindow.isVisible {
                    // Let the completion window handle Escape
                    return event
                }

                // Don't consume ESC if a sheet is presented - let it dismiss the sheet
                if AppState.shared.isSheetPresented {
                    return event
                }

                NotificationCenter.default.post(name: .clearSelection, object: nil)
                // Return nil to consume the event, or return event to let it propagate
                return nil
            }
            return event
        }
    }

    private func showAllTablesMetadata() {
        // Post notification for MainContentView to handle
        NotificationCenter.default.post(name: .showAllTables, object: nil)
    }

    private func removeEscapeKeyMonitor() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }
}

#Preview {
    ContentView()
}

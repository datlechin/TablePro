//
//  ContentView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import AppKit
import os
import SwiftUI

struct ContentView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ContentView")

    /// Payload identifying what this native window-tab should display.
    /// nil = default empty query tab (first window on connection).
    let payload: EditorTabPayload?

    @State private var currentSession: ConnectionSession?
    @State private var connections: [DatabaseConnection] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showNewConnectionSheet = false
    @State private var showEditConnectionSheet = false
    @State private var connectionToEdit: DatabaseConnection?
    @State private var connectionToDelete: DatabaseConnection?
    @State private var showDeleteConfirmation = false
    @State private var hasLoaded = false
    @State private var rightPanelState = RightPanelState()
    @State private var inspectorContext = InspectorContext.empty
    @State private var windowTitle: String
    /// Per-window sidebar selection (independent of other window-tabs)
    @State private var localSelectedTables: Set<TableInfo> = []

    @Environment(\.openWindow)
    private var openWindow
    @EnvironmentObject private var appState: AppState

    private let storage = ConnectionStorage.shared

    init(payload: EditorTabPayload?) {
        self.payload = payload
        let defaultTitle: String
        if let tableName = payload?.tableName {
            defaultTitle = tableName
        } else if let connectionId = payload?.connectionId,
                  let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId }) {
            defaultTitle = connection.type == .mongodb ? "MQL Query" : "SQL Query"
        } else {
            defaultTitle = "SQL Query"
        }
        _windowTitle = State(initialValue: defaultTitle)
    }

    var body: some View {
        mainContent
            .frame(minWidth: 1_100, minHeight: 600)
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
            .onAppear {
                loadConnections()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in
                openWindow(id: "connection-form", value: nil as UUID?)
            }
            .onReceive(NotificationCenter.default.publisher(for: .deselectConnection)) { _ in
                let sessionId = payload?.connectionId ?? DatabaseManager.shared.currentSessionId
                if let sessionId {
                    Task { @MainActor in
                        let confirmed = await AlertHelper.confirmDestructive(
                            title: String(localized: "Disconnect"),
                            message: String(localized: "Are you sure you want to disconnect from this database?"),
                            confirmButton: String(localized: "Disconnect"),
                            cancelButton: String(localized: "Cancel")
                        )

                        if confirmed {
                            await DatabaseManager.shared.disconnectSession(sessionId)
                        }
                    }
                }
            }
            // Right sidebar toggle is handled by MainContentView (has the binding)
            // Left sidebar toggle uses native NSSplitViewController.toggleSidebar via responder chain
            .onReceive(DatabaseManager.shared.$currentSessionId) { newSessionId in
                let ourConnectionId = payload?.connectionId
                // Windows with a payload only react to their own connection
                if ourConnectionId != nil {
                    guard newSessionId == ourConnectionId else { return }
                } else {
                    // No payload (legacy path): only pick up the initial connection,
                    // don't switch once we already have one
                    guard currentSession == nil else { return }
                }

                if let connectionId = ourConnectionId ?? newSessionId {
                    currentSession = DatabaseManager.shared.activeSessions[connectionId]
                    columnVisibility = currentSession != nil ? .all : .detailOnly
                    if let session = currentSession {
                        AppState.shared.isConnected = true
                        AppState.shared.isReadOnly = session.connection.isReadOnly
                        AppState.shared.isMongoDB = session.connection.type == .mongodb
                    }
                } else {
                    currentSession = nil
                    columnVisibility = .detailOnly
                }
            }
            .onReceive(DatabaseManager.shared.$activeSessions) { sessions in
                // Use our payload's connectionId, or our current session's id if already connected,
                // or lastly the global currentSessionId (only for initial bootstrap)
                let connectionId = payload?.connectionId ?? currentSession?.id ?? DatabaseManager.shared.currentSessionId
                guard let sid = connectionId else {
                    if currentSession != nil { currentSession = nil }
                    return
                }
                guard let newSession = sessions[sid] else {
                    // Session was removed (disconnected)
                    if currentSession?.id == sid {
                        currentSession = nil
                        columnVisibility = .detailOnly
                        AppState.shared.isConnected = false
                        AppState.shared.isReadOnly = false
                        AppState.shared.isMongoDB = false
                    }
                    return
                }
                if let existing = currentSession,
                   existing.isContentViewEquivalent(to: newSession) {
                    return
                }
                currentSession = newSession
                AppState.shared.isConnected = true
                AppState.shared.isReadOnly = newSession.connection.isReadOnly
                AppState.shared.isMongoDB = newSession.connection.type == .mongodb
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                // Sync AppState flags from this window's session when it becomes focused
                if let connectionId = payload?.connectionId,
                   let session = DatabaseManager.shared.activeSessions[connectionId] {
                    AppState.shared.isConnected = true
                    AppState.shared.isReadOnly = session.connection.isReadOnly
                    AppState.shared.isMongoDB = session.connection.type == .mongodb
                } else if payload?.connectionId != nil {
                    AppState.shared.isConnected = false
                    AppState.shared.isReadOnly = false
                    AppState.shared.isMongoDB = false
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
                    SidebarView(
                        tables: sessionTablesBinding,
                        selectedTables: $localSelectedTables,
                        activeTableName: windowTitle,
                        onShowAllTables: {
                            showAllTablesMetadata()
                        },
                        pendingTruncates: sessionPendingTruncatesBinding,
                        pendingDeletes: sessionPendingDeletesBinding,
                        tableOperationOptions: sessionTableOperationOptionsBinding,
                        databaseType: currentSession.connection.type,
                        connectionId: currentSession.connection.id,
                        schemaProvider: MainContentCoordinator.schemaProvider(for: currentSession.connection.id)
                    )
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 600)
            } detail: {
                // MARK: - Detail (Main workspace with optional right sidebar)
                MainContentView(
                    connection: currentSession.connection,
                    payload: payload,
                    windowTitle: $windowTitle,
                    tables: sessionTablesBinding,
                    selectedTables: $localSelectedTables,
                    pendingTruncates: sessionPendingTruncatesBinding,
                    pendingDeletes: sessionPendingDeletesBinding,
                    tableOperationOptions: sessionTableOperationOptionsBinding,
                    inspectorContext: $inspectorContext,
                    rightPanelState: rightPanelState
                )
                .id(currentSession.id)
            }
            .navigationTitle(windowTitle)
            .navigationSubtitle(currentSession.connection.name)
            .inspector(isPresented: Bindable(rightPanelState).isPresented) {
                UnifiedRightPanelView(
                    state: rightPanelState,
                    inspectorContext: inspectorContext,
                    connection: currentSession.connection,
                    tables: currentSession.tables
                )
                .inspectorColumnWidth(min: 280, ideal: 320, max: 500)
            }
        } else {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Connecting...")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("TablePro")
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
                guard let sessionId = payload?.connectionId ?? currentSession?.id else { return }
                Task { @MainActor in
                    DatabaseManager.shared.updateSession(sessionId) { session in
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
                try await DatabaseManager.shared.connectToSession(connection)
            } catch {
                Self.logger.error("Failed to connect: \(error.localizedDescription)")
            }
        }
    }

    private func handleCloseSession(_ sessionId: UUID) {
        Task {
            await DatabaseManager.shared.disconnectSession(sessionId)
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
        if DatabaseManager.shared.activeSessions[connection.id] != nil {
            Task {
                await DatabaseManager.shared.disconnectSession(connection.id)
            }
        }

        connections.removeAll { $0.id == connection.id }
        storage.deleteConnection(connection)
        storage.saveConnections(connections)
    }

    private func showAllTablesMetadata() {
        // Post notification for MainContentView to handle
        NotificationCenter.default.post(name: .showAllTables, object: nil)
    }
}

#Preview {
    ContentView(payload: nil)
}

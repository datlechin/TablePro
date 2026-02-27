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
        let start = CFAbsoluteTimeGetCurrent()
        self.payload = payload
        _windowTitle = State(initialValue: payload?.tableName ?? "SQL Query")
        Self.logger.debug("[PERF] ContentView.init done in \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000))ms, payload=\(payload?.tableName ?? "nil")")
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
                if let sessionId = DatabaseManager.shared.currentSessionId {
                    // Always confirm before disconnecting
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
                currentSession = DatabaseManager.shared.currentSession
                columnVisibility = newSessionId == nil ? .detailOnly : .all
                AppState.shared.isConnected = newSessionId != nil
                AppState.shared.isReadOnly = DatabaseManager.shared.activeSessions[newSessionId ?? UUID()]?.connection.isReadOnly ?? false
            }
            .onReceive(DatabaseManager.shared.$activeSessions) { sessions in
                guard let sid = DatabaseManager.shared.currentSessionId else {
                    if currentSession != nil { currentSession = nil }
                    return
                }
                guard let newSession = sessions[sid] else { return }
                // Skip update if fields ContentView uses haven't changed
                if let existing = currentSession,
                   existing.isContentViewEquivalent(to: newSession) {
                    return
                }
                currentSession = newSession
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
                        databaseType: currentSession.connection.type
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
            // No active session yet - show loading while connecting
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
                guard let sessionId = DatabaseManager.shared.currentSessionId else { return }
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

//
//  MainContentAlerts.swift
//  TablePro
//
//  ViewModifier for MainContentView alerts and sheets.
//  Extracts alert/sheet logic from main view for cleaner code.
//

import SwiftUI

/// ViewModifier handling all alerts and sheets for MainContentView
struct MainContentAlerts: ViewModifier {
    // MARK: - Dependencies

    @ObservedObject var coordinator: MainContentCoordinator
    let connection: DatabaseConnection

    // MARK: - Bindings

    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>
    let tables: [TableInfo]
    let selectedTables: Set<TableInfo>

    // MARK: - Environment

    @EnvironmentObject private var appState: AppState

    // MARK: - Body

    func body(content: Content) -> some View {
        content
            .alert("Discard Unsaved Changes?", isPresented: showDiscardAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) {
                    coordinator.handleDiscard(
                        pendingTruncates: &pendingTruncates,
                        pendingDeletes: &pendingDeletes
                    )
                }
            } message: {
                Text(discardAlertMessage)
            }

            .sheet(isPresented: $coordinator.showDatabaseSwitcher) {
                DatabaseSwitcherSheet(
                    isPresented: $coordinator.showDatabaseSwitcher,
                    currentDatabase: connection.database.isEmpty ? nil : connection.database,
                    databaseType: connection.type
                )                    { database in
                    coordinator.switchToDatabase(database)
                }
            }
            .focusedValue(\.isDatabaseSwitcherOpen, coordinator.showDatabaseSwitcher)
            .onChange(of: coordinator.showDatabaseSwitcher) { _, isPresented in
                appState.isSheetPresented = isPresented
            }

            .sheet(isPresented: $coordinator.showExportDialog) {
                ExportDialog(
                    isPresented: $coordinator.showExportDialog,
                    connection: connection,
                    preselectedTables: Set(selectedTables.map { $0.name })
                )
            }
            .onChange(of: coordinator.showExportDialog) { _, isPresented in
                appState.isSheetPresented = isPresented
            }

            .sheet(isPresented: $coordinator.showImportDialog) {
                ImportDialog(
                    isPresented: $coordinator.showImportDialog,
                    connection: connection,
                    initialFileURL: coordinator.importFileURL
                )
            }
            .onChange(of: coordinator.showImportDialog) { _, isPresented in
                appState.isSheetPresented = isPresented
                // Clear the file URL when dialog is dismissed
                if !isPresented {
                    coordinator.importFileURL = nil
                }
            }
    }

    // MARK: - Computed Properties

    private var showDiscardAlert: Binding<Bool> {
        Binding(
            get: { coordinator.pendingDiscardAction != nil },
            set: { if !$0 { coordinator.pendingDiscardAction = nil } }
        )
    }

    private var discardAlertMessage: String {
        guard let action = coordinator.pendingDiscardAction else { return "" }
        switch action {
        case .refresh, .refreshAll:
            return "Refreshing will discard all unsaved changes."
        case .closeTab:
            return "Closing this tab will discard all unsaved changes."
        }
    }
}

// MARK: - View Extension

extension View {
    /// Apply MainContentView alerts and sheets
    func mainContentAlerts(
        coordinator: MainContentCoordinator,
        connection: DatabaseConnection,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tables: [TableInfo],
        selectedTables: Set<TableInfo>
    ) -> some View {
        modifier(MainContentAlerts(
            coordinator: coordinator,
            connection: connection,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            tables: tables,
            selectedTables: selectedTables
        ))
    }
}

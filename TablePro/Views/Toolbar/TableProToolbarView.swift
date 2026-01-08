//
//  TableProToolbarView.swift
//  TablePro
//
//  Main toolbar composition view combining all toolbar components.
//  This is a pure presentation view - all state is injected via bindings.
//
//  Layout:
//  - Left (.navigation): Reserved for future navigation controls
//  - Center (.principal): Environment badge + Connection status
//  - Right (.primaryAction): Execution indicator
//

import SwiftUI

/// Content for the principal (center) toolbar area
/// Displays environment badge, connection status, and execution indicator in a unified container
struct ToolbarPrincipalContent: View {
    @ObservedObject var state: ConnectionToolbarState

    var body: some View {
        HStack(spacing: 12) {
            // Tag badge (if tag is assigned)
            if let tagId = state.tagId,
               let tag = TagStorage.shared.tag(for: tagId) {
                TagBadgeView(tag: tag)

                // Vertical separator
                Divider()
                    .frame(height: 16)
            }

            // Main connection status display
            ConnectionStatusView(
                databaseType: state.databaseType,
                databaseVersion: state.databaseVersion,
                databaseName: state.databaseName,
                connectionName: state.connectionName,
                connectionState: state.connectionState,
                displayColor: state.displayColor
            )

            // Vertical separator before execution indicator
            Divider()
                .frame(height: 16)

            // Execution indicator (spinner or duration)
            ExecutionIndicatorView(
                isExecuting: state.isExecuting,
                lastDuration: state.lastQueryDuration
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }
}

/// Toolbar modifier that composes all toolbar items
/// Apply this to a view to add the production toolbar
struct TableProToolbar: ViewModifier {
    @ObservedObject var state: ConnectionToolbarState

    func body(content: Content) -> some View {
        content
            .toolbar {
                // MARK: - Navigation (Left)
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 8) {
                        // Database switcher button
                        Button {
                            NotificationCenter.default.post(name: .openDatabaseSwitcher, object: nil)
                        } label: {
                            Image(systemName: "cylinder")
                        }
                        .help("Open Database (⌘K)")
                        .disabled(state.connectionState != .connected || state.databaseType == .sqlite)

                        // SQL query tab button
                        Button("SQL") {
                            NotificationCenter.default.post(name: .newTab, object: nil)
                        }
                        .help("New Query Tab (⌘T)")

                        // Refresh button
                        Button {
                            NotificationCenter.default.post(name: .refreshData, object: nil)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh (⌘R)")
                        .disabled(state.connectionState != .connected)
                    }
                }

                // MARK: - Principal (Center)
                // Main connection information display with execution indicator
                ToolbarItem(placement: .principal) {
                    ToolbarPrincipalContent(state: state)
                }

                // MARK: - Primary Action (Right)
                // Right sidebar (inspector) toggle button
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(name: .toggleRightSidebar, object: nil)
                    } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help("Toggle Inspector (⌘⌥B)")
                }
            }
    }
}

// MARK: - View Extension

extension View {
    /// Apply the TablePro toolbar to this view
    /// - Parameter state: The toolbar state to display
    /// - Returns: View with toolbar applied
    func tableProToolbar(state: ConnectionToolbarState) -> some View {
        modifier(TableProToolbar(state: state))
    }
}

// MARK: - Preview

#Preview("With Production Tag") {
    let state = ConnectionToolbarState()
    state.tagId = ConnectionTag.presets.first { $0.name == "production" }?.id
    state.databaseType = .mariadb
    state.databaseVersion = "11.1.2"
    state.connectionName = "Production Database"
    state.connectionState = .connected
    state.displayColor = .red

    return NavigationStack {
        Text("Content")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
    .tableProToolbar(state: state)
    .frame(width: 900, height: 400)
}

#Preview("Executing Query") {
    let state = ConnectionToolbarState()
    state.tagId = ConnectionTag.presets.first { $0.name == "local" }?.id
    state.databaseType = .mysql
    state.databaseVersion = "8.0.35"
    state.connectionName = "Development"
    state.connectionState = .executing
    state.isExecuting = true
    state.displayColor = .orange

    return NavigationStack {
        Text("Content")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
    .tableProToolbar(state: state)
    .frame(width: 900, height: 400)
}

#Preview("No Tag") {
    let state = ConnectionToolbarState()
    state.tagId = nil
    state.databaseType = .postgresql
    state.databaseVersion = "16.1"
    state.connectionName = "Analytics"
    state.connectionState = .connected
    state.displayColor = .blue

    return NavigationStack {
        Text("Content")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
    .tableProToolbar(state: state)
    .frame(width: 900, height: 400)
    .preferredColorScheme(.dark)
}

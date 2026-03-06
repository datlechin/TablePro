//
//  WelcomeWindowView.swift
//  TablePro
//
//  Separate welcome window with split-panel layout.
//  Shows on app launch, closes when connecting to a database.
//

import AppKit
import os
import SwiftUI

// MARK: - WelcomeWindowView

struct WelcomeWindowView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WelcomeWindowView")
    private let storage = ConnectionStorage.shared
    private let groupStorage = GroupStorage.shared
    private let dbManager = DatabaseManager.shared

    @State private var connections: [DatabaseConnection] = []
    @State private var searchText = ""
    @State private var connectionToDelete: DatabaseConnection?
    @State private var showDeleteConfirmation = false
    @State private var selectedConnectionId: UUID?
    @State private var showOnboarding = !AppSettingsStorage.shared.hasCompletedOnboarding()

    // Group state
    @State private var groups: [ConnectionGroup] = []
    @State private var expandedGroups: Set<UUID> = []
    @State private var groupFormContext: GroupFormContext?
    @State private var groupToDelete: ConnectionGroup?
    @State private var showDeleteGroupConfirmation = false

    @Environment(\.openWindow) private var openWindow

    private var filteredConnections: [DatabaseConnection] {
        if searchText.isEmpty {
            return connections
        }
        return connections.filter { connection in
            connection.name.localizedCaseInsensitiveContains(searchText)
                || connection.host.localizedCaseInsensitiveContains(searchText)
                || connection.database.localizedCaseInsensitiveContains(searchText)
                || groups.first(where: { $0.id == connection.groupId })?.name
                    .localizedCaseInsensitiveContains(searchText) == true
        }
    }

    var body: some View {
        ZStack {
            if showOnboarding {
                OnboardingContentView {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        showOnboarding = false
                    }
                }
                .transition(.move(edge: .leading))
            } else {
                welcomeContent
                    .transition(.move(edge: .trailing))
            }
        }
        .background(.background)
        .ignoresSafeArea()
        .frame(minWidth: 650, minHeight: 400)
        .onAppear {
            loadConnections()
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in
            openWindow(id: "connection-form", value: nil as UUID?)
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectionUpdated)) { _ in
            loadConnections()
        }
        .confirmationDialog(
            "Delete Group",
            isPresented: $showDeleteGroupConfirmation,
            presenting: groupToDelete
        ) { group in
            Button("Delete", role: .destructive) {
                deleteGroup(group)
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text("Are you sure you want to delete \"\(group.name)\"? Connections will be ungrouped.")
        }
        .sheet(item: $groupFormContext) { context in
            ConnectionGroupFormSheet(
                group: context.group,
                parentGroupId: context.parentGroupId
            ) { group in
                if context.group != nil {
                    groupStorage.updateGroup(group)
                } else {
                    groupStorage.addGroup(group)
                    expandedGroups.insert(group.id)
                    groupStorage.saveExpandedGroupIds(expandedGroups)
                }
                groupFormContext = nil
                loadConnections()
            }
        }
    }

    private var welcomeContent: some View {
        HStack(spacing: 0) {
            // Left panel - Branding
            leftPanel

            Divider()

            // Right panel - Connections
            rightPanel
        }
        .transition(.opacity)
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            // App branding
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .shadow(color: Color(red: 1.0, green: 0.576, blue: 0.0).opacity(0.4), radius: 20, x: 0, y: 0)

                VStack(spacing: 6) {
                    Text("TablePro")
                        .font(
                            .system(
                                size: DesignConstants.IconSize.extraLarge, weight: .semibold,
                                design: .rounded))

                    Text("Version \(Bundle.main.appVersion)")
                        .font(.system(size: DesignConstants.FontSize.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
                .frame(height: 48)

            // Action button
            VStack(spacing: 12) {
                Button(action: { openWindow(id: "connection-form") }) {
                    Label("Create connection...", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(WelcomeButtonStyle())
            }
            .padding(.horizontal, 32)

            Spacer()

            // Footer hints
            HStack(spacing: 16) {
                KeyboardHint(keys: "⌘N", label: "New")
                KeyboardHint(keys: "⌘,", label: "Settings")
            }
            .font(.system(size: DesignConstants.FontSize.small))
            .foregroundStyle(.tertiary)
            .padding(.bottom, DesignConstants.Spacing.lg)
        }
        .frame(width: 260)
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Button(action: { openWindow(id: "connection-form") }) {
                    Image(systemName: "plus")
                        .font(.system(size: DesignConstants.FontSize.medium, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(
                            width: DesignConstants.IconSize.extraLarge,
                            height: DesignConstants.IconSize.extraLarge
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .quaternaryLabelColor))
                        )
                }
                .buttonStyle(.plain)
                .help("New Connection (⌘N)")

                Button(action: {
                    groupFormContext = GroupFormContext(group: nil, parentGroupId: nil)
                }) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: DesignConstants.FontSize.medium, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(
                            width: DesignConstants.IconSize.extraLarge,
                            height: DesignConstants.IconSize.extraLarge
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .quaternaryLabelColor))
                        )
                }
                .buttonStyle(.plain)
                .help(String(localized: "New Group"))

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: DesignConstants.FontSize.medium))
                        .foregroundStyle(.tertiary)

                    TextField("Search for connection...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: DesignConstants.FontSize.body))
                }
                .padding(.horizontal, DesignConstants.Spacing.sm)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                )
            }
            .padding(.horizontal, DesignConstants.Spacing.md)
            .padding(.vertical, DesignConstants.Spacing.sm)

            Divider()

            // Connection list
            ZStack {
                connectionList

                if connections.isEmpty, groups.isEmpty {
                    emptyState
                } else if !searchText.isEmpty, filteredConnections.isEmpty {
                    emptyState
                }
            }
        }
        .frame(minWidth: 350)
    }

    // MARK: - Connection List (NSOutlineView)

    private var connectionList: some View {
        ConnectionOutlineView(
            groups: groups,
            connections: searchText.isEmpty ? connections : filteredConnections,
            expandedGroupIds: expandedGroups,
            selectedItemId: selectedConnectionId,
            searchText: searchText,
            onSelectionChanged: { id in
                selectedConnectionId = id
            },
            onDoubleClickConnection: { connection in
                connectToDatabase(connection)
            },
            onToggleGroup: { groupId in
                toggleGroup(groupId)
            },
            onReorderConnections: { reorderedConns in
                let updatedIds = Dictionary(uniqueKeysWithValues: reorderedConns.map { ($0.id, $0) })
                var allConns = connections
                for index in allConns.indices {
                    if let updated = updatedIds[allConns[index].id] {
                        allConns[index] = updated
                    }
                }
                // Append any new entries (e.g. moved from another group)
                for conn in reorderedConns where !allConns.contains(where: { $0.id == conn.id }) {
                    allConns.append(conn)
                }
                storage.saveConnections(allConns)
                connections = allConns
            },
            onReorderGroups: { reorderedGroups in
                let updatedIds = Dictionary(uniqueKeysWithValues: reorderedGroups.map { ($0.id, $0) })
                var allGroups = groups
                for index in allGroups.indices {
                    if let updated = updatedIds[allGroups[index].id] {
                        allGroups[index] = updated
                    }
                }
                for grp in reorderedGroups where !allGroups.contains(where: { $0.id == grp.id }) {
                    allGroups.append(grp)
                }
                groupStorage.saveGroups(allGroups)
                loadConnections()
            },
            onMoveGroup: { group, newParentId in
                var updated = group
                updated.parentGroupId = newParentId
                groupStorage.updateGroup(updated)
                loadConnections()
            },
            onNewConnection: {
                openWindow(id: "connection-form")
            },
            onNewGroup: { parentId in
                groupFormContext = GroupFormContext(group: nil, parentGroupId: parentId)
            },
            onEditGroup: { group in
                groupFormContext = GroupFormContext(group: group, parentGroupId: group.parentGroupId)
            },
            onDeleteGroup: { group in
                groupToDelete = group
                showDeleteGroupConfirmation = true
            },
            onEditConnection: { connection in
                openWindow(id: "connection-form", value: connection.id as UUID?)
                focusConnectionFormWindow()
            },
            onDuplicateConnection: { connection in
                duplicateConnection(connection)
            },
            onCopyConnectionURL: { connection in
                Task.detached {
                    let pw = ConnectionStorage.shared.loadPassword(for: connection.id)
                    let sshPw = ConnectionStorage.shared.loadSSHPassword(for: connection.id)
                    let url = ConnectionURLFormatter.format(connection, password: pw, sshPassword: sshPw)
                    await MainActor.run {
                        ClipboardService.shared.writeText(url)
                    }
                }
            },
            onDeleteConnection: { connection in
                connectionToDelete = connection
                showDeleteConfirmation = true
            },
            onMoveConnectionToGroup: { connection, groupId in
                moveConnectionToGroup(connection, groupId: groupId)
            }
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: DesignConstants.IconSize.huge))
                .foregroundStyle(.quaternary)

            if searchText.isEmpty {
                Text("No connections yet")
                    .font(.system(size: DesignConstants.FontSize.title3, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Click + to create your first connection")
                    .font(.system(size: DesignConstants.FontSize.medium))
                    .foregroundStyle(.tertiary)
            } else {
                Text("No matching connections")
                    .font(.system(size: DesignConstants.FontSize.title3, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func loadConnections() {
        let saved = storage.loadConnections()
        if saved.isEmpty {
            connections = DatabaseConnection.sampleConnections
            storage.saveConnections(connections)
        } else {
            connections = saved
        }
        groups = groupStorage.loadGroups()
        expandedGroups = groupStorage.loadExpandedGroupIds()
    }

    private func connectToDatabase(_ connection: DatabaseConnection) {
        // Open main window first, then connect in background
        openWindow(id: "main", value: EditorTabPayload(connectionId: connection.id))
        NSApplication.shared.closeWindows(withId: "welcome")

        // Connect in background - main window shows loading state
        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                // Show error to user and re-open welcome window
                await MainActor.run {
                    AlertHelper.showErrorSheet(
                        title: String(localized: "Connection Failed"),
                        message: error.localizedDescription,
                        window: nil
                    )
                    openWindow(id: "welcome")
                }
                Self.logger.error(
                    "Failed to connect: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func deleteConnection(_ connection: DatabaseConnection) {
        connections.removeAll { $0.id == connection.id }
        storage.deleteConnection(connection)
        storage.saveConnections(connections)
    }

    private func duplicateConnection(_ connection: DatabaseConnection) {
        // Create duplicate with new UUID and copy passwords
        let duplicate = storage.duplicateConnection(connection)

        // Refresh connections list
        loadConnections()

        // Open edit form for the duplicate so user can rename
        openWindow(id: "connection-form", value: duplicate.id as UUID?)
        focusConnectionFormWindow()
    }

    /// Focus the connection form window as soon as it's available
    private func focusConnectionFormWindow() {
        // Poll rapidly until window is found (much faster than fixed delay)
        func attemptFocus(remainingAttempts: Int = 10) {
            for window in NSApp.windows {
                if window.identifier?.rawValue.contains("connection-form") == true
                    || window.title == "Connection"
                {
                    window.makeKeyAndOrderFront(nil)
                    return
                }
            }
            // Window not found yet, try again in 20ms
            if remainingAttempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    attemptFocus(remainingAttempts: remainingAttempts - 1)
                }
            }
        }
        // Start immediately on next run loop
        DispatchQueue.main.async {
            attemptFocus()
        }
    }

    private func deleteGroup(_ group: ConnectionGroup) {
        let allGroups = groupStorage.loadGroups()
        let descendantIds = collectDescendantIds(of: group.id, in: allGroups)
        let allDeletedIds = descendantIds.union([group.id])
        groupStorage.deleteGroup(group)
        expandedGroups.subtract(allDeletedIds)
        groupStorage.saveExpandedGroupIds(expandedGroups)
        loadConnections()
    }

    private func moveConnectionToGroup(_ connection: DatabaseConnection, groupId: UUID?) {
        var updated = connection
        updated.groupId = groupId
        storage.updateConnection(updated)
        loadConnections()
    }

    private func collectDescendantIds(of groupId: UUID, in groups: [ConnectionGroup]) -> Set<UUID> {
        var result = Set<UUID>()
        let children = groups.filter { $0.parentGroupId == groupId }
        for child in children {
            result.insert(child.id)
            result.formUnion(collectDescendantIds(of: child.id, in: groups))
        }
        return result
    }

    private func toggleGroup(_ groupId: UUID) {
        if expandedGroups.contains(groupId) {
            expandedGroups.remove(groupId)
        } else {
            expandedGroups.insert(groupId)
        }
        groupStorage.saveExpandedGroupIds(expandedGroups)
    }
}

// MARK: - GroupFormContext

/// Identifiable wrapper so `.sheet(item:)` creates fresh content with correct values
private struct GroupFormContext: Identifiable {
    let id = UUID()
    let group: ConnectionGroup?
    let parentGroupId: UUID?
}

// MARK: - WelcomeButtonStyle

private struct WelcomeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DesignConstants.FontSize.body))
            .foregroundStyle(.primary)
            .padding(.horizontal, DesignConstants.Spacing.md)
            .padding(.vertical, DesignConstants.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        Color(
                            nsColor: configuration.isPressed
                                ? .controlBackgroundColor : .quaternaryLabelColor))
            )
    }
}

// MARK: - KeyboardHint

private struct KeyboardHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: DesignConstants.FontSize.caption, design: .monospaced))
                .padding(.horizontal, DesignConstants.Spacing.xxs + 1)
                .padding(.vertical, DesignConstants.Spacing.xxxs)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                )
            Text(label)
        }
    }
}

// MARK: - Preview

#Preview("Welcome Window") {
    WelcomeWindowView()
        .frame(width: 700, height: 450)
}

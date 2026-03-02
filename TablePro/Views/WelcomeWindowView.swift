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
    @ObservedObject private var dbManager = DatabaseManager.shared

    @State private var connections: [DatabaseConnection] = []
    @State private var searchText = ""
    @State private var showNewConnectionSheet = false
    @State private var showEditConnectionSheet = false
    @State private var connectionToEdit: DatabaseConnection?
    @State private var connectionToDelete: DatabaseConnection?
    @State private var showDeleteConfirmation = false
    @State private var hoveredConnectionId: UUID?
    @State private var selectedConnectionId: UUID?  // For keyboard navigation
    @State private var showOnboarding = !AppSettingsStorage.shared.hasCompletedOnboarding()

    // Group state
    @State private var groups: [ConnectionGroup] = []
    @State private var expandedGroups: Set<UUID> = []
    @State private var showNewGroupSheet = false
    @State private var groupToEdit: ConnectionGroup?
    @State private var groupToDelete: ConnectionGroup?
    @State private var showDeleteGroupConfirmation = false
    @State private var newGroupParentId: UUID?

    private let groupStorage = GroupStorage.shared

    @Environment(\.openWindow) private var openWindow

    private var filteredConnections: [DatabaseConnection] {
        if searchText.isEmpty {
            return connections
        }
        return connections.filter { connection in
            connection.name.localizedCaseInsensitiveContains(searchText)
                || connection.host.localizedCaseInsensitiveContains(searchText)
                || connection.database.localizedCaseInsensitiveContains(searchText)
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
        .sheet(isPresented: $showNewGroupSheet) {
            ConnectionGroupFormSheet(
                group: groupToEdit,
                parentGroupId: newGroupParentId
            ) { group in
                if groupToEdit != nil {
                    groupStorage.updateGroup(group)
                } else {
                    groupStorage.addGroup(group)
                    expandedGroups.insert(group.id)
                    groupStorage.saveExpandedGroupIds(expandedGroups)
                }
                groupToEdit = nil
                newGroupParentId = nil
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
            if filteredConnections.isEmpty {
                emptyState
            } else {
                connectionList
            }
        }
        .frame(minWidth: 350)
        .contentShape(Rectangle())
        .contextMenu { newConnectionContextMenu }
    }

    @ViewBuilder
    private var newConnectionContextMenu: some View {
        Button(action: { openWindow(id: "connection-form") }) {
            Label("New Connection...", systemImage: "plus")
        }
        Button(action: {
            groupToEdit = nil
            newGroupParentId = nil
            showNewGroupSheet = true
        }) {
            Label("New Group...", systemImage: "folder.badge.plus")
        }
    }

    // MARK: - Connection List

    /// Connection list with group hierarchy support.
    /// When searching: flat filtered list. Otherwise: grouped with DisclosureGroups.
    private var connectionList: some View {
        List(selection: $selectedConnectionId) {
            if !searchText.isEmpty {
                // Flat filtered list during search
                ForEach(filteredConnections) { connection in
                    connectionRow(for: connection)
                }
            } else {
                // Grouped hierarchical view
                ForEach(rootGroups) { group in
                    groupSection(for: group)
                }
                .onMove { from, to in
                    moveRootGroups(from: from, to: to)
                }

                // Ungrouped connections
                ForEach(ungroupedConnections) { connection in
                    connectionRow(for: connection)
                }
                .onMove { from, to in
                    moveUngroupedConnections(from: from, to: to)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 44)
        .dropDestination(for: String.self) { items, _ in
            handleDropOnGroup(items: items, targetGroupId: nil)
        }
        .onKeyPress(.return) {
            if let id = selectedConnectionId,
                let connection = connections.first(where: { $0.id == id })
            {
                connectToDatabase(connection)
            }
            return .handled
        }
    }

    // MARK: - Group Hierarchy

    private var rootGroups: [ConnectionGroup] {
        groups.filter { $0.parentGroupId == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var ungroupedConnections: [DatabaseConnection] {
        connections.filter { $0.groupId == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func childGroups(of parentId: UUID) -> [ConnectionGroup] {
        groups.filter { $0.parentGroupId == parentId }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func connectionsInGroup(_ groupId: UUID) -> [DatabaseConnection] {
        connections.filter { $0.groupId == groupId }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func totalConnectionCount(in group: ConnectionGroup) -> Int {
        let direct = connections.filter { $0.groupId == group.id }.count
        let children = childGroups(of: group.id)
        let nested = children.reduce(0) { $0 + totalConnectionCount(in: $1) }
        return direct + nested
    }

    private func expandedBinding(_ groupId: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(groupId) },
            set: { isExpanded in
                if isExpanded {
                    expandedGroups.insert(groupId)
                } else {
                    expandedGroups.remove(groupId)
                }
                groupStorage.saveExpandedGroupIds(expandedGroups)
            }
        )
    }

    private func groupSection(for group: ConnectionGroup) -> AnyView {
        AnyView(
            DisclosureGroup(isExpanded: expandedBinding(group.id)) {
                ForEach(childGroups(of: group.id)) { child in
                    groupSection(for: child)
                }
                ForEach(connectionsInGroup(group.id)) { connection in
                    connectionRow(for: connection)
                }
            } label: {
                groupRowLabel(group)
            }
        )
    }

    private func groupRowLabel(_ group: ConnectionGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(group.color.isDefault ? .secondary : group.color.color)
                .font(.system(size: DesignConstants.FontSize.body))

            Text(group.name)
                .font(.system(size: DesignConstants.FontSize.body, weight: .medium))
                .foregroundStyle(.primary)

            Text("\(totalConnectionCount(in: group))")
                .font(.system(size: DesignConstants.FontSize.small))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .contentShape(Rectangle())
        .overlay(
            DoubleClickView {
                if expandedGroups.contains(group.id) {
                    expandedGroups.remove(group.id)
                } else {
                    expandedGroups.insert(group.id)
                }
                groupStorage.saveExpandedGroupIds(expandedGroups)
            }
        )
        .dropDestination(for: String.self) { items, _ in
            handleDropOnGroup(items: items, targetGroupId: group.id)
        }
        .contextMenu {
            Button(action: { openWindow(id: "connection-form") }) {
                Label("New Connection...", systemImage: "plus")
            }
            Button(action: {
                groupToEdit = nil
                newGroupParentId = group.id
                showNewGroupSheet = true
            }) {
                Label("New Subgroup...", systemImage: "folder.badge.plus")
            }
            Divider()
            Button(action: {
                groupToEdit = group
                newGroupParentId = group.parentGroupId
                showNewGroupSheet = true
            }) {
                Label("Edit Group...", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                groupToDelete = group
                showDeleteGroupConfirmation = true
            } label: {
                Label("Delete Group", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func connectionRow(for connection: DatabaseConnection) -> some View {
        ConnectionRow(
            connection: connection,
            groups: groups,
            onConnect: { connectToDatabase(connection) },
            onEdit: {
                openWindow(id: "connection-form", value: connection.id as UUID?)
                focusConnectionFormWindow()
            },
            onDuplicate: {
                duplicateConnection(connection)
            },
            onDelete: {
                connectionToDelete = connection
                showDeleteConfirmation = true
            },
            onMoveToGroup: { groupId in
                moveConnectionToGroup(connection, groupId: groupId)
            }
        )
        .tag(connection.id)
        .listRowInsets(DesignConstants.swiftUIListRowInsets)
        .listRowSeparator(.hidden)
        .draggable(connection.id.uuidString)
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
        let savedExpanded = groupStorage.loadExpandedGroupIds()
        // Auto-expand new groups
        expandedGroups = savedExpanded.union(Set(groups.map(\.id)))
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
        groupStorage.deleteGroup(group)
        expandedGroups.remove(group.id)
        groupStorage.saveExpandedGroupIds(expandedGroups)
        loadConnections()
    }

    private func moveConnectionToGroup(_ connection: DatabaseConnection, groupId: UUID?) {
        var updated = connection
        updated.groupId = groupId
        storage.updateConnection(updated)
        loadConnections()
    }

    private func moveUngroupedConnections(from: IndexSet, to: Int) {
        var ungrouped = connections.filter { $0.groupId == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        ungrouped.move(fromOffsets: from, toOffset: to)
        for (index, var conn) in ungrouped.enumerated() {
            conn.sortOrder = index
            storage.updateConnection(conn)
        }
        loadConnections()
    }

    private func moveRootGroups(from: IndexSet, to: Int) {
        var roots = groups.filter { $0.parentGroupId == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        roots.move(fromOffsets: from, toOffset: to)
        for (index, var group) in roots.enumerated() {
            group.sortOrder = index
            groupStorage.updateGroup(group)
        }
        loadConnections()
    }

    private func handleDropOnGroup(items: [String], targetGroupId: UUID?) -> Bool {
        var changed = false
        for item in items {
            guard let uuid = UUID(uuidString: item) else { continue }
            if var conn = connections.first(where: { $0.id == uuid }) {
                guard conn.groupId != targetGroupId else { continue }
                conn.groupId = targetGroupId
                storage.updateConnection(conn)
                changed = true
            }
        }
        if changed {
            loadConnections()
        }
        return changed
    }
}

// MARK: - ConnectionRow

private struct ConnectionRow: View {
    let connection: DatabaseConnection
    var groups: [ConnectionGroup] = []
    var onConnect: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMoveToGroup: ((UUID?) -> Void)?

    private var displayTag: ConnectionTag? {
        guard let tagId = connection.tagId else { return nil }
        return TagStorage.shared.tag(for: tagId)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Database type icon
            Image(connection.type.iconName)
                .renderingMode(.template)
                .font(.system(size: DesignConstants.IconSize.medium))
                .foregroundStyle(connection.displayColor)
                .frame(
                    width: DesignConstants.IconSize.medium, height: DesignConstants.IconSize.medium)

            // Connection info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.name)
                        .font(.system(size: DesignConstants.FontSize.body, weight: .medium))
                        .foregroundStyle(.primary)

                    // Tag (single)
                    if let tag = displayTag {
                        Text(tag.name)
                            .font(.system(size: DesignConstants.FontSize.tiny))
                            .foregroundStyle(tag.color.color)
                            .padding(.horizontal, DesignConstants.Spacing.xxs)
                            .padding(.vertical, DesignConstants.Spacing.xxxs)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(
                                    tag.color.color.opacity(0.15)))
                    }
                }

                Text(connectionSubtitle)
                    .font(.system(size: DesignConstants.FontSize.small))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, DesignConstants.Spacing.xxs)
        .contentShape(Rectangle())
        .overlay(
            DoubleClickView { onConnect?() }
        )
        .contextMenu {
            if let onConnect = onConnect {
                Button(action: onConnect) {
                    Label("Connect", systemImage: "play.fill")
                }
                Divider()
            }

            if let onEdit = onEdit {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
            }

            if let onDuplicate = onDuplicate {
                Button(action: onDuplicate) {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
            }

            if !groups.isEmpty, let onMoveToGroup = onMoveToGroup {
                Divider()
                Menu("Move to Group") {
                    Button {
                        onMoveToGroup(nil)
                    } label: {
                        HStack {
                            Text("None")
                            if connection.groupId == nil {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Divider()
                    ForEach(groups.filter { $0.parentGroupId == nil }.sorted { $0.sortOrder < $1.sortOrder }) { group in
                        Button {
                            onMoveToGroup(group.id)
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                Text(group.name)
                                if connection.groupId == group.id {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            if let onDelete = onDelete {
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var connectionSubtitle: String {
        if connection.sshConfig.enabled {
            return "SSH : \(connection.sshConfig.username)@\(connection.sshConfig.host)"
        }
        if connection.host.isEmpty {
            return connection.database.isEmpty ? connection.type.rawValue : connection.database
        }
        return connection.host
    }
}

// MARK: - EnvironmentBadge

private struct EnvironmentBadge: View {
    let connection: DatabaseConnection

    private var environment: ConnectionEnvironment {
        if connection.sshConfig.enabled {
            return .ssh
        }
        if connection.host.contains("prod") || connection.name.lowercased().contains("prod") {
            return .production
        }
        if connection.host.contains("staging") || connection.name.lowercased().contains("staging") {
            return .staging
        }
        return .local
    }

    var body: some View {
        Text("(\(environment.rawValue.lowercased()))")
            .font(.system(size: DesignConstants.FontSize.small))
            .foregroundStyle(environment.badgeColor)
    }
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

// MARK: - ConnectionEnvironment Extension

private extension ConnectionEnvironment {
    var badgeColor: Color {
        switch self {
        case .local:
            return Color(nsColor: .systemGreen)
        case .ssh:
            return Color(nsColor: .systemBlue)
        case .staging:
            return Color(nsColor: .systemOrange)
        case .production:
            return Color(nsColor: .systemRed)
        }
    }
}

// MARK: - DoubleClickView

private struct DoubleClickView: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughDoubleClickView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PassThroughDoubleClickView)?.onDoubleClick = onDoubleClick
    }
}

private class PassThroughDoubleClickView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2, event.clickCount % 2 == 0 {
            onDoubleClick?()
        }
        // Always forward to next responder for List selection
        super.mouseDown(with: event)
    }
}

// MARK: - Preview

#Preview("Welcome Window") {
    WelcomeWindowView()
        .frame(width: 700, height: 450)
}

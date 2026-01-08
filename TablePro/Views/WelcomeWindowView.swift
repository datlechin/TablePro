//
//  WelcomeWindowView.swift
//  TablePro
//
//  Separate welcome window with split-panel layout.
//  Shows on app launch, closes when connecting to a database.
//

import SwiftUI

// MARK: - WelcomeWindowView

struct WelcomeWindowView: View {
    private let storage = ConnectionStorage.shared
    @StateObject private var dbManager = DatabaseManager.shared

    @State private var connections: [DatabaseConnection] = []
    @State private var searchText = ""
    @State private var showNewConnectionSheet = false
    @State private var showEditConnectionSheet = false
    @State private var connectionToEdit: DatabaseConnection?
    @State private var connectionToDelete: DatabaseConnection?
    @State private var showDeleteConfirmation = false
    @State private var hoveredConnectionId: UUID?
    @State private var selectedConnectionId: UUID?  // For keyboard navigation
    @State private var connectionError: String?  // For showing connection errors
    @State private var showConnectionError = false

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var filteredConnections: [DatabaseConnection] {
        if searchText.isEmpty {
            return connections
        }
        return connections.filter { connection in
            connection.name.localizedCaseInsensitiveContains(searchText) ||
                connection.host.localizedCaseInsensitiveContains(searchText) ||
                connection.database.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel - Branding
            leftPanel

            Divider()

            // Right panel - Connections
            rightPanel
        }
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
        .alert("Connection Failed", isPresented: $showConnectionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionError ?? "Unknown error")
        }
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            // App branding
            VStack(spacing: 16) {
                // Logo with glow
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.30))
                        .frame(width: 100, height: 100)
                        .blur(radius: 25)

                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 80, height: 80)
                }

                VStack(spacing: 6) {
                    Text("TablePro")
                        .font(.system(size: DesignConstants.IconSize.extraLarge, weight: .semibold, design: .rounded))

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
                        .frame(width: DesignConstants.IconSize.extraLarge, height: DesignConstants.IconSize.extraLarge)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.06))
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
                        .fill(Color.primary.opacity(0.04))
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
    }

    // MARK: - Connection List

    /// Connection list that behaves like native NSTableView:
    /// - Single click: selects row (handled by List's selection binding)
    /// - Double click: connects to database (via simultaneousGesture in ConnectionRow)
    /// - Return key: connects to selected row
    /// - Arrow keys: native keyboard navigation
    private var connectionList: some View {
        List(selection: $selectedConnectionId) {
            ForEach(filteredConnections) { connection in
                ConnectionRow(
                    connection: connection,
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
                    }
                )
                .tag(connection.id)
                .listRowInsets(DesignConstants.swiftUIListRowInsets)
                .listRowSeparator(.hidden)
            }
            // Reorder only when not searching to prevent index mapping issues
            .onMove { from, to in
                guard searchText.isEmpty else { return }
                connections.move(fromOffsets: from, toOffset: to)
                storage.saveConnections(connections)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .environment(\.defaultMinListRowHeight, 44)
        .onKeyPress(.return) {
            // Return key connects to selected row
            if let id = selectedConnectionId,
               let connection = connections.first(where: { $0.id == id }) {
                connectToDatabase(connection)
            }
            return .handled
        }
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
    }

    private func connectToDatabase(_ connection: DatabaseConnection) {
        // Open main window immediately - no delay
        openWindow(id: "main")
        dismissWindow(id: "welcome")

        // Connect in background - main window shows loading state
        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                // Show error to user and re-open welcome window
                await MainActor.run {
                    connectionError = error.localizedDescription
                    showConnectionError = true
                    openWindow(id: "welcome")
                }
                print("Failed to connect: \(error)")
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
                if window.identifier?.rawValue.contains("connection-form") == true ||
                    window.title == "Connection" {
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
}

// MARK: - ConnectionRow

private struct ConnectionRow: View {
    let connection: DatabaseConnection
    var onConnect: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onDelete: (() -> Void)?

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
                .frame(width: DesignConstants.IconSize.medium, height: DesignConstants.IconSize.medium)

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
                            .background(Capsule().fill(tag.color.color.opacity(0.15)))
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
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0.04))
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
                        .fill(Color.primary.opacity(0.06))
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
            return .green
        case .ssh:
            return .blue
        case .staging:
            return .orange
        case .production:
            return .red
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {}
}

private class PassThroughDoubleClickView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        }
        // Always forward to next responder for List selection
        super.mouseDown(with: event)
    }
}

// MARK: - Bundle Extension

private extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - Preview

#Preview("Welcome Window") {
    WelcomeWindowView()
        .frame(width: 700, height: 450)
}

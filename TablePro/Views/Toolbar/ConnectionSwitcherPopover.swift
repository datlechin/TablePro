//
//  ConnectionSwitcherPopover.swift
//  TablePro
//
//  Quick-switch popover for active and saved connections.
//  Shown from the toolbar connection button.
//

import SwiftUI

/// Popover content for quick connection switching
struct ConnectionSwitcherPopover: View {
    @State private var savedConnections: [DatabaseConnection] = []
    @State private var isConnecting: UUID?
    @State private var selectedIndex: Int = 0
    @State private var keyMonitor: Any?

    /// Callback when the popover should dismiss
    var onDismiss: (() -> Void)?

    private var activeSessions: [UUID: ConnectionSession] {
        DatabaseManager.shared.activeSessions
    }

    private var currentSessionId: UUID? {
        DatabaseManager.shared.currentSessionId
    }

    /// All items in display order for keyboard navigation
    private var allItems: [ConnectionItem] {
        var items: [ConnectionItem] = []

        let sorted = Array(activeSessions.values).sorted { $0.lastActiveAt > $1.lastActiveAt }
        for session in sorted {
            items.append(.session(session))
        }

        let inactive = savedConnections.filter { activeSessions[$0.id] == nil }
        for connection in inactive {
            items.append(.saved(connection))
        }

        return items
    }

    var body: some View {
        let sortedSessions = Array(activeSessions.values).sorted { $0.lastActiveAt > $1.lastActiveAt }
        let inactiveSaved = savedConnections.filter { activeSessions[$0.id] == nil }

        VStack(spacing: 0) {
            List {
                // Active connections section
                if !sortedSessions.isEmpty {
                    Section {
                        ForEach(Array(sortedSessions.enumerated()), id: \.element.id) { index, session in
                            connectionRow(
                                connection: session.connection,
                                isActive: session.id == currentSessionId,
                                isConnected: session.status.isConnected,
                                isHighlighted: index == selectedIndex
                            )
                            .onTapGesture {
                                switchToSession(session.id)
                            }
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        index == selectedIndex
                                            ? Color(nsColor: .selectedContentBackgroundColor)
                                            : Color.clear
                                    )
                                    .padding(.horizontal, 4)
                            )
                            .listRowInsets(DesignConstants.swiftUIListRowInsets)
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("ACTIVE CONNECTIONS")
                            .font(.system(size: DesignConstants.FontSize.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                // Saved connections (not currently active)
                if !inactiveSaved.isEmpty {
                    Section {
                        ForEach(Array(inactiveSaved.enumerated()), id: \.element.id) { index, connection in
                            let itemIndex = sortedSessions.count + index
                            connectionRow(
                                connection: connection,
                                isActive: false,
                                isConnected: false,
                                isConnecting: isConnecting == connection.id,
                                isHighlighted: itemIndex == selectedIndex
                            )
                            .onTapGesture {
                                connectToSaved(connection)
                            }
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        itemIndex == selectedIndex
                                            ? Color(nsColor: .selectedContentBackgroundColor)
                                            : Color.clear
                                    )
                                    .padding(.horizontal, 4)
                            )
                            .listRowInsets(DesignConstants.swiftUIListRowInsets)
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("SAVED CONNECTIONS")
                            .font(.system(size: DesignConstants.FontSize.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            // Manage connections button
            Button {
                onDismiss?()
                NotificationCenter.default.post(name: .openWelcomeWindow, object: nil)
            } label: {
                HStack {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                    Text("Manage Connections...")
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .frame(
            width: 280,
            height: listHeight(
                sessions: sortedSessions.count,
                saved: inactiveSaved.count
            )
        )
        .onAppear {
            savedConnections = ConnectionStorage.shared.loadConnections()
            if let currentId = currentSessionId {
                let sorted = Array(activeSessions.values).sorted { $0.lastActiveAt > $1.lastActiveAt }
                if let idx = sorted.firstIndex(where: { $0.id == currentId }) {
                    selectedIndex = idx
                }
            }
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    // MARK: - Keyboard Navigation

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let items = allItems
            switch event.keyCode {
            case 126: // Up arrow
                if selectedIndex > 0 {
                    selectedIndex -= 1
                }
                return nil
            case 125: // Down arrow
                if selectedIndex < items.count - 1 {
                    selectedIndex += 1
                }
                return nil
            case 36: // Return
                guard selectedIndex >= 0, selectedIndex < items.count else { return event }
                switch items[selectedIndex] {
                case .session(let session):
                    switchToSession(session.id)
                case .saved(let connection):
                    connectToSaved(connection)
                }
                return nil
            case 53: // Escape
                onDismiss?()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Item Type

    private enum ConnectionItem {
        case session(ConnectionSession)
        case saved(DatabaseConnection)
    }

    // MARK: - Subviews

    private func connectionRow(
        connection: DatabaseConnection,
        isActive: Bool,
        isConnected: Bool,
        isConnecting: Bool = false,
        isHighlighted: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            // Color indicator
            Circle()
                .fill(isHighlighted ? Color.white : connection.displayColor)
                .frame(width: 8, height: 8)

            // Connection info
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isHighlighted ? .white : .primary)
                    .lineLimit(1)

                Text(connectionSubtitle(connection))
                    .font(.system(size: 11))
                    .foregroundStyle(isHighlighted ? .white.opacity(0.7) : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Status indicator
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
            } else if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(isHighlighted ? .white : .green)
                    .font(.system(size: 14))
            } else if isConnected {
                Circle()
                    .fill(isHighlighted ? Color.white : .green)
                    .frame(width: 6, height: 6)
            }

            // Database type badge
            Text(connection.type.rawValue.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(isHighlighted ? .white.opacity(0.7) : .secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            isHighlighted
                                ? Color.white.opacity(0.15)
                                : Color.secondary.opacity(0.12)
                        )
                )
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Layout

    /// Calculates popover height based on content to avoid excess whitespace
    private func listHeight(sessions: Int, saved: Int) -> CGFloat {
        let rowHeight: CGFloat = 44
        let sectionHeaderHeight: CGFloat = 28
        let buttonHeight: CGFloat = 44 // Manage Connections + divider
        var height: CGFloat = buttonHeight

        if sessions > 0 {
            height += sectionHeaderHeight + CGFloat(sessions) * rowHeight
        }
        if saved > 0 {
            height += sectionHeaderHeight + CGFloat(saved) * rowHeight
        }

        // Cap at reasonable max so it scrolls with many connections
        return min(height, 400)
    }

    // MARK: - Helpers

    private func connectionSubtitle(_ connection: DatabaseConnection) -> String {
        if connection.type == .sqlite {
            return connection.database
        }
        let port = connection.port != connection.type.defaultPort ? ":\(connection.port)" : ""
        return "\(connection.host)\(port)/\(connection.database)"
    }

    private func switchToSession(_ sessionId: UUID) {
        onDismiss?()
        DatabaseManager.shared.switchToSession(sessionId)
    }

    private func connectToSaved(_ connection: DatabaseConnection) {
        isConnecting = connection.id
        onDismiss?()
        Task {
            try? await DatabaseManager.shared.connectToSession(connection)
            await MainActor.run {
                isConnecting = nil
            }
        }
    }
}

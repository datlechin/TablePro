//
//  ConnectionToolbarState.swift
//  TablePro
//
//  Observable state container for toolbar connection information.
//  Centralizes all toolbar-related state in a single, composable object.
//

import Combine
import SwiftUI

// MARK: - Connection Environment

/// Represents the connection environment type for visual badges
enum ConnectionEnvironment: String, CaseIterable {
    case local = "LOCAL"
    case ssh = "SSH"
    case production = "PROD"
    case staging = "STAGING"

    /// SF Symbol for this environment type
    var iconName: String {
        switch self {
        case .local: return "house.fill"
        case .ssh: return "lock.fill"
        case .production: return "exclamationmark.triangle.fill"
        case .staging: return "flask.fill"
        }
    }

    /// Badge background color
    var backgroundColor: Color {
        switch self {
        case .local: return Color.gray.opacity(0.3)
        case .ssh: return Color.orange.opacity(0.3)
        case .production: return Color.red.opacity(0.3)
        case .staging: return Color.blue.opacity(0.3)
        }
    }

    /// Badge foreground color
    var foregroundColor: Color {
        switch self {
        case .local: return .secondary
        case .ssh: return .orange
        case .production: return .red
        case .staging: return .blue
        }
    }
}

// MARK: - Connection State

/// Represents the current state of the database connection
enum ToolbarConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case executing
    case error(String)

    /// Status indicator color
    var indicatorColor: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .executing: return .blue
        case .error: return .red
        }
    }

    /// Human-readable description
    var description: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .executing: return "Executing..."
        case .error(let message): return "Error: \(message)"
        }
    }

    /// Whether to show activity indicator
    var isAnimating: Bool {
        switch self {
        case .connecting, .executing: return true
        default: return false
        }
    }
}

// MARK: - Toolbar State

/// Observable state container for the connection toolbar.
/// Uses ObservableObject for macOS 13+ compatibility.
/// This is the single source of truth for all toolbar UI state.
final class ConnectionToolbarState: ObservableObject {
    // MARK: - Connection Info

    /// The tag assigned to this connection (optional)
    @Published var tagId: UUID?

    /// Database type (MySQL, MariaDB, PostgreSQL, SQLite)
    @Published var databaseType: DatabaseType = .mysql

    /// Server version string (e.g., "11.1.2")
    @Published var databaseVersion: String?

    /// Connection name for display
    @Published var connectionName: String = ""

    /// Current database name
    @Published var databaseName: String = ""

    /// Custom display color for the connection (uses database type color if not set)
    @Published var displayColor: Color = .orange

    /// Current connection state
    @Published var connectionState: ToolbarConnectionState = .disconnected

    // MARK: - Query Execution

    /// Whether a query is currently executing
    @Published var isExecuting: Bool = false {
        didSet {
            // Automatically update connection state when execution state changes
            if isExecuting && connectionState == .connected {
                connectionState = .executing
            } else if !isExecuting && connectionState == .executing {
                connectionState = .connected
            }
        }
    }

    /// Duration of the last completed query
    @Published var lastQueryDuration: TimeInterval?

    // MARK: - Future Expansion

    /// Whether the connection is read-only
    @Published var isReadOnly: Bool = false

    /// Network latency in milliseconds (for SSH connections)
    @Published var latencyMs: Int?

    /// Replication lag in seconds (for replicated databases)
    @Published var replicationLagSeconds: Int?

    // MARK: - Computed Properties

    /// Formatted database version with type
    var formattedDatabaseInfo: String {
        if let version = databaseVersion, !version.isEmpty {
            return "\(databaseType.rawValue) \(version)"
        }
        return databaseType.rawValue
    }

    /// Tooltip text for the status indicator
    var statusTooltip: String {
        var parts: [String] = [connectionState.description]

        if let latency = latencyMs {
            parts.append("Latency: \(latency)ms")
        }

        if let lag = replicationLagSeconds {
            parts.append("Replication lag: \(lag)s")
        }

        if isReadOnly {
            parts.append("Read-only")
        }

        return parts.joined(separator: " • ")
    }

    // MARK: - Initialization

    init() {}

    /// Initialize with a database connection
    init(connection: DatabaseConnection) {
        update(from: connection)
    }

    // MARK: - Update Methods

    /// Update state from a DatabaseConnection model
    func update(from connection: DatabaseConnection) {
        connectionName = connection.name
        databaseName = connection.database
        databaseType = connection.type
        displayColor = connection.displayColor
        tagId = connection.tagId
    }

    /// Update connection state from ConnectionStatus
    func updateConnectionState(from status: ConnectionStatus) {
        switch status {
        case .disconnected:
            connectionState = .disconnected
        case .connecting:
            connectionState = .connecting
        case .connected:
            connectionState = isExecuting ? .executing : .connected
        case .error(let message):
            connectionState = .error(message)
        }
    }

    /// Reset to default disconnected state
    func reset() {
        tagId = nil
        databaseType = .mysql
        databaseVersion = nil
        connectionName = ""
        databaseName = ""
        displayColor = databaseType.themeColor
        connectionState = .disconnected
        isExecuting = false
        lastQueryDuration = nil
        isReadOnly = false
        latencyMs = nil
        replicationLagSeconds = nil
    }
}

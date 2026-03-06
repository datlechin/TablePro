//
//  SSHTunnelManager.swift
//  TablePro
//
//  Manages SSH tunnel lifecycle for database connections
//

import Foundation
import os

extension Notification.Name {
    static let sshTunnelDied = Notification.Name("sshTunnelDied")
}

/// Error types for SSH tunnel operations
enum SSHTunnelError: Error, LocalizedError {
    case tunnelCreationFailed(String)
    case tunnelAlreadyExists(UUID)
    case noAvailablePort
    case sshCommandNotFound
    case authenticationFailed
    case connectionTimeout

    var errorDescription: String? {
        switch self {
        case .tunnelCreationFailed(let message):
            return String(localized: "SSH tunnel creation failed: \(message)")
        case .tunnelAlreadyExists(let id):
            return String(localized: "SSH tunnel already exists for connection: \(id.uuidString)")
        case .noAvailablePort:
            return String(localized: "No available local port for SSH tunnel")
        case .sshCommandNotFound:
            return String(localized: "SSH command not found. Please ensure OpenSSH is installed.")
        case .authenticationFailed:
            return String(localized: "SSH authentication failed. Check your credentials or private key.")
        case .connectionTimeout:
            return String(localized: "SSH connection timed out")
        }
    }
}

/// Represents an active SSH tunnel
struct SSHTunnel {
    let connectionId: UUID
    let localPort: Int
    let remoteHost: String
    let remotePort: Int
    let process: Process
    let createdAt: Date
}

/// Manages SSH tunnels for database connections using system ssh command
actor SSHTunnelManager {
    static let shared = SSHTunnelManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHTunnelManager")

    private var tunnels: [UUID: SSHTunnel] = [:]
    private let portRangeStart = 60_000
    private let portRangeEnd = 65_000
    private var healthCheckTask: Task<Void, Never>?

    private init() {
        Task { [weak self] in
            await self?.startHealthCheck()
        }
    }

    private func startHealthCheck() {
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await self?.checkTunnelHealth()
            }
        }
    }

    /// Check if tunnels are still alive and attempt reconnection if needed
    private func checkTunnelHealth() async {
        for (connectionId, tunnel) in tunnels {
            // Check if process is still running
            if !tunnel.process.isRunning {
                Self.logger.warning("SSH tunnel for \(connectionId) died, attempting reconnection...")

                // Notify DatabaseManager to reconnect
                await notifyTunnelDied(connectionId: connectionId)
            }
        }
    }

    /// Notify that a tunnel has died (DatabaseManager should handle reconnection)
    private func notifyTunnelDied(connectionId: UUID) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .sshTunnelDied,
                object: nil,
                userInfo: ["connectionId": connectionId]
            )
        }
    }

    /// Create an SSH tunnel for a database connection
    /// - Parameters:
    ///   - connectionId: The database connection ID
    ///   - sshHost: SSH server hostname
    ///   - sshPort: SSH server port (default 22)
    ///   - sshUsername: SSH username
    ///   - authMethod: Authentication method
    ///   - privateKeyPath: Path to private key file (for key auth)
    ///   - keyPassphrase: Passphrase for encrypted private key (optional)
    ///   - sshPassword: SSH password (for password auth) - Note: password auth requires sshpass
    ///   - remoteHost: Database host (as seen from SSH server)
    ///   - remotePort: Database port
    /// - Returns: Local port number for the tunnel
    func createTunnel(
        connectionId: UUID,
        sshHost: String,
        sshPort: Int = 22,
        sshUsername: String,
        authMethod: SSHAuthMethod,
        privateKeyPath: String? = nil,
        keyPassphrase: String? = nil,
        sshPassword: String? = nil,
        remoteHost: String,
        remotePort: Int
    ) async throws -> Int {
        // Check if tunnel already exists
        if tunnels[connectionId] != nil {
            try await closeTunnel(connectionId: connectionId)
        }

        // Find available local port
        let localPort = try await findAvailablePort()

        // Build SSH command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var arguments = [
            "-N",  // Don't execute remote command
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ServerAliveInterval=60",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-L", "\(localPort):\(remoteHost):\(remotePort)",
            "-p", String(sshPort),
        ]

        // Add authentication
        switch authMethod {
        case .privateKey:
            guard let keyPath = privateKeyPath, !keyPath.isEmpty else {
                throw SSHTunnelError.tunnelCreationFailed("Private key path is required for key authentication")
            }

            let expandedPath = expandPath(keyPath)

            // Validate private key exists and is readable
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: expandedPath) else {
                throw SSHTunnelError.tunnelCreationFailed("Private key file not found at: \(expandedPath)")
            }
            guard fileManager.isReadableFile(atPath: expandedPath) else {
                throw SSHTunnelError.tunnelCreationFailed("Private key file is not readable. Check permissions (should be 600): \(expandedPath)")
            }

            // Force public key authentication
            arguments.append(contentsOf: ["-i", expandedPath])
            arguments.append(contentsOf: ["-o", "PubkeyAuthentication=yes"])
            arguments.append(contentsOf: ["-o", "PasswordAuthentication=no"])
            arguments.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])

        case .password:
            // For password auth, we'll use SSH_ASKPASS with a helper script
            // Note: This requires ssh to be run without a TTY (which -N provides)
            arguments.append(contentsOf: ["-o", "PasswordAuthentication=yes"])
            arguments.append(contentsOf: ["-o", "PreferredAuthentications=password"])
            arguments.append(contentsOf: ["-o", "PubkeyAuthentication=no"])
        }

        arguments.append("\(sshUsername)@\(sshHost)")

        process.arguments = arguments

        // Set up SSH_ASKPASS for passphrase or password
        var askpassScriptPath: String?

        if authMethod == .privateKey, let passphrase = keyPassphrase {
            askpassScriptPath = try createAskpassScript(password: passphrase)
        } else if authMethod == .password, let password = sshPassword {
            askpassScriptPath = try createAskpassScript(password: password)
        }

        if let scriptPath = askpassScriptPath {
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = scriptPath
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = ":0"  // Required for SSH_ASKPASS to work
            process.environment = environment
        }

        // Capture stderr for error messages
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        // Start the process
        do {
            try process.run()
        } catch {
            removeAskpassScript(askpassScriptPath)
            throw SSHTunnelError.tunnelCreationFailed(error.localizedDescription)
        }

        // Wait for tunnel to become ready by probing the local port
        let tunnelReady = await waitForTunnelReady(
            localPort: localPort,
            process: process,
            timeoutSeconds: 15
        )

        removeAskpassScript(askpassScriptPath)

        if !tunnelReady {
            // Process died or timed out — read stderr for diagnostics
            if !process.isRunning {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"

                throw classifySSHError(
                    errorMessage: errorMessage,
                    authMethod: authMethod
                )
            }

            // Process still running but port never became reachable
            process.terminate()
            throw SSHTunnelError.connectionTimeout
        }

        // Store the tunnel
        let tunnel = SSHTunnel(
            connectionId: connectionId,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            process: process,
            createdAt: Date()
        )
        tunnels[connectionId] = tunnel

        return localPort
    }

    /// Close an SSH tunnel
    func closeTunnel(connectionId: UUID) async throws {
        guard let tunnel = tunnels[connectionId] else { return }

        if tunnel.process.isRunning {
            tunnel.process.terminate()
            await waitForProcessExit(tunnel.process)
        }

        tunnels.removeValue(forKey: connectionId)
    }

    /// Close all SSH tunnels
    func closeAllTunnels() async {
        for (_, tunnel) in tunnels {
            if tunnel.process.isRunning {
                tunnel.process.terminate()
            }
        }
        tunnels.removeAll()
    }

    /// Check if a tunnel exists for a connection
    func hasTunnel(connectionId: UUID) -> Bool {
        guard let tunnel = tunnels[connectionId] else { return false }
        return tunnel.process.isRunning
    }

    /// Get the local port for an existing tunnel
    func getLocalPort(connectionId: UUID) -> Int? {
        guard let tunnel = tunnels[connectionId], tunnel.process.isRunning else {
            return nil
        }
        return tunnel.localPort
    }

    // MARK: - Private Helpers

    private func findAvailablePort() async throws -> Int {
        for port in portRangeStart...portRangeEnd {
            if isPortAvailable(port) {
                return port
            }
        }
        throw SSHTunnelError.noAvailablePort
    }

    private func isPortAvailable(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path(percentEncoded: false)
        }
        return path
    }

    private func createAskpassScript(password: String) throws -> String {
        let scriptPath = NSTemporaryDirectory() + "ssh_askpass_\(UUID().uuidString)"
        let scriptContent = "#!/bin/bash\necho '\(password.replacingOccurrences(of: "'", with: "'\\''"))'\n"

        guard let data = scriptContent.data(using: .utf8) else {
            throw SSHTunnelError.tunnelCreationFailed("Failed to encode askpass script")
        }

        let created = FileManager.default.createFile(
            atPath: scriptPath,
            contents: data,
            attributes: [.posixPermissions: 0o700]
        )

        guard created else {
            throw SSHTunnelError.tunnelCreationFailed("Failed to create askpass script")
        }

        return scriptPath
    }

    /// Wait for a Process to exit without blocking the current thread
    private func waitForProcessExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }

    /// Probe the local port to detect when the SSH tunnel is ready to accept connections.
    /// Returns `true` when the port is reachable, `false` on timeout or process death.
    private func waitForTunnelReady(
        localPort: Int,
        process: Process,
        timeoutSeconds: Int
    ) async -> Bool {
        let pollInterval: UInt64 = 250_000_000 // 250ms
        let maxAttempts = timeoutSeconds * 4    // 4 polls per second

        for _ in 0..<maxAttempts {
            // If the SSH process died, bail out immediately
            guard process.isRunning else { return false }

            // Try to connect to the local forwarded port
            if isPortReachable(localPort) {
                return true
            }

            try? await Task.sleep(nanoseconds: pollInterval)
        }

        return false
    }

    /// Check whether a TCP connection to localhost:port succeeds
    private func isPortReachable(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

    /// Classify an SSH stderr message into a specific error type
    private func classifySSHError(
        errorMessage: String,
        authMethod: SSHAuthMethod
    ) -> SSHTunnelError {
        if errorMessage.contains("Permission denied") {
            if authMethod == .privateKey {
                return .tunnelCreationFailed(
                    "Private key authentication failed. Possible causes:\n" +
                        "• Private key doesn't match the public key on server\n" +
                        "• Wrong passphrase for encrypted private key\n" +
                        "• Wrong user or server\n" +
                        "Debug: \(errorMessage)"
                )
            } else {
                return .authenticationFailed
            }
        }

        if errorMessage.contains("authentication") {
            return .authenticationFailed
        }

        if errorMessage.contains("Connection timed out") || errorMessage.contains("Connection refused") {
            return .tunnelCreationFailed(
                "Cannot connect to SSH server. Check:\n" +
                    "• Server address and port are correct\n" +
                    "• Server is reachable (firewall, network)\n" +
                    "Debug: \(errorMessage)"
            )
        }

        return .tunnelCreationFailed(errorMessage)
    }

    private func removeAskpassScript(_ path: String?) {
        guard let path else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            Self.logger.warning("Failed to remove askpass script at \(path): \(error.localizedDescription)")
        }
    }
}

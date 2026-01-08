//
//  SSHTunnelManager.swift
//  TablePro
//
//  Manages SSH tunnel lifecycle for database connections
//

import Foundation

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
            return "SSH tunnel creation failed: \(message)"
        case .tunnelAlreadyExists(let id):
            return "SSH tunnel already exists for connection: \(id)"
        case .noAvailablePort:
            return "No available local port for SSH tunnel"
        case .sshCommandNotFound:
            return "SSH command not found. Please ensure OpenSSH is installed."
        case .authenticationFailed:
            return "SSH authentication failed. Check your credentials or private key."
        case .connectionTimeout:
            return "SSH connection timed out"
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

    private var tunnels: [UUID: SSHTunnel] = [:]
    private let portRangeStart = 60_000
    private let portRangeEnd = 65_000

    private init() {}

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
        var askpassScript: String?

        if authMethod == .privateKey, let passphrase = keyPassphrase {
            // Private key with passphrase - use SSH_ASKPASS to provide it
            askpassScript = try await createAskpassScript(password: passphrase)
        } else if authMethod == .password, let password = sshPassword {
            // Password authentication
            askpassScript = try await createAskpassScript(password: password)
        }

        if let script = askpassScript {
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = script
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
            throw SSHTunnelError.tunnelCreationFailed(error.localizedDescription)
        }

        // Wait a bit for connection to establish
        try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 seconds

        // Check if process is still running
        if !process.isRunning {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"

            // Provide more specific error messages
            if errorMessage.contains("Permission denied") {
                if authMethod == .privateKey {
                    throw SSHTunnelError.tunnelCreationFailed(
                        "Private key authentication failed. Possible causes:\n" +
                            "• Private key doesn't match the public key on server\n" +
                            "• Wrong passphrase for encrypted private key\n" +
                            "• Wrong user or server\n" +
                            "Debug: \(errorMessage)"
                    )
                } else {
                    throw SSHTunnelError.authenticationFailed
                }
            }

            if errorMessage.contains("authentication") {
                throw SSHTunnelError.authenticationFailed
            }

            if errorMessage.contains("Connection timed out") || errorMessage.contains("Connection refused") {
                throw SSHTunnelError.tunnelCreationFailed(
                    "Cannot connect to SSH server. Check:\n" +
                        "• Server address and port are correct\n" +
                        "• Server is reachable (firewall, network)\n" +
                        "Debug: \(errorMessage)"
                )
            }

            throw SSHTunnelError.tunnelCreationFailed(errorMessage)
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

        // Clean up askpass script if created (for password or passphrase)
        if authMethod == .password || keyPassphrase != nil {
            cleanupAskpassScript()
        }

        return localPort
    }

    /// Close an SSH tunnel
    func closeTunnel(connectionId: UUID) async throws {
        guard let tunnel = tunnels[connectionId] else { return }

        if tunnel.process.isRunning {
            tunnel.process.terminate()
            tunnel.process.waitUntilExit()
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
            return NSHomeDirectory() + path.dropFirst()
        }
        return path
    }

    /// Create a temporary script for SSH_ASKPASS
    private func createAskpassScript(password: String) async throws -> String {
        let scriptPath = NSTemporaryDirectory() + "ssh_askpass_\(UUID().uuidString)"
        let scriptContent = """
            #!/bin/bash
            echo '\(password.replacingOccurrences(of: "'", with: "'\\''"))'
            """

        try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        // Make it executable
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", scriptPath]
        try chmod.run()
        chmod.waitUntilExit()

        return scriptPath
    }

    private func cleanupAskpassScript() {
        // Clean up any temporary askpass scripts
        let tempDir = NSTemporaryDirectory()
        if let enumerator = FileManager.default.enumerator(atPath: tempDir) {
            while let file = enumerator.nextObject() as? String {
                if file.hasPrefix("ssh_askpass_") {
                    try? FileManager.default.removeItem(atPath: tempDir + file)
                }
            }
        }
    }
}

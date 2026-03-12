//
//  SSHTunnelManager.swift
//  TablePro
//
//  Manages SSH tunnel lifecycle for database connections
//

import Foundation
import os

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

private struct SSHTunnelLaunch {
    let process: Process
    let errorPipe: Pipe
    let askpassScriptPath: String?
}

/// Manages SSH tunnels for database connections using system ssh command
actor SSHTunnelManager {
    static let shared = SSHTunnelManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHTunnelManager")

    private var tunnels: [UUID: SSHTunnel] = [:]
    private let portRangeStart = 60_000
    private let portRangeEnd = 65_000
    private var healthCheckTask: Task<Void, Never>?
    private static let processRegistry = OSAllocatedUnfairLock(initialState: [UUID: Process]())

    private init() {
        Task { [weak self] in
            await self?.startHealthCheck()
        }
    }

    private func startHealthCheck() {
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled else { break }
                await self?.checkTunnelHealth()
            }
        }
    }

    private func checkTunnelHealth() async {
        for (connectionId, tunnel) in tunnels {
            if !tunnel.process.isRunning {
                Self.logger.warning("SSH tunnel for \(connectionId) died (detected by fallback health check)")
                await handleTunnelDeath(connectionId: connectionId)
            }
        }
    }

    private func handleTunnelDeath(connectionId: UUID) async {
        guard tunnels.removeValue(forKey: connectionId) != nil else { return }
        Self.processRegistry.withLock { $0[connectionId] = nil }
        await DatabaseManager.shared.handleSSHTunnelDied(connectionId: connectionId)
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
        agentSocketPath: String? = nil,
        remoteHost: String,
        remotePort: Int,
        jumpHosts: [SSHJumpHost] = []
    ) async throws -> Int {
        // Check if tunnel already exists
        if tunnels[connectionId] != nil {
            try await closeTunnel(connectionId: connectionId)
        }

        for localPort in localPortCandidates() {
            let launch: SSHTunnelLaunch

            do {
                launch = try createTunnelLaunch(
                    localPort: localPort,
                    sshHost: sshHost,
                    sshPort: sshPort,
                    sshUsername: sshUsername,
                    authMethod: authMethod,
                    privateKeyPath: privateKeyPath,
                    keyPassphrase: keyPassphrase,
                    sshPassword: sshPassword,
                    agentSocketPath: agentSocketPath,
                    remoteHost: remoteHost,
                    remotePort: remotePort,
                    jumpHosts: jumpHosts
                )
            } catch let error as SSHTunnelError {
                throw error
            } catch {
                throw SSHTunnelError.tunnelCreationFailed(error.localizedDescription)
            }

            do {
                try launch.process.run()
            } catch {
                removeAskpassScript(launch.askpassScriptPath)
                throw SSHTunnelError.tunnelCreationFailed(error.localizedDescription)
            }

            let tunnelReady = await waitForTunnelReady(
                localPort: localPort,
                process: launch.process,
                timeoutSeconds: 15
            )

            removeAskpassScript(launch.askpassScriptPath)

            if !tunnelReady {
                if !launch.process.isRunning {
                    let errorData = launch.errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"

                    if Self.isLocalPortBindFailure(errorMessage) {
                        Self.logger.notice("SSH tunnel bind race on local port \(localPort), retrying with another port")
                        continue
                    }

                    throw classifySSHError(
                        errorMessage: errorMessage,
                        authMethod: authMethod
                    )
                }

                launch.process.terminate()
                throw SSHTunnelError.connectionTimeout
            }

            let tunnel = SSHTunnel(
                connectionId: connectionId,
                localPort: localPort,
                remoteHost: remoteHost,
                remotePort: remotePort,
                process: launch.process,
                createdAt: Date()
            )
            tunnels[connectionId] = tunnel
            Self.processRegistry.withLock { $0[connectionId] = launch.process }

            launch.process.terminationHandler = { [weak self] _ in
                Task { [weak self] in
                    await self?.handleTunnelDeath(connectionId: connectionId)
                }
            }

            return localPort
        }

        throw SSHTunnelError.noAvailablePort
    }

    /// Close an SSH tunnel
    func closeTunnel(connectionId: UUID) async throws {
        guard let tunnel = tunnels[connectionId] else { return }

        if tunnel.process.isRunning {
            tunnel.process.terminate()
            await waitForProcessExit(tunnel.process)
        }

        tunnels.removeValue(forKey: connectionId)
        Self.processRegistry.withLock { $0[connectionId] = nil }
    }

    /// Close all SSH tunnels
    func closeAllTunnels() async {
        let currentTunnels = tunnels
        tunnels.removeAll()
        Self.processRegistry.withLock { $0.removeAll(); return }

        await withTaskGroup(of: Void.self) { group in
            for (_, tunnel) in currentTunnels where tunnel.process.isRunning {
                group.addTask {
                    tunnel.process.terminate()
                    await self.waitForProcessExit(tunnel.process, timeout: .seconds(3))
                }
            }
        }
    }

    /// Synchronously terminate all SSH tunnel processes.
    /// Called from `applicationWillTerminate` where async is not available.
    nonisolated func terminateAllProcessesSync() {
        let processes = Self.processRegistry.withLock { dict -> [Process] in
            let procs = Array(dict.values)
            dict.removeAll()
            return procs
        }
        for process in processes where process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1.0)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
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

    private func localPortCandidates() -> [Int] {
        Array(portRangeStart...portRangeEnd).shuffled()
    }

    // swiftlint:disable:next function_parameter_count
    private func createTunnelLaunch(
        localPort: Int,
        sshHost: String,
        sshPort: Int,
        sshUsername: String,
        authMethod: SSHAuthMethod,
        privateKeyPath: String?,
        keyPassphrase: String?,
        sshPassword: String?,
        agentSocketPath: String?,
        remoteHost: String,
        remotePort: Int,
        jumpHosts: [SSHJumpHost]
    ) throws -> SSHTunnelLaunch {
        let process = Process()
        let errorPipe = Pipe()
        var askpassScriptPath: String?

        do {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

            var arguments = [
                "-N",  // Don't execute remote command
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ServerAliveInterval=60",
                "-o", "ServerAliveCountMax=3",
                "-o", "ConnectTimeout=10",
                "-o", "ExitOnForwardFailure=yes",
                "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
                "-p", String(sshPort),
            ]

            switch authMethod {
            case .privateKey:
                guard let keyPath = privateKeyPath, !keyPath.isEmpty else {
                    throw SSHTunnelError.tunnelCreationFailed("Private key path is required for key authentication")
                }

                let expandedPath = expandPath(keyPath)
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: expandedPath) else {
                    throw SSHTunnelError.tunnelCreationFailed("Private key file not found at: \(expandedPath)")
                }
                guard fileManager.isReadableFile(atPath: expandedPath) else {
                    throw SSHTunnelError.tunnelCreationFailed("Private key file is not readable. Check permissions (should be 600): \(expandedPath)")
                }

                arguments.append(contentsOf: ["-i", expandedPath])
                arguments.append(contentsOf: ["-o", "PubkeyAuthentication=yes"])
                arguments.append(contentsOf: ["-o", "PasswordAuthentication=no"])
                arguments.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])

            case .password:
                arguments.append(contentsOf: ["-o", "PasswordAuthentication=yes"])
                arguments.append(contentsOf: ["-o", "PreferredAuthentications=password"])
                arguments.append(contentsOf: ["-o", "PubkeyAuthentication=no"])

            case .sshAgent:
                arguments.append(contentsOf: ["-o", "PubkeyAuthentication=yes"])
                arguments.append(contentsOf: ["-o", "PasswordAuthentication=no"])
                arguments.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
            }

            for jumpHost in jumpHosts where jumpHost.authMethod == .privateKey && !jumpHost.privateKeyPath.isEmpty {
                arguments.append(contentsOf: ["-i", expandPath(jumpHost.privateKeyPath)])
            }

            if !jumpHosts.isEmpty {
                let jumpString = jumpHosts.map(\.proxyJumpString).joined(separator: ",")
                arguments.append(contentsOf: ["-J", jumpString])
            }

            arguments.append("\(sshUsername)@\(sshHost)")
            process.arguments = arguments

            if authMethod == .privateKey, let passphrase = keyPassphrase {
                askpassScriptPath = try createAskpassScript(password: passphrase)
            } else if authMethod == .password, let password = sshPassword {
                askpassScriptPath = try createAskpassScript(password: password)
            }

            if let scriptPath = askpassScriptPath {
                var environment = ProcessInfo.processInfo.environment
                environment["SSH_ASKPASS"] = scriptPath
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["DISPLAY"] = ":0"
                process.environment = environment
            }

            if authMethod == .sshAgent, let socketPath = agentSocketPath, !socketPath.isEmpty {
                var environment = process.environment ?? ProcessInfo.processInfo.environment
                environment["SSH_AUTH_SOCK"] = expandPath(socketPath)
                process.environment = environment
            }

            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice

            return SSHTunnelLaunch(
                process: process,
                errorPipe: errorPipe,
                askpassScriptPath: askpassScriptPath
            )
        } catch {
            removeAskpassScript(askpassScriptPath)
            throw error
        }
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

    private func waitForProcessExit(_ process: Process, timeout: Duration = .seconds(5)) async {
        guard process.isRunning else { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    process.terminationHandler = { _ in
                        continuation.resume()
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
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

            if isPortReachable(localPort),
               isPortOwnedByProcessTree(localPort, rootProcessId: process.processIdentifier) {
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

    private func isPortOwnedByProcessTree(_ port: Int, rootProcessId: Int32) -> Bool {
        let listeningProcessIds = listeningProcessIds(for: port)
        guard !listeningProcessIds.isEmpty else { return false }

        let processTreeIds = processTreeIds(rootProcessId: rootProcessId)
        return !listeningProcessIds.isDisjoint(with: processTreeIds)
    }

    private func listeningProcessIds(for port: Int) -> Set<Int32> {
        let output = runCommand(
            executablePath: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        )

        return Set(
            output
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0) }
        )
    }

    private func processTreeIds(rootProcessId: Int32) -> Set<Int32> {
        let parentProcessIds = currentParentProcessIds()
        return Self.descendantProcessIds(
            rootProcessId: rootProcessId,
            parentProcessIds: parentProcessIds
        )
    }

    private func currentParentProcessIds() -> [Int32: Int32] {
        let output = runCommand(
            executablePath: "/bin/ps",
            arguments: ["-axo", "pid=,ppid="]
        )

        var parentProcessIds: [Int32: Int32] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2,
                  let pid = Int32(parts[0]),
                  let parentPid = Int32(parts[1]) else {
                continue
            }
            parentProcessIds[pid] = parentPid
        }
        return parentProcessIds
    }

    private func runCommand(executablePath: String, arguments: [String]) -> String {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    internal static func descendantProcessIds(
        rootProcessId: Int32,
        parentProcessIds: [Int32: Int32]
    ) -> Set<Int32> {
        var discovered: Set<Int32> = [rootProcessId]
        var queue: [Int32] = [rootProcessId]

        while let currentProcessId = queue.first {
            queue.removeFirst()

            for (processId, parentProcessId) in parentProcessIds
                where parentProcessId == currentProcessId && !discovered.contains(processId) {
                discovered.insert(processId)
                queue.append(processId)
            }
        }

        return discovered
    }

    static func isLocalPortBindFailure(_ errorMessage: String) -> Bool {
        let normalized = errorMessage.lowercased()
        return normalized.contains("address already in use")
            || normalized.contains("cannot listen to port")
            || normalized.contains("could not request local forwarding")
            || normalized.contains("port forwarding failed")
    }

    /// Classify an SSH stderr message into a specific error type
    private func classifySSHError(
        errorMessage: String,
        authMethod: SSHAuthMethod
    ) -> SSHTunnelError {
        if errorMessage.contains("Permission denied") {
            if authMethod == .sshAgent {
                return .tunnelCreationFailed(
                    "SSH agent authentication failed. Possible causes:\n" +
                        "• No keys loaded in SSH agent (run ssh-add -l to check)\n" +
                        "• Agent key doesn't match the public key on server\n" +
                        "• Wrong user or server\n" +
                        "Debug: \(errorMessage)"
                )
            } else if authMethod == .privateKey {
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

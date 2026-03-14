//
//  LibSSH2Tunnel.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

/// Represents an active SSH tunnel backed by libssh2.
/// Each instance owns a TCP socket, libssh2 session, a local listening socket,
/// and the forwarding/keep-alive tasks.
internal final class LibSSH2Tunnel: @unchecked Sendable {
    let connectionId: UUID
    let localPort: Int
    let createdAt: Date

    private static let logger = Logger(subsystem: "com.TablePro", category: "LibSSH2Tunnel")

    private let session: OpaquePointer           // LIBSSH2_SESSION*
    private let socketFD: Int32                   // TCP socket to SSH server
    private let listenFD: Int32                   // Local listening socket

    // Jump host chain (in connection order)
    private let jumpChain: [JumpHop]

    private var forwardingTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private let isAlive = OSAllocatedUnfairLock(initialState: true)

    /// Callback invoked when the tunnel dies (keep-alive failure, etc.)
    var onDeath: ((UUID) -> Void)?

    struct JumpHop {
        let session: OpaquePointer    // LIBSSH2_SESSION*
        let socket: Int32             // TCP or socketpair fd
        let channel: OpaquePointer    // LIBSSH2_CHANNEL* (direct-tcpip to next hop)
        let relayTask: Task<Void, Never>?  // socketpair relay task (nil for first hop)
    }

    private static let relayBufferSize = 32_768 // 32KB

    init(connectionId: UUID, localPort: Int, session: OpaquePointer,
         socketFD: Int32, listenFD: Int32, jumpChain: [JumpHop] = []) {
        self.connectionId = connectionId
        self.localPort = localPort
        self.session = session
        self.socketFD = socketFD
        self.listenFD = listenFD
        self.jumpChain = jumpChain
        self.createdAt = Date()
    }

    var isRunning: Bool {
        isAlive.withLock { $0 }
    }

    // MARK: - Forwarding

    func startForwarding(remoteHost: String, remotePort: Int) {
        libssh2_session_set_blocking(session, 0)

        forwardingTask = Task.detached { [weak self] in
            guard let self else { return }
            Self.logger.info("Forwarding started on port \(self.localPort) -> \(remoteHost):\(remotePort)")

            while !Task.isCancelled && self.isRunning {
                let clientFD = self.acceptClient()
                guard clientFD >= 0 else {
                    if !Task.isCancelled && self.isRunning {
                        // accept timed out or was interrupted, retry
                        continue
                    }
                    break
                }

                let channel = self.openDirectTcpipChannel(
                    remoteHost: remoteHost,
                    remotePort: remotePort
                )

                guard let channel else {
                    Self.logger.error("Failed to open direct-tcpip channel")
                    Darwin.close(clientFD)
                    continue
                }

                Self.logger.debug("Client connected, relaying to \(remoteHost):\(remotePort)")
                self.spawnRelay(clientFD: clientFD, channel: channel)
            }

            Self.logger.info("Forwarding loop ended for port \(self.localPort)")
        }
    }

    // MARK: - Keep-Alive

    func startKeepAlive() {
        libssh2_keepalive_config(session, 1, 30)

        keepAliveTask = Task.detached { [weak self] in
            guard let self else { return }

            while !Task.isCancelled && self.isRunning {
                var secondsToNext: Int32 = 0
                let rc = libssh2_keepalive_send(self.session, &secondsToNext)

                if rc != 0 {
                    Self.logger.warning("Keep-alive failed with error \(rc), marking tunnel dead")
                    self.markDead()
                    break
                }

                let sleepInterval = max(Int(secondsToNext), 10)
                try? await Task.sleep(for: .seconds(sleepInterval))
            }
        }
    }

    // MARK: - Lifecycle

    func close() {
        let wasAlive = isAlive.withLock { alive -> Bool in
            let was = alive
            alive = false
            return was
        }
        guard wasAlive else { return }

        forwardingTask?.cancel()
        keepAliveTask?.cancel()

        Darwin.close(listenFD)

        libssh2_session_set_blocking(session, 1)
        tablepro_libssh2_session_disconnect(session, "Closing tunnel")
        libssh2_session_free(session)
        Darwin.close(socketFD)

        for hop in jumpChain.reversed() {
            hop.relayTask?.cancel()
            libssh2_channel_free(hop.channel)
            tablepro_libssh2_session_disconnect(hop.session, "Closing")
            libssh2_session_free(hop.session)
            Darwin.close(hop.socket)
        }

        Self.logger.info("Tunnel closed for connection \(self.connectionId)")
    }

    /// Synchronous cleanup for app termination. No Task needed.
    func closeSync() {
        let wasAlive = isAlive.withLock { alive -> Bool in
            let was = alive
            alive = false
            return was
        }
        guard wasAlive else { return }

        forwardingTask?.cancel()
        keepAliveTask?.cancel()

        Darwin.close(listenFD)

        libssh2_session_set_blocking(session, 1)
        tablepro_libssh2_session_disconnect(session, "Closing tunnel")
        libssh2_session_free(session)
        Darwin.close(socketFD)

        for hop in jumpChain.reversed() {
            hop.relayTask?.cancel()
            libssh2_channel_free(hop.channel)
            tablepro_libssh2_session_disconnect(hop.session, "Closing")
            libssh2_session_free(hop.session)
            Darwin.close(hop.socket)
        }
    }

    // MARK: - Private

    private func markDead() {
        let wasAlive = isAlive.withLock { alive -> Bool in
            let was = alive
            alive = false
            return was
        }
        if wasAlive {
            onDeath?(connectionId)
        }
    }

    /// Accept a client connection on the listening socket with a 1-second poll timeout.
    private func acceptClient() -> Int32 {
        var pollFD = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFD, 1, 1_000) // 1 second timeout

        guard pollResult > 0, pollFD.revents & Int16(POLLIN) != 0 else {
            return -1
        }

        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenFD, $0, &addrLen)
            }
        }

        return clientFD
    }

    /// Open a direct-tcpip channel, handling EAGAIN with select().
    private func openDirectTcpipChannel(remoteHost: String, remotePort: Int) -> OpaquePointer? {
        while true {
            let channel = libssh2_channel_direct_tcpip_ex(
                session,
                remoteHost,
                Int32(remotePort),
                "127.0.0.1",
                Int32(localPort)
            )

            if let channel {
                return channel
            }

            let errno = libssh2_session_last_errno(session)
            guard errno == LIBSSH2_ERROR_EAGAIN else {
                return nil
            }

            if !waitForSocket(session: session, socketFD: socketFD, timeoutMs: 5_000) {
                return nil
            }
        }
    }

    /// Bidirectional relay between a client socket and an SSH channel.
    private func spawnRelay(clientFD: Int32, channel: OpaquePointer) {
        Task.detached { [weak self] in
            guard let self else {
                libssh2_channel_free(channel)
                Darwin.close(clientFD)
                return
            }

            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Self.relayBufferSize)
            defer {
                buffer.deallocate()
                libssh2_channel_close(channel)
                libssh2_channel_free(channel)
                Darwin.close(clientFD)
            }

            while !Task.isCancelled && self.isRunning {
                var pollFDs = [
                    pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: self.socketFD, events: Int16(POLLIN), revents: 0),
                ]

                let pollResult = poll(&pollFDs, 2, 100) // 100ms timeout
                if pollResult < 0 { break }

                // Read from SSH channel -> write to client
                let channelRead = tablepro_libssh2_channel_read(
                    channel, buffer, Self.relayBufferSize
                )
                if channelRead > 0 {
                    var totalSent = 0
                    while totalSent < Int(channelRead) {
                        let sent = send(
                            clientFD,
                            buffer.advanced(by: totalSent),
                            Int(channelRead) - totalSent,
                            0
                        )
                        if sent <= 0 { return }
                        totalSent += sent
                    }
                } else if channelRead == 0 || libssh2_channel_eof(channel) != 0 {
                    // Channel EOF
                    return
                } else if channelRead != Int(LIBSSH2_ERROR_EAGAIN) {
                    // Real error
                    return
                }

                // Read from client -> write to SSH channel
                if pollFDs[0].revents & Int16(POLLIN) != 0 {
                    let clientRead = recv(clientFD, buffer, Self.relayBufferSize, 0)
                    if clientRead <= 0 { return }

                    var totalWritten = 0
                    while totalWritten < Int(clientRead) {
                        let written = tablepro_libssh2_channel_write(
                            channel,
                            buffer.advanced(by: totalWritten),
                            Int(clientRead) - totalWritten
                        )
                        if written > 0 {
                            totalWritten += Int(written)
                        } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                            _ = self.waitForSocket(
                                session: self.session,
                                socketFD: self.socketFD,
                                timeoutMs: 1_000
                            )
                        } else {
                            return
                        }
                    }
                }
            }
        }
    }

    /// Wait for the SSH socket to become ready, based on libssh2's block directions.
    private func waitForSocket(session: OpaquePointer, socketFD: Int32, timeoutMs: Int32) -> Bool {
        let directions = libssh2_session_block_directions(session)

        var events: Int16 = 0
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 {
            events |= Int16(POLLIN)
        }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            events |= Int16(POLLOUT)
        }

        guard events != 0 else { return true }

        var pollFD = pollfd(fd: socketFD, events: events, revents: 0)
        let rc = poll(&pollFD, 1, timeoutMs)
        return rc > 0
    }
}

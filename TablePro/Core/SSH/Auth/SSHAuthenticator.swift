//
//  SSHAuthenticator.swift
//  TablePro
//

import CLibSSH2
import Foundation

/// Protocol for SSH authentication methods
protocol SSHAuthenticator: Sendable {
    /// Authenticate the SSH session
    /// - Parameters:
    ///   - session: libssh2 session pointer
    ///   - username: SSH username
    /// - Throws: SSHTunnelError on failure
    func authenticate(session: OpaquePointer, username: String) throws
}

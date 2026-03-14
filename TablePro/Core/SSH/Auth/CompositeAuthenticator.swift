//
//  CompositeAuthenticator.swift
//  TablePro
//

import CLibSSH2
import Foundation
import os

/// Authenticator that tries multiple auth methods in sequence.
/// Used for servers requiring e.g. password + keyboard-interactive (TOTP).
struct CompositeAuthenticator: SSHAuthenticator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CompositeAuthenticator")

    let authenticators: [any SSHAuthenticator]

    func authenticate(session: OpaquePointer, username: String) throws {
        for (index, authenticator) in authenticators.enumerated() {
            Self.logger.debug(
                "Trying authenticator \(index + 1)/\(authenticators.count): \(String(describing: type(of: authenticator)))"
            )

            try authenticator.authenticate(session: session, username: username)

            if libssh2_userauth_authenticated(session) != 0 {
                Self.logger.info("Authentication succeeded after \(index + 1) step(s)")
                return
            }
        }

        if libssh2_userauth_authenticated(session) == 0 {
            throw SSHTunnelError.authenticationFailed
        }
    }
}

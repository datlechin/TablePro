//
//  TOTPProvider.swift
//  TablePro
//

import Foundation

/// Protocol for providing TOTP verification codes
protocol TOTPProvider: Sendable {
    /// Generate or obtain a TOTP code
    /// - Returns: The TOTP code string
    /// - Throws: SSHTunnelError if the code cannot be obtained
    func provideCode() throws -> String
}

/// Automatically generates TOTP codes from a stored secret.
///
/// If the current code expires in less than 5 seconds, waits for the next
/// period to avoid submitting a code that expires during the authentication handshake.
struct AutoTOTPProvider: TOTPProvider {
    let generator: TOTPGenerator

    func provideCode() throws -> String {
        let remaining = generator.secondsRemaining()
        if remaining < 5 {
            Thread.sleep(forTimeInterval: TimeInterval(remaining + 1))
        }
        return generator.generate()
    }
}

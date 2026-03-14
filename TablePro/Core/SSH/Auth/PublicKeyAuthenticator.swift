//
//  PublicKeyAuthenticator.swift
//  TablePro
//

import Foundation

import CLibSSH2

internal struct PublicKeyAuthenticator: SSHAuthenticator {
    let privateKeyPath: String
    let passphrase: String?

    func authenticate(session: OpaquePointer, username: String) throws {
        let expandedPath = expandPath(privateKeyPath)

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SSHTunnelError.tunnelCreationFailed(
                "Private key file not found at: \(expandedPath)"
            )
        }
        guard FileManager.default.isReadableFile(atPath: expandedPath) else {
            throw SSHTunnelError.tunnelCreationFailed(
                "Private key file not readable. Check permissions (should be 600): \(expandedPath)"
            )
        }

        let pubKeyPath = expandedPath + ".pub"
        let hasPubKey = FileManager.default.fileExists(atPath: pubKeyPath)

        let rc: Int32
        if hasPubKey {
            rc = pubKeyPath.withCString { pubKeyCStr in
                libssh2_userauth_publickey_fromfile_ex(
                    session,
                    username, UInt32(username.utf8.count),
                    pubKeyCStr,
                    expandedPath,
                    passphrase
                )
            }
        } else {
            rc = libssh2_userauth_publickey_fromfile_ex(
                session,
                username, UInt32(username.utf8.count),
                nil,
                expandedPath,
                passphrase
            )
        }

        guard rc == 0 else {
            throw SSHTunnelError.authenticationFailed
        }
    }

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
                .path(percentEncoded: false)
        }
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
                .path(percentEncoded: false)
        }
        return path
    }
}

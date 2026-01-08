//
//  SSHConfigParser.swift
//  TablePro
//
//  Parser for ~/.ssh/config file to auto-fill SSH connection details
//

import Foundation

/// Represents a parsed entry from ~/.ssh/config
struct SSHConfigEntry: Identifiable, Hashable {
    let id = UUID()
    let host: String  // Host pattern (alias used in ssh command)
    let hostname: String?  // Actual hostname/IP
    let port: Int?  // Port number
    let user: String?  // Username
    let identityFile: String?  // Path to private key

    /// Display name for UI
    var displayName: String {
        if let hostname = hostname, hostname != host {
            return "\(host) (\(hostname))"
        }
        return host
    }
}

/// Parser for SSH config file (~/.ssh/config)
final class SSHConfigParser {
    /// Default SSH config file path
    static let defaultConfigPath = NSHomeDirectory() + "/.ssh/config"

    /// Parse SSH config file and return all entries
    /// - Parameter path: Path to the SSH config file (defaults to ~/.ssh/config)
    /// - Returns: Array of SSHConfigEntry
    static func parse(path: String = defaultConfigPath) -> [SSHConfigEntry] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }

        return parseContent(content)
    }

    /// Parse SSH config content string
    /// - Parameter content: The content of the SSH config file
    /// - Returns: Array of SSHConfigEntry
    static func parseContent(_ content: String) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var currentHost: String?
        var currentHostname: String?
        var currentPort: Int?
        var currentUser: String?
        var currentIdentityFile: String?

        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Parse key-value pair
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            let key = parts[0].lowercased()
            let value = parts.dropFirst().joined(separator: " ")

            switch key {
            case "host":
                // Save previous entry if exists
                if let host = currentHost {
                    // Skip wildcard patterns like "*"
                    if !host.contains("*") && !host.contains("?") {
                        entries.append(
                            SSHConfigEntry(
                                host: host,
                                hostname: currentHostname,
                                port: currentPort,
                                user: currentUser,
                                identityFile: expandPath(currentIdentityFile)
                            ))
                    }
                }

                // Start new entry
                currentHost = value
                currentHostname = nil
                currentPort = nil
                currentUser = nil
                currentIdentityFile = nil

            case "hostname":
                currentHostname = value

            case "port":
                currentPort = Int(value)

            case "user":
                currentUser = value

            case "identityfile":
                currentIdentityFile = value

            default:
                break  // Ignore other directives
            }
        }

        // Don't forget the last entry
        if let host = currentHost, !host.contains("*"), !host.contains("?") {
            entries.append(
                SSHConfigEntry(
                    host: host,
                    hostname: currentHostname,
                    port: currentPort,
                    user: currentUser,
                    identityFile: expandPath(currentIdentityFile)
                ))
        }

        return entries
    }

    /// Find a specific entry by host name
    /// - Parameters:
    ///   - host: The host name to search for
    ///   - path: Path to the SSH config file
    /// - Returns: The matching SSHConfigEntry or nil
    static func findEntry(for host: String, path: String = defaultConfigPath) -> SSHConfigEntry? {
        let entries = parse(path: path)
        return entries.first { $0.host.lowercased() == host.lowercased() }
    }

    /// Expand ~ to home directory in path
    private static func expandPath(_ path: String?) -> String? {
        guard let path = path else { return nil }

        if path.hasPrefix("~") {
            return NSHomeDirectory() + path.dropFirst()
        }
        return path
    }
}

//
//  ConnectionURLFormatter.swift
//  TablePro
//

import Foundation

struct ConnectionURLFormatter {
    static func format(_ connection: DatabaseConnection, password: String?, sshPassword: String?) -> String {
        let scheme = urlScheme(for: connection.type)

        if connection.type == .sqlite {
            return formatSQLite(connection.database)
        }

        if connection.sshConfig.enabled {
            return formatSSH(connection, scheme: scheme, password: password)
        }

        return formatStandard(connection, scheme: scheme, password: password)
    }

    // MARK: - Private

    private static func urlScheme(for type: DatabaseType) -> String {
        switch type {
        case .mysql: return "mysql"
        case .mariadb: return "mariadb"
        case .postgresql: return "postgresql"
        case .redshift: return "redshift"
        case .sqlite: return "sqlite"
        case .mongodb: return "mongodb"
        case .redis: return "redis"
        case .mssql: return "sqlserver"
        }
    }

    private static func formatSQLite(_ database: String) -> String {
        if database.hasPrefix("/") {
            return "sqlite:///\(database.dropFirst())"
        }
        return "sqlite://\(database)"
    }

    private static func formatSSH(
        _ connection: DatabaseConnection,
        scheme: String,
        password: String?
    ) -> String {
        var result = "\(scheme)+ssh://"

        let ssh = connection.sshConfig
        if !ssh.username.isEmpty {
            result += "\(percentEncodeUserinfo(ssh.username))@"
        }
        result += ssh.host
        if ssh.port != 22 {
            result += ":\(ssh.port)"
        }

        result += "/"

        if !connection.username.isEmpty {
            result += percentEncodeUserinfo(connection.username)
            if let password, !password.isEmpty {
                result += ":\(percentEncodeUserinfo(password))"
            }
            result += "@"
        }

        result += connection.host
        if connection.port != connection.type.defaultPort {
            result += ":\(connection.port)"
        }

        result += "/\(connection.database)"

        let query = buildQueryString(connection)
        if !query.isEmpty {
            result += "?\(query)"
        }

        return result
    }

    private static func formatStandard(
        _ connection: DatabaseConnection,
        scheme: String,
        password: String?
    ) -> String {
        var result = "\(scheme)://"

        if !connection.username.isEmpty {
            result += percentEncodeUserinfo(connection.username)
            if let password, !password.isEmpty {
                result += ":\(percentEncodeUserinfo(password))"
            }
            result += "@"
        }

        result += connection.host
        if connection.port != connection.type.defaultPort {
            result += ":\(connection.port)"
        }

        result += "/\(connection.database)"

        let query = buildQueryString(connection)
        if !query.isEmpty {
            result += "?\(query)"
        }

        return result
    }

    private static func buildQueryString(_ connection: DatabaseConnection) -> String {
        var params: [String] = []

        if !connection.name.isEmpty {
            let encoded = connection.name
                .replacingOccurrences(of: " ", with: "+")
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                .replacingOccurrences(of: "&", with: "%26")
                .replacingOccurrences(of: "=", with: "%3D")
                ?? connection.name
            params.append("name=\(encoded)")
        }

        if connection.sshConfig.enabled && connection.sshConfig.authMethod == .privateKey {
            params.append("usePrivateKey=true")
        }

        if let sslParam = sslModeParam(connection.sslConfig.mode) {
            params.append("sslmode=\(sslParam)")
        }

        if let hex = colorHex(connection.color) {
            params.append("statusColor=\(hex)")
        }

        if let tagId = connection.tagId,
           let tag = TagStorage.shared.tag(for: tagId) {
            let encoded = tag.name
                .replacingOccurrences(of: " ", with: "+")
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                .replacingOccurrences(of: "&", with: "%26")
                .replacingOccurrences(of: "=", with: "%3D")
                ?? tag.name
            params.append("env=\(encoded)")
        }

        return params.joined(separator: "&")
    }

    private static func colorHex(_ color: ConnectionColor) -> String? {
        switch color {
        case .none: return nil
        case .red: return "FF3B30"
        case .orange: return "FF9500"
        case .yellow: return "FFCC00"
        case .green: return "34C759"
        case .blue: return "007AFF"
        case .purple: return "AF52DE"
        case .pink: return "FF2D55"
        case .gray: return "8E8E93"
        }
    }

    private static func sslModeParam(_ mode: SSLMode) -> String? {
        switch mode {
        case .disabled: return nil
        case .preferred: return "prefer"
        case .required: return "require"
        case .verifyCa: return "verify-ca"
        case .verifyIdentity: return "verify-full"
        }
    }

    private static func percentEncodeUserinfo(_ value: String) -> String {
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

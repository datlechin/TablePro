//
//  ConnectionURLParser.swift
//  TablePro
//

import Foundation

struct ParsedConnectionURL {
    let type: DatabaseType
    let host: String
    let port: Int?
    let database: String
    let username: String
    let password: String
    let sslMode: SSLMode?
    let authSource: String?
    let sshHost: String?
    let sshPort: Int?
    let sshUsername: String?
    let usePrivateKey: Bool?
    let connectionName: String?

    var suggestedName: String {
        if let connectionName, !connectionName.isEmpty {
            return connectionName
        }
        let typeName = type.rawValue
        if !database.isEmpty {
            return "\(typeName) \(host)/\(database)"
        }
        if !host.isEmpty {
            return "\(typeName) \(host)"
        }
        return typeName
    }
}

enum ConnectionURLParseError: Error, LocalizedError, Equatable {
    case emptyString
    case invalidURL
    case unsupportedScheme(String)
    case missingHost

    var errorDescription: String? {
        switch self {
        case .emptyString:
            return String(localized: "Connection URL cannot be empty")
        case .invalidURL:
            return String(localized: "Invalid connection URL format")
        case .unsupportedScheme(let scheme):
            return String(localized: "Unsupported database scheme: \(scheme)")
        case .missingHost:
            return String(localized: "Connection URL must include a host")
        }
    }
}

struct ConnectionURLParser {
    static func parse(_ urlString: String) -> Result<ParsedConnectionURL, ConnectionURLParseError> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyString)
        }

        guard let schemeEnd = trimmed.range(of: "://") else {
            return .failure(.invalidURL)
        }

        var scheme = trimmed[trimmed.startIndex..<schemeEnd.lowerBound].lowercased()

        var isSSH = false
        if scheme.hasSuffix("+ssh") {
            isSSH = true
            scheme = String(scheme.dropLast(4))
        }

        let dbType: DatabaseType
        switch scheme {
        case "postgresql", "postgres":
            dbType = .postgresql
        case "mysql":
            dbType = .mysql
        case "mariadb":
            dbType = .mariadb
        case "sqlite":
            dbType = .sqlite
        case "mongodb", "mongodb+srv":
            dbType = .mongodb
        default:
            return .failure(.unsupportedScheme(scheme))
        }

        if dbType == .sqlite {
            let path = String(trimmed[schemeEnd.upperBound...])
            return .success(ParsedConnectionURL(
                type: .sqlite,
                host: "",
                port: nil,
                database: path,
                username: "",
                password: "",
                sslMode: nil,
                authSource: nil,
                sshHost: nil,
                sshPort: nil,
                sshUsername: nil,
                usePrivateKey: nil,
                connectionName: nil
            ))
        }

        if isSSH {
            return parseSSHURL(trimmed, schemeEnd: schemeEnd, dbType: dbType)
        }

        let httpURL = "http://" + String(trimmed[schemeEnd.upperBound...])
        guard let components = URLComponents(string: httpURL) else {
            return .failure(.invalidURL)
        }

        guard let host = components.host, !host.isEmpty else {
            return .failure(.missingHost)
        }

        let port = components.port
        let username = components.percentEncodedUser.flatMap {
            $0.removingPercentEncoding
        } ?? ""
        let password = components.percentEncodedPassword.flatMap {
            $0.removingPercentEncoding
        } ?? ""

        var database = components.path
        if database.hasPrefix("/") {
            database = String(database.dropFirst())
        }

        var sslMode: SSLMode?
        var authSource: String?
        if let queryItems = components.queryItems {
            for item in queryItems {
                if item.name == "sslmode", let value = item.value {
                    sslMode = parseSSLMode(value)
                }
                if item.name == "authSource" || item.name == "authsource" {
                    authSource = item.value
                }
            }
        }

        return .success(ParsedConnectionURL(
            type: dbType,
            host: host,
            port: port,
            database: database,
            username: username,
            password: password,
            sslMode: sslMode,
            authSource: authSource,
            sshHost: nil,
            sshPort: nil,
            sshUsername: nil,
            usePrivateKey: nil,
            connectionName: nil
        ))
    }

    // SSH URL format: scheme+ssh://ssh_user@ssh_host:ssh_port/db_user:db_pass@db_host:db_port/db_name?params
    // URLComponents can't handle two user@host segments, so we parse manually.
    private static func parseSSHURL(
        _ urlString: String,
        schemeEnd: Range<String.Index>,
        dbType: DatabaseType
    ) -> Result<ParsedConnectionURL, ConnectionURLParseError> {
        let afterScheme = String(urlString[schemeEnd.upperBound...])

        var mainPart = afterScheme
        var queryString: String?
        if let questionIndex = afterScheme.firstIndex(of: "?") {
            mainPart = String(afterScheme[afterScheme.startIndex..<questionIndex])
            queryString = String(afterScheme[afterScheme.index(after: questionIndex)...])
        }

        guard let firstSlash = mainPart.firstIndex(of: "/") else {
            return .failure(.invalidURL)
        }

        let sshPart = String(mainPart[mainPart.startIndex..<firstSlash])
        let dbPart = String(mainPart[mainPart.index(after: firstSlash)...])

        var sshUsername: String?
        var sshHostPort: String
        if let atIndex = sshPart.firstIndex(of: "@") {
            sshUsername = String(sshPart[sshPart.startIndex..<atIndex])
            sshHostPort = String(sshPart[sshPart.index(after: atIndex)...])
        } else {
            sshHostPort = sshPart
        }

        guard !sshHostPort.isEmpty else {
            return .failure(.missingHost)
        }

        var sshHost: String
        var sshPort: Int?
        if let colonIndex = sshHostPort.firstIndex(of: ":") {
            sshHost = String(sshHostPort[sshHostPort.startIndex..<colonIndex])
            sshPort = Int(sshHostPort[sshHostPort.index(after: colonIndex)...])
        } else {
            sshHost = sshHostPort
        }

        var dbUsername = ""
        var dbPassword = ""
        var dbHostPort = ""
        var database = ""

        if let atIndex = dbPart.lastIndex(of: "@") {
            let credentials = String(dbPart[dbPart.startIndex..<atIndex])
            let afterAt = String(dbPart[dbPart.index(after: atIndex)...])

            if let colonIndex = credentials.firstIndex(of: ":") {
                dbUsername = String(credentials[credentials.startIndex..<colonIndex])
                dbPassword = String(credentials[credentials.index(after: colonIndex)...])
            } else {
                dbUsername = credentials
            }

            if let slashIndex = afterAt.firstIndex(of: "/") {
                dbHostPort = String(afterAt[afterAt.startIndex..<slashIndex])
                database = String(afterAt[afterAt.index(after: slashIndex)...])
            } else {
                dbHostPort = afterAt
            }
        } else {
            if let slashIndex = dbPart.firstIndex(of: "/") {
                dbHostPort = String(dbPart[dbPart.startIndex..<slashIndex])
                database = String(dbPart[dbPart.index(after: slashIndex)...])
            } else {
                dbHostPort = dbPart
            }
        }

        var host: String
        var port: Int?
        if let colonIndex = dbHostPort.lastIndex(of: ":") {
            host = String(dbHostPort[dbHostPort.startIndex..<colonIndex])
            port = Int(dbHostPort[dbHostPort.index(after: colonIndex)...])
        } else {
            host = dbHostPort
        }

        if host.isEmpty {
            host = "127.0.0.1"
        }

        var connectionName: String?
        var usePrivateKey: Bool?
        var sslMode: SSLMode?
        var authSource: String?

        if let queryString {
            let params = queryString.split(separator: "&", omittingEmptySubsequences: true)
            for param in params {
                let parts = param.split(separator: "=", maxSplits: 1)
                guard let key = parts.first else { continue }
                let value = parts.count > 1 ? String(parts[1]) : nil

                switch String(key) {
                case "name":
                    connectionName = value?
                        .replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? value
                case "usePrivateKey":
                    usePrivateKey = value?.lowercased() == "true"
                case "sslmode":
                    if let value {
                        sslMode = parseSSLMode(value)
                    }
                case "authSource", "authsource":
                    authSource = value
                default:
                    break
                }
            }
        }

        return .success(ParsedConnectionURL(
            type: dbType,
            host: host,
            port: port,
            database: database,
            username: dbUsername,
            password: dbPassword,
            sslMode: sslMode,
            authSource: authSource,
            sshHost: sshHost,
            sshPort: sshPort,
            sshUsername: sshUsername,
            usePrivateKey: usePrivateKey,
            connectionName: connectionName
        ))
    }

    private static func parseSSLMode(_ value: String) -> SSLMode? {
        switch value.lowercased() {
        case "disable", "disabled":
            return .disabled
        case "prefer", "preferred":
            return .preferred
        case "require", "required":
            return .required
        case "verify-ca":
            return .verifyCa
        case "verify-full", "verify-identity":
            return .verifyIdentity
        default:
            return nil
        }
    }
}

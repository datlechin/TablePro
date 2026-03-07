//
//  SSHConfigurationTests.swift
//  TableProTests
//
//  Tests for SSHConfiguration model
//

import Foundation
import Testing
@testable import TablePro

@Suite("SSH Configuration")
struct SSHConfigurationTests {

    @Test("Disabled SSH config is always valid")
    func testDisabledIsValid() {
        let config = SSHConfiguration(enabled: false)
        #expect(config.isValid == true)
    }

    @Test("Password auth is valid with host and username")
    func testPasswordAuthValid() {
        let config = SSHConfiguration(
            enabled: true, host: "example.com", username: "admin",
            authMethod: .password
        )
        #expect(config.isValid == true)
    }

    @Test("Private key auth requires non-empty key path")
    func testPrivateKeyAuthRequiresPath() {
        let invalid = SSHConfiguration(
            enabled: true, host: "example.com", username: "admin",
            authMethod: .privateKey, privateKeyPath: ""
        )
        #expect(invalid.isValid == false)

        let valid = SSHConfiguration(
            enabled: true, host: "example.com", username: "admin",
            authMethod: .privateKey, privateKeyPath: "~/.ssh/id_rsa"
        )
        #expect(valid.isValid == true)
    }

    @Test("SSH Agent auth is valid without any key path")
    func testSSHAgentAuthValid() {
        let config = SSHConfiguration(
            enabled: true, host: "example.com", username: "admin",
            authMethod: .sshAgent
        )
        #expect(config.isValid == true)
    }

    @Test("SSH Agent auth is valid with custom socket path")
    func testSSHAgentAuthValidWithSocket() {
        let config = SSHConfiguration(
            enabled: true, host: "example.com", username: "admin",
            authMethod: .sshAgent, agentSocketPath: SSHAgentSocketOption.onePasswordSocketPath
        )
        #expect(config.isValid == true)
    }

    @Test("Missing host makes config invalid")
    func testMissingHostInvalid() {
        let config = SSHConfiguration(
            enabled: true, host: "", username: "admin",
            authMethod: .sshAgent
        )
        #expect(config.isValid == false)
    }

    @Test("Missing username makes config invalid")
    func testMissingUsernameInvalid() {
        let config = SSHConfiguration(
            enabled: true, host: "example.com", username: "",
            authMethod: .sshAgent
        )
        #expect(config.isValid == false)
    }

    @Test("Agent socket path defaults to empty string")
    func testAgentSocketPathDefault() {
        let config = SSHConfiguration()
        #expect(config.agentSocketPath == "")
    }

    @Test("Empty socket path maps to SSH_AUTH_SOCK option")
    func testEmptySocketPathMapsToSystemDefault() {
        #expect(SSHAgentSocketOption(socketPath: "") == .systemDefault)
    }

    @Test("1Password socket path maps to 1Password option")
    func testOnePasswordSocketPathMapsToPreset() {
        #expect(SSHAgentSocketOption(socketPath: SSHAgentSocketOption.onePasswordSocketPath) == .onePassword)
    }

    @Test("1Password alias path maps to 1Password option")
    func testOnePasswordAliasPathMapsToPreset() {
        #expect(SSHAgentSocketOption(socketPath: "~/.1password/agent.sock") == .onePassword)
    }

    @Test("Unknown socket path maps to custom option")
    func testCustomSocketPathMapsToCustomOption() {
        #expect(SSHAgentSocketOption(socketPath: "/tmp/custom.sock") == .custom)
    }

    @Test("System default option resolves to empty socket path")
    func testSystemDefaultOptionResolvesToEmptyPath() {
        #expect(SSHAgentSocketOption.systemDefault.resolvedPath(customPath: "/tmp/custom.sock") == "")
    }

    @Test("1Password option resolves to preset socket path")
    func testOnePasswordOptionResolvesToPresetPath() {
        #expect(
            SSHAgentSocketOption.onePassword.resolvedPath(customPath: "/tmp/custom.sock")
                == SSHAgentSocketOption.onePasswordSocketPath
        )
    }

    @Test("Custom option resolves to trimmed custom socket path")
    func testCustomOptionResolvesToTrimmedPath() {
        #expect(
            SSHAgentSocketOption.custom.resolvedPath(customPath: "  /tmp/custom.sock  ")
                == "/tmp/custom.sock"
        )
    }
}

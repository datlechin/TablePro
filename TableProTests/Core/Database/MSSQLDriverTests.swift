//
//  MSSQLDriverTests.swift
//  TableProTests
//
//  Tests for MSSQLDriver — parts that don't require a live connection.
//

import Foundation
@testable import TablePro
import Testing

@Suite("MSSQL Driver")
struct MSSQLDriverTests {
    // MARK: - Helpers

    private func makeConnection(mssqlSchema: String? = nil) -> DatabaseConnection {
        var conn = TestFixtures.makeConnection(type: .mssql)
        conn.mssqlSchema = mssqlSchema
        return conn
    }

    // MARK: - Initialization Tests

    @Test("Init sets currentSchema to dbo when mssqlSchema is nil")
    func initDefaultSchemaNil() {
        let driver = MSSQLDriver(connection: makeConnection(mssqlSchema: nil))
        #expect(driver.currentSchema == "dbo")
    }

    @Test("Init sets currentSchema to dbo when mssqlSchema is empty string")
    func initDefaultSchemaEmpty() {
        let driver = MSSQLDriver(connection: makeConnection(mssqlSchema: ""))
        #expect(driver.currentSchema == "dbo")
    }

    @Test("Init uses mssqlSchema when provided and non-empty")
    func initCustomSchema() {
        let driver = MSSQLDriver(connection: makeConnection(mssqlSchema: "sales"))
        #expect(driver.currentSchema == "sales")
    }

    // MARK: - escapedSchema Tests

    @Test("escapedSchema returns schema unchanged when no single quotes")
    func escapedSchemaNoQuotes() {
        let driver = MSSQLDriver(connection: makeConnection(mssqlSchema: "sales"))
        #expect(driver.escapedSchema == "sales")
    }

    @Test("escapedSchema doubles single quote in schema name")
    func escapedSchemaDoublesSingleQuote() {
        let driver = MSSQLDriver(connection: makeConnection(mssqlSchema: "O'Brien"))
        #expect(driver.escapedSchema == "O''Brien")
    }

    @Test("escapedSchema doubles multiple single quotes")
    func escapedSchemaMultipleQuotes() {
        let driver = MSSQLDriver(connection: makeConnection(mssqlSchema: "O'Bri'en"))
        #expect(driver.escapedSchema == "O''Bri''en")
    }

    // MARK: - switchSchema Tests

    @Test("switchSchema updates currentSchema")
    func switchSchemaUpdatesCurrentSchema() async throws {
        let driver = MSSQLDriver(connection: makeConnection())
        try await driver.switchSchema(to: "hr")
        #expect(driver.currentSchema == "hr")
    }

    @Test("switchSchema updates escapedSchema accordingly")
    func switchSchemaUpdatesEscapedSchema() async throws {
        let driver = MSSQLDriver(connection: makeConnection())
        try await driver.switchSchema(to: "O'Connor")
        #expect(driver.escapedSchema == "O''Connor")
    }

    // MARK: - Status Tests

    @Test("Status starts as disconnected")
    func statusStartsDisconnected() {
        let driver = MSSQLDriver(connection: makeConnection())
        if case .disconnected = driver.status {
            #expect(true)
        } else {
            Issue.record("Expected .disconnected status, got \(driver.status)")
        }
    }

    // MARK: - Execute Tests

    @Test("Execute throws when not connected")
    func executeThrowsWhenNotConnected() async {
        let driver = MSSQLDriver(connection: makeConnection())
        await #expect(throws: (any Error).self) {
            _ = try await driver.execute(query: "SELECT 1")
        }
    }
}

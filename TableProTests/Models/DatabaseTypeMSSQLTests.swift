//
//  DatabaseTypeMSSQLTests.swift
//  TableProTests
//
//  Tests for DatabaseType.mssql properties and methods.
//

import Foundation
@testable import TablePro
import Testing

@Suite("DatabaseType MSSQL")
struct DatabaseTypeMSSQLTests {
    // MARK: - Basic Properties

    @Test("defaultPort is 1433")
    func defaultPort() {
        #expect(DatabaseType.mssql.defaultPort == 1_433)
    }

    @Test("rawValue is SQL Server")
    func rawValue() {
        #expect(DatabaseType.mssql.rawValue == "SQL Server")
    }

    @Test("identifierQuote is open bracket")
    func identifierQuote() {
        #expect(DatabaseType.mssql.identifierQuote == "[")
    }

    @Test("requiresAuthentication is true")
    func requiresAuthentication() {
        #expect(DatabaseType.mssql.requiresAuthentication == true)
    }

    @Test("supportsForeignKeys is true")
    func supportsForeignKeys() {
        #expect(DatabaseType.mssql.supportsForeignKeys == true)
    }

    @Test("supportsSchemaEditing is true")
    func supportsSchemaEditing() {
        #expect(DatabaseType.mssql.supportsSchemaEditing == true)
    }

    @Test("iconName is mssql-icon")
    func iconName() {
        #expect(DatabaseType.mssql.iconName == "mssql-icon")
    }

    // MARK: - quoteIdentifier Tests

    @Test("quoteIdentifier wraps simple name with brackets")
    func quoteIdentifierSimple() {
        #expect(DatabaseType.mssql.quoteIdentifier("users") == "[users]")
    }

    @Test("quoteIdentifier handles name with spaces")
    func quoteIdentifierWithSpaces() {
        #expect(DatabaseType.mssql.quoteIdentifier("my table") == "[my table]")
    }

    @Test("quoteIdentifier escapes embedded closing bracket")
    func quoteIdentifierWithEmbeddedBracket() {
        #expect(DatabaseType.mssql.quoteIdentifier("user]s") == "[user]]s]")
    }

    @Test("quoteIdentifier handles empty name")
    func quoteIdentifierEmpty() {
        #expect(DatabaseType.mssql.quoteIdentifier("") == "[]")
    }

    @Test("quoteIdentifier escapes multiple embedded closing brackets")
    func quoteIdentifierMultipleBrackets() {
        #expect(DatabaseType.mssql.quoteIdentifier("a]b]c") == "[a]]b]]c]")
    }

    // MARK: - allCases Tests

    @Test("allCases contains mssql")
    func allCasesContainsMSSql() {
        #expect(DatabaseType.allCases.contains(.mssql))
    }

    @Test("allCases contains mssql entry")
    func allCasesCount() {
        #expect(DatabaseType.allCases.contains(.mssql))
    }
}

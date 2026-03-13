//
//  DatabaseTypeTests.swift
//  TableProTests
//
//  Tests for DatabaseType enum
//

import Foundation
import Testing
@testable import TablePro

@Suite("DatabaseType")
struct DatabaseTypeTests {

    @Test("MySQL default port is 3306")
    func testMySQLDefaultPort() {
        #expect(DatabaseType.mysql.defaultPort == 3306)
    }

    @Test("MariaDB default port is 3306")
    func testMariaDBDefaultPort() {
        #expect(DatabaseType.mariadb.defaultPort == 3306)
    }

    @Test("PostgreSQL default port is 5432")
    func testPostgreSQLDefaultPort() {
        #expect(DatabaseType.postgresql.defaultPort == 5432)
    }

    @Test("SQLite default port is 0")
    func testSQLiteDefaultPort() {
        #expect(DatabaseType.sqlite.defaultPort == 0)
    }

    @Test("MongoDB default port is 27017")
    func testMongoDBDefaultPort() {
        #expect(DatabaseType.mongodb.defaultPort == 27_017)
    }

    @Test("CaseIterable count is 11")
    func testCaseIterableCount() {
        #expect(DatabaseType.allCases.count == 11)
    }

    @Test("Raw value matches display name", arguments: [
        (DatabaseType.mysql, "MySQL"),
        (DatabaseType.mariadb, "MariaDB"),
        (DatabaseType.postgresql, "PostgreSQL"),
        (DatabaseType.sqlite, "SQLite"),
        (DatabaseType.mongodb, "MongoDB"),
        (DatabaseType.redis, "Redis"),
        (DatabaseType.redshift, "Redshift"),
        (DatabaseType.mssql, "SQL Server"),
        (DatabaseType.oracle, "Oracle"),
        (DatabaseType.clickhouse, "ClickHouse"),
        (DatabaseType.duckdb, "DuckDB")
    ])
    func testRawValueMatchesDisplayName(dbType: DatabaseType, expectedRawValue: String) {
        #expect(dbType.rawValue == expectedRawValue)
    }

    // MARK: - ClickHouse Tests

    @Test("ClickHouse default port is 8123")
    func testClickHouseDefaultPort() {
        #expect(DatabaseType.clickhouse.defaultPort == 8_123)
    }

    @Test("ClickHouse requires authentication")
    func testClickHouseRequiresAuth() {
        #expect(DatabaseType.clickhouse.requiresAuthentication == true)
    }

    @Test("ClickHouse does not support foreign keys")
    func testClickHouseSupportsForeignKeys() {
        #expect(DatabaseType.clickhouse.supportsForeignKeys == false)
    }

    @Test("ClickHouse supports schema editing")
    func testClickHouseSupportsSchemaEditing() {
        #expect(DatabaseType.clickhouse.supportsSchemaEditing == true)
    }

    @Test("ClickHouse icon name is clickhouse-icon")
    func testClickHouseIconName() {
        #expect(DatabaseType.clickhouse.iconName == "clickhouse-icon")
    }
}

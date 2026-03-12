//
//  ClickHouseDialectTests.swift
//  TableProTests
//
//  Tests for ClickHouse dialect via plugin-provided SQLDialectFactory
//

import Foundation
import Testing
@testable import TablePro

@Suite("ClickHouse Dialect")
struct ClickHouseDialectTests {

    @Test("Factory creates dialect for .clickhouse")
    @MainActor
    func testFactoryCreatesDialect() {
        let dialect = SQLDialectFactory.createDialect(for: .clickhouse)
        #expect(dialect.identifierQuote == "`" || dialect.identifierQuote == "\"")
    }
}

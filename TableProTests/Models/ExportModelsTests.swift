//
//  ExportModelsTests.swift
//  TableProTests
//
//  Created on 2026-02-17.
//

import Foundation
import Testing
@testable import TablePro

@Suite("Export Models")
struct ExportModelsTests {

    @Test("Export format file extension for CSV")
    func exportFormatCSV() {
        #expect(ExportFormat.csv.fileExtension == "csv")
    }

    @Test("Export format file extension for JSON")
    func exportFormatJSON() {
        #expect(ExportFormat.json.fileExtension == "json")
    }

    @Test("Export format file extension for SQL")
    func exportFormatSQL() {
        #expect(ExportFormat.sql.fileExtension == "sql")
    }

    @Test("Export format file extension for XLSX")
    func exportFormatXLSX() {
        #expect(ExportFormat.xlsx.fileExtension == "xlsx")
    }

    @Test("Export format has five cases")
    func exportFormatCaseCount() {
        #expect(ExportFormat.allCases.count == 5)
    }

    @Test("CSV delimiter comma actual value")
    func csvDelimiterComma() {
        #expect(CSVDelimiter.comma.actualValue == ",")
    }

    @Test("CSV delimiter semicolon actual value")
    func csvDelimiterSemicolon() {
        #expect(CSVDelimiter.semicolon.actualValue == ";")
    }

    @Test("CSV delimiter tab actual value")
    func csvDelimiterTab() {
        #expect(CSVDelimiter.tab.actualValue == "\t")
    }

    @Test("CSV delimiter pipe actual value")
    func csvDelimiterPipe() {
        #expect(CSVDelimiter.pipe.actualValue == "|")
    }

    @Test("Export configuration default full file name")
    func exportConfigurationDefaultFullFileName() {
        let config = ExportConfiguration()
        #expect(config.fullFileName == "export.csv")
    }

    @Test("Export configuration full file name with JSON format")
    func exportConfigurationJSONFullFileName() {
        var config = ExportConfiguration()
        config.format = .json
        #expect(config.fullFileName == "export.json")
    }

    @Test("Export configuration full file name with compressed SQL")
    func exportConfigurationCompressedSQL() {
        var config = ExportConfiguration()
        config.format = .sql
        config.sqlOptions.compressWithGzip = true
        #expect(config.fullFileName == "export.sql.gz")
    }

    @Test("Export configuration full file name with custom name")
    func exportConfigurationCustomName() {
        var config = ExportConfiguration()
        config.fileName = "my_data"
        config.format = .xlsx
        #expect(config.fullFileName == "my_data.xlsx")
    }

    @Test("Export database item selected count with no tables")
    func exportDatabaseItemNoTables() {
        let item = ExportDatabaseItem(name: "testdb", tables: [])
        #expect(item.selectedCount == 0)
        #expect(item.allSelected == false)
        #expect(item.noneSelected == true)
    }

    @Test("Export database item selected count with all selected")
    func exportDatabaseItemAllSelected() {
        let tables = [
            ExportTableItem(name: "users", type: .table, isSelected: true),
            ExportTableItem(name: "posts", type: .table, isSelected: true)
        ]
        let item = ExportDatabaseItem(name: "testdb", tables: tables)
        #expect(item.selectedCount == 2)
        #expect(item.allSelected == true)
        #expect(item.noneSelected == false)
    }

    @Test("Export database item selected count with partial selection")
    func exportDatabaseItemPartialSelection() {
        let tables = [
            ExportTableItem(name: "users", type: .table, isSelected: true),
            ExportTableItem(name: "posts", type: .table, isSelected: false)
        ]
        let item = ExportDatabaseItem(name: "testdb", tables: tables)
        #expect(item.selectedCount == 1)
        #expect(item.allSelected == false)
        #expect(item.noneSelected == false)
    }

    @Test("Export database item selected count with none selected")
    func exportDatabaseItemNoneSelected() {
        let tables = [
            ExportTableItem(name: "users", type: .table, isSelected: false),
            ExportTableItem(name: "posts", type: .table, isSelected: false)
        ]
        let item = ExportDatabaseItem(name: "testdb", tables: tables)
        #expect(item.selectedCount == 0)
        #expect(item.allSelected == false)
        #expect(item.noneSelected == true)
    }

    @Test("Export database item selected tables")
    func exportDatabaseItemSelectedTables() {
        let tables = [
            ExportTableItem(name: "users", type: .table, isSelected: true),
            ExportTableItem(name: "posts", type: .table, isSelected: false),
            ExportTableItem(name: "comments", type: .table, isSelected: true)
        ]
        let item = ExportDatabaseItem(name: "testdb", tables: tables)
        let selectedTables = item.selectedTables
        #expect(selectedTables.count == 2)
        #expect(selectedTables.map(\.name) == ["users", "comments"])
    }

    @Test("Export table item qualified name without database name")
    func exportTableItemQualifiedNameWithoutDatabase() {
        let table = ExportTableItem(name: "users", type: .table, isSelected: true)
        #expect(table.qualifiedName == "users")
    }

    @Test("Export table item qualified name with database name")
    func exportTableItemQualifiedNameWithDatabase() {
        let table = ExportTableItem(name: "users", databaseName: "mydb", type: .table, isSelected: true)
        #expect(table.qualifiedName == "mydb.users")
    }
}

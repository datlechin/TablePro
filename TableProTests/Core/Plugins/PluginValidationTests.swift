//
//  PluginValidationTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("PluginError.invalidDescriptor")
struct PluginErrorInvalidDescriptorTests {

    @Test("error description includes plugin ID and reason")
    func errorDescription() {
        let error = PluginError.invalidDescriptor(
            pluginId: "com.example.broken",
            reason: "databaseTypeId is empty"
        )
        let description = error.localizedDescription
        #expect(description.contains("com.example.broken"))
        #expect(description.contains("databaseTypeId is empty"))
    }

    @Test("error description for duplicate type ID includes existing plugin name")
    func duplicateTypeIdDescription() {
        let error = PluginError.invalidDescriptor(
            pluginId: "com.example.new-plugin",
            reason: "databaseTypeId 'mysql' is already registered by 'MySQL'"
        )
        let description = error.localizedDescription
        #expect(description.contains("com.example.new-plugin"))
        #expect(description.contains("mysql"))
        #expect(description.contains("MySQL"))
    }

    @Test("error description for empty display name")
    func emptyDisplayNameDescription() {
        let error = PluginError.invalidDescriptor(
            pluginId: "com.example.test",
            reason: "databaseDisplayName is empty"
        )
        let description = error.localizedDescription
        #expect(description.contains("databaseDisplayName is empty"))
    }

    @Test("error description for additional type ID conflict")
    func additionalTypeIdConflict() {
        let error = PluginError.invalidDescriptor(
            pluginId: "com.example.multi",
            reason: "additionalDatabaseTypeId 'redshift' is already registered by 'PostgreSQL'"
        )
        let description = error.localizedDescription
        #expect(description.contains("additionalDatabaseTypeId"))
        #expect(description.contains("redshift"))
        #expect(description.contains("PostgreSQL"))
    }
}

@Suite("ConnectionField Validation Logic")
struct ConnectionFieldValidationLogicTests {

    @Test("duplicate field IDs are detectable")
    func duplicateFieldIds() {
        let fields = [
            ConnectionField(id: "encoding", label: "Encoding"),
            ConnectionField(id: "timeout", label: "Timeout"),
            ConnectionField(id: "encoding", label: "Character Encoding")
        ]
        var seenIds = Set<String>()
        var duplicates: [String] = []
        for field in fields {
            if !seenIds.insert(field.id).inserted {
                duplicates.append(field.id)
            }
        }
        #expect(duplicates == ["encoding"])
    }

    @Test("empty field ID is detectable")
    func emptyFieldId() {
        let field = ConnectionField(id: "", label: "Something")
        #expect(field.id.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test("empty field label is detectable")
    func emptyFieldLabel() {
        let field = ConnectionField(id: "test", label: "")
        #expect(field.label.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test("dropdown with empty options is detectable")
    func emptyDropdownOptions() {
        let field = ConnectionField(
            id: "encoding",
            label: "Encoding",
            fieldType: .dropdown(options: [])
        )
        if case .dropdown(let options) = field.fieldType {
            #expect(options.isEmpty)
        } else {
            Issue.record("Expected dropdown field type")
        }
    }

    @Test("dropdown with options is valid")
    func validDropdown() {
        let field = ConnectionField(
            id: "encoding",
            label: "Encoding",
            fieldType: .dropdown(options: [
                ConnectionField.DropdownOption(value: "utf8", label: "UTF-8"),
                ConnectionField.DropdownOption(value: "latin1", label: "Latin-1")
            ])
        )
        if case .dropdown(let options) = field.fieldType {
            #expect(options.count == 2)
        } else {
            Issue.record("Expected dropdown field type")
        }
    }
}

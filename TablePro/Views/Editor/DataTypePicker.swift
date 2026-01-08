//
//  DataTypePicker.swift
//  TablePro
//
//  Picker for SQL data types, grouped by category.
//  Shows database-specific types based on the current database type.
//

import SwiftUI

struct DataTypePicker: View {
    @Binding var selectedType: String
    let databaseType: DatabaseType

    var body: some View {
        Picker("", selection: $selectedType) {
            ForEach(DataTypeCategory.allCases, id: \.self) { category in
                Section(header: Text(category.rawValue)) {
                    ForEach(category.types(for: databaseType), id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

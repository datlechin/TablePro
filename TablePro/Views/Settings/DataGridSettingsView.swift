//
//  DataGridSettingsView.swift
//  TablePro
//
//  Settings for data grid display and pagination
//

import SwiftUI

struct DataGridSettingsView: View {
    @Binding var settings: DataGridSettings

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font:", selection: $settings.fontFamily) {
                    ForEach(EditorFont.allCases.filter { $0.isAvailable }) { font in
                        Text(font.displayName).tag(font)
                    }
                }

                Picker("Size:", selection: $settings.fontSize) {
                    ForEach(10...18, id: \.self) { size in
                        Text("\(size) pt").tag(size)
                    }
                }

                GroupBox("Preview") {
                    Text("1  John Doe  john@example.com  NULL")
                        .font(Font(settings.fontFamily.font(size: CGFloat(settings.clampedFontSize))))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }

            Section("Display") {
                Picker("Row height:", selection: $settings.rowHeight) {
                    ForEach(DataGridRowHeight.allCases) { height in
                        Text(height.displayName).tag(height)
                    }
                }

                Picker("Date format:", selection: $settings.dateFormat) {
                    ForEach(DateFormatOption.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                // NULL Display with validation
                VStack(alignment: .leading, spacing: 4) {
                    TextField("NULL display:", text: $settings.nullDisplay)

                    if let error = settings.nullDisplayValidationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Max \(SettingsValidationRules.nullDisplayMaxLength) characters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Show alternate row backgrounds", isOn: $settings.showAlternateRows)

                Toggle("Auto-show inspector on row select", isOn: $settings.autoShowInspector)
            }

            Section("Pagination") {
                Picker("Default page size:", selection: $settings.defaultPageSize) {
                    Text("100 rows").tag(100)
                    Text("500 rows").tag(500)
                    Text("1,000 rows").tag(1_000)
                    Text("5,000 rows").tag(5_000)
                    Text("10,000 rows").tag(10_000)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    DataGridSettingsView(settings: .constant(.default))
        .frame(width: 450, height: 350)
}

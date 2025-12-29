//
//  ExportCSVOptionsView.swift
//  TablePro
//
//  Options panel for CSV export format.
//  Provides controls for delimiter, quoting, NULL handling, and formatting.
//

import SwiftUI

/// Options panel for CSV export
struct ExportCSVOptionsView: View {
    @Binding var options: CSVExportOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Checkboxes section
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Convert NULL to EMPTY", isOn: $options.convertNullToEmpty)
                    .toggleStyle(.checkbox)

                Toggle("Convert line break to space", isOn: $options.convertLineBreakToSpace)
                    .toggleStyle(.checkbox)

                Toggle("Put field names in the first row", isOn: $options.includeFieldNames)
                    .toggleStyle(.checkbox)

                Toggle("Sanitize formula-like values", isOn: $options.sanitizeFormulas)
                    .toggleStyle(.checkbox)
                    .help("Prevent CSV formula injection by prefixing values starting with =, +, -, @ with a single quote")
            }

            Divider()
                .padding(.vertical, 4)

            // Dropdowns section
            VStack(alignment: .leading, spacing: 10) {
                optionRow("Delimiter") {
                    Picker("", selection: $options.delimiter) {
                        ForEach(CSVDelimiter.allCases) { delimiter in
                            Text(delimiter.displayName).tag(delimiter)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140, alignment: .trailing)
                }

                optionRow("Quote") {
                    Picker("", selection: $options.quoteHandling) {
                        ForEach(CSVQuoteHandling.allCases) { handling in
                            Text(handling.rawValue).tag(handling)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140, alignment: .trailing)
                }

                optionRow("Line break") {
                    Picker("", selection: $options.lineBreak) {
                        ForEach(CSVLineBreak.allCases) { lineBreak in
                            Text(lineBreak.rawValue).tag(lineBreak)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140, alignment: .trailing)
                }

                optionRow("Decimal") {
                    Picker("", selection: $options.decimalFormat) {
                        ForEach(CSVDecimalFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140, alignment: .trailing)
                }
            }
        }
        .font(.system(size: 13))
    }

    private func optionRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.primary)
                .frame(width: 80, alignment: .leading)
            Spacer()
            content()
        }
    }
}

// MARK: - Preview

#Preview {
    ExportCSVOptionsView(options: .constant(CSVExportOptions()))
        .padding()
        .frame(width: 280)
}

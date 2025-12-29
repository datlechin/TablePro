//
//  ExportJSONOptionsView.swift
//  TablePro
//
//  Options panel for JSON export format.
//  Provides controls for formatting and NULL value handling.
//

import SwiftUI

/// Options panel for JSON export
struct ExportJSONOptionsView: View {
    @Binding var options: JSONExportOptions

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.xs) {
            Toggle("Pretty print (formatted output)", isOn: $options.prettyPrint)
                .toggleStyle(.checkbox)

            Toggle("Include NULL values", isOn: $options.includeNullValues)
                .toggleStyle(.checkbox)

            Toggle("Preserve all values as strings", isOn: $options.preserveAllAsStrings)
                .toggleStyle(.checkbox)
                .help("Keep leading zeros in ZIP codes, phone numbers, and IDs by outputting all values as strings")
        }
        .font(.system(size: DesignConstants.FontSize.body))
    }
}

// MARK: - Preview

#Preview {
    ExportJSONOptionsView(options: .constant(JSONExportOptions()))
        .padding()
        .frame(width: 300)
}

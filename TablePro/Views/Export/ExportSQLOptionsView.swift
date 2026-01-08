//
//  ExportSQLOptionsView.swift
//  TablePro
//
//  Options panel for SQL export format.
//  Note: Structure, Drop, and Data options are per-table (shown in tree view).
//  This view only contains global options like compression.
//

import SwiftUI

/// Options panel for SQL export (global options only)
struct ExportSQLOptionsView: View {
    @Binding var options: SQLExportOptions

    /// Available batch size options
    private static let batchSizeOptions = [1, 100, 500, 1_000]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.xs) {
            // Info text about per-table options
            Text("Structure, Drop, and Data options are configured per table in the table list.")
                .font(.system(size: DesignConstants.FontSize.small))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, DesignConstants.Spacing.xxs)

            // Batch size picker
            HStack {
                Text("Rows per INSERT")
                    .font(.system(size: DesignConstants.FontSize.body))

                Spacer()

                Picker("", selection: $options.batchSize) {
                    ForEach(Self.batchSizeOptions, id: \.self) { size in
                        Text(size == 1 ? "1 (no batching)" : "\(size)")
                            .tag(size)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
            }
            .help("Higher values create fewer INSERT statements, resulting in smaller files and faster imports")

            // Global compression option
            Toggle("Compress the file using Gzip", isOn: $options.compressWithGzip)
                .toggleStyle(.checkbox)
                .font(.system(size: DesignConstants.FontSize.body))
        }
    }
}

// MARK: - Preview

#Preview {
    ExportSQLOptionsView(options: .constant(SQLExportOptions()))
        .padding()
        .frame(width: 300)
}

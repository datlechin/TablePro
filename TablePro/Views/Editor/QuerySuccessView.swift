//
//  QuerySuccessView.swift
//  TablePro
//
//  Success message view for non-SELECT queries (INSERT, UPDATE, DELETE, etc.)
//

import SwiftUI

/// Displays success message for queries that don't return result sets
struct QuerySuccessView: View {
    let rowsAffected: Int
    let executionTime: TimeInterval?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            // Success message
            Text("Query executed successfully")
                .font(.headline)
                .foregroundStyle(.primary)

            // Details
            HStack(spacing: 8) {
                // Rows affected
                Label("\(rowsAffected) row\(rowsAffected == 1 ? "" : "s") affected", systemImage: "square.stack.3d.up")
                    .foregroundStyle(.secondary)

                if let time = executionTime {
                    Text("•")
                        .foregroundStyle(.tertiary)

                    // Execution time
                    Text(formatExecutionTime(time))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func formatExecutionTime(_ time: TimeInterval) -> String {
        if time < 0.001 {
            return String(format: "%.3f ms", time * 1_000)
        } else if time < 1 {
            return String(format: "%.2f ms", time * 1_000)
        } else {
            return String(format: "%.2f s", time)
        }
    }
}

#Preview {
    QuerySuccessView(rowsAffected: 3, executionTime: 0.025)
        .frame(width: 400, height: 300)
}

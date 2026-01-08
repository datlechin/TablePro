//
//  ExecutionIndicatorView.swift
//  TablePro
//
//  Query execution state indicator for the toolbar.
//  Shows a spinner during execution and optionally displays duration.
//

import SwiftUI

/// Compact execution indicator for the toolbar right section
struct ExecutionIndicatorView: View {
    let isExecuting: Bool
    let lastDuration: TimeInterval?

    var body: some View {
        HStack(spacing: 6) {
            if isExecuting {
                ProgressView()
                    .controlSize(.small)
                    .help("Query executing...")
            } else if let duration = lastDuration {
                // Show last query duration when not executing
                Text(formattedDuration(duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("Last query execution time")
            } else {
                Text("--")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.quaternary)
                    .help("Run a query to see execution time")
            }
        }
        .frame(minWidth: 50)
        .animation(.easeInOut(duration: 0.2), value: isExecuting)
    }

    // MARK: - Helpers

    /// Format duration for display
    private func formattedDuration(_ duration: TimeInterval) -> String {
        if duration < 0.001 {
            return "<1ms"
        } else if duration < 1.0 {
            return String(format: "%.0fms", duration * 1_000)
        } else if duration < 60.0 {
            return String(format: "%.2fs", duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
        }
    }
}

// MARK: - Preview

#Preview("Executing") {
    ExecutionIndicatorView(isExecuting: true, lastDuration: nil)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Completed Fast") {
    ExecutionIndicatorView(isExecuting: false, lastDuration: 0.023)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Completed Slow") {
    ExecutionIndicatorView(isExecuting: false, lastDuration: 2.456)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("No Duration") {
    ExecutionIndicatorView(isExecuting: false, lastDuration: nil)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}

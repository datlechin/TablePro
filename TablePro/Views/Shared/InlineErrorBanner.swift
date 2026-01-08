//
//  InlineErrorBanner.swift
//  TablePro
//
//  Native macOS-style inline error banner following Apple Human Interface Guidelines.
//  Replaces blocking alert dialogs with non-blocking inline notifications.
//

import SwiftUI

/// Native macOS-style inline error banner
///
/// Design follows Apple HIG:
/// - Icon: `exclamationmark.circle.fill` with multicolor rendering
/// - Background: System `controlBackgroundColor` (adapts to light/dark mode)
/// - Border: 0.5px hairline using `separatorColor`
/// - Corners: 6px rounded (macOS standard)
/// - Text: 12pt in `.primary` color for readability
struct InlineErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Native macOS error icon
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 16))
                .symbolRenderingMode(.multicolor)

            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // Dismiss button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .opacity(0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

#Preview("Light Mode") {
    VStack {
        InlineErrorBanner(
            message: "Table 'users' doesn't exist"
        )            {}
        Spacer()
    }
    .frame(width: 500, height: 200)
}

#Preview("Dark Mode") {
    VStack {
        InlineErrorBanner(
            message: "You have an error in your SQL syntax; check the manual that corresponds to your MySQL server version for the right syntax to use near 'SELEC' at line 1"
        )            {}
        Spacer()
    }
    .frame(width: 500, height: 200)
    .preferredColorScheme(.dark)
}

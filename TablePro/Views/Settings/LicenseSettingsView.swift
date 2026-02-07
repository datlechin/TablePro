//
//  LicenseSettingsView.swift
//  TablePro
//
//  License settings tab: status display, activation form, and deactivation
//

import AppKit
import SwiftUI

struct LicenseSettingsView: View {
    @StateObject private var licenseManager = LicenseManager.shared

    @State private var licenseKeyInput = ""
    @State private var isActivating = false

    var body: some View {
        Form {
            if let license = licenseManager.license {
                licensedSection(license)
            } else {
                unlicensedSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Licensed State

    @ViewBuilder
    private func licensedSection(_ license: License) -> some View {
        Section("License") {
            LabeledContent("Email:", value: license.email)

            LabeledContent("License Key:") {
                Text(maskedKey(license.key))
                    .textSelection(.enabled)
            }
        }

        Section("Maintenance") {
            HStack {
                Text("Remove license from this machine")
                Spacer()
                Button("Deactivate...") {
                    Task { @MainActor in
                        let confirmed = await AlertHelper.confirmDestructive(
                            title: "Deactivate License?",
                            message: "This will remove the license from this machine. You can reactivate later.",
                            confirmButton: "Deactivate",
                            cancelButton: "Cancel"
                        )

                        if confirmed {
                            await deactivate()
                        }
                    }
                }
                .disabled(licenseManager.isValidating)
            }
        }
    }

    // MARK: - Unlicensed State

    private var unlicensedSection: some View {
        Section("License") {
            TextField("License Key:", text: $licenseKeyInput)
                .font(.system(.body, design: .monospaced))
                .disableAutocorrection(true)
                .onSubmit { Task { await activate() } }

            HStack {
                Spacer()
                if isActivating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Activate") {
                        Task { await activate() }
                    }
                    .disabled(licenseKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - Helpers

    private func maskedKey(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 5 else { return key }
        let first = String(parts[0])
        let masked = Array(repeating: "*****", count: 4).joined(separator: "-")
        return "\(first)-\(masked)"
    }

    // MARK: - Actions

    private func activate() async {
        isActivating = true
        defer { isActivating = false }

        do {
            try await licenseManager.activate(licenseKey: licenseKeyInput)
            licenseKeyInput = ""
        } catch {
            AlertHelper.showErrorSheet(
                title: "Activation Failed",
                message: error.localizedDescription,
                window: NSApp.keyWindow
            )
        }
    }

    private func deactivate() async {
        do {
            try await licenseManager.deactivate()
        } catch {
            AlertHelper.showErrorSheet(
                title: "Deactivation Failed",
                message: error.localizedDescription,
                window: NSApp.keyWindow
            )
        }
    }
}

#Preview("Unlicensed") {
    LicenseSettingsView()
        .frame(width: 450, height: 300)
}

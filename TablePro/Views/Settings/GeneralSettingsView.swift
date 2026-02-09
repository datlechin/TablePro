//
//  GeneralSettingsView.swift
//  TablePro
//
//  Settings for startup behavior, iCloud sync, and software updates
//

import Sparkle
import SwiftUI

struct GeneralSettingsView: View {
    @Binding var settings: GeneralSettings
    @ObservedObject var updaterBridge: UpdaterBridge
    @StateObject private var syncCoordinator = SyncCoordinator.shared
    @State private var showConflictSheet = false

    private var iCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    var body: some View {
        Form {
            Picker("When TablePro starts:", selection: $settings.startupBehavior) {
                ForEach(StartupBehavior.allCases) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }

            Section("iCloud Sync") {
                Toggle("Sync data across devices", isOn: $settings.iCloudSyncEnabled)
                    .disabled(!iCloudAvailable)

                if settings.iCloudSyncEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Syncs connections, tags, settings, and templates",
                            systemImage: "checkmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Label(
                            "Passwords are stored locally in Keychain and not synced",
                            systemImage: "lock.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 2)

                    if let lastSync = syncCoordinator.lastSyncDate {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.icloud")
                                .foregroundStyle(.green)
                            Text("Last synced \(lastSync, style: .relative) ago")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !syncCoordinator.pendingConflicts.isEmpty {
                        Button {
                            showConflictSheet = true
                        } label: {
                            Label(
                                "Resolve \(syncCoordinator.pendingConflicts.count) conflict(s)",
                                systemImage: "exclamationmark.triangle"
                            )
                        }
                        .foregroundStyle(.orange)
                    }
                }

                if !iCloudAvailable {
                    Label(
                        "Sign in to iCloud in System Settings to enable sync",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Software Update") {
                Toggle("Automatically check for updates", isOn: $settings.automaticallyCheckForUpdates)
                    .onChange(of: settings.automaticallyCheckForUpdates) { newValue in
                        updaterBridge.updater.automaticallyChecksForUpdates = newValue
                    }

                Button("Check for Updates...") {
                    updaterBridge.checkForUpdates()
                }
                .disabled(!updaterBridge.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            updaterBridge.updater.automaticallyChecksForUpdates = settings.automaticallyCheckForUpdates
        }
        .sheet(isPresented: $showConflictSheet) {
            SyncConflictResolutionView(syncCoordinator: syncCoordinator)
        }
    }
}

#Preview {
    GeneralSettingsView(
        settings: .constant(.default),
        updaterBridge: UpdaterBridge()
    )
    .frame(width: 450, height: 400)
}

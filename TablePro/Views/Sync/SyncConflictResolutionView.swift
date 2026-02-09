//
//  SyncConflictResolutionView.swift
//  TablePro
//
//  SwiftUI view for resolving iCloud sync conflicts.
//

import SwiftUI

/// Sheet view for resolving pending sync conflicts
struct SyncConflictResolutionView: View {
    @ObservedObject var syncCoordinator: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)

                Text("Sync Conflicts")
                    .font(.headline)

                Text("Your local data differs from iCloud. Choose which version to keep for each item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()

            Divider()

            // Conflict list
            if syncCoordinator.pendingConflicts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                    Text("All conflicts resolved")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(syncCoordinator.pendingConflicts) { conflict in
                        ConflictRowView(conflict: conflict) { resolution in
                            syncCoordinator.resolveConflict(conflict, resolution: resolution)
                            if syncCoordinator.pendingConflicts.isEmpty {
                                dismiss()
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // Footer
            HStack {
                Button("Keep All Local") {
                    resolveAll(.keepLocal)
                }

                Button("Keep All Remote") {
                    resolveAll(.keepRemote)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(minWidth: 500, maxWidth: 500, minHeight: 350, maxHeight: 500)
    }

    private func resolveAll(_ resolution: ConflictResolution) {
        let conflicts = syncCoordinator.pendingConflicts
        for conflict in conflicts {
            syncCoordinator.resolveConflict(conflict, resolution: resolution)
        }
        dismiss()
    }
}

// MARK: - Conflict Row

private struct ConflictRowView: View {
    let conflict: SyncConflict
    let onResolve: (ConflictResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(.orange)
                Text(conflict.dataType.rawValue)
                    .font(.system(size: 13, weight: .medium))
            }

            Text(conflict.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Keep Local") {
                    onResolve(.keepLocal)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Keep Remote") {
                    onResolve(.keepRemote)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch conflict.dataType {
        case .connections: return "externaldrive.connected.to.line.below"
        case .tags: return "tag"
        case .templates: return "doc.text"
        default: return "gearshape"
        }
    }
}

//
//  ConnectionGroupFormSheet.swift
//  TablePro
//

import SwiftUI

/// Sheet for creating or editing a connection group
struct ConnectionGroupFormSheet: View {
    @Environment(\.dismiss) private var dismiss

    let group: ConnectionGroup?
    let parentGroupId: UUID?
    var onSave: ((ConnectionGroup) -> Void)?

    @State private var name: String = ""
    @State private var color: ConnectionColor = .blue

    init(
        group: ConnectionGroup? = nil,
        parentGroupId: UUID? = nil,
        onSave: ((ConnectionGroup) -> Void)? = nil
    ) {
        self.group = group
        self.parentGroupId = parentGroupId
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(group == nil ? String(localized: "New Group") : String(localized: "Edit Group"))
                .font(.headline)

            TextField(String(localized: "Group name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            VStack(alignment: .leading, spacing: 6) {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                GroupColorPicker(selectedColor: $color)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Button(group == nil ? String(localized: "Create") : String(localized: "Save")) {
                    save()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            if let group {
                name = group.name
                color = group.color
            }
        }
        .onExitCommand {
            dismiss()
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if var existing = group {
            existing.name = trimmedName
            existing.color = color
            onSave?(existing)
        } else {
            let sortOrder = GroupStorage.shared.nextSortOrder(parentId: parentGroupId)
            let newGroup = ConnectionGroup(
                name: trimmedName,
                color: color,
                parentGroupId: parentGroupId,
                sortOrder: sortOrder
            )
            onSave?(newGroup)
        }
        dismiss()
    }
}

// MARK: - Group Color Picker

/// Color picker for groups (excludes "none" option)
private struct GroupColorPicker: View {
    @Binding var selectedColor: ConnectionColor

    private var availableColors: [ConnectionColor] {
        ConnectionColor.allCases.filter { $0 != .none }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(availableColors) { color in
                Circle()
                    .fill(color.color)
                    .frame(width: DesignConstants.IconSize.medium, height: DesignConstants.IconSize.medium)
                    .overlay(
                        Circle()
                            .stroke(Color.primary, lineWidth: selectedColor == color ? 2 : 0)
                            .frame(
                                width: DesignConstants.IconSize.large,
                                height: DesignConstants.IconSize.large
                            )
                    )
                    .onTapGesture {
                        selectedColor = color
                    }
            }
        }
    }
}

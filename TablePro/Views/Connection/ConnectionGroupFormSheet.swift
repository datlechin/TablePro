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
    @State private var selectedParentId: UUID?
    @State private var allGroups: [ConnectionGroup] = []

    private let groupStorage = GroupStorage.shared

    init(
        group: ConnectionGroup? = nil,
        parentGroupId: UUID? = nil,
        onSave: ((ConnectionGroup) -> Void)? = nil
    ) {
        self.group = group
        self.parentGroupId = parentGroupId
        self.onSave = onSave
    }

    /// All groups excluding self and descendants when editing
    private var availableGroups: [ConnectionGroup] {
        guard let editingGroup = group else { return allGroups }
        let excludedIds = groupStorage.collectDescendantIds(of: editingGroup.id, in: allGroups)
            .union([editingGroup.id])
        return allGroups.filter { !excludedIds.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(group == nil ? String(localized: "New Group") : String(localized: "Edit Group"))
                .font(.headline)
                .padding(.top, 20)

            Form {
                Section {
                    TextField(String(localized: "Name"), text: $name, prompt: Text("Group name"))

                    LabeledContent(String(localized: "Color")) {
                        GroupColorPicker(selectedColor: $color)
                    }

                    LabeledContent(String(localized: "Parent Group")) {
                        ParentGroupPicker(
                            selectedParentId: $selectedParentId,
                            allGroups: availableGroups
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(group == nil ? String(localized: "Create") : String(localized: "Save")) {
                    save()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 360)
        .onAppear {
            allGroups = groupStorage.loadGroups()
            if let group {
                name = group.name
                color = group.color
                selectedParentId = group.parentGroupId
            } else {
                selectedParentId = parentGroupId
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
            let originalParentId = existing.parentGroupId
            existing.name = trimmedName
            existing.color = color
            if originalParentId != selectedParentId {
                existing.parentGroupId = selectedParentId
                existing.sortOrder = groupStorage.nextSortOrder(parentId: selectedParentId)
            } else {
                existing.parentGroupId = selectedParentId
            }
            onSave?(existing)
        } else {
            let sortOrder = groupStorage.nextSortOrder(parentId: selectedParentId)
            let newGroup = ConnectionGroup(
                name: trimmedName,
                color: color,
                parentGroupId: selectedParentId,
                sortOrder: sortOrder
            )
            onSave?(newGroup)
        }
        dismiss()
    }

}

// MARK: - Parent Group Picker

/// Menu-based group picker with nested submenus for child groups
private struct ParentGroupPicker: View {
    @Binding var selectedParentId: UUID?
    let allGroups: [ConnectionGroup]

    private var selectedGroup: ConnectionGroup? {
        guard let id = selectedParentId else { return nil }
        return allGroups.first { $0.id == id }
    }

    private func children(of parentId: UUID?) -> [ConnectionGroup] {
        allGroups
            .filter { $0.parentGroupId == parentId }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        Menu {
            Button {
                selectedParentId = nil
            } label: {
                HStack {
                    Text("None")
                    if selectedParentId == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            let rootGroups = children(of: nil)
            if !rootGroups.isEmpty {
                Divider()
            }

            ForEach(rootGroups) { group in
                groupMenuItem(group)
            }
        } label: {
            HStack(spacing: 6) {
                if let group = selectedGroup {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(group.color.color)
                        .font(.system(size: 10))
                    Text(group.name)
                        .foregroundStyle(.primary)
                } else {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func groupMenuItem(_ group: ConnectionGroup) -> AnyView {
        let subgroups = children(of: group.id)
        if subgroups.isEmpty {
            return AnyView(
                Button {
                    selectedParentId = group.id
                } label: {
                    HStack {
                        Image(nsImage: colorDot(group.color.color))
                        Text(group.name)
                        if selectedParentId == group.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            )
        } else {
            return AnyView(
                Menu {
                    Button {
                        selectedParentId = group.id
                    } label: {
                        HStack {
                            Image(nsImage: colorDot(group.color.color))
                            Text(group.name)
                            if selectedParentId == group.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    Divider()

                    ForEach(subgroups) { child in
                        groupMenuItem(child)
                    }
                } label: {
                    HStack {
                        Image(nsImage: colorDot(group.color.color))
                        Text(group.name)
                        if selectedParentId == group.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            )
        }
    }

    private func colorDot(_ color: Color) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
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

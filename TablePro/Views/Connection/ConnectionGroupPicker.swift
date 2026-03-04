//
//  ConnectionGroupPicker.swift
//  TablePro
//

import SwiftUI

/// Group selection dropdown for the connection form
struct ConnectionGroupPicker: View {
    @Binding var selectedGroupId: UUID?
    @State private var allGroups: [ConnectionGroup] = []
    @State private var showingCreateSheet = false

    private let groupStorage = GroupStorage.shared

    private var selectedGroup: ConnectionGroup? {
        guard let id = selectedGroupId else { return nil }
        return groupStorage.group(for: id)
    }

    private func children(of parentId: UUID?) -> [ConnectionGroup] {
        allGroups
            .filter { $0.parentGroupId == parentId }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        Menu {
            Button {
                selectedGroupId = nil
            } label: {
                HStack {
                    Text("None")
                    if selectedGroupId == nil {
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

            Divider()

            Button {
                showingCreateSheet = true
            } label: {
                Label("Create New Group...", systemImage: "plus.circle")
            }

            if !allGroups.isEmpty {
                Divider()

                Menu("Manage Groups") {
                    ForEach(allGroups) { group in
                        Button(role: .destructive) {
                            deleteGroup(group)
                        } label: {
                            Label("Delete \"\(group.name)\"", systemImage: "trash")
                        }
                    }
                }
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
        .task { allGroups = groupStorage.loadGroups() }
        .sheet(isPresented: $showingCreateSheet) {
            ConnectionGroupFormSheet { newGroup in
                groupStorage.addGroup(newGroup)
                selectedGroupId = newGroup.id
                allGroups = groupStorage.loadGroups()
            }
        }
    }

    // MARK: - Helpers

    private func groupMenuItem(_ group: ConnectionGroup) -> AnyView {
        let subgroups = children(of: group.id)
        if subgroups.isEmpty {
            return AnyView(
                Button {
                    selectedGroupId = group.id
                } label: {
                    HStack {
                        Image(nsImage: colorDot(group.color.color))
                        Text(group.name)
                        if selectedGroupId == group.id {
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
                        selectedGroupId = group.id
                    } label: {
                        HStack {
                            Image(nsImage: colorDot(group.color.color))
                            Text(group.name)
                            if selectedGroupId == group.id {
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
                        if selectedGroupId == group.id {
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

    private func deleteGroup(_ group: ConnectionGroup) {
        if selectedGroupId == group.id {
            selectedGroupId = nil
        }
        groupStorage.deleteGroup(group)
        allGroups = groupStorage.loadGroups()
    }
}

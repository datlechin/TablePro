//
//  ConnectionGroupEditor.swift
//  TablePro
//

import SwiftUI

/// Group selection dropdown for the connection form
struct ConnectionGroupEditor: View {
    @Binding var selectedGroupId: UUID?
    @State private var allGroups: [ConnectionGroup] = []
    @State private var showingCreateSheet = false

    private let groupStorage = GroupStorage.shared

    private var selectedGroup: ConnectionGroup? {
        guard let id = selectedGroupId else { return nil }
        return groupStorage.group(for: id)
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

            Divider()

            ForEach(sortedGroupsFlat(), id: \.group.id) { item in
                Button {
                    selectedGroupId = item.group.id
                } label: {
                    HStack {
                        Image(nsImage: colorDot(item.group.color.color))
                        Text("\(item.prefix)\(item.group.name)")
                        if selectedGroupId == item.group.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button {
                showingCreateSheet = true
            } label: {
                Label("Create New Group...", systemImage: "plus.circle")
            }

            if allGroups.contains(where: { _ in true }) {
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

    private struct FlatGroupItem {
        let group: ConnectionGroup
        let prefix: String
    }

    private func sortedGroupsFlat() -> [FlatGroupItem] {
        var result: [FlatGroupItem] = []
        func walk(_ parentId: UUID?, depth: Int) {
            let children = allGroups
                .filter { $0.parentGroupId == parentId }
                .sorted { $0.sortOrder < $1.sortOrder }
            for child in children {
                let prefix = String(repeating: "  ", count: depth)
                result.append(FlatGroupItem(group: child, prefix: prefix))
                walk(child.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        return result
    }

    /// Create a colored circle NSImage for use in menu items
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

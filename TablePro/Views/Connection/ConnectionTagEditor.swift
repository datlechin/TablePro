//
//  ConnectionTagEditor.swift
//  TablePro
//
//  Created by Claude on 20/12/25.
//

import SwiftUI

/// Tag selection for a connection (single tag only)
struct ConnectionTagEditor: View {
    @Binding var selectedTagId: UUID?
    @State private var allTags: [ConnectionTag] = []
    @State private var showingCreateSheet = false

    private let tagStorage = TagStorage.shared

    private var selectedTag: ConnectionTag? {
        guard let id = selectedTagId else { return nil }
        return tagStorage.tag(for: id)
    }

    var body: some View {
        HStack(spacing: 6) {
            // Selected tag or placeholder
            if let tag = selectedTag {
                TagChip(tag: tag, isSelected: true) {
                    selectedTagId = nil
                }
            }

            // Tag picker menu
            Menu {
                // None option
                Button {
                    selectedTagId = nil
                } label: {
                    HStack {
                        Text("None")
                        if selectedTagId == nil {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                // Available tags
                ForEach(allTags) { tag in
                    Button {
                        selectedTagId = tag.id
                    } label: {
                        HStack {
                            Text(tag.name)
                            if tag.isPreset {
                                Text("preset")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if selectedTagId == tag.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                // Create new tag
                Button {
                    showingCreateSheet = true
                } label: {
                    Label("Create New Tag...", systemImage: "plus.circle")
                }

                // Manage tags (delete custom tags)
                if allTags.contains(where: { !$0.isPreset }) {
                    Divider()

                    Menu("Manage Tags") {
                        ForEach(allTags.filter { !$0.isPreset }) { tag in
                            Button(role: .destructive) {
                                deleteTag(tag)
                            } label: {
                                Label("Delete \"\(tag.name)\"", systemImage: "trash")
                            }
                        }
                    }
                }
            } label: {
                if selectedTag == nil {
                    Label("Select tag", systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: DesignConstants.FontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
        }
        .onAppear { allTags = tagStorage.loadTags() }
        .sheet(isPresented: $showingCreateSheet) {
            CreateTagSheet                { tagName, tagColor in
                let tag = ConnectionTag(name: tagName.lowercased(), isPreset: false, color: tagColor)
                tagStorage.addTag(tag)
                selectedTagId = tag.id
                allTags = tagStorage.loadTags()
            }
        }
    }

    private func deleteTag(_ tag: ConnectionTag) {
        // Clear selection if deleting selected tag
        if selectedTagId == tag.id {
            selectedTagId = nil
        }
        tagStorage.deleteTag(tag)
        allTags = tagStorage.loadTags()
    }
}

// MARK: - Tag Chip

struct TagChip: View {
    let tag: ConnectionTag
    let isSelected: Bool
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(tag.name)
                .font(.caption)

            if isSelected, let onRemove = onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: DesignConstants.IconSize.statusDot, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(tag.color.color.opacity(0.2))
        )
        .foregroundStyle(tag.color.color)
    }
}

// MARK: - Create Tag Sheet

private struct CreateTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tagName: String = ""
    @State private var tagColor: ConnectionColor = .gray
    let onSave: (String, ConnectionColor) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Create New Tag")
                .font(.headline)

            TextField("Tag name", text: $tagName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            VStack(alignment: .leading, spacing: 6) {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TagColorPicker(selectedColor: $tagColor)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Create") {
                    onSave(tagName, tagColor)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(tagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

// MARK: - Tag Color Picker

/// Color picker for tags (excludes "none" option)
private struct TagColorPicker: View {
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
                            .frame(width: DesignConstants.IconSize.large, height: DesignConstants.IconSize.large)
                    )
                    .onTapGesture {
                        selectedColor = color
                    }
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var tagId: UUID?

        var body: some View {
            VStack(spacing: 20) {
                ConnectionTagEditor(selectedTagId: $tagId)
                Text("Selected: \(tagId?.uuidString ?? "none")")
            }
            .padding()
            .frame(width: 400)
        }
    }

    return PreviewWrapper()
}

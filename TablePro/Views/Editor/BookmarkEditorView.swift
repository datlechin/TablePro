//
//  BookmarkEditorView.swift
//  TablePro
//
//  Native SwiftUI form for creating/editing bookmarks
//

import SwiftUI

struct BookmarkEditorView: View {
    // MARK: - Properties

    @Environment(\.dismiss) private var dismiss

    private let bookmark: QueryBookmark?
    private let query: String
    private let connectionId: UUID?
    private let isEditing: Bool
    private let onSave: (QueryBookmark) -> Void

    @State private var name: String
    @State private var tags: String
    @State private var notes: String
    @State private var showingValidationAlert = false

    @FocusState private var focusedField: Field?

    private enum Field {
        case name, tags, notes
    }

    // MARK: - Initialization

    init(bookmark: QueryBookmark? = nil, query: String, connectionId: UUID?, onSave: @escaping (QueryBookmark) -> Void) {
        self.bookmark = bookmark
        self.query = query
        self.connectionId = connectionId
        self.isEditing = bookmark != nil
        self.onSave = onSave

        // Initialize state from bookmark
        _name = State(initialValue: bookmark?.name ?? "")
        _tags = State(initialValue: bookmark?.formattedTags ?? "")
        _notes = State(initialValue: bookmark?.notes ?? "")
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Content area with form fields
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Name field
                    FormRow(label: "Name") {
                        TextField("Bookmark name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .name)
                            .submitLabel(.done)
                    }

                    // SQL Query (read-only preview)
                    FormRow(label: "Query") {
                        ScrollView {
                            Text(query)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .frame(height: 90)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                    }

                    // Tags field
                    FormRow(label: "Tags") {
                        TextField("e.g., reports, analytics, daily", text: $tags)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .tags)
                            .submitLabel(.done)
                    }

                    // Notes field
                    FormRow(label: "Notes") {
                        TextEditor(text: $notes)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .frame(height: 70)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                            .focused($focusedField, equals: .notes)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer with buttons
            HStack(spacing: 12) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button(isEditing ? "Save" : "Save Bookmark") {
                    saveBookmark()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 520, height: 350)
        .onAppear {
            focusedField = .name
        }
        .alert("Name Required", isPresented: $showingValidationAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please enter a name for this bookmark.")
        }
    }

    // MARK: - Actions

    private func saveBookmark() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            showingValidationAlert = true
            return
        }

        let parsedTags = QueryBookmark.parseTags(tags)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        let savedBookmark: QueryBookmark
        if let existing = bookmark {
            savedBookmark = QueryBookmark(
                id: existing.id,
                name: trimmedName,
                query: query,
                connectionId: connectionId,
                tags: parsedTags,
                createdAt: existing.createdAt,
                lastUsedAt: existing.lastUsedAt,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
        } else {
            savedBookmark = QueryBookmark(
                name: trimmedName,
                query: query,
                connectionId: connectionId,
                tags: parsedTags,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
        }

        onSave(savedBookmark)
        dismiss()
    }
}

// MARK: - Helper Views

/// Generic form row with label and content (AppKit-style)
private struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label + ":")
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            content
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Preview

#Preview {
    BookmarkEditorView(
        query: "SELECT * FROM users WHERE created_at > NOW() - INTERVAL 7 DAY",
        connectionId: nil as UUID?
    )           { _ in }
}

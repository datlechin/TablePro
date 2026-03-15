//
//  FavoriteEditDialog.swift
//  TablePro
//

import SwiftUI

/// Dialog for creating or editing a SQL favorite
struct FavoriteEditDialog: View {
    @Environment(\.dismiss) private var dismiss

    let connectionId: UUID
    let favorite: SQLFavorite?
    let initialQuery: String?
    let folderId: UUID?
    let forceGlobal: Bool

    @State private var name: String = ""
    @State private var query: String = ""
    @State private var keyword: String = ""
    @State private var isGlobal: Bool = true
    @State private var keywordError: String?
    @State private var isSaving = false

    private var isEditing: Bool { favorite != nil }
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            !query.trimmingCharacters(in: .whitespaces).isEmpty &&
            keywordError == nil
    }

    /// Maximum query size (500KB, matching PersistedTab pattern)
    private static let maxQuerySize = 500_000

    init(
        connectionId: UUID,
        favorite: SQLFavorite? = nil,
        initialQuery: String? = nil,
        folderId: UUID? = nil,
        forceGlobal: Bool = false
    ) {
        self.connectionId = connectionId
        self.favorite = favorite
        self.initialQuery = initialQuery
        self.folderId = folderId
        self.forceGlobal = forceGlobal
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Favorite" : "Save as Favorite")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Form
            Form {
                TextField(String(localized: "Name"), text: $name)

                TextField(String(localized: "Keyword (optional)"), text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: keyword) { _, newValue in
                        validateKeyword(newValue)
                    }

                if let error = keywordError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Query")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $query)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .border(Color(nsColor: .separatorColor))
                }

                if !forceGlobal {
                    Toggle(String(localized: "Global (visible in all connections)"), isOn: $isGlobal)
                }
            }
            .padding()

            Divider()

            // Buttons
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing ? String(localized: "Save") : String(localized: "Add")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSaving)
            }
            .padding()
        }
        .frame(width: 480, height: 420)
        .onAppear {
            if let fav = favorite {
                name = fav.name
                query = fav.query
                keyword = fav.keyword ?? ""
                isGlobal = forceGlobal || fav.connectionId == nil
            } else {
                isGlobal = forceGlobal || true
                if let q = initialQuery {
                    query = q
                }
            }
        }
    }

    // MARK: - Validation

    private func validateKeyword(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            keywordError = nil
            return
        }
        if trimmed.contains(" ") {
            keywordError = String(localized: "Keyword cannot contain spaces")
            return
        }
        Task { @MainActor in
            let scopeConnectionId = isGlobal ? nil : connectionId
            let available = await SQLFavoriteManager.shared.isKeywordAvailable(
                trimmed,
                connectionId: scopeConnectionId,
                excludingFavoriteId: favorite?.id
            )
            if !available {
                keywordError = String(localized: "This keyword is already in use")
            } else {
                let sqlKeywords: Set<String> = [
                    "select", "from", "where", "insert", "update", "delete",
                    "create", "drop", "alter", "join", "on", "and", "or",
                    "not", "in", "like", "between", "order", "group", "having",
                    "limit", "set", "values", "into", "as", "is", "null",
                    "true", "false", "case", "when", "then", "else", "end"
                ]
                if sqlKeywords.contains(trimmed.lowercased()) {
                    keywordError = String(
                        localized: "Warning: this shadows the SQL keyword '\(trimmed.uppercased())'"
                    )
                } else {
                    keywordError = nil
                }
            }
        }
    }

    // MARK: - Save

    private func save() {
        isSaving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespaces)
        let trimmedQuery: String
        if (query as NSString).length > Self.maxQuerySize {
            trimmedQuery = String(query.prefix(Self.maxQuerySize))
        } else {
            trimmedQuery = query
        }

        let scopeConnectionId = isGlobal ? nil : connectionId
        let keywordValue = trimmedKeyword.isEmpty ? nil : trimmedKeyword

        Task { @MainActor in
            if let existing = favorite {
                var updated = existing
                updated.name = trimmedName
                updated.query = trimmedQuery
                updated.keyword = keywordValue
                updated.connectionId = scopeConnectionId
                updated.updatedAt = Date()
                _ = await SQLFavoriteManager.shared.updateFavorite(updated)
            } else {
                let newFavorite = SQLFavorite(
                    name: trimmedName,
                    query: trimmedQuery,
                    keyword: keywordValue,
                    folderId: folderId,
                    connectionId: scopeConnectionId
                )
                _ = await SQLFavoriteManager.shared.addFavorite(newFavorite)
            }
            dismiss()
        }
    }
}

//
//  QueryBookmark.swift
//  TablePro
//
//  Query bookmark model for saved queries
//

import Foundation

/// Represents a saved query bookmark
struct QueryBookmark: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let query: String
    var connectionId: UUID?  // Optional - can be used across connections
    var tags: [String]
    let createdAt: Date
    var lastUsedAt: Date?
    var notes: String?

    init(
        id: UUID = UUID(),
        name: String,
        query: String,
        connectionId: UUID? = nil,
        tags: [String] = [],
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.connectionId = connectionId
        self.tags = tags
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.notes = notes
    }

    /// Formatted tags for display (comma-separated)
    var formattedTags: String {
        tags.joined(separator: ", ")
    }

    /// Has tags
    var hasTags: Bool {
        !tags.isEmpty
    }

    /// Parse comma-separated tag string into array
    static func parseTags(_ tagString: String) -> [String] {
        tagString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

//
//  QueryHistoryManager.swift
//  OpenTable
//
//  Thread-safe coordinator for query history and bookmarks
//  Communicates via NotificationCenter (NOT ObservableObject)
//

import Foundation

/// Notification names for query history updates
extension Notification.Name {
    static let queryHistoryDidUpdate = Notification.Name("queryHistoryDidUpdate")
    static let queryBookmarksDidUpdate = Notification.Name("queryBookmarksDidUpdate")
    static let loadQueryIntoEditor = Notification.Name("loadQueryIntoEditor")
}

/// Thread-safe manager for query history and bookmarks
/// NOT an ObservableObject - uses NotificationCenter for UI communication
final class QueryHistoryManager {
    static let shared = QueryHistoryManager()
    
    private let storage = QueryHistoryStorage.shared
    
    private init() {
        // Perform cleanup on initialization (app launch)
        storage.cleanup()
    }
    
    // MARK: - History Capture
    
    /// Record a query execution (non-blocking background write)
    func recordQuery(
        query: String,
        connectionId: UUID,
        databaseName: String,
        executionTime: TimeInterval,
        rowCount: Int,
        wasSuccessful: Bool,
        errorMessage: String? = nil
    ) {
        let entry = QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: databaseName,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful,
            errorMessage: errorMessage
        )
        
        // Background write (non-blocking)
        storage.addHistory(entry) { success in
            if success {
                // Notify UI to refresh on main thread
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .queryHistoryDidUpdate,
                        object: nil
                    )
                }
            }
        }
    }
    
    // MARK: - History Retrieval
    
    /// Fetch history entries (synchronous - safe for UI)
    func fetchHistory(
        limit: Int = 100,
        offset: Int = 0,
        connectionId: UUID? = nil,
        searchText: String? = nil,
        dateFilter: DateFilter = .all
    ) -> [QueryHistoryEntry] {
        return storage.fetchHistory(
            limit: limit,
            offset: offset,
            connectionId: connectionId,
            searchText: searchText,
            dateFilter: dateFilter
        )
    }
    
    /// Search queries using FTS5 full-text search
    func searchQueries(_ text: String) -> [QueryHistoryEntry] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return fetchHistory()
        }
        return storage.fetchHistory(searchText: text)
    }
    
    /// Delete a history entry
    func deleteHistory(id: UUID) -> Bool {
        let success = storage.deleteHistory(id: id)
        if success {
            NotificationCenter.default.post(name: .queryHistoryDidUpdate, object: nil)
        }
        return success
    }
    
    /// Get total history count
    func getHistoryCount() -> Int {
        return storage.getHistoryCount()
    }
    
    // MARK: - Bookmarks
    
    /// Save a new bookmark
    func saveBookmark(
        name: String,
        query: String,
        connectionId: UUID? = nil,
        tags: [String] = [],
        notes: String? = nil
    ) -> Bool {
        let bookmark = QueryBookmark(
            name: name,
            query: query,
            connectionId: connectionId,
            tags: tags,
            notes: notes
        )
        
        let success = storage.addBookmark(bookmark)
        if success {
            NotificationCenter.default.post(name: .queryBookmarksDidUpdate, object: nil)
        }
        return success
    }
    
    /// Save bookmark from history entry
    func saveBookmarkFromHistory(_ entry: QueryHistoryEntry, name: String) -> Bool {
        return saveBookmark(
            name: name,
            query: entry.query,
            connectionId: entry.connectionId
        )
    }
    
    /// Update an existing bookmark
    func updateBookmark(_ bookmark: QueryBookmark) -> Bool {
        let success = storage.updateBookmark(bookmark)
        if success {
            NotificationCenter.default.post(name: .queryBookmarksDidUpdate, object: nil)
        }
        return success
    }
    
    /// Update bookmark's last used timestamp
    func markBookmarkUsed(id: UUID) {
        if var bookmark = fetchBookmarks().first(where: { $0.id == id }) {
            bookmark.lastUsedAt = Date()
            _ = storage.updateBookmark(bookmark)
        }
    }
    
    /// Fetch bookmarks with optional filters
    func fetchBookmarks(searchText: String? = nil, tag: String? = nil) -> [QueryBookmark] {
        return storage.fetchBookmarks(searchText: searchText, tag: tag)
    }
    
    /// Delete a bookmark
    func deleteBookmark(id: UUID) -> Bool {
        let success = storage.deleteBookmark(id: id)
        if success {
            NotificationCenter.default.post(name: .queryBookmarksDidUpdate, object: nil)
        }
        return success
    }
    
    // MARK: - Cleanup
    
    /// Manually trigger cleanup (normally runs automatically)
    func cleanup() {
        storage.cleanup()
    }
}

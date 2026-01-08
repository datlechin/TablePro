//
//  HistoryDataProvider.swift
//  TablePro
//
//  Data provider for history and bookmark entries.
//  Extracted from HistoryListViewController for better separation of concerns.
//

import Foundation

/// Data provider for history and bookmark entries
final class HistoryDataProvider {
    // MARK: - Properties

    private(set) var historyEntries: [QueryHistoryEntry] = []
    private(set) var bookmarks: [QueryBookmark] = []

    var displayMode: HistoryDisplayMode = .history
    var dateFilter: UIDateFilter = .all
    var searchText: String = ""

    private var searchTask: DispatchWorkItem?
    private let searchDebounceInterval: TimeInterval = 0.15

    /// Callback when data changes
    var onDataChanged: (() -> Void)?

    // MARK: - Computed Properties

    var count: Int {
        switch displayMode {
        case .history:
            return historyEntries.count
        case .bookmarks:
            return bookmarks.count
        }
    }

    var isEmpty: Bool {
        isEmpty
    }

    // MARK: - Data Loading

    func loadData() {
        switch displayMode {
        case .history:
            loadHistory()
        case .bookmarks:
            loadBookmarks()
        }
    }

    private func loadHistory() {
        historyEntries = QueryHistoryManager.shared.fetchHistory(
            limit: 500,
            offset: 0,
            connectionId: nil,
            searchText: searchText.isEmpty ? nil : searchText,
            dateFilter: dateFilter.toDateFilter
        )
    }

    private func loadBookmarks() {
        bookmarks = QueryHistoryManager.shared.fetchBookmarks(
            searchText: searchText.isEmpty ? nil : searchText,
            tag: nil
        )
    }

    // MARK: - Search

    func scheduleSearch(completion: @escaping () -> Void) {
        searchTask?.cancel()

        let task = DispatchWorkItem { [weak self] in
            self?.loadData()
            completion()
        }
        searchTask = task

        DispatchQueue.main.asyncAfter(deadline: .now() + searchDebounceInterval, execute: task)
    }

    // MARK: - Item Access

    func historyEntry(at index: Int) -> QueryHistoryEntry? {
        guard index >= 0 && index < historyEntries.count else { return nil }
        return historyEntries[index]
    }

    func bookmark(at index: Int) -> QueryBookmark? {
        guard index >= 0 && index < bookmarks.count else { return nil }
        return bookmarks[index]
    }

    func query(at index: Int) -> String? {
        switch displayMode {
        case .history:
            return historyEntry(at: index)?.query
        case .bookmarks:
            return bookmark(at: index)?.query
        }
    }

    // MARK: - Deletion

    func deleteItem(at index: Int) -> Bool {
        switch displayMode {
        case .history:
            guard let entry = historyEntry(at: index) else { return false }
            QueryHistoryManager.shared.deleteHistory(id: entry.id)
            return true
        case .bookmarks:
            guard let bookmark = bookmark(at: index) else { return false }
            QueryHistoryManager.shared.deleteBookmark(id: bookmark.id)
            return true
        }
    }

    func clearAll() -> Bool {
        switch displayMode {
        case .history:
            return QueryHistoryManager.shared.clearAllHistory()
        case .bookmarks:
            return QueryHistoryManager.shared.clearAllBookmarks()
        }
    }

    // MARK: - Bookmark Operations

    func markBookmarkUsed(at index: Int) {
        guard displayMode == .bookmarks,
              let bookmark = bookmark(at: index) else { return }
        QueryHistoryManager.shared.markBookmarkUsed(id: bookmark.id)
    }
}

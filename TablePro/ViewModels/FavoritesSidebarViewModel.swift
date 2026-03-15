//
//  FavoritesSidebarViewModel.swift
//  TablePro
//

import Foundation
import Observation

/// Tree node for displaying favorites and folders in a hierarchy
enum FavoriteTreeItem: Identifiable, Hashable {
    case folder(SQLFavoriteFolder, children: [FavoriteTreeItem])
    case favorite(SQLFavorite)

    var id: String {
        switch self {
        case .folder(let folder, _): return "folder-\(folder.id)"
        case .favorite(let fav): return "fav-\(fav.id)"
        }
    }
}

/// ViewModel for the favorites sidebar section
@MainActor @Observable
final class FavoritesSidebarViewModel {
    // MARK: - State

    var treeItems: [FavoriteTreeItem] = []
    var isLoading = false
    var showEditDialog = false
    var editingFavorite: SQLFavorite?
    var editingQuery: String?
    var editingFolderId: UUID?

    var isFavoritesExpanded: Bool = {
        let key = "sidebar.isFavoritesExpanded"
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return true
    }() {
        didSet { UserDefaults.standard.set(isFavoritesExpanded, forKey: "sidebar.isFavoritesExpanded") }
    }

    // MARK: - Dependencies

    private let connectionId: UUID
    private let manager = SQLFavoriteManager.shared
    @ObservationIgnored private var notificationObserver: NSObjectProtocol?

    init(connectionId: UUID) {
        self.connectionId = connectionId

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .sqlFavoritesDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.loadFavorites()
            }
        }
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Loading

    func loadFavorites() async {
        isLoading = true
        defer { isLoading = false }

        async let favoritesResult = manager.fetchFavorites(connectionId: connectionId)
        async let foldersResult = manager.fetchFolders(connectionId: connectionId)

        let favorites = await favoritesResult
        let folders = await foldersResult

        treeItems = buildTree(folders: folders, favorites: favorites, parentId: nil)
    }

    // MARK: - Tree Building

    private func buildTree(
        folders: [SQLFavoriteFolder],
        favorites: [SQLFavorite],
        parentId: UUID?
    ) -> [FavoriteTreeItem] {
        var items: [FavoriteTreeItem] = []

        let levelFolders = folders
            .filter { $0.parentId == parentId }
            .sorted { $0.sortOrder < $1.sortOrder }

        for folder in levelFolders {
            let children = buildTree(folders: folders, favorites: favorites, parentId: folder.id)
            items.append(.folder(folder, children: children))
        }

        let levelFavorites = favorites
            .filter { $0.folderId == parentId }
            .sorted { $0.sortOrder < $1.sortOrder }

        for fav in levelFavorites {
            items.append(.favorite(fav))
        }

        return items
    }

    // MARK: - Actions

    func createFavorite(query: String? = nil, folderId: UUID? = nil) {
        editingFavorite = nil
        editingQuery = query
        editingFolderId = folderId
        showEditDialog = true
    }

    func editFavorite(_ favorite: SQLFavorite) {
        editingFavorite = favorite
        editingQuery = nil
        showEditDialog = true
    }

    func deleteFavorite(_ favorite: SQLFavorite) {
        Task {
            _ = await manager.deleteFavorite(id: favorite.id)
        }
    }

    func createFolder(parentId: UUID? = nil) {
        Task {
            let folder = SQLFavoriteFolder(
                name: String(localized: "New Folder"),
                parentId: parentId,
                connectionId: connectionId
            )
            _ = await manager.addFolder(folder)
        }
    }

    func deleteFolder(_ folder: SQLFavoriteFolder) {
        Task {
            _ = await manager.deleteFolder(id: folder.id)
        }
    }

    func renameFolder(_ folder: SQLFavoriteFolder, to newName: String) {
        Task {
            var updated = folder
            updated.name = newName
            updated.updatedAt = Date()
            _ = await manager.updateFolder(updated)
        }
    }

    // MARK: - Filtering

    func filteredItems(searchText: String) -> [FavoriteTreeItem] {
        guard !searchText.isEmpty else { return treeItems }
        return filterTree(treeItems, searchText: searchText)
    }

    private func filterTree(_ items: [FavoriteTreeItem], searchText: String) -> [FavoriteTreeItem] {
        items.compactMap { item in
            switch item {
            case .favorite(let fav):
                if fav.name.localizedCaseInsensitiveContains(searchText) ||
                    (fav.keyword?.localizedCaseInsensitiveContains(searchText) == true) {
                    return item
                }
                return nil
            case .folder(let folder, let children):
                let filteredChildren = filterTree(children, searchText: searchText)
                if !filteredChildren.isEmpty ||
                    folder.name.localizedCaseInsensitiveContains(searchText) {
                    return .folder(folder, children: filteredChildren)
                }
                return nil
            }
        }
    }
}

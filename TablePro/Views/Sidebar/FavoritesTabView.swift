//
//  FavoritesTabView.swift
//  TablePro
//
//  Full-tab view for SQL favorites in the sidebar.
//

import SwiftUI

/// Full-tab favorites view with folder hierarchy and bottom toolbar
struct FavoritesTabView: View {
    @State private var viewModel: FavoritesSidebarViewModel
    @State private var selectedFavoriteIds: Set<String> = []
    @State private var folderToDelete: SQLFavoriteFolder?
    @State private var showDeleteFolderAlert = false
    let searchText: String
    private weak var coordinator: MainContentCoordinator?

    init(connectionId: UUID, searchText: String, coordinator: MainContentCoordinator?) {
        _viewModel = State(wrappedValue: FavoritesSidebarViewModel(connectionId: connectionId))
        self.searchText = searchText
        self.coordinator = coordinator
    }

    var body: some View {
        Group {
            let items = viewModel.filteredItems(searchText: searchText)

            if viewModel.treeItems.isEmpty && searchText.isEmpty && !viewModel.isLoading {
                emptyState
            } else if items.isEmpty {
                noMatchState
            } else {
                favoritesList(items)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                bottomToolbar
            }
        }
        .onAppear {
            Task { await viewModel.loadFavorites() }
        }
        .sheet(isPresented: $viewModel.showEditDialog) {
            FavoriteEditDialog(
                connectionId: coordinator?.connectionId ?? UUID(),
                favorite: viewModel.editingFavorite,
                initialQuery: viewModel.editingQuery,
                folderId: viewModel.editingFolderId
            )
        }
        .alert(
            String(localized: "Delete Folder?"),
            isPresented: $showDeleteFolderAlert,
            presenting: folderToDelete
        ) { folder in
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Delete"), role: .destructive) {
                viewModel.deleteFolder(folder)
            }
        } message: { folder in
            Text("The folder \"\(folder.name)\" will be deleted. Items inside will be moved to the parent level.")
        }
    }

    // MARK: - List

    private func favoritesList(_ items: [FavoriteTreeItem]) -> some View {
        List(selection: $selectedFavoriteIds) {
            ForEach(items) { item in
                FavoriteTreeItemRow(
                    item: item,
                    viewModel: viewModel,
                    coordinator: coordinator,
                    onDeleteFolder: { folder in
                        folderToDelete = folder
                        showDeleteFolderAlert = true
                    }
                )
                .tag(item.id)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            deleteSelectedFavorites()
        }
        .contextMenu {
            if !selectedFavoriteIds.isEmpty {
                Button(role: .destructive) {
                    deleteSelectedFavorites()
                } label: {
                    Label(String(localized: "Delete Selected"), systemImage: "trash")
                }
            }
        }
    }

    private func deleteSelectedFavorites() {
        let allFavorites = collectFavorites(from: viewModel.treeItems)
        let toDelete = allFavorites.filter { selectedFavoriteIds.contains("fav-\($0.id)") }
        for fav in toDelete {
            viewModel.deleteFavorite(fav)
        }
        selectedFavoriteIds.removeAll()
    }

    private func collectFavorites(from items: [FavoriteTreeItem]) -> [SQLFavorite] {
        var result: [SQLFavorite] = []
        for item in items {
            switch item {
            case .favorite(let fav):
                result.append(fav)
            case .folder(_, let children):
                result.append(contentsOf: collectFavorites(from: children))
            }
        }
        return result
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "star")
                .font(.system(size: 28, weight: .thin))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text("No Favorites")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            Text("Save frequently used queries\nfor quick access.")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .multilineTextAlignment(.center)

            Button {
                viewModel.createFavorite()
            } label: {
                Label(String(localized: "New Favorite"), systemImage: "plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .thin))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text("No Matching Favorites")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.createFavorite()
            } label: {
                Label(String(localized: "New Favorite"), systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            Spacer()

            Button {
                viewModel.createFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Recursive Tree Item View

struct FavoriteTreeItemRow: View {
    let item: FavoriteTreeItem
    let viewModel: FavoritesSidebarViewModel
    weak var coordinator: MainContentCoordinator?
    var onDeleteFolder: ((SQLFavoriteFolder) -> Void)?
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        switch item {
        case .favorite(let favorite):
            FavoriteRowView(favorite: favorite)
                .overlay {
                    DoubleClickDetector {
                        coordinator?.insertFavorite(favorite)
                    }
                }
                .contextMenu {
                    FavoriteItemContextMenu(
                        favorite: favorite,
                        viewModel: viewModel,
                        coordinator: coordinator
                    )
                }
        case .folder(let folder, let children):
            DisclosureGroup(isExpanded: Binding(
                get: { viewModel.expandedFolderIds.contains(folder.id) },
                set: { isExpanded in
                    if isExpanded {
                        viewModel.expandedFolderIds.insert(folder.id)
                    } else {
                        viewModel.expandedFolderIds.remove(folder.id)
                    }
                }
            )) {
                ForEach(children) { child in
                    FavoriteTreeItemRow(
                        item: child,
                        viewModel: viewModel,
                        coordinator: coordinator,
                        onDeleteFolder: onDeleteFolder
                    )
                    .tag(child.id)
                }
            } label: {
                if viewModel.renamingFolderId == folder.id {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        TextField(
                            "",
                            text: Binding(
                                get: { viewModel.renamingFolderName },
                                set: { viewModel.renamingFolderName = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .focused($isRenameFocused)
                        .onSubmit {
                            viewModel.commitRenameFolder(folder)
                        }
                        .onExitCommand {
                            viewModel.renamingFolderId = nil
                        }
                        .onAppear {
                            isRenameFocused = true
                        }
                    }
                } else {
                    Label(folder.name, systemImage: "folder")
                        .contextMenu {
                            FolderContextMenu(
                                folder: folder,
                                viewModel: viewModel,
                                onDelete: onDeleteFolder ?? { _ in }
                            )
                        }
                }
            }
        }
    }
}

// MARK: - Context Menus

private struct FavoriteItemContextMenu: View {
    let favorite: SQLFavorite
    let viewModel: FavoritesSidebarViewModel
    weak var coordinator: MainContentCoordinator?

    var body: some View {
        Button(String(localized: "Edit...")) {
            viewModel.editFavorite(favorite)
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(favorite.query, forType: .string)
        } label: {
            Label(String(localized: "Copy Query"), systemImage: "doc.on.doc")
        }

        Button {
            coordinator?.insertFavorite(favorite)
        } label: {
            Label(String(localized: "Insert in Editor"), systemImage: "text.insert")
        }

        Button {
            coordinator?.runFavoriteInNewTab(favorite)
        } label: {
            Label(String(localized: "Run in New Tab"), systemImage: "play")
        }

        Divider()

        Button(role: .destructive) {
            viewModel.deleteFavorite(favorite)
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
    }
}

private struct FolderContextMenu: View {
    let folder: SQLFavoriteFolder
    let viewModel: FavoritesSidebarViewModel
    var onDelete: (SQLFavoriteFolder) -> Void

    var body: some View {
        Button(String(localized: "Rename")) {
            viewModel.startRenameFolder(folder)
        }

        Button(String(localized: "New Favorite...")) {
            viewModel.createFavorite(folderId: folder.id)
        }

        Button(String(localized: "New Subfolder")) {
            viewModel.createFolder(parentId: folder.id)
        }

        Divider()

        Button(role: .destructive) {
            onDelete(folder)
        } label: {
            Label(String(localized: "Delete Folder"), systemImage: "trash")
        }
    }
}

//
//  FavoritesSidebarSection.swift
//  TablePro
//

import SwiftUI

/// Sidebar section displaying SQL favorites organized in folders
struct FavoritesSidebarSection: View {
    @State private var viewModel: FavoritesSidebarViewModel
    let searchText: String
    private weak var coordinator: MainContentCoordinator?

    init(connectionId: UUID, searchText: String, coordinator: MainContentCoordinator?) {
        _viewModel = State(wrappedValue: FavoritesSidebarViewModel(connectionId: connectionId))
        self.searchText = searchText
        self.coordinator = coordinator
    }

    var body: some View {
        Section(isExpanded: $viewModel.isFavoritesExpanded) {
            let items = viewModel.filteredItems(searchText: searchText)
            if items.isEmpty {
                Text("No favorites")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(items) { item in
                    favoriteTreeItemView(item)
                }
            }
        } header: {
            HStack {
                Text("Favorites")
                Spacer()
                Button {
                    viewModel.createFavorite()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
            .contextMenu {
                Button("New Favorite...") {
                    viewModel.createFavorite()
                }
                Button("New Folder") {
                    viewModel.createFolder()
                }
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
    }

    // MARK: - Tree Item Views

    @ViewBuilder
    private func favoriteTreeItemView(_ item: FavoriteTreeItem) -> some View {
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
            DisclosureGroup {
                ForEach(children) { child in
                    favoriteTreeItemView(child)
                }
            } label: {
                Label(folder.name, systemImage: "folder")
                    .contextMenu {
                        FolderContextMenu(
                            folder: folder,
                            viewModel: viewModel
                        )
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
        Button("Edit...") {
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

    var body: some View {
        Button("New Favorite...") {
            viewModel.createFavorite(folderId: folder.id)
        }

        Button("New Subfolder") {
            viewModel.createFolder(parentId: folder.id)
        }

        Divider()

        Button(role: .destructive) {
            viewModel.deleteFolder(folder)
        } label: {
            Label(String(localized: "Delete Folder"), systemImage: "trash")
        }
    }
}

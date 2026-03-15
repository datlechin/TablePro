//
//  MainContentCoordinator+Favorites.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// Insert a favorite's query into the current editor tab
    func insertFavorite(_ favorite: SQLFavorite) {
        guard let tabIndex = tabManager.selectedTabIndex else { return }
        tabManager.tabs[tabIndex].query = favorite.query
    }

    /// Open a favorite's query in a new tab
    func runFavoriteInNewTab(_ favorite: SQLFavorite) {
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            databaseName: connection.database,
            initialQuery: favorite.query
        )
        WindowOpener.shared.openNativeTab(payload)
    }
}

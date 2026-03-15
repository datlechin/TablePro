//
//  MainContentCoordinator+Favorites.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// Insert a favorite's query into the current editor tab.
    /// If the current tab is not a query tab, opens a new query tab instead.
    func insertFavorite(_ favorite: SQLFavorite) {
        if let tabIndex = tabManager.selectedTabIndex,
           tabManager.tabs[tabIndex].tabType == .query {
            tabManager.tabs[tabIndex].query = favorite.query
        } else {
            runFavoriteInNewTab(favorite)
        }
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

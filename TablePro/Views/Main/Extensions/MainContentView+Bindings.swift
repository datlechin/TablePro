//
//  MainContentView+Bindings.swift
//  TablePro
//
//  Extension containing computed bindings for MainContentView.
//  Extracted to reduce main view complexity.
//

import SwiftUI

extension MainContentView {
    // MARK: - Selected Row Data for Sidebar

    /// Compute selected row data for right sidebar display
    var selectedRowDataForSidebar: [(column: String, value: String?, type: String)]? {
        guard let tab = coordinator.tabManager.selectedTab,
              !selectedRowIndices.isEmpty,
              let firstIndex = selectedRowIndices.min(),
              firstIndex < tab.resultRows.count else { return nil }

        let row = tab.resultRows[firstIndex]
        var data: [(column: String, value: String?, type: String)] = []

        for (i, col) in tab.resultColumns.enumerated() {
            let value = i < row.values.count ? row.values[i] : nil
            let type = "string"  // Can be enhanced with actual column type info
            data.append((column: col, value: value, type: type))
        }

        return data
    }

    // MARK: - Sort State Binding

    /// Binding for the current tab's sort state
    var sortStateBinding: Binding<SortState> {
        Binding(
            get: {
                guard let tab = coordinator.tabManager.selectedTab else {
                    return SortState()
                }
                return tab.sortState
            },
            set: { newValue in
                if let index = coordinator.tabManager.selectedTabIndex {
                    coordinator.tabManager.tabs[index].sortState = newValue
                }
            }
        )
    }

    // MARK: - Show Structure Binding

    /// Binding for showStructure state
    var showStructureBinding: Binding<Bool> {
        Binding(
            get: { coordinator.tabManager.selectedTab?.showStructure ?? false },
            set: { newValue in
                if let index = coordinator.tabManager.selectedTabIndex {
                    coordinator.tabManager.tabs[index].showStructure = newValue
                }
            }
        )
    }

    // MARK: - Current Tab Accessor

    /// Current selected tab for convenience
    var currentTab: QueryTab? {
        coordinator.tabManager.selectedTab
    }
}

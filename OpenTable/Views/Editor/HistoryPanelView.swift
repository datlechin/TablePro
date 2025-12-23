//
//  HistoryPanelView.swift
//  OpenTable
//
//  SwiftUI wrapper for HistoryPanelController
//

import SwiftUI
import AppKit

/// SwiftUI wrapper for the history/bookmark panel
struct HistoryPanelView: NSViewControllerRepresentable {

    func makeNSViewController(context: Context) -> HistoryPanelController {
        return HistoryPanelController()
    }

    func updateNSViewController(_ nsViewController: HistoryPanelController, context: Context) {
        // No dynamic updates needed
    }
}

#if DEBUG
struct HistoryPanelView_Previews: PreviewProvider {
    static var previews: some View {
        HistoryPanelView()
            .frame(width: 600, height: 300)
    }
}
#endif

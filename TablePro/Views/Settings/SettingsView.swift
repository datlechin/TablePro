//
//  SettingsView.swift
//  TablePro
//
//  Main settings view using macOS native TabView style
//

import SwiftUI

/// Main settings view with tab-based navigation (macOS Settings style)
struct SettingsView: View {
    @StateObject private var settingsManager = AppSettingsManager.shared

    var body: some View {
        TabView {
            GeneralSettingsView(settings: $settingsManager.general)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            AppearanceSettingsView(settings: $settingsManager.appearance)
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            EditorSettingsView(settings: $settingsManager.editor)
                .tabItem {
                    Label("Editor", systemImage: "doc.text")
                }

            DataGridSettingsView(settings: $settingsManager.dataGrid)
                .tabItem {
                    Label("Data Grid", systemImage: "tablecells")
                }

            HistorySettingsView(settings: $settingsManager.history)
                .tabItem {
                    Label("History", systemImage: "clock")
                }

            LicenseSettingsView()
                .tabItem {
                    Label("License", systemImage: "key")
                }
        }
        .frame(width: 500, height: 400)
    }
}

#Preview {
    SettingsView()
}

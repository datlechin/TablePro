//
//  SettingsView.swift
//  TablePro
//
//  Main settings view using macOS native TabView style
//

import SwiftUI

/// Settings tab identifiers for programmatic navigation
enum SettingsTab: String {
    case general, appearance, editor, dataGrid, keyboard, history, ai, plugins, sync, license

    var preferredSize: CGSize {
        switch self {
        case .general:    CGSize(width: 450, height: 380)
        case .appearance: CGSize(width: 720, height: 500)
        case .editor:     CGSize(width: 450, height: 300)
        case .dataGrid:   CGSize(width: 450, height: 380)
        case .keyboard:   CGSize(width: 500, height: 500)
        case .history:    CGSize(width: 450, height: 320)
        case .ai:         CGSize(width: 500, height: 520)
        case .plugins:    CGSize(width: 650, height: 500)
        case .sync:       CGSize(width: 450, height: 420)
        case .license:    CGSize(width: 450, height: 280)
        }
    }
}

/// Main settings view with tab-based navigation (macOS Settings style)
struct SettingsView: View {
    @Bindable private var settingsManager = AppSettingsManager.shared
    @Environment(UpdaterBridge.self) var updaterBridge
    @AppStorage("selectedSettingsTab") private var selectedTab: String = SettingsTab.general.rawValue

    private var currentTab: SettingsTab {
        SettingsTab(rawValue: selectedTab) ?? .general
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(settings: $settingsManager.general, updaterBridge: updaterBridge)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general.rawValue)

            AppearanceSettingsView(settings: $settingsManager.appearance)
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
                .tag(SettingsTab.appearance.rawValue)

            EditorSettingsView(settings: $settingsManager.editor)
                .tabItem {
                    Label("Editor", systemImage: "doc.text")
                }
                .tag(SettingsTab.editor.rawValue)

            DataGridSettingsView(settings: $settingsManager.dataGrid)
                .tabItem {
                    Label("Data Grid", systemImage: "tablecells")
                }
                .tag(SettingsTab.dataGrid.rawValue)

            KeyboardSettingsView(settings: $settingsManager.keyboard)
                .tabItem {
                    Label("Keyboard", systemImage: "keyboard")
                }
                .tag(SettingsTab.keyboard.rawValue)

            HistorySettingsView(settings: $settingsManager.history)
                .tabItem {
                    Label("History", systemImage: "clock")
                }
                .tag(SettingsTab.history.rawValue)

            AISettingsView(settings: $settingsManager.ai)
                .tabItem {
                    Label("AI", systemImage: "sparkles")
                }
                .tag(SettingsTab.ai.rawValue)

            PluginsSettingsView()
                .tabItem {
                    Label("Plugins", systemImage: "puzzlepiece.extension")
                }
                .tag(SettingsTab.plugins.rawValue)

            SyncSettingsView()
                .tabItem {
                    Label("Sync", systemImage: "icloud")
                }
                .tag(SettingsTab.sync.rawValue)
                .requiresPro(.iCloudSync)

            LicenseSettingsView()
                .tabItem {
                    Label("License", systemImage: "key")
                }
                .tag(SettingsTab.license.rawValue)
        }
        .frame(width: currentTab.preferredSize.width, height: currentTab.preferredSize.height)
        .background(SettingsWindowResizer(size: currentTab.preferredSize))
    }
}

#Preview {
    SettingsView()
        .environment(UpdaterBridge())
}

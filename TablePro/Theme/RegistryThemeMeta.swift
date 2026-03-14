import Foundation

struct RegistryThemeMeta: Codable {
    var installed: [InstalledRegistryTheme]

    init(installed: [InstalledRegistryTheme] = []) {
        self.installed = installed
    }
}

struct InstalledRegistryTheme: Codable, Identifiable {
    let id: String
    let registryPluginId: String
    let version: String
    let installedDate: Date
}

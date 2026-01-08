import Foundation

/// Represents a saved filter preset with a name and filters
struct FilterPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var filters: [TableFilter]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, filters: [TableFilter], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.filters = filters
        self.createdAt = createdAt
    }
}

/// Storage manager for filter presets
final class FilterPresetStorage {
    static let shared = FilterPresetStorage()

    private let presetsKey = "com.TablePro.filter.presets"
    private let defaults = UserDefaults.standard

    private init() {}

    /// Save a new preset
    func savePreset(_ preset: FilterPreset) {
        var presets = loadAllPresets()

        // Replace if preset with same name exists
        if let index = presets.firstIndex(where: { $0.name == preset.name }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }

        saveAllPresets(presets)
    }

    /// Load all saved presets
    func loadAllPresets() -> [FilterPreset] {
        guard let data = defaults.data(forKey: presetsKey),
              let presets = try? JSONDecoder().decode([FilterPreset].self, from: data) else {
            return []
        }
        return presets.sorted { $0.createdAt > $1.createdAt }
    }

    /// Delete a preset
    func deletePreset(_ preset: FilterPreset) {
        var presets = loadAllPresets()
        presets.removeAll { $0.id == preset.id }
        saveAllPresets(presets)
    }

    /// Delete all presets
    func deleteAllPresets() {
        defaults.removeObject(forKey: presetsKey)
    }

    /// Rename a preset
    func renamePreset(_ preset: FilterPreset, to newName: String) {
        var updatedPreset = preset
        updatedPreset.name = newName
        savePreset(updatedPreset)
    }

    // MARK: - Private

    private func saveAllPresets(_ presets: [FilterPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: presetsKey)
    }
}

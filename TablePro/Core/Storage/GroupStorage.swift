//
//  GroupStorage.swift
//  TablePro
//

import Foundation
import os

/// Service for persisting connection groups
final class GroupStorage {
    static let shared = GroupStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "GroupStorage")

    private let groupsKey = "com.TablePro.groups"
    private let expandedGroupsKey = "com.TablePro.expandedGroups"
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    // MARK: - Group CRUD

    /// Load all groups
    func loadGroups() -> [ConnectionGroup] {
        guard let data = defaults.data(forKey: groupsKey) else {
            return []
        }

        do {
            return try decoder.decode([ConnectionGroup].self, from: data)
        } catch {
            Self.logger.error("Failed to load groups: \(error)")
            return []
        }
    }

    /// Save all groups
    func saveGroups(_ groups: [ConnectionGroup]) {
        do {
            let data = try encoder.encode(groups)
            defaults.set(data, forKey: groupsKey)
        } catch {
            Self.logger.error("Failed to save groups: \(error)")
        }
    }

    /// Add a new group
    func addGroup(_ group: ConnectionGroup) {
        var groups = loadGroups()
        groups.append(group)
        saveGroups(groups)
    }

    /// Update an existing group
    func updateGroup(_ group: ConnectionGroup) {
        var groups = loadGroups()
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
            saveGroups(groups)
        }
    }

    /// Delete a group and all its descendants.
    /// Member connections become ungrouped.
    func deleteGroup(_ group: ConnectionGroup) {
        var groups = loadGroups()
        let deletedIds = collectDescendantIds(of: group.id, in: groups)
        let allDeletedIds = deletedIds.union([group.id])

        // Remove deleted groups
        groups.removeAll { allDeletedIds.contains($0.id) }
        saveGroups(groups)

        // Ungroup connections that belonged to deleted groups
        let storage = ConnectionStorage.shared
        var connections = storage.loadConnections()
        var changed = false
        for index in connections.indices {
            if let gid = connections[index].groupId, allDeletedIds.contains(gid) {
                connections[index].groupId = nil
                changed = true
            }
        }
        if changed {
            storage.saveConnections(connections)
        }
    }

    /// Get group by ID
    func group(for id: UUID) -> ConnectionGroup? {
        loadGroups().first { $0.id == id }
    }

    /// Get child groups of a parent, sorted by sortOrder
    func childGroups(of parentId: UUID?) -> [ConnectionGroup] {
        loadGroups()
            .filter { $0.parentGroupId == parentId }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Get the next sort order for a new item in a parent context
    func nextSortOrder(parentId: UUID?) -> Int {
        let siblings = loadGroups().filter { $0.parentGroupId == parentId }
        return (siblings.map(\.sortOrder).max() ?? -1) + 1
    }

    // MARK: - Expanded State

    /// Load the set of expanded group IDs
    func loadExpandedGroupIds() -> Set<UUID> {
        guard let data = defaults.data(forKey: expandedGroupsKey) else {
            return []
        }

        do {
            let ids = try decoder.decode([UUID].self, from: data)
            return Set(ids)
        } catch {
            Self.logger.error("Failed to load expanded groups: \(error)")
            return []
        }
    }

    /// Save the set of expanded group IDs
    func saveExpandedGroupIds(_ ids: Set<UUID>) {
        do {
            let data = try encoder.encode(Array(ids))
            defaults.set(data, forKey: expandedGroupsKey)
        } catch {
            Self.logger.error("Failed to save expanded groups: \(error)")
        }
    }

    // MARK: - Helpers

    /// Recursively collect all descendant group IDs
    private func collectDescendantIds(of groupId: UUID, in groups: [ConnectionGroup]) -> Set<UUID> {
        var result = Set<UUID>()
        let children = groups.filter { $0.parentGroupId == groupId }
        for child in children {
            result.insert(child.id)
            result.formUnion(collectDescendantIds(of: child.id, in: groups))
        }
        return result
    }
}

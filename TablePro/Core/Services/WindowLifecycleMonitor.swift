//
//  WindowLifecycleMonitor.swift
//  TablePro
//
//  Deterministic NSWindow lifecycle tracker using willCloseNotification.
//  Replaces the fragile SwiftUI onAppear/onDisappear-based NativeTabRegistry
//  with a notification-driven approach that avoids stale entries and timing heuristics.
//

import AppKit
import Foundation
import os

@MainActor
internal final class WindowLifecycleMonitor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WindowLifecycleMonitor")

    internal static let shared = WindowLifecycleMonitor()

    private struct Entry {
        let connectionId: UUID
        let window: NSWindow
        var observer: NSObjectProtocol?
    }

    private var entries: [UUID: Entry] = [:]

    private init() {}

    deinit {
        for entry in entries.values {
            if let observer = entry.observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        entries.removeAll()
    }

    // MARK: - Registration

    /// Register a window and start observing its willCloseNotification.
    internal func register(window: NSWindow, connectionId: UUID, windowId: UUID) {
        // Remove any existing entry for this windowId to avoid duplicate observers
        if let existing = entries[windowId] {
            if let observer = existing.observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let closedWindow = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.handleWindowClose(closedWindow)
            }
        }

        entries[windowId] = Entry(
            connectionId: connectionId,
            window: window,
            observer: observer
        )

        let totalEntries = entries.count
        Self.logger.info(
            "register -- windowId=\(windowId), connectionId=\(connectionId), total=\(totalEntries)"
        )
    }

    /// Remove the UUID mapping for a window.
    internal func unregisterWindow(for windowId: UUID) {
        guard let entry = entries.removeValue(forKey: windowId) else {
            Self.logger.debug("unregisterWindow -- windowId=\(windowId) not found, ignoring")
            return
        }

        if let observer = entry.observer {
            NotificationCenter.default.removeObserver(observer)
        }

        let remaining = windowCount(for: entry.connectionId)
        Self.logger.info(
            "unregisterWindow -- windowId=\(windowId), connectionId=\(entry.connectionId), remaining=\(remaining)"
        )
    }

    // MARK: - Queries

    /// Return all live windows for a connection.
    internal func windows(for connectionId: UUID) -> [NSWindow] {
        entries.values
            .filter { $0.connectionId == connectionId }
            .map(\.window)
    }

    /// Check if other live windows exist for a connection, excluding a specific windowId.
    internal func hasOtherWindows(for connectionId: UUID, excluding windowId: UUID) -> Bool {
        entries.contains { key, value in
            key != windowId && value.connectionId == connectionId
        }
    }

    /// All connection IDs that currently have registered windows.
    internal func allConnectionIds() -> Set<UUID> {
        Set(entries.values.map(\.connectionId))
    }

    /// Find the first visible window for a connection.
    internal func findWindow(for connectionId: UUID) -> NSWindow? {
        entries.values
            .filter { $0.connectionId == connectionId }
            .map(\.window)
            .first { $0.isVisible }
    }

    /// Look up the connectionId for a given windowId.
    internal func connectionId(for windowId: UUID) -> UUID? {
        entries[windowId]?.connectionId
    }

    /// Check if any windows are registered for a connection.
    internal func hasWindows(for connectionId: UUID) -> Bool {
        entries.values.contains { $0.connectionId == connectionId }
    }

    /// Check if a specific window is still registered
    internal func isRegistered(windowId: UUID) -> Bool {
        entries[windowId] != nil
    }

    // MARK: - Private

    private func windowCount(for connectionId: UUID) -> Int {
        entries.values.filter { $0.connectionId == connectionId }.count
    }

    private func handleWindowClose(_ closedWindow: NSWindow) {
        // Find the entry matching this window
        guard let (windowId, entry) = entries.first(where: { $0.value.window === closedWindow }) else {
            Self.logger.debug("handleWindowClose -- no entry found for closed window, ignoring")
            return
        }

        let connectionId = entry.connectionId

        // Clean up observer and remove entry
        if let observer = entry.observer {
            NotificationCenter.default.removeObserver(observer)
        }
        entries.removeValue(forKey: windowId)

        let remaining = windowCount(for: connectionId)
        Self.logger.info(
            "handleWindowClose -- windowId=\(windowId), connectionId=\(connectionId), remaining=\(remaining)"
        )

        if remaining == 0 {
            Self.logger.info(
                "handleWindowClose -- last window closed for connectionId=\(connectionId)"
            )
        }
    }
}

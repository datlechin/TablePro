//
//  ICloudSyncEngine.swift
//  TablePro
//
//  NSUbiquitousKeyValueStore implementation of SyncEngine.
//

import Foundation

/// iCloud sync backend using NSUbiquitousKeyValueStore
final class ICloudSyncEngine: SyncEngine {
    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    func startObserving(onChange: @escaping ([String]) -> Void) {
        // Remove any existing observer first
        stopObserving()

        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            else {
                return
            }
            onChange(changedKeys)
        }

        // Trigger initial pull from iCloud
        store.synchronize()
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    func write(_ data: Data, forKey key: String) {
        store.set(data, forKey: key)
    }

    func read(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    func remove(forKey key: String) {
        store.removeObject(forKey: key)
    }

    @discardableResult
    func synchronize() -> Bool {
        store.synchronize()
    }

    deinit {
        stopObserving()
    }
}

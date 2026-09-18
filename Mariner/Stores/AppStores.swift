// Copyright 2026 Link Dupont
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

/// URLs waiting for a freshly opened tab or window to navigate to.
///
/// Opening a tab or window is fire-and-forget at the AppKit/SwiftUI level,
/// so the requester enqueues the target here first; the new window's
/// `BrowserWindowView` dequeues it on appear and navigates its fresh state.
@Observable @MainActor
final class PendingLinks {
    private var urls: [String] = []

    func enqueue(_ url: String) {
        urls.append(url)
    }

    func dequeue() -> String? {
        guard !urls.isEmpty else { return nil }
        return urls.removeFirst()
    }
}

/// A saved gemini URL.
struct Bookmark: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var url: String
    var title: String
}

/// Key-value storage for iCloud bookmark sync, abstracted for tests.
/// Production uses `NSUbiquitousKeyValueStore`; tests substitute an in-memory fake.
protocol UbiquitousKeyValueStoring {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func synchronize() -> Bool
}

/// Live `UbiquitousKeyValueStoring` backed by `NSUbiquitousKeyValueStore`.
final class LiveUbiquitousKeyValueStore: UbiquitousKeyValueStoring {
    private let store: NSUbiquitousKeyValueStore

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
    }

    func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    func set(_ data: Data, forKey key: String) {
        store.set(data, forKey: key)
    }

    func synchronize() -> Bool {
        store.synchronize()
    }
}

/// @Observable store of bookmarks, persisted as JSON and optionally synced via iCloud.
/// Pass `persistenceURL: nil` for an in-memory store (previews, tests).
/// Pass a `ubiquitousStore` to sync over iCloud key-value storage; nil (the default)
/// keeps the store local-only, which is what previews and tests use.
@Observable @MainActor
final class BookmarkStore {
    private(set) var bookmarks: [Bookmark] = []

    /// Whether changes push to (and arrive from) iCloud. Turning it on re-merges.
    var syncEnabled: Bool {
        didSet {
            guard syncEnabled != oldValue else { return }
            if syncEnabled {
                startObserving()
                initialSync()
            } else {
                stopObserving()
            }
        }
    }

    /// iCloud key holding the JSON-encoded bookmark array (v1: same encoding as the file).
    static let syncKey = "bookmarks"

    private let persistenceURL: URL?
    private let ubiquitousStore: (any UbiquitousKeyValueStoring)?
    private var isObserving = false
    private var isApplyingRemoteChange = false

    init(
        persistenceURL: URL? = BookmarkStore.defaultURL,
        ubiquitousStore: (any UbiquitousKeyValueStoring)? = nil,
        syncEnabled: Bool = true
    ) {
        self.persistenceURL = persistenceURL
        self.ubiquitousStore = ubiquitousStore
        self.syncEnabled = syncEnabled
        load()
        if syncEnabled {
            startObserving()
            initialSync()
        }
    }

    func contains(_ url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    @discardableResult
    func toggle(url: String, title: String) -> Bool {
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: index)
            persist()
            return false
        }
        bookmarks.append(Bookmark(url: url, title: title))
        persist()
        return true
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persist()
    }

    /// Merges bookmark data received from iCloud into local state.
    /// The live change notification funnels through here; tests call it directly.
    func applyRemoteData(_ data: Data?) {
        guard syncEnabled, ubiquitousStore != nil else { return }
        guard let data,
            let remote = try? JSONDecoder().decode([Bookmark].self, from: data)
        else { return }
        let merged = Self.merge(local: bookmarks, remote: remote)
        guard merged != bookmarks else { return }
        isApplyingRemoteChange = true
        bookmarks = merged
        persistLocal()
        isApplyingRemoteChange = false
        pushToRemote()
    }

    /// Re-reads iCloud state after an external-change notification.
    func handleExternalChange() {
        guard syncEnabled, let store = ubiquitousStore else { return }
        applyRemoteData(store.data(forKey: Self.syncKey))
    }

    /// Union by URL: local order first, remote-only URLs appended.
    /// Local titles win on conflict. A bookmark deleted on one device is
    /// re-adopted from another (no tombstones in v1) to avoid data loss.
    static func merge(local: [Bookmark], remote: [Bookmark]) -> [Bookmark] {
        var seen = Set(local.map(\.url))
        var merged = local
        for bookmark in remote where !seen.contains(bookmark.url) {
            seen.insert(bookmark.url)
            merged.append(bookmark)
        }
        return merged
    }

    private func load() {
        guard let persistenceURL,
            let data = try? Data(contentsOf: persistenceURL),
            let decoded = try? JSONDecoder().decode([Bookmark].self, from: data)
        else { return }
        bookmarks = decoded
    }

    private func persist() {
        persistLocal()
        pushToRemote()
    }

    private func persistLocal() {
        guard let persistenceURL,
            let data = try? JSONEncoder().encode(bookmarks)
        else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }

    private func pushToRemote() {
        guard syncEnabled, !isApplyingRemoteChange,
            let store = ubiquitousStore,
            let data = try? JSONEncoder().encode(bookmarks)
        else { return }
        store.set(data, forKey: Self.syncKey)
        _ = store.synchronize()
    }

    /// First contact with iCloud: adopt remote state when local is empty,
    /// merge otherwise, and advertise local bookmarks when iCloud has none.
    private func initialSync() {
        guard syncEnabled, let store = ubiquitousStore else { return }
        _ = store.synchronize()
        if let remote = store.data(forKey: Self.syncKey) {
            applyRemoteData(remote)
        } else if !bookmarks.isEmpty {
            pushToRemote()
        }
    }

    private func startObserving() {
        // No removal: stores are app-lifetime singletons, the handler captures
        // self weakly, and it no-ops whenever sync is disabled.
        guard !isObserving, ubiquitousStore != nil else { return }
        isObserving = true
        _ = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleExternalChange()
            }
        }
    }

    private func stopObserving() {
        isObserving = false
    }

    static var defaultURL: URL? {
        guard let dir = appSupportDirectory else { return nil }
        return dir.appending(path: "bookmarks.json")
    }
}

/// One visited page.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var url: String
    var title: String
    var visitedAt: Date = Date()
}

/// @Observable browsing history, persisted as JSON (newest last, capped).
/// Pass `persistenceURL: nil` for an in-memory store (previews, tests).
@Observable @MainActor
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []

    static let maxEntries = 500

    private let persistenceURL: URL?

    init(persistenceURL: URL? = HistoryStore.defaultURL) {
        self.persistenceURL = persistenceURL
        load()
    }

    /// Most recent first, for display.
    var recentFirst: [HistoryEntry] {
        entries.reversed()
    }

    func record(url: String, title: String) {
        // Collapse repeats: re-visiting a URL moves it to the front.
        entries.removeAll { $0.url == url }
        entries.append(HistoryEntry(url: url, title: title))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    private func load() {
        guard let persistenceURL,
            let data = try? Data(contentsOf: persistenceURL),
            let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func persist() {
        guard let persistenceURL,
            let data = try? JSONEncoder().encode(entries)
        else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }

    static var defaultURL: URL? {
        guard let dir = appSupportDirectory else { return nil }
        return dir.appending(path: "history.json")
    }
}

/// Per-host preferences (client identity bindings), persisted as JSON.
/// Pass `persistenceURL: nil` for an in-memory store (previews, tests).
@Observable @MainActor
final class HostSettings {
    /// Host (lowercased, no port) → client identity id to present.
    var identityBindings: [String: String] = [:]

    private let persistenceURL: URL?

    init(persistenceURL: URL? = HostSettings.defaultURL) {
        self.persistenceURL = persistenceURL
        load()
    }

    func identityID(forHost host: String) -> String? {
        identityBindings[host.lowercased()]
    }

    func bindIdentity(_ id: String?, toHost host: String) {
        if let id {
            identityBindings[host.lowercased()] = id
        } else {
            identityBindings.removeValue(forKey: host.lowercased())
        }
        persist()
    }

    private struct Snapshot: Codable {
        var identityBindings: [String: String] = [:]
    }

    private func load() {
        guard let persistenceURL,
            let data = try? Data(contentsOf: persistenceURL),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        identityBindings = snapshot.identityBindings
    }

    private func persist() {
        guard let persistenceURL else { return }
        let snapshot = Snapshot(identityBindings: identityBindings)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }

    static var defaultURL: URL? {
        guard let dir = appSupportDirectory else { return nil }
        return dir.appending(path: "hosts.json")
    }
}

private var appSupportDirectory: URL? {
    let dir = URL.applicationSupportDirectory.appending(path: "Mariner", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

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
import Testing

@testable import Mariner

/// In-memory fake for `UbiquitousKeyValueStoring`.
final class FakeUbiquitousStore: UbiquitousKeyValueStoring {
    var storage: [String: Data] = [:]
    var synchronizeCount = 0

    func data(forKey key: String) -> Data? {
        storage[key]
    }

    func set(_ data: Data, forKey key: String) {
        storage[key] = data
    }

    func synchronize() -> Bool {
        synchronizeCount += 1
        return true
    }

    func seed(_ bookmarks: [Bookmark]) {
        storage[BookmarkStore.syncKey] = try! JSONEncoder().encode(bookmarks)
    }

    func stored() -> [Bookmark]? {
        guard let data = storage[BookmarkStore.syncKey] else { return nil }
        return try? JSONDecoder().decode([Bookmark].self, from: data)
    }
}

@MainActor
struct BookmarkSyncTests {
    private func bookmark(_ url: String, _ title: String) -> Bookmark {
        Bookmark(url: url, title: title)
    }

    @Test func localTogglePushesToRemote() {
        let remote = FakeUbiquitousStore()
        let store = BookmarkStore(persistenceURL: nil, ubiquitousStore: remote)

        store.toggle(url: "gemini://a.com/", title: "A")

        #expect(remote.stored()?.map(\.url) == ["gemini://a.com/"])
        #expect(remote.synchronizeCount > 0)
    }

    @Test func nilStoreStaysLocalOnly() {
        let store = BookmarkStore(persistenceURL: nil)

        store.toggle(url: "gemini://a.com/", title: "A")

        #expect(store.bookmarks.map(\.url) == ["gemini://a.com/"])
    }

    @Test func externalChangeMergesRemoteOnlyBookmarks() {
        let remote = FakeUbiquitousStore()
        let store = BookmarkStore(persistenceURL: nil, ubiquitousStore: remote)
        store.toggle(url: "gemini://a.com/", title: "A")
        remote.seed([bookmark("gemini://a.com/", "A"), bookmark("gemini://b.com/", "B")])

        store.handleExternalChange()

        #expect(store.bookmarks.map(\.url) == ["gemini://a.com/", "gemini://b.com/"])
        // Converged state is pushed back so other devices catch up.
        #expect(remote.stored()?.map(\.url) == ["gemini://a.com/", "gemini://b.com/"])
    }

    @Test func identicalRemoteIsANoOp() {
        let remote = FakeUbiquitousStore()
        let store = BookmarkStore(persistenceURL: nil, ubiquitousStore: remote)
        store.toggle(url: "gemini://a.com/", title: "A")
        let pushes = remote.synchronizeCount

        store.handleExternalChange()

        #expect(remote.synchronizeCount == pushes)
    }

    @Test func disabledStoreIgnoresRemoteAndSkipsPush() {
        let remote = FakeUbiquitousStore()
        let store = BookmarkStore(persistenceURL: nil, ubiquitousStore: remote, syncEnabled: false)
        remote.seed([bookmark("gemini://b.com/", "B")])

        store.toggle(url: "gemini://a.com/", title: "A")
        store.handleExternalChange()

        #expect(store.bookmarks.map(\.url) == ["gemini://a.com/"])
        #expect(remote.stored()?.map(\.url) == ["gemini://b.com/"])
        #expect(remote.synchronizeCount == 0)
    }

    @Test func corruptRemoteIsIgnored() {
        let remote = FakeUbiquitousStore()
        let store = BookmarkStore(persistenceURL: nil, ubiquitousStore: remote)
        store.toggle(url: "gemini://a.com/", title: "A")
        remote.storage[BookmarkStore.syncKey] = Data("not-json".utf8)

        store.handleExternalChange()

        #expect(store.bookmarks.map(\.url) == ["gemini://a.com/"])
    }

    @Test func initAdoptsRemoteWhenLocalIsEmpty() {
        let remote = FakeUbiquitousStore()
        remote.seed([bookmark("gemini://b.com/", "B")])

        let store = BookmarkStore(persistenceURL: nil, ubiquitousStore: remote)

        #expect(store.bookmarks.map(\.url) == ["gemini://b.com/"])
    }

    @Test func reenablingMergesRemote() {
        let remote = FakeUbiquitousStore()
        let store = BookmarkStore(persistenceURL: nil, ubiquitousStore: remote, syncEnabled: false)
        store.toggle(url: "gemini://a.com/", title: "A")
        remote.seed([bookmark("gemini://b.com/", "B")])

        store.syncEnabled = true

        #expect(store.bookmarks.map(\.url) == ["gemini://a.com/", "gemini://b.com/"])
    }

    @Test func mergePrefersLocalTitles() {
        let merged = BookmarkStore.merge(
            local: [bookmark("gemini://a.com/", "Mine")],
            remote: [bookmark("gemini://a.com/", "Theirs"), bookmark("gemini://b.com/", "B")]
        )

        #expect(merged.map(\.url) == ["gemini://a.com/", "gemini://b.com/"])
        #expect(merged.map(\.title) == ["Mine", "B"])
    }
}

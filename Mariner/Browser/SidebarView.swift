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

import GeminiKit
import SwiftUI

/// The library sidebar: collapsible Bookmarks and History sections in one list.
struct SidebarView: View {
    @Bindable var state: BrowserState

    @State private var bookmarksExpanded = true
    @State private var historyExpanded = true
    @State private var librarySearch = ""
    @State private var entryPendingRemoval: HistoryEntry?
    @State private var showClearHistoryConfirm = false
    /// Incremented by the Go menu's Clear History item to request confirmation here.
    @State private var clearHistoryRequests = 0

    var body: some View {
        List {
            bookmarksSection
            historySection
        }
        .listStyle(.sidebar)
        .searchable(text: $librarySearch, placement: .sidebar, prompt: "Filter library")
        .navigationTitle("Library")
        .focusedValue(\.clearHistoryRequest, $clearHistoryRequests)
        .onChange(of: clearHistoryRequests) { _, _ in
            showClearHistoryConfirm = true
        }
        .confirmationDialog(
            "Remove from history?",
            isPresented: Binding(
                get: { entryPendingRemoval != nil },
                set: { if !$0 { entryPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: entryPendingRemoval
        ) { entry in
            Button("Remove", role: .destructive) {
                state.history.remove(entry)
                entryPendingRemoval = nil
            }
        } message: { entry in
            Text("Remove \"\(entry.title.isEmpty ? entry.url : entry.title)\" from your browsing history? This cannot be undone.")
        }
        .confirmationDialog(
            "Clear all browsing history?",
            isPresented: $showClearHistoryConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                state.history.clear()
            }
        } message: {
            Text("This removes all visited page titles and URLs. This cannot be undone.")
        }
    }

    private var bookmarksSection: some View {
        Section(isExpanded: $bookmarksExpanded) {
            if filteredBookmarks.isEmpty {
                Text("No bookmarks").foregroundStyle(.secondary)
            } else {
                ForEach(filteredBookmarks) { bookmark in
                    Button {
                        state.go(to: bookmark.url)
                    } label: {
                        Text(bookmark.title.isEmpty ? bookmark.url : bookmark.title)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove", role: .destructive) {
                            state.bookmarks.remove(bookmark)
                        }
                    }
                    .swipeActions {
                        Button("", systemImage: "trash", role: .destructive) {
                            state.bookmarks.remove(bookmark)
                        }
                    }
                }
            }
        } header: {
            Label("Bookmarks", systemImage: "star")
        }
    }

    private var historySection: some View {
        Section(isExpanded: $historyExpanded) {
            if state.history.entries.isEmpty {
                Text("No history yet").foregroundStyle(.secondary)
            } else if filteredHistory.isEmpty {
                Text("No matching history").foregroundStyle(.secondary)
            } else {
                ForEach(filteredHistory) { entry in
                    Button {
                        state.go(to: entry.url)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.title.isEmpty ? entry.url : entry.title)
                                .lineLimit(1)
                            Text(entry.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove", role: .destructive) {
                            entryPendingRemoval = entry
                        }
                    }
                    .swipeActions {
                        Button("", systemImage: "trash", role: .destructive) {
                            entryPendingRemoval = entry
                        }
                    }
                }
            }
        } header: {
            Label("History", systemImage: "clock")
                .contextMenu {
                    Button("Clear History…", role: .destructive) {
                        showClearHistoryConfirm = true
                    }
                    .disabled(state.history.entries.isEmpty)
                }
        }
    }

    private var filterQuery: String {
        librarySearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredBookmarks: [Bookmark] {
        let bookmarks = state.bookmarks.bookmarks
        guard !filterQuery.isEmpty else { return bookmarks }
        return bookmarks.filter {
            $0.title.localizedStandardContains(filterQuery) || $0.url.localizedStandardContains(filterQuery)
        }
    }

    private var filteredHistory: [HistoryEntry] {
        let entries = state.history.recentFirst
        guard !filterQuery.isEmpty else { return entries }
        return entries.filter {
            $0.title.localizedStandardContains(filterQuery) || $0.url.localizedStandardContains(filterQuery)
        }
    }
}

#Preview("Sidebar") {
    SidebarView(
        state: BrowserState(
            fetcher: { _, _, _ in .content(statusCode: 20, mimetype: "text/gemini", data: Data(), certificate: nil) },
            settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true),
            bookmarks: BookmarkStore(persistenceURL: nil),
            history: HistoryStore(persistenceURL: nil),
            hosts: HostSettings(persistenceURL: nil)
        )
    )
    .frame(width: 260, height: 500)
}

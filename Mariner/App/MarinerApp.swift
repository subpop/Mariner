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

import AppKit
import GeminiKit
import SwiftUI

/// Identifier of the browser window group, for `openWindow(id:)` requests
/// such as "Open in New Window" from a link context menu.
let browserWindowGroupID = "browser"

/// Opens a new browser tab via the native tabbing API: asks AppKit for a
/// new window, then joins it to the key window's tab group.
func openNewBrowserTab() {
    let currentWindow = NSApp.keyWindow
    NSApp
        .sendAction(
            #selector(NSResponder.newWindowForTab(_:)),
            to: nil,
            from: nil
        )
    // SwiftUI opens the new window untabbed; join it to the
    // current window's tab group explicitly.
    guard let currentWindow,
        let newWindow = NSApp.keyWindow,
        newWindow != currentWindow,
        !(currentWindow.tabbedWindows?.contains(newWindow) ?? false)
    else { return }
    currentWindow.addTabbedWindow(newWindow, ordered: .above)
    newWindow.tabGroup?.selectedWindow = newWindow
}

@main struct MarinerApp: App {
    @State private var settings: AppSettings
    @State private var bookmarks: BookmarkStore
    @State private var history = HistoryStore()
    @State private var hosts = HostSettings()
    @State private var identities = ClientIdentityStore()
    @State private var pendingLinks = PendingLinks()
    /// The key window's session, for scenes (Settings) that live outside it.
    @State private var activeBrowser: BrowserState?

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _bookmarks = State(initialValue: BookmarkStore(
            ubiquitousStore: LiveUbiquitousKeyValueStore(),
            syncEnabled: settings.iCloudBookmarkSync
        ))
    }

    @FocusedValue(\.browserState) private var browser
    @FocusedBinding(\.showRaw) private var showRaw
    @FocusedBinding(\.openLocationRequest) private var openLocationRequest
    @FocusedBinding(\.searchRequest) private var searchRequest
    @FocusedBinding(\.clearHistoryRequest) private var clearHistoryRequest

    var body: some Scene {
        WindowGroup(id: browserWindowGroupID) {
            BrowserWindowView(
                settings: settings,
                bookmarks: bookmarks,
                history: history,
                hosts: hosts,
                identities: identities,
                pendingLinks: pendingLinks,
                activeBrowser: $activeBrowser
            )
        }
        .onChange(of: settings.iCloudBookmarkSync) { _, newValue in
            bookmarks.syncEnabled = newValue
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { openNewBrowserTab() }
                .keyboardShortcut("t", modifiers: .command)
                Button("Open Location…") { openLocationRequest? += 1 }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(openLocationRequest == nil)
            }

            CommandMenu("Go") {
                Button("Back", systemImage: "chevron.left") { browser?.back() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(browser?.canGoBack != true)
                Button("Forward", systemImage: "chevron.right") { browser?.forward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(browser?.canGoForward != true)
                Button("Reload", systemImage: "arrow.clockwise") { browser?.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(browser?.currentURL == nil)
                Button("Home", systemImage: "house") { browser?.goHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("Clear History…", systemImage: "trash") { clearHistoryRequest? += 1 }
                    .disabled(browser?.history.entries.isEmpty != false)
            }

            CommandMenu("Page") {
                Button("Find in Page…", systemImage: "magnifyingglass") {
                    browser?.find.isVisible.toggle()
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Search…", systemImage: "magnifyingglass") { searchRequest? += 1 }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(searchRequest == nil)

                Button(browser?.isBookmarked == true ? "Remove Bookmark" : "Add Bookmark", systemImage: "star") {
                    browser?.toggleBookmark()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(browser?.currentURL == nil)

                Button("Save Page…", systemImage: "square.and.arrow.down") {
                    browser?.saveRequested = true
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(browser?.lastBody == nil)

                if let showRaw = Binding($showRaw) {
                    Toggle("Show Raw Content", systemImage: "doc.plaintext", isOn: showRaw)
                        .keyboardShortcut("u", modifiers: [.command, .option])
                        .disabled(!isGemtextPage)
                }
            }

            CommandGroup(after: .toolbar) {
                Button("Zoom In", systemImage: "plus.magnifyingglass") { browser?.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(browser?.canZoomIn != true)
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { browser?.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(browser?.canZoomOut != true)
                Button("Actual Size", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { browser?.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(browser?.textZoomOffset != 0)
            }

            SidebarCommands()
        }

        Settings {
            SettingsView(
                settings: settings,
                currentPageURL: activeBrowser?.currentURL,
                hosts: hosts,
                history: history,
                identities: identities
            )
        }
    }

    private var isGemtextPage: Bool {
        if case .gemtext = browser?.page { return true }
        return false
    }
}

private struct BrowserStateKey: FocusedValueKey {
    typealias Value = BrowserState
}

private struct ShowRawKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct OpenLocationKey: FocusedValueKey {
    typealias Value = Binding<Int>
}

private struct SearchRequestKey: FocusedValueKey {
    typealias Value = Binding<Int>
}

private struct ClearHistoryKey: FocusedValueKey {
    typealias Value = Binding<Int>
}

extension FocusedValues {
    var browserState: BrowserState? {
        get { self[BrowserStateKey.self] }
        set { self[BrowserStateKey.self] = newValue }
    }

    var showRaw: Binding<Bool>? {
        get { self[ShowRawKey.self] }
        set { self[ShowRawKey.self] = newValue }
    }

    var openLocationRequest: Binding<Int>? {
        get { self[OpenLocationKey.self] }
        set { self[OpenLocationKey.self] = newValue }
    }

    var searchRequest: Binding<Int>? {
        get { self[SearchRequestKey.self] }
        set { self[SearchRequestKey.self] = newValue }
    }

    var clearHistoryRequest: Binding<Int>? {
        get { self[ClearHistoryKey.self] }
        set { self[ClearHistoryKey.self] = newValue }
    }
}

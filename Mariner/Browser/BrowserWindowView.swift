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
import UniformTypeIdentifiers

/// One browser window: owns its session so native tabs stay independent.
/// Stores are shared across windows; everything else is per-tab.
struct BrowserWindowView: View {
    let identities: ClientIdentityStore
    let pendingLinks: PendingLinks
    @Binding var activeBrowser: BrowserState?
    @State private var state: BrowserState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var showImport = false
    @State private var exporting = false
    @State private var locationRequests = 0
    @State private var showingPageInfo = false
    @State private var showingLocationSheet = false
    @State private var searchText = ""
    @State private var searchRequests = 0
    @FocusState private var findFocused: Bool
    @FocusState private var searchFocused: Bool

    init(
        settings: AppSettings,
        bookmarks: BookmarkStore,
        history: HistoryStore,
        hosts: HostSettings,
        identities: ClientIdentityStore,
        pendingLinks: PendingLinks,
        activeBrowser: Binding<BrowserState?>
    ) {
        _state = State(initialValue: BrowserState(
            settings: settings,
            bookmarks: bookmarks,
            history: history,
            hosts: hosts
        ))
        _activeBrowser = activeBrowser
        self.identities = identities
        self.pendingLinks = pendingLinks
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
        } detail: {
            VStack(spacing: 0) {
                if state.find.isVisible {
                    FindBar(state: state, focused: $findFocused)
                }
                PageContent(
                    state: state,
                    showImport: $showImport,
                    exporting: $exporting,
                    onLinkMenu: handleLinkMenu
                )
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left") { state.back() }
                        .disabled(!state.canGoBack)
                        .keyboardShortcut("[", modifiers: .command)

                    Button("Forward", systemImage: "chevron.right") { state.forward() }
                        .disabled(!state.canGoForward)
                        .keyboardShortcut("]", modifiers: .command)

                    Button("Home", systemImage: "house") { state.goHome() }
                        .keyboardShortcut("h", modifiers: [.command, .shift])

                    if state.isLoading {
                        Button("Stop", systemImage: "xmark") { state.stop() }
                            .keyboardShortcut(".", modifiers: .command)
                    } else {
                        Button("Reload", systemImage: "arrow.clockwise") { state.reload() }
                            .disabled(state.currentURL == nil)
                            .keyboardShortcut("r", modifiers: .command)
                    }
                }

                ToolbarItemGroup(placement: .principal) {
                    Button("Open Location", systemImage: "globe") {
                        showingLocationSheet = true
                    }

                    Button("Page Info", systemImage: "info.circle") {
                        showingPageInfo = true
                    }
                    .disabled(state.currentURL == nil)

                    Button(
                        state.isBookmarked ? "Remove Bookmark" : "Add Bookmark",
                        systemImage: state.isBookmarked ? "star.fill" : "star"
                    ) {
                        state.toggleBookmark()
                    }
                    .disabled(state.currentURL == nil)
                }

                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search", text: $searchText)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .onSubmit {
                                state.search(searchText)
                                searchText = ""
                                searchFocused = false
                            }
                            .onExitCommand {
                                searchText = ""
                                searchFocused = false
                            }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(minWidth: 120, idealWidth: 180, maxWidth: 240)
                }
            }
            .labelStyle(.iconOnly)
        }
        .navigationTitle(pageTitle)
        .frame(minWidth: 760, minHeight: 520)
        .onOpenURL { url in state.go(to: url.absoluteString) }
        .onChange(of: state.find.isVisible) { _, visible in
            if visible { findFocused = true }
        }
        .onChange(of: state.saveRequested) { _, requested in
            if requested {
                state.saveRequested = false
                if state.lastBody != nil { exporting = true }
            }
        }
        .onChange(of: locationRequests) { _, _ in
            showingLocationSheet = true
        }
        .onChange(of: searchRequests) { _, _ in
            searchFocused = true
        }
        .onAppear {
            state.identityStore = identities
            activeBrowser = state
            // A tab or window opened for a link ("Open in New Tab/Window")
            // enqueued its target before opening; navigate this fresh state to it.
            if let pending = pendingLinks.dequeue() {
                state.go(to: pending)
            }
        }
        .onDisappear {
            if activeBrowser === state { activeBrowser = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { activeBrowser = state }
        }
        .sheet(isPresented: inputShown) {
            if case .input(_, let prompt, let sensitive) = state.page {
                InputPromptSheet(
                    prompt: prompt, sensitive: sensitive,
                    onSubmit: { state.submitInput($0); },
                    onCancel: { state.cancelInput() }
                )
            }
        }
        .sheet(isPresented: certSheetShown) {
            if case .clientCert(let url, let message) = state.page {
                ClientCertSheet(
                    host: url.hostForDisplay, message: message,
                    identities: state.identityStore?.identities ?? [],
                    onImport: { showImport = true },
                    onUse: { state.useIdentity($0, remember: $1) },
                    onCancel: { state.dismissToSafety() }
                )
            }
        }
        .sheet(isPresented: $showImport) {
            if let store = state.identityStore {
                ImportIdentitySheet(store: store) { _ in showImport = false }
            }
        }
        .sheet(isPresented: $showingPageInfo) {
            PageInfoSheet(state: state)
        }
        .sheet(isPresented: $showingLocationSheet) {
            LocationSheet(
                initialText: state.addressText,
                onSubmit: {
                    state.go(to: $0)
                    showingLocationSheet = false
                },
                onCancel: { showingLocationSheet = false }
            )
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .data,
            defaultFilename: exportFilename
        ) { _ in }
        .focusedValue(\.browserState, state)
        .focusedValue(\.showRaw, $state.showRaw)
        .focusedValue(\.openLocationRequest, $locationRequests)
        .focusedValue(\.searchRequest, $searchRequests)
    }

    /// Window title: the page's first heading when it has one, else the host.
    private var pageTitle: String {
        guard let url = state.currentURL else { return "" }
        return state.page.historyTitle(fallback: url.hostForDisplay)
    }

    /// Handles a gemtext link context-menu action.
    private func handleLinkMenu(_ action: LinkMenuAction, raw: String, label: String?) {
        switch action {
        case .copy:
            guard let string = state.absoluteLinkString(raw) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        case .bookmark:
            state.toggleLinkBookmark(raw, label: label)
        case .newTab:
            guard let target = state.resolvedLinkTarget(raw) else { return }
            pendingLinks.enqueue(target.normalizedScheme())
            openNewBrowserTab()
        case .newWindow:
            guard let target = state.resolvedLinkTarget(raw) else { return }
            pendingLinks.enqueue(target.normalizedScheme())
            openWindow(id: browserWindowGroupID)
        }
    }

    private var inputShown: Binding<Bool> {
        Binding(
            get: { if case .input = state.page { return true }; return false },
            set: { if !$0 { state.cancelInput() } }
        )
    }

    private var certSheetShown: Binding<Bool> {
        Binding(
            get: { if case .clientCert = state.page { return true }; return false },
            set: { if !$0 { state.dismissToSafety() } }
        )
    }

    private var exportDocument: RawDataDocument? {
        state.lastBody.map { RawDataDocument(data: $0.data) }
    }

    private var exportFilename: String {
        guard let url = state.currentURL else { return "page.gmi" }
        let last = url.path.split(separator: "/").last.map(String.init)
        if let last, !last.isEmpty { return last }
        return "\(url.hostForDisplay).gmi"
    }
}

#Preview {
    BrowserWindowView(
        settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true),
        bookmarks: BookmarkStore(persistenceURL: nil),
        history: HistoryStore(persistenceURL: nil),
        hosts: HostSettings(persistenceURL: nil),
        identities: ClientIdentityStore(),
        pendingLinks: PendingLinks(),
        activeBrowser: .constant(nil)
    )
}

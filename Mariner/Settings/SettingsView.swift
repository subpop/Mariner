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

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var currentPageURL: GeminiURI?
    @Bindable var hosts: HostSettings
    @Bindable var history: HistoryStore
    @Bindable var identities: ClientIdentityStore

    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") {
                GeneralSettingsTab(settings: settings, currentPageURL: currentPageURL)
            }
            Tab("Identities", systemImage: "person.badge.key") {
                IdentitiesSettingsTab(hosts: hosts, identities: identities)
            }
            Tab("Privacy", systemImage: "hand.raised") {
                PrivacySettingsTab(history: history)
            }
        }
        .frame(width: 480, height: 360)
    }
}

private struct GeneralSettingsTab: View {
    @Bindable var settings: AppSettings
    var currentPageURL: GeminiURI?

    var body: some View {
        Form {
            Section("Navigation") {
                Picker("Homepage", selection: $settings.homePage) {
                    ForEach(HomePage.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                if settings.homePage == .url {
                    HStack {
                        TextField("URL:", text: $settings.homePageURL)
                        Button("Use Current Page") {
                            if let currentPageURL {
                                settings.homePageURL = currentPageURL.normalizedScheme()
                            }
                        }
                        .disabled(currentPageURL == nil)
                    }
                }
            }
            Section("Search") {
                Picker("Search engine", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                if settings.searchEngine == .custom {
                    TextField("Search URL template:", text: $settings.searchURL, prompt: Text("Must contain {query}"))
                }
            }
            Section("Network") {
                TextField("Request timeout (seconds)", value: $settings.requestTimeout, format: .number.precision(.fractionLength(0)))
                Toggle("Follow same-server redirects automatically", isOn: $settings.autoFollowSameHostRedirects)
            }
            Section {
                Toggle("Sync bookmarks with iCloud", isOn: $settings.iCloudBookmarkSync)
            } header: {
                Text("iCloud")
            } footer: {
                Text("Requires signing into iCloud with the same Apple Account on each Mac.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct IdentitiesSettingsTab: View {
    @Bindable var hosts: HostSettings
    @Bindable var identities: ClientIdentityStore

    @State private var showImport = false

    var body: some View {
        Group {
            if identities.identities.isEmpty {
                ContentUnavailableView {
                    Label("No Client Identities", systemImage: "person.badge.key")
                } description: {
                    Text("Import a PKCS#12 file to use certificate-protected sites.")
                } actions: {
                    Button("Import Identity…") { showImport = true }
                }
            } else {
                List {
                    ForEach(identities.identities) { identity in
                        Label {
                            HStack {
                                Text(identity.displayName)
                                Spacer()
                                if let host = boundHost(for: identity.id) {
                                    Text(host)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "person.badge.key.fill")
                        }
                        .contextMenu {
                            Button("Remove", role: .destructive) {
                                identities.delete(identity)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        Divider()
                        HStack {
                            Spacer()
                            Button("Import Identity…") { showImport = true }
                        }
                        .padding()
                    }
                    .background(.bar)
                }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportIdentitySheet(store: identities) { _ in showImport = false }
        }
    }

    private func boundHost(for identityID: String) -> String? {
        hosts.identityBindings.first { $0.value == identityID }?.key
    }
}

private struct PrivacySettingsTab: View {
    @Bindable var history: HistoryStore

    @State private var showClearHistoryConfirm = false
    @State private var showForgetAllConfirm = false
    @State private var pins: [CertificateStore.Pin] = []
    @State private var pinsForgotten = false

    var body: some View {
        Form {
            Section {
                Button("Clear History…", role: .destructive) {
                    showClearHistoryConfirm = true
                }
                .disabled(history.entries.isEmpty)
            } header: {
                Text("Browsing History")
            } footer: {
                Text("Removes all visited page titles and URLs stored on this Mac.")
            }
            Section {
                if pins.isEmpty {
                    Text("No trusted server certificates.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pins, id: \.self) { pin in
                        TrustedCertificateRow(pin: pin) {
                            remove(pin)
                        }
                    }
                }
                Button("Forget All Server Certificates", role: .destructive) {
                    showForgetAllConfirm = true
                }
                .disabled(pins.isEmpty)
            } header: {
                Text("Server Certificates")
            } footer: {
                if pinsForgotten {
                    Text("All pinned certificates were removed.")
                } else {
                    Text("Removes stored certificate pins. You will be asked to verify servers again.")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshPins()
        }
        .confirmationDialog(
            "Clear all browsing history?",
            isPresented: $showClearHistoryConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                history.clear()
            }
        } message: {
            Text("This removes all visited page titles and URLs. This cannot be undone.")
        }
        .confirmationDialog(
            "Forget all server certificates?",
            isPresented: $showForgetAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Forget All Certificates", role: .destructive) {
                forgetAll()
            }
        } message: {
            Text("This removes all stored certificate pins. You will be asked to verify servers again. This cannot be undone.")
        }
    }

    private func refreshPins() async {
        pins = await GeminiClient.shared.certificateStore.listPins()
        if !pins.isEmpty {
            pinsForgotten = false
        }
    }

    private func remove(_ pin: CertificateStore.Pin) {
        Task {
            await GeminiClient.shared.certificateStore.delete(host: pin.host, port: pin.port)
            await refreshPins()
        }
    }

    private func forgetAll() {
        Task {
            await GeminiClient.shared.certificateStore.forgetAll()
            pinsForgotten = true
            await refreshPins()
        }
    }
}

private struct TrustedCertificateRow: View {
    var pin: CertificateStore.Pin
    var remove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(verbatim: "\(pin.host):\(pin.port)")
                    .monospaced()
                Text(fingerprintHex(pin.fingerprint))
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(action: {
                remove()
            }, label: {
                Image(systemName: "trash")
            })
        }
        .contextMenu {
            Button("Remove Trust", role: .destructive) {
                remove()
            }
        }
    }
}

#Preview {
    let settings = AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true)
    return SettingsView(
        settings: settings,
        currentPageURL: nil,
        hosts: HostSettings(persistenceURL: nil),
        history: HistoryStore(persistenceURL: nil),
        identities: ClientIdentityStore()
    )
}

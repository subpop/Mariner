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
import UniformTypeIdentifiers

// MARK: - SheetHeader

/// Shared icon + bold-title header for sheet dialogs, echoing native macOS dialog styling.
private struct SheetHeader: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading) {
                Text(title)
                    .font(.title3.bold())
                if let message, !message.isEmpty {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - InputPromptSheet

/// Input prompt for `1x` statuses. Status 11 uses a secure field.
struct InputPromptSheet: View {
    let prompt: String
    let sensitive: Bool
    var onSubmit: (String) -> Void
    var onCancel: () -> Void

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                icon: sensitive ? "lock.fill" : "text.cursor",
                title: sensitive ? "Sensitive Input Required" : "Input Required",
                message: prompt.isEmpty ? nil : prompt
            )
            .padding([.horizontal, .top])

            Form {
                Section {
                    if sensitive {
                        SecureField("Enter response…", text: $draft)
                            .focused($fieldFocused)
                            .onSubmit { submit() }
                    } else {
                        TextField("Enter response…", text: $draft)
                            .focused($fieldFocused)
                            .onSubmit { submit() }
                    }
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Submit", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 360)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSubmit(draft)
    }
}

// MARK: - CertificateMismatchView

/// Full-page warning for a changed server certificate (TOFU mismatch).
struct CertificateMismatchView: View {
    let url: String
    let stored: String
    let presented: String
    var onTrust: () -> Void
    var onGoBack: () -> Void

    var body: some View {
        ScrollView {
            VStack {
                Image(systemName: "exclamationmark.shield")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("Certificate Mismatch")
                    .font(.title2.bold())
                Text("The certificate for this server changed since your first visit.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Grid(alignment: .leading) {
                    GridRow {
                        Text("Address").foregroundStyle(.secondary)
                        Text(url).monospaced()
                    }
                    GridRow {
                        Text("Trusted").foregroundStyle(.secondary)
                        Text(stored).monospaced().textSelection(.enabled)
                    }
                    GridRow {
                        Text("Presented").foregroundStyle(.secondary)
                        Text(presented).monospaced().textSelection(.enabled)
                    }
                }
                .padding()
                .background(.primary.opacity(0.05))
                .clipShape(.rect(cornerRadius: 8))
                Text("This can be a routine renewal — or someone intercepting the connection. Only trust the new certificate if you can verify the fingerprint out of band.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                HStack {
                    Button("Go Back", action: onGoBack)
                        .keyboardShortcut(.cancelAction)
                    Button("Trust New Certificate", action: onTrust)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - ClientCertSheet

/// Chooser shown for `6x` statuses: pick an identity, optionally bind it to the host.
struct ClientCertSheet: View {
    let host: String
    let message: String
    let identities: [StoredClientIdentity]
    var onImport: () -> Void
    var onUse: (StoredClientIdentity?, Bool) -> Void
    var onCancel: () -> Void

    @State private var selection: String?
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                icon: "person.badge.key",
                title: "Client Certificate Required",
                message: message.isEmpty ? "\(host) requests a client certificate." : message
            )
            .padding([.horizontal, .top])

            Form {
                if identities.isEmpty {
                    Section {
                        Text("No identities imported yet. Import a PKCS#12 (.p12/.pfx) file to continue, or proceed without a certificate.")
                            .foregroundStyle(.secondary)
                        Button("Import Identity…", systemImage: "square.and.arrow.down", action: onImport)
                    }
                } else {
                    Section {
                        Picker("Identity", selection: $selection) {
                            Text("No certificate").tag(nil as String?)
                            ForEach(identities) { identity in
                                Text(identity.displayName).tag(identity.id as String?)
                            }
                        }
                        Toggle("Remember for \(host)", isOn: $remember)
                    } footer: {
                        Button("Import Identity…", action: onImport)
                            .buttonStyle(.link)
                    }
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    onUse(identities.first { $0.id == selection }, remember)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 400)
    }
}

// MARK: - ImportIdentitySheet

/// Imports a PKCS#12 identity file into the Keychain.
struct ImportIdentitySheet: View {
    var store: ClientIdentityStore
    var onDone: (StoredClientIdentity?) -> Void

    @State private var pickingFile = false
    @State private var fileURL: URL?
    @State private var password = ""
    @State private var error: IdentityError?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                icon: "square.and.arrow.down",
                title: "Import Client Identity",
                message: "Choose a PKCS#12 file and enter its password to add it to the Keychain."
            )
            .padding([.horizontal, .top])

            Form {
                Section {
                    Button(fileURL?.lastPathComponent ?? "Choose .p12 or .pfx file…", systemImage: "doc.badge.plus") {
                        pickingFile = true
                    }
                    SecureField("File password", text: $password)
                        .onSubmit { importFile() }
                    if let error {
                        Text(error.localizedDescription)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: importFile)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(fileURL == nil)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 380)
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: Self.pkcs12Types, allowsMultipleSelection: false) { result in
            if case .success(let urls) = result {
                fileURL = urls.first
                error = nil
            }
        }
    }

    private static var pkcs12Types: [UTType] {
        let exts = ["p12", "pfx"].compactMap { UTType(filenameExtension: $0) }
        return exts.isEmpty ? [.data] : exts
    }

    private func importFile() {
        guard let fileURL else { return }
        guard fileURL.startAccessingSecurityScopedResource() else {
            error = .keychainError("Could not read the selected file.")
            return
        }
        defer { fileURL.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: fileURL)
            let identity = try store.importIdentity(pkcs12Data: data, password: password)
            onDone(identity)
        } catch let identityError as IdentityError {
            error = identityError
        } catch {
            self.error = .keychainError(error.localizedDescription)
        }
    }
}

// MARK: - LocationSheet

/// Address entry opened via Cmd+L.
struct LocationSheet: View {
    let initialText: String
    var onSubmit: (String) -> Void
    var onCancel: () -> Void

    @State private var draft: String
    @FocusState private var fieldFocused: Bool

    init(initialText: String, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initialText = initialText
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _draft = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                icon: "globe",
                title: "Open Location",
                message: "Enter a gemini address to visit."
            )
            .padding([.horizontal, .top])

            Form {
                Section {
                    TextField("Enter gemini address", text: $draft)
                        .focused($fieldFocused)
                        .onSubmit { submit() }
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 400)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

/// One check line in the page-info certificate section: a title with an
/// optional status icon, plus an optional trailing detail.
private struct CertCheckRow: View {
    let title: String
    let detail: String?
    var icon: String?
    var iconColor: Color?

    var body: some View {
        LabeledContent {
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } label: {
            if let icon, let iconColor {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: icon)
                        .foregroundStyle(iconColor)
                }
            } else {
                Text(title)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private func certDateString(_ date: Date) -> String {
    date.formatted(.dateTime.year().month().day().hour().minute().second().timeZone())
}

// MARK: - PageInfoSheet

/// Read-only details for the current page, opened from the info button.
struct PageInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let state: BrowserState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                icon: "info.circle",
                title: "Page Info"
            )
            .padding([.horizontal, .top])

            Form {
                Section("Page Information") {
                    LabeledContent("Address") {
                        Text(state.currentURL?.normalizedScheme() ?? "")
                            .monospaced()
                            .textSelection(.enabled)
                    }
                    if let body = state.lastBody {
                        if let code = state.lastStatusCode {
                            LabeledContent("Status") {
                                Text("\(code) \(GeminiStatus(code: code, meta: body.mime)?.statusDescription ?? "Unknown status")")
                                    .textSelection(.enabled)
                            }
                        }
                        LabeledContent("Media type") {
                            Text(body.mime)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Size") {
                            Text("\(body.data.count.formatted(.number)) bytes")
                        }
                    }
                }

                if let certificate = state.lastCertificate, let host = state.currentURL?.host {
                    Section("Server Certificate") {
                        if BrowserState.certificateNameMatches(host: host, dnsNames: certificate.dnsNames) {
                            CertCheckRow(
                                title: "Domain name matches",
                                detail: nil,
                                icon: "checkmark.circle.fill",
                                iconColor: .green
                            )
                        } else if certificate.dnsNames.isEmpty {
                            CertCheckRow(title: "Lists no domain names", detail: nil)
                        } else {
                            CertCheckRow(
                                title: "Domain name does not match",
                                detail: certificate.dnsNames.joined(separator: ", "),
                                icon: "xmark.circle.fill",
                                iconColor: .red
                            )
                        }
                        let now = Date()
                        if now < certificate.notValidBefore {
                            CertCheckRow(
                                title: "Not valid until",
                                detail: certDateString(certificate.notValidBefore),
                                icon: "exclamationmark.triangle.fill",
                                iconColor: .orange
                            )
                        } else if now > certificate.notValidAfter {
                            CertCheckRow(
                                title: "Expired",
                                detail: certDateString(certificate.notValidAfter),
                                icon: "xmark.circle.fill",
                                iconColor: .red
                            )
                        } else {
                            CertCheckRow(
                                title: "Not Expired",
                                detail: certDateString(certificate.notValidAfter),
                                icon: "checkmark.circle.fill",
                                iconColor: .green
                            )
                        }
                    }
                }

                Section("Client-Side Certificate") {
                    if let name = state.boundIdentityDisplayName {
                        Text(name)
                    } else {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done", role: .cancel) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 460)
        .onExitCommand { dismiss() }
    }
}

#Preview("Input prompt") {
    InputPromptSheet(prompt: "What's your name?", sensitive: false) { _ in } onCancel: {}
}

#Preview("Sensitive input") {
    InputPromptSheet(prompt: "Enter the secret code.", sensitive: true) { _ in } onCancel: {}
}

#Preview("Certificate mismatch") {
    CertificateMismatchView(
        url: "gemini://example.com/",
        stored: "aabbccddeeff00112233445566778899",
        presented: "11223344556677889900aabbccddeeff"
    ) {} onGoBack: {}
}

#Preview("Client certificate, empty") {
    ClientCertSheet(host: "example.com", message: "", identities: [], onImport: {}, onUse: { _, _ in }, onCancel: {})
}

#Preview("Client certificate, with identities") {
    ClientCertSheet(
        host: "example.com",
        message: "",
        identities: [
            StoredClientIdentity(id: "mariner.identity.1", displayName: "Alice Example"),
            StoredClientIdentity(id: "mariner.identity.2", displayName: "Bob Example"),
        ],
        onImport: {},
        onUse: { _, _ in },
        onCancel: {}
    )
}

#Preview("Import identity") {
    ImportIdentitySheet(store: ClientIdentityStore()) { _ in }
}

#Preview("Open location") {
    LocationSheet(initialText: "gemini://example.com/") { _ in } onCancel: {}
}

#Preview("Page info") {
    let state = BrowserState(
        fetcher: { _, _, _ in .content(statusCode: 20, mimetype: "text/gemini", data: Data("# Hi".utf8), certificate: nil) },
        settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true),
        bookmarks: BookmarkStore(persistenceURL: nil),
        history: HistoryStore(persistenceURL: nil),
        hosts: HostSettings(persistenceURL: nil)
    )
    state.navigate(to: "gemini://example.com/")
    return PageInfoSheet(state: state)
}

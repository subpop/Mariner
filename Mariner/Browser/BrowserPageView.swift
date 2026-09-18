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

// MARK: - FindBar

struct FindBar: View {
    @Bindable var state: BrowserState
    var focused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var find = state.find
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in Page", text: $find.query)
                .textFieldStyle(.roundedBorder)
                .focused(focused)
                .onChange(of: state.find.query) { _, _ in state.updateFind() }
                .onSubmit { state.find.next() }
            if !state.find.query.isEmpty {
                Text(matchLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Previous Match", systemImage: "chevron.up") { state.find.previous() }
            Button("Next Match", systemImage: "chevron.down") { state.find.next() }
            Button("Done", systemImage: "xmark") {
                state.find.hide()
            }
            .keyboardShortcut(.escape)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .labelStyle(.iconOnly)
    }

    private var matchLabel: String {
        guard !state.find.matches.isEmpty else { return "No matches" }
        return "\(state.find.currentIndex + 1) of \(state.find.matches.count)"
    }
}

// MARK: - PageContent

struct PageContent: View {
    @Bindable var state: BrowserState
    @Binding var showImport: Bool
    @Binding var exporting: Bool
    var onLinkMenu: (LinkMenuAction, String, String?) -> Void = { _, _, _ in }

    /// Zoom derived from the persisted step count. Read here so the page
    /// re-renders when the user zooms.
    private var zoom: PageZoom { PageZoom(steps: state.settings.textZoomOffset) }

    var body: some View {
        Group {
            switch state.page {
        case .blank:
            NoContentView()
        case .welcome:
            WelcomePageView(
                zoom: zoom,
                onOpenLink: { state.openLink($0) },
                onLinkMenu: onLinkMenu,
                isLinkBookmarked: state.isLinkBookmarked
            )
        case .loading(let url):
            VStack {
                ProgressView()
                Text("Loading \(url.hostForDisplay)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .gemtext(_, let blocks):
            if state.showRaw, let body = state.lastBody {
                ScrollView {
                    Text(state.decodedText(body.data, mimetype: body.mime))
                        .font(zoom.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                GemtextView(
                    blocks: blocks,
                    findQuery: state.find.query,
                    findTarget: state.find.target,
                    zoom: zoom,
                    onOpenLink: { state.openLink($0) },
                    onLinkMenu: onLinkMenu,
                    isLinkBookmarked: state.isLinkBookmarked
                )
            }
        case .plainText(_, let mime, let text):
            ScrollView {
                Text(text)
                    .font(zoom.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationSubtitle(mime)
        case .binary(_, let mime, let byteCount):
            BinaryView(mime: mime, byteCount: byteCount) { exporting = true }
        case .image(_, let mime, let data):
            ImageView(mime: mime, data: data) { exporting = true }
        case .input:
            VStack {
                ProgressView()
                Text("Waiting for input…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(_, let message):
            FailureView(message: message, canRetry: state.currentURL != nil) {
                state.reload()
            }
        case .certMismatch(let url, let stored, let presented):
            CertificateMismatchView(
                url: url.normalizedScheme(),
                stored: fingerprintHex(stored),
                presented: fingerprintHex(presented),
                onTrust: { state.trustCertificate() },
                onGoBack: { state.dismissToSafety() }
            )
        case .redirectPrompt(let current, let proposed):
            RedirectView(current: current.normalizedScheme(), proposed: proposed.normalizedScheme()) {
                state.acceptRedirect()
            } onAbort: {
                state.abortRedirect()
            }
        case .clientCert(let url, let message):
            ClientCertInterstitial(host: url.hostForDisplay, message: message) {
                showImport = true
            }
        }
        }
        .environment(\.font, zoom.body)
    }
}

// MARK: - PageZoom

/// Page text zoom.
///
/// `dynamicTypeSize` is inert on macOS: it cannot be changed by users and
/// does not affect text size. Zoom therefore scales explicit font sizes
/// derived from the system text styles instead of shifting Dynamic Type.
struct PageZoom {
    /// Persisted step count; each step multiplies font sizes by 1.1.
    var steps: Int = 0

    var factor: Double { pow(1.1, Double(steps)) }

    private func size(for style: NSFont.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: style).pointSize * factor
    }

    /// Default font for body text, applied via the `\.font` environment.
    var body: Font { Font.system(size: size(for: .body)) }
    var title1: Font { Font.system(size: size(for: .title1), weight: .bold) }
    var title2: Font { Font.system(size: size(for: .title2), weight: .bold) }
    var title3: Font { Font.system(size: size(for: .title3), weight: .bold) }
    var caption: Font { Font.system(size: size(for: .caption1)) }
    var mono: Font { Font.system(size: size(for: .body), design: .monospaced) }
}

// MARK: - NoContentView

/// A truly blank page: renders nothing.
private struct NoContentView: View {
    var body: some View {
        Color.clear
    }
}

// MARK: - WelcomePageView

/// The welcome state: a static welcome document rendered by the gemtext renderer.
private struct WelcomePageView: View {
    var zoom = PageZoom()
    var onOpenLink: (String) -> Void
    var onLinkMenu: (LinkMenuAction, String, String?) -> Void = { _, _, _ in }
    var isLinkBookmarked: (String) -> Bool = { _ in false }

    var body: some View {
        GemtextView(
            blocks: Self.blocks,
            zoom: zoom,
            onOpenLink: onOpenLink,
            onLinkMenu: onLinkMenu,
            isLinkBookmarked: isLinkBookmarked
        )
    }

    private static let blocks: [GemtextBlock] = GemtextParser.parse("""
        # Welcome to Mariner
        A browser for Gemini: small, fast, and free.
        Gemini is a lightweight, privacy-focused alternative to the web built around simple text documents.
        To get started, try visiting:
        => gemini://geminiprotocol.net/ Gemini Protocol
        => gemini://geminiprotocol.net/docs/ Protocol documentation
        => gemini://kennedy.gemi.dev/ Kennedy Search Capsule
        """)
}

// MARK: - FailureView

private struct FailureView: View {
    let message: String
    let canRetry: Bool
    var onRetry: () -> Void

    var body: some View {
        VStack {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("Could not load page")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if canRetry {
                Button("Try Again", systemImage: "arrow.clockwise", action: onRetry)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - BinaryView

private struct BinaryView: View {
    let mime: String
    let byteCount: Int
    var onSave: () -> Void

    var body: some View {
        VStack {
            Image(systemName: "doc")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("This file can't be displayed")
                .font(.headline)
            Text("\(mime) · \(byteCount.formatted(.byteCount(style: .file)))")
                .foregroundStyle(.secondary)
            Button("Save File…", systemImage: "square.and.arrow.down", action: onSave)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ImageView

private struct ImageView: View {
    let mime: String
    let data: Data
    var onSave: () -> Void

    var body: some View {
        if let nsImage = NSImage(data: data) {
            ScrollView {
                VStack {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 720)
                    Text("\(mime) · \(data.count.formatted(.byteCount(style: .file)))")
                        .foregroundStyle(.secondary)
                    Button("Save File…", systemImage: "square.and.arrow.down", action: onSave)
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
        } else {
            BinaryView(mime: mime, byteCount: data.count, onSave: onSave)
        }
    }
}

// MARK: - RedirectView

private struct RedirectView: View {
    let current: String
    let proposed: String
    var onAccept: () -> Void
    var onAbort: () -> Void

    var body: some View {
        VStack {
            Image(systemName: "arrow.turn.up.right")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Redirect to a different server")
                .font(.title2.bold())
            Text("From \(current)\nTo \(proposed)")
                .font(.callout)
                .monospaced()
                .multilineTextAlignment(.center)
            HStack {
                Button("Stay Here", action: onAbort)
                    .keyboardShortcut(.cancelAction)
                Button("Follow Redirect", action: onAccept)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClientCertInterstitial: View {
    let host: String
    let message: String
    var onManage: () -> Void

    var body: some View {
        VStack {
            Image(systemName: "person.badge.key")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Certificate requested")
                .font(.headline)
            Text(message.isEmpty ? "\(host) wants a client certificate. Choose one to continue." : message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Use the certificate sheet to pick an identity, or import one first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Manage Identities…", action: onManage)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// FileDocument wrapper so raw response bodies can be saved via fileExporter.
struct RawDataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

func fingerprintHex(_ bytes: [UInt8]) -> String {
    bytes.map { $0 < 16 ? "0\(String($0, radix: 16))" : String($0, radix: 16) }.joined()
}

#Preview("Gemtext") {
    PageContent(
        state: BrowserState(
            fetcher: { _, _, _ in .content(statusCode: 20, mimetype: "text/gemini", data: Data("# Hello".utf8), certificate: nil) },
            settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true),
            bookmarks: BookmarkStore(persistenceURL: nil),
            history: HistoryStore(persistenceURL: nil),
            hosts: HostSettings(persistenceURL: nil)
        ),
        showImport: .constant(false),
        exporting: .constant(false)
    )
}

#Preview("Welcome") {
    PageContent(
        state: BrowserState(
            fetcher: { _, _, _ in .content(statusCode: 20, mimetype: "text/gemini", data: Data(), certificate: nil) },
            settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true),
            bookmarks: BookmarkStore(persistenceURL: nil),
            history: HistoryStore(persistenceURL: nil),
            hosts: HostSettings(persistenceURL: nil)
        ),
        showImport: .constant(false),
        exporting: .constant(false)
    )
}

#Preview("Blank") {
    let state = BrowserState(
        fetcher: { _, _, _ in .content(statusCode: 20, mimetype: "text/gemini", data: Data(), certificate: nil) },
        settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true),
        bookmarks: BookmarkStore(persistenceURL: nil),
        history: HistoryStore(persistenceURL: nil),
        hosts: HostSettings(persistenceURL: nil)
    )
    state.page = .blank
    return PageContent(state: state, showImport: .constant(false), exporting: .constant(false))
}

#Preview("Failure") {
    FailureView(message: "Connection refused by geminiprotocol.net:1965.", canRetry: true) {}
}

#Preview("Failure, no retry") {
    FailureView(message: "Invalid URL.", canRetry: false) {}
}

#Preview("Binary") {
    BinaryView(mime: "application/pdf", byteCount: 1_234_567) {}
}

#Preview("Redirect") {
    RedirectView(current: "gemini://example.com/", proposed: "gemini://other.example/", onAccept: {}, onAbort: {})
}

#Preview("Client certificate") {
    ClientCertInterstitial(host: "example.com", message: "") {}
}

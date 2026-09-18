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
import Foundation
import GeminiKit

/// Injectable transport for previews and tests.
typealias FetchFn = @Sendable (GeminiURI, ClientIdentity?, TimeInterval) async throws -> GeminiFetchResult
/// Persists a newly trusted server fingerprint.
typealias TrustFn = @Sendable (GeminiURI, [UInt8]) async -> Void
/// Hands a non-gemini URL to the system (default browser, Mail, …).
typealias OpenExternalFn = @MainActor (URL) -> Void

/// Single-window browser state: navigation, fetch engine, and UI prompts.
///
/// The fetch closure and trust closure default to the live `GeminiClient`;
/// tests inject stubs. `identityStore` is set by the app; when nil, `6x`
/// challenges always surface the chooser with an empty list.
@Observable @MainActor
final class BrowserState {
    var page: PageState = .welcome
    var addressText = ""
    var currentURL: GeminiURI?
    var canGoBack = false
    var canGoForward = false

    /// Raw body of the last `2x` response, for Save.
    var lastBody: (mime: String, data: Data)?
    /// Status code of the last `2x` response (usually 20), for Page Info.
    var lastStatusCode: Int?
    /// Certificate the server presented for the current page, for Page Info.
    var lastCertificate: PresentedCertificateInfo?
    /// Set by the Save command; the browser view consumes it into a fileExporter.
    var saveRequested = false
    /// When true, gemtext pages render as raw source instead of parsed blocks.
    var showRaw = false

    // Find-in-page
    let find = FindModel()

    let settings: AppSettings
    let bookmarks: BookmarkStore
    let history: HistoryStore
    let hosts: HostSettings
    var identityStore: ClientIdentityStore?

    private let fetcher: FetchFn
    private let trust: TrustFn
    private let openExternal: OpenExternalFn
    private var backStack: [(GeminiURI, PageState)] = []
    private var forwardStack: [(GeminiURI, PageState)] = []
    private var requestID = 0
    private var loadTask: Task<Void, Never>?

    static let maxRedirectDepth = 5

    init(
        fetcher: @escaping FetchFn = BrowserState.liveFetch,
        trust: @escaping TrustFn = BrowserState.liveTrust,
        openExternal: @escaping OpenExternalFn = BrowserState.liveOpenExternal,
        settings: AppSettings = AppSettings(),
        bookmarks: BookmarkStore = BookmarkStore(),
        history: HistoryStore = HistoryStore(),
        hosts: HostSettings = HostSettings()
    ) {
        self.fetcher = fetcher
        self.trust = trust
        self.openExternal = openExternal
        self.settings = settings
        self.bookmarks = bookmarks
        self.history = history
        self.hosts = hosts
    }

    static func liveFetch(_ uri: GeminiURI, _ identity: ClientIdentity?, _ timeout: TimeInterval) async throws -> GeminiFetchResult {
        try await GeminiClient.shared.fetch(uri, clientIdentity: identity, timeout: timeout)
    }

    static func liveTrust(_ uri: GeminiURI, _ fingerprint: [UInt8]) async {
        await GeminiClient.shared.certificateStore.save(host: uri.host, port: uri.port, fingerprint: fingerprint)
    }

    /// Whether `host` is covered by the certificate's DNS names: an exact
    /// (case-insensitive) match, or a single-label `*.` wildcard match.
    static func certificateNameMatches(host: String, dnsNames: [String]) -> Bool {
        let host = host.lowercased()
        return dnsNames.contains { name in
            let name = name.lowercased()
            if name.hasPrefix("*.") {
                let suffix = String(name.dropFirst(2))
                guard host.count > suffix.count + 1, host.hasSuffix("." + suffix) else { return false }
                return !host.dropLast(suffix.count + 1).contains(".")
            }
            return host == name
        }
    }

    /// Display name of the client identity bound to the current host, if any.
    var boundIdentityDisplayName: String? {
        guard let url = currentURL,
            let id = hosts.identityID(forHost: url.host)
        else { return nil }
        return identityStore?.identities.first { $0.id == id }?.displayName
    }

    static func liveOpenExternal(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    var isBookmarked: Bool {
        guard let currentURL else { return false }
        return bookmarks.contains(currentURL.normalizedScheme())
    }

    // MARK: - Navigation

    func go(to raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        navigate(to: trimmed.normalizedScheme())
    }

    /// Explicit search, bypassing the URL-or-search guessing in `go(to:)`.
    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        navigate(to: searchTarget(for: trimmed))
    }

    /// Navigates to a candidate address, showing a failure page when it doesn't parse.
    func navigate(to candidate: String) {
        do {
            let uri = try GeminiURI.parse(candidate)
            addressText = uri.normalizedScheme()
            load(uri)
        } catch {
            currentURL = nil
            page = .failure(url: nil, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            syncChrome()
        }
    }

    /// Builds the search URL for `query` from the configured search template.
    func searchTarget(for query: String) -> String {
        settings.searchTemplate.replacing("{query}", with: GeminiURI.encode(query))
    }

    func goHome() {
        switch settings.homePage {
        case .blank:
            showLocalPage(.blank)
        case .welcome:
            showLocalPage(.welcome)
        case .url:
            go(to: settings.homePageURL)
        }
    }

    func reload() {
        guard let currentURL else { return }
        load(currentURL, replacing: true)
    }

    /// True while a fetch is in flight.
    var isLoading: Bool {
        if case .loading = page { return true }
        return false
    }

    /// Cancels the in-flight fetch; the page becomes a "Request cancelled." failure.
    /// The abandoned transport runs to its own timeouts, but its late result is
    /// discarded via `requestID`, so the UI unblocks immediately. `currentURL`
    /// is kept so the user can retry with Reload.
    func stop() {
        guard isLoading, let url = currentURL else { return }
        loadTask?.cancel()
        loadTask = nil
        requestID += 1
        page = .failure(url: url, message: "Request cancelled.")
        updateFind()
        syncChrome()
    }

    func back() {
        guard let (url, state) = backStack.popLast(), let currentURL, isRestorable(page) else { return }
        forwardStack.append((currentURL, page))
        self.currentURL = url
        page = state
        addressText = url.normalizedScheme()
        lastBody = nil
        lastStatusCode = nil
        lastCertificate = nil
        showRaw = false
        updateFind()
        syncChrome()
    }

    func forward() {
        guard let (url, state) = forwardStack.popLast(), let currentURL, isRestorable(page) else { return }
        backStack.append((currentURL, page))
        self.currentURL = url
        page = state
        addressText = url.normalizedScheme()
        lastBody = nil
        lastStatusCode = nil
        lastCertificate = nil
        showRaw = false
        updateFind()
        syncChrome()
    }

    func openLink(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Anything with a non-gemini scheme is handed to the system first:
        // relative link targets can otherwise look like bare "host:…" strings,
        // and gemini resolution would swallow real external URLs as relative paths.
        if isExternalLinkTarget(trimmed) {
            if let url = URL(string: trimmed) { openExternal(url) }
            return
        }
        if let target = resolvedLinkTarget(trimmed) {
            load(target)
            return
        }
        page = .failure(url: currentURL, message: "Unsupported link: \(trimmed)")
        syncChrome()
    }

    // MARK: - Link actions (context menu)

    /// True when the raw link target carries a non-gemini scheme and would be
    /// handed to the system instead of fetched by Mariner.
    func isExternalLinkTarget(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return scheme != "gemini"
    }

    /// Resolves a raw gemtext link target to a navigable gemini URI, or nil
    /// when the link is external or unresolvable. Shared by `openLink` and
    /// the link context-menu actions so they agree on the target.
    func resolvedLinkTarget(_ raw: String) -> GeminiURI? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isExternalLinkTarget(trimmed) else { return nil }
        if let base = currentURL, let target = try? base.resolving(trimmed) {
            return target
        }
        // No current page (e.g. the welcome or blank page): absolute gemini URLs
        // still resolve without a base to resolve against.
        if currentURL == nil, let target = try? GeminiURI.parse(trimmed.normalizedScheme()) {
            return target
        }
        return nil
    }

    /// Absolute URL string of a raw link target, resolved against the current
    /// page. Works for gemini and external links; nil when unresolvable.
    func absoluteLinkString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isExternalLinkTarget(trimmed) { return URL(string: trimmed)?.absoluteString }
        return resolvedLinkTarget(trimmed)?.normalizedScheme()
    }

    /// True when the raw link target resolves to an already-bookmarked gemini URL.
    func isLinkBookmarked(_ raw: String) -> Bool {
        guard let target = resolvedLinkTarget(raw) else { return false }
        return bookmarks.contains(target.normalizedScheme())
    }

    /// Toggles a bookmark for a raw gemtext link target. The link label
    /// becomes the bookmark title, falling back to the host. External and
    /// unresolvable links are ignored.
    func toggleLinkBookmark(_ raw: String, label: String?) {
        guard let target = resolvedLinkTarget(raw) else { return }
        let title: String
        if let label, !label.isEmpty {
            title = label
        } else {
            title = target.hostForDisplay
        }
        bookmarks.toggle(url: target.normalizedScheme(), title: title)
    }

    // MARK: - Prompts

    func submitInput(_ text: String) {
        guard case .input(let url, _, _) = page else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        load(url.withInputQuery(GeminiURI.encode(query)))
    }

    func cancelInput() {
        guard case .input(let url, _, _) = page else { return }
        page = .failure(url: url, message: "Input cancelled.")
        syncChrome()
    }

    func acceptRedirect() {
        guard case .redirectPrompt(_, let proposed) = page else { return }
        load(proposed, redirectDepth: 1)
    }

    func abortRedirect() {
        guard case .redirectPrompt(let current, _) = page else { return }
        page = .failure(url: current, message: "Redirect cancelled.")
        syncChrome()
    }

    func trustCertificate() {
        guard case .certMismatch(let url, _, let presented) = page else { return }
        let uri = url
        let fingerprint = presented
        Task { @MainActor [weak self] in
            await self?.trust(uri, fingerprint)
            self?.load(uri, replacing: true)
        }
    }

    /// Retries the `6x` URL presenting `identity` (nil = no certificate).
    /// When `remember` is set, binds the identity to the host for next time.
    func useIdentity(_ identity: StoredClientIdentity?, remember: Bool) {
        guard case .clientCert(let url, _) = page else { return }
        if remember {
            hosts.bindIdentity(identity?.id, toHost: url.host)
        }
        let ref = identity.flatMap { identityStore?.secIdentity(for: $0.id) }.map { ClientIdentity($0) }
        load(url, replacing: true, identityOverride: ref, retriedWithIdentity: true)
    }
    func toggleBookmark() {
        guard let currentURL else { return }
        let canonical = currentURL.normalizedScheme()
        bookmarks.toggle(url: canonical, title: page.historyTitle(fallback: currentURL.hostForDisplay))
    }

    // MARK: - Text zoom

    /// Steps away from the system Dynamic Type size; persisted in settings.
    var textZoomOffset: Int {
        get { settings.textZoomOffset }
        set { settings.textZoomOffset = newValue }
    }

    var canZoomIn: Bool { settings.textZoomOffset < AppSettings.maxTextZoomOffset }
    var canZoomOut: Bool { settings.textZoomOffset > AppSettings.minTextZoomOffset }

    func zoomIn() {
        if canZoomIn { settings.textZoomOffset += 1 }
    }

    func zoomOut() {
        if canZoomOut { settings.textZoomOffset -= 1 }
    }

    func resetZoom() {
        settings.textZoomOffset = 0
    }

    /// Leaves an interstitial (e.g. cert mismatch): back if possible, else blank.
    func dismissToSafety() {
        if canGoBack {
            back()
        } else {
            showLocalPage(.blank)
        }
    }

    /// Shows a local page (blank or welcome), keeping the current page in history.
    private func showLocalPage(_ state: PageState) {
        if let currentURL, isRestorable(page) {
            backStack.append((currentURL, page))
            forwardStack.removeAll()
        }
        currentURL = nil
        addressText = ""
        page = state
        lastBody = nil
        lastStatusCode = nil
        lastCertificate = nil
        showRaw = false
        updateFind()
        syncChrome()
    }

    // MARK: - Find-in-page

    /// Recomputes find matches for the current page.
    func updateFind() {
        find.update(for: page.searchableTexts)
    }

    // MARK: - Engine

    private func load(
        _ uri: GeminiURI,
        redirectDepth: Int = 0,
        replacing: Bool = false,
        identityOverride: ClientIdentity? = nil,
        retriedWithIdentity: Bool = false
    ) {
        if !replacing, let currentURL, isRestorable(page) {
            backStack.append((currentURL, page))
            forwardStack.removeAll()
        }
        currentURL = uri
        addressText = uri.normalizedScheme()
        page = .loading(uri)
        lastBody = nil
        lastStatusCode = nil
        lastCertificate = nil
        showRaw = false
        updateFind()
        syncChrome()

        requestID += 1
        let id = requestID
        let timeout = settings.requestTimeout
        let identity = identityOverride ?? boundIdentity(for: uri.host)
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == id { self.loadTask = nil }
            }
            let outcome: Result<GeminiFetchResult, GeminiFetchError>
            do {
                outcome = .success(try await self.fetcher(uri, identity, timeout))
            } catch is CancellationError {
                outcome = .failure(.connectionFailed("Request cancelled."))
            } catch let fetchError as GeminiFetchError {
                outcome = .failure(fetchError)
            } catch {
                outcome = .failure(.connectionFailed(error.localizedDescription))
            }
            guard self.requestID == id else { return }
            self.apply(outcome, requested: uri, redirectDepth: redirectDepth, retriedWithIdentity: retriedWithIdentity)
        }
    }

    private func apply(
        _ outcome: Result<GeminiFetchResult, GeminiFetchError>,
        requested: GeminiURI,
        redirectDepth: Int,
        retriedWithIdentity: Bool
    ) {
        switch outcome {
        case .failure(let error):
            page = .failure(url: requested, message: error.errorDescription ?? "Request failed.")
        case .success(let result):
            switch result {
            case .content(let statusCode, let mimetype, let data, let certificate):
                applyContent(statusCode: statusCode, mimetype: mimetype, data: data, certificate: certificate, url: requested)
            case .redirect(let target):
                applyRedirect(target: target, requested: requested, redirectDepth: redirectDepth)
                syncChrome()
                return
            case .status(let status):
                applyStatus(status, requested: requested, retriedWithIdentity: retriedWithIdentity)
            case .certMismatch(let stored, let presented):
                page = .certMismatch(url: requested, stored: stored, presented: presented)
            }
        }
        updateFind()
        syncChrome()
    }

    private func applyContent(statusCode: Int, mimetype: String, data: Data, certificate: PresentedCertificateInfo?, url: GeminiURI) {
        lastBody = (mime: mimetype, data: data)
        lastStatusCode = statusCode
        lastCertificate = certificate
        let base = mimetype.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if base == "text/gemini" {
            var source = decodedText(data, mimetype: mimetype)
            // The spec asks clients to ignore a leading BOM in text/gemini.
            if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
            let blocks = GemtextParser.parse(source)
            page = .gemtext(url: url, blocks: blocks)
            history.record(url: url.normalizedScheme(), title: page.historyTitle(fallback: url.hostForDisplay))
        } else if base.hasPrefix("text/") {
            page = .plainText(url: url, mime: base, text: decodedText(data, mimetype: mimetype))
            history.record(url: url.normalizedScheme(), title: url.hostForDisplay)
        } else if base.hasPrefix("image/") {
            page = .image(url: url, mime: base, data: data)
            history.record(url: url.normalizedScheme(), title: url.normalizedScheme())
        } else {
            page = .binary(url: url, mime: base.isEmpty ? mimetype : base, byteCount: data.count)
            history.record(url: url.normalizedScheme(), title: url.hostForDisplay)
        }
    }

    /// Decode a `text/*` body honoring the MIME `charset` parameter (see `charsetParameter(from:)`).
    func decodedText(_ data: Data, mimetype: String) -> String {
        textString(from: data, charset: charsetParameter(from: mimetype))
    }

    /// Extract the raw `charset` MIME parameter value (`; charset=...`), case-insensitively,
    /// unwrapping optional quotes. Returns nil when absent; other parameters are ignored.
    func charsetParameter(from mimetype: String) -> String? {
        let parameters = mimetype.split(separator: ";").dropFirst()
        for parameter in parameters {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset"
            else { continue }
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func applyRedirect(target: String, requested: GeminiURI, redirectDepth: Int) {        guard redirectDepth < Self.maxRedirectDepth else {
            page = .failure(url: requested, message: "Too many redirects.")
            return
        }
        guard let resolved = try? requested.resolving(target) else {
            page = .failure(url: requested, message: "Redirect to an invalid URL: \(target)")
            return
        }
        let sameHost = resolved.host.lowercased() == requested.host.lowercased() && resolved.port == requested.port
        let autoFollow = settings.autoFollowSameHostRedirects
        if sameHost && autoFollow {
            load(resolved, redirectDepth: redirectDepth + 1, replacing: true)
        } else {
            page = .redirectPrompt(current: requested, proposed: resolved)
        }
    }

    private func applyStatus(_ status: GeminiStatus, requested: GeminiURI, retriedWithIdentity: Bool) {
        if status.isInput {
            page = .input(url: requested, prompt: status.meta, sensitive: status.isSensitiveInput)
        } else if status.isTemporaryFailure || status.isPermanentFailure {
            page = .failure(url: requested, message: status.meta.isEmpty ? status.statusDescription : status.meta)
        } else if status.isClientCertFailure {
            if !retriedWithIdentity, let ref = boundIdentity(for: requested.host) {
                load(requested, replacing: true, identityOverride: ref, retriedWithIdentity: true)
                return
            }
            page = .clientCert(url: requested, message: status.meta)
        } else {
            page = .failure(url: requested, message: "Unexpected status \(status.code).")
        }
    }

    private func boundIdentity(for host: String) -> ClientIdentity? {
        guard let id = hosts.identityID(forHost: host),
            let secIdentity = identityStore?.secIdentity(for: id)
        else { return nil }
        return ClientIdentity(secIdentity)
    }

    private func isRestorable(_ state: PageState) -> Bool {
        switch state {
        case .blank, .welcome, .loading: return false
        default: return true
        }
    }

    private func syncChrome() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }
}

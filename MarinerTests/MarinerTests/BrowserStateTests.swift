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
import GeminiKit
import Testing

@testable import Mariner

/// Scripted transport plus captured call details for engine tests.
@MainActor
final class StubTransport {
    var responses: [String: GeminiFetchResult] = [:]
    var failures: [String: GeminiFetchError] = [:]
    var requestedURLs: [String] = []
    var presentedIdentity: [Bool] = []
    var timeouts: [TimeInterval] = []

    func fetch(_ uri: GeminiURI, _ identity: ClientIdentity?, _ timeout: TimeInterval) async throws -> GeminiFetchResult {
        requestedURLs.append(uri.normalizedScheme())
        presentedIdentity.append(identity != nil)
        timeouts.append(timeout)
        if let failure = failures[uri.normalizedScheme()] { throw failure }
        return responses[uri.normalizedScheme()] ?? .status(GeminiStatus(code: 51, meta: "Not found")!)
    }
}

@MainActor
struct BrowserStateTests {
    private func makeState(
        _ transport: StubTransport,
        trust: TrustFn? = nil,
        settings: AppSettings = AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true)
    ) -> BrowserState {
        BrowserState(
            fetcher: transport.fetch,
            trust: trust ?? { _, _ in },
            settings: settings,
            bookmarks: BookmarkStore(persistenceURL: nil),
            history: HistoryStore(persistenceURL: nil),
            hosts: HostSettings(persistenceURL: nil)
        )
    }

    private func settle(_ state: BrowserState) async {
        for _ in 0..<200 {
            if case .loading = state.page {
                try? await Task.sleep(for: .milliseconds(2))
            } else {
                return
            }
        }
    }

    private func uri(_ raw: String) -> GeminiURI {
        try! GeminiURI.parse(raw)
    }

    @Test func invalidAddressShowsFailure() async {
        let transport = StubTransport()
        let state = makeState(transport)
        state.go(to: "gemini://")
        #expect(state.page == .failure(url: nil, message: state.page.failureMessage ?? ""))
        #expect(state.currentURL == nil)
    }

    @Test func whitespaceAddressNavigatesAsHost() async {
        let transport = StubTransport()
        let state = makeState(transport)
        state.go(to: "gemini clients")
        await settle(state)
        #expect(transport.requestedURLs == ["gemini://gemini clients/"])
        #expect(state.page.failureMessage != nil)
    }

    @Test func nonASCIIAddressShowsFailure() async {
        let transport = StubTransport()
        let state = makeState(transport)
        state.go(to: "münchen.de")
        #expect(transport.requestedURLs.isEmpty)
        #expect(state.page.failureMessage != nil)
    }

    @Test func customSearchTemplateSubstituted() async {
        let transport = StubTransport()
        transport.responses["gemini://custom.example/find?some words"] = .content(
            statusCode: 20,
            mimetype: "text/gemini", data: Data("results".utf8), certificate: nil)
        let state = makeState(
            transport,
            settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true, searchEngine: .custom, searchURL: "gemini://custom.example/find?{query}"))
        state.search("some words")
        await settle(state)
        #expect(transport.requestedURLs == ["gemini://custom.example/find?some words"])
    }

    @Test func explicitSearchNavigatesSingleTokenQuery() async {
        let transport = StubTransport()
        transport.responses["gemini://kennedy.gemi.dev/search?linux"] = .content(
            statusCode: 20,
            mimetype: "text/gemini", data: Data("results".utf8), certificate: nil)
        let state = makeState(transport)
        state.search("linux")
        await settle(state)
        #expect(transport.requestedURLs == ["gemini://kennedy.gemi.dev/search?linux"])
        #expect(state.page == .gemtext(url: uri("gemini://kennedy.gemi.dev/search?linux"), blocks: [.text("results")]))
    }

    @Test func addressSingleTokenNavigatesAsHost() async {
        let transport = StubTransport()
        transport.responses["gemini://linux/"] = .content(
            statusCode: 20,
            mimetype: "text/gemini", data: Data("hello".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "linux")
        await settle(state)
        #expect(transport.requestedURLs == ["gemini://linux/"])
        #expect(state.page == .gemtext(url: uri("gemini://linux/"), blocks: [.text("hello")]))
    }

    @Test func unparseableSingleTokenStillFails() async {
        let transport = StubTransport()
        let state = makeState(transport)
        state.go(to: "foo:999999")
        #expect(state.page == .failure(url: nil, message: state.page.failureMessage ?? ""))
        #expect(transport.requestedURLs.isEmpty)
    }

    @Test func gemtextContentRendersAndRecordsHistory() async {
        let transport = StubTransport()
        transport.responses["gemini://example.com/"] = .content(
            statusCode: 20,
            mimetype: "text/gemini", data: Data("# Hello\nWorld".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "example.com")
        await settle(state)
        #expect(state.page == .gemtext(url: uri("gemini://example.com/"), blocks: [.heading(level: 1, text: "Hello"), .text("World")]))
        #expect(state.history.entries.count == 1)
        #expect(state.history.entries[0].title == "Hello")
        #expect(state.canGoBack == false)
        #expect(state.canGoForward == false)
        #expect(transport.timeouts.first == 30)
    }

    @Test func tabSeparatedLinkLabelsSurviveEndToEnd() async {
        let transport = StubTransport()
        transport.responses["gemini://example.com/"] = .content(
            statusCode: 20,
            mimetype: "text/gemini",
            data: Data("=> docs/faq.gmi\tIf you'd like to know more, read our FAQ".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "example.com")
        await settle(state)
        #expect(
            state.page
                == .gemtext(
                    url: uri("gemini://example.com/"),
                    blocks: [
                        .link(
                            url: "docs/faq.gmi",
                            label: "If you'd like to know more, read our FAQ")
                    ]))
    }

    @Test func nonGeminiLinksHandedToSystem() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("home".utf8), certificate: nil)
        var opened: [URL] = []
        let state = BrowserState(
            fetcher: transport.fetch,
            trust: { _, _ in },
            openExternal: { opened.append($0) },
            settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true),
            bookmarks: BookmarkStore(persistenceURL: nil),
            history: HistoryStore(persistenceURL: nil),
            hosts: HostSettings(persistenceURL: nil)
        )
        state.go(to: "gemini://a.com/")
        await settle(state)
        state.openLink("https://example.com/page")
        state.openLink("mailto:hello@example.com")
        #expect(opened.map(\.absoluteString) == ["https://example.com/page", "mailto:hello@example.com"])
        // No gemini fetch issued for external links, and the page is untouched.
        #expect(transport.requestedURLs == ["gemini://a.com/"])
        #expect(state.page == .gemtext(url: uri("gemini://a.com/"), blocks: [.text("home")]))
    }

    @Test func geminiLinksStillFetchInApp() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("home".utf8), certificate: nil)
        transport.responses["gemini://a.com/local"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("local".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/")
        await settle(state)
        state.openLink("/local")
        await settle(state)
        #expect(transport.requestedURLs == ["gemini://a.com/", "gemini://a.com/local"])
        #expect(state.page == .gemtext(url: uri("gemini://a.com/local"), blocks: [.text("local")]))
        state.openLink("gemini://a.com/")
        await settle(state)
        #expect(state.page == .gemtext(url: uri("gemini://a.com/"), blocks: [.text("home")]))
    }

    @Test func linkTargetResolutionMatchesNavigation() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("home".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/")
        await settle(state)
        #expect(state.resolvedLinkTarget("/local") == uri("gemini://a.com/local"))
        #expect(state.resolvedLinkTarget("gemini://b.com/x") == uri("gemini://b.com/x"))
        #expect(state.resolvedLinkTarget("https://example.com/") == nil)
        #expect(state.resolvedLinkTarget("") == nil)
        #expect(state.isExternalLinkTarget("https://example.com/") == true)
        #expect(state.isExternalLinkTarget("mailto:a@b.com") == true)
        #expect(state.isExternalLinkTarget("/local") == false)
        #expect(state.absoluteLinkString("/local") == "gemini://a.com/local")
        #expect(state.absoluteLinkString("https://example.com/p") == "https://example.com/p")
        #expect(state.absoluteLinkString("") == nil)
    }

    @Test func linkBookmarkToggleUsesLabelThenHost() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("home".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/")
        await settle(state)
        #expect(state.isLinkBookmarked("/local") == false)
        state.toggleLinkBookmark("/local", label: "Local page")
        #expect(state.isLinkBookmarked("/local") == true)
        #expect(state.bookmarks.bookmarks.map(\.url) == ["gemini://a.com/local"])
        #expect(state.bookmarks.bookmarks.map(\.title) == ["Local page"])
        state.toggleLinkBookmark("/local", label: "Local page")
        #expect(state.isLinkBookmarked("/local") == false)
        #expect(state.bookmarks.bookmarks.isEmpty)
        // No label: falls back to the host.
        state.toggleLinkBookmark("gemini://b.com/x", label: nil)
        #expect(state.bookmarks.bookmarks.map(\.url) == ["gemini://b.com/x"])
        #expect(state.bookmarks.bookmarks.map(\.title) == ["b.com"])
        // External and unresolvable links are ignored.
        state.toggleLinkBookmark("https://example.com/", label: "Web")
        #expect(state.bookmarks.bookmarks.count == 1)
    }

    @Test func customTimeoutHonored() async {
        let transport = StubTransport()
        transport.responses["gemini://example.com/"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("x".utf8), certificate: nil)
        let state = makeState(transport, settings: AppSettings(requestTimeout: 7, autoFollowSameHostRedirects: true))
        state.go(to: "gemini://example.com/")
        await settle(state)
        #expect(transport.timeouts.first == 7)
    }

    @Test func stopCancelsInFlightLoad() async {
        let state = BrowserState(
            fetcher: { _, _, _ in
                try await Task.sleep(for: .seconds(30))
                throw GeminiFetchError.timedOut
            },
            trust: { _, _ in },
            settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true),
            bookmarks: BookmarkStore(persistenceURL: nil),
            history: HistoryStore(persistenceURL: nil),
            hosts: HostSettings(persistenceURL: nil)
        )
        #expect(!state.isLoading)
        state.go(to: "gemini://example.com/")
        #expect(state.isLoading)
        state.stop()
        #expect(!state.isLoading)
        #expect(state.page == .failure(url: uri("gemini://example.com/"), message: "Request cancelled."))
        #expect(state.currentURL == uri("gemini://example.com/"))
        // Stopping when idle is a no-op.
        state.stop()
        #expect(state.page == .failure(url: uri("gemini://example.com/"), message: "Request cancelled."))
    }

    @Test func homeBlankShowsEmptyPageWithoutFetching() {
        let transport = StubTransport()
        let state = makeState(transport, settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true, homePage: .blank))
        state.goHome()
        #expect(state.page == .blank)
        #expect(state.currentURL == nil)
        #expect(transport.requestedURLs.isEmpty)
    }

    @Test func homeWelcomeShowsWelcomePageWithoutFetching() {
        let transport = StubTransport()
        let state = makeState(transport, settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true, homePage: .welcome))
        state.goHome()
        #expect(state.page == .welcome)
        #expect(state.currentURL == nil)
        #expect(transport.requestedURLs.isEmpty)
    }

    @Test func homeURLLoadsConfiguredURL() async {
        let transport = StubTransport()
        transport.responses["gemini://home.example/"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("home".utf8), certificate: nil)
        let state = makeState(
            transport,
            settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true, homePage: .url, homePageURL: "gemini://home.example/"))
        state.goHome()
        await settle(state)
        #expect(state.page == .gemtext(url: uri("gemini://home.example/"), blocks: [.text("home")]))
    }

    @Test func mimeDispatch() async {
        let transport = StubTransport()
        transport.responses["gemini://example.com/a"] = .content(statusCode: 20, mimetype: "text/plain; charset=utf-8", data: Data("hi".utf8), certificate: nil)
        transport.responses["gemini://example.com/b"] = .content(statusCode: 20, mimetype: "image/png", data: Data([1, 2, 3]), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://example.com/a")
        await settle(state)
        #expect(state.page == .plainText(url: uri("gemini://example.com/a"), mime: "text/plain", text: "hi"))
        state.go(to: "gemini://example.com/b")
        await settle(state)
        #expect(state.page == .image(url: uri("gemini://example.com/b"), mime: "image/png", data: Data([1, 2, 3])))
        #expect(state.lastBody?.data.count == 3)
    }

    @Test func charsetParameterDecoding() async {
        let transport = StubTransport()
        transport.responses["gemini://example.com/ascii"] = .content(statusCode: 20, mimetype: "text/plain; charset=us-ascii", data: Data("plain ascii".utf8), certificate: nil)
        transport.responses["gemini://example.com/quoted"] = .content(statusCode: 20, mimetype: "text/plain; charset=\"utf-8\"", data: Data("héllo".utf8), certificate: nil)
        transport.responses["gemini://example.com/unknown"] = .content(statusCode: 20, mimetype: "text/plain; charset=iso-8859-1", data: Data("héllo".utf8), certificate: nil)
        // 0xE9 alone is not valid UTF-8; decoding falls back to lossy ASCII.
        transport.responses["gemini://example.com/lossy"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data([0x63, 0x61, 0x66, 0xE9]), certificate: nil)
        // Leading BOM is ignored for text/gemini.
        transport.responses["gemini://example.com/bom"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data([0xEF, 0xBB, 0xBF]) + Data("# Title".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://example.com/ascii")
        await settle(state)
        #expect(state.page == .plainText(url: uri("gemini://example.com/ascii"), mime: "text/plain", text: "plain ascii"))
        state.go(to: "gemini://example.com/quoted")
        await settle(state)
        #expect(state.page == .plainText(url: uri("gemini://example.com/quoted"), mime: "text/plain", text: "héllo"))
        state.go(to: "gemini://example.com/unknown")
        await settle(state)
        #expect(state.page == .plainText(url: uri("gemini://example.com/unknown"), mime: "text/plain", text: "héllo"))
        state.go(to: "gemini://example.com/lossy")
        await settle(state)
        #expect(state.page == .gemtext(url: uri("gemini://example.com/lossy"), blocks: [.text("caf�")]))
        state.go(to: "gemini://example.com/bom")
        await settle(state)
        #expect(state.page == .gemtext(url: uri("gemini://example.com/bom"), blocks: [.heading(level: 1, text: "Title")]))
    }

    @Test func imageHistoryTitleUsesURL() async {
        let transport = StubTransport()
        transport.responses["gemini://example.com/pic.png"] = .content(statusCode: 20, mimetype: "image/png", data: Data([1, 2, 3]), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://example.com/pic.png")
        await settle(state)
        #expect(state.history.entries.count == 1)
        #expect(state.history.entries[0].title == "gemini://example.com/pic.png")
    }

    @Test func transportErrorShowsFailure() async {
        let transport = StubTransport()
        transport.failures["gemini://example.com/"] = .timedOut
        let state = makeState(transport)
        state.go(to: "gemini://example.com/")
        await settle(state)
        #expect(state.page == .failure(url: uri("gemini://example.com/"), message: "Connection timed out"))
    }

    @Test func sameHostRedirectAutoFollows() async {
        let transport = StubTransport()
        transport.responses["gemini://example.com/"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("home".utf8), certificate: nil)
        transport.responses["gemini://example.com/old"] = .redirect(target: "/new")
        transport.responses["gemini://example.com/new"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("new".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://example.com/")
        await settle(state)
        state.go(to: "gemini://example.com/old")
        await settle(state)
        #expect(state.page == .gemtext(url: uri("gemini://example.com/new"), blocks: [.text("new")]))
        // The redirect hop leaves no back-stack entry of its own.
        state.back()
        #expect(state.page == .gemtext(url: uri("gemini://example.com/"), blocks: [.text("home")]))
    }

    @Test func sameHostRedirectPromptsWhenAutoFollowDisabled() async {
        let transport = StubTransport()
        transport.responses["gemini://example.com/old"] = .redirect(target: "/new")
        transport.responses["gemini://example.com/new"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("new".utf8), certificate: nil)
        let state = makeState(transport, settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: false))
        state.go(to: "gemini://example.com/old")
        await settle(state)
        #expect(state.page == .redirectPrompt(current: uri("gemini://example.com/old"), proposed: uri("gemini://example.com/new")))
        state.acceptRedirect()
        await settle(state)
        #expect(state.page == .gemtext(url: uri("gemini://example.com/new"), blocks: [.text("new")]))
    }

    @Test func crossHostRedirectPrompts() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/"] = .redirect(target: "gemini://b.com/")
        transport.responses["gemini://b.com/"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("b".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/")
        await settle(state)
        #expect(state.page == .redirectPrompt(current: uri("gemini://a.com/"), proposed: uri("gemini://b.com/")))
        state.abortRedirect()
        #expect(state.page == .failure(url: uri("gemini://a.com/"), message: "Redirect cancelled."))
        state.go(to: "gemini://a.com/")
        await settle(state)
        state.acceptRedirect()
        await settle(state)
        #expect(state.page == .gemtext(url: uri("gemini://b.com/"), blocks: [.text("b")]))
    }

    @Test func redirectLoopFails() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/"] = .redirect(target: "/")
        let state = makeState(transport)
        state.go(to: "gemini://a.com/")
        await settle(state)
        #expect(state.page == .failure(url: uri("gemini://a.com/"), message: "Too many redirects."))
    }

    @Test func inputRoundTrip() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/s"] = .status(GeminiStatus(code: 10, meta: "Name?")!)
        transport.responses["gemini://a.com/s?Bob"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("hi Bob".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/s")
        await settle(state)
        #expect(state.page == .input(url: uri("gemini://a.com/s"), prompt: "Name?", sensitive: false))
        state.submitInput("Bob")
        await settle(state)
        #expect(transport.requestedURLs.last == "gemini://a.com/s?Bob")
        #expect(state.page == .gemtext(url: uri("gemini://a.com/s?Bob"), blocks: [.text("hi Bob")]))
    }

    @Test func sensitiveInputFlagged() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/s"] = .status(GeminiStatus(code: 11, meta: "Password?")!)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/s")
        await settle(state)
        #expect(state.page == .input(url: uri("gemini://a.com/s"), prompt: "Password?", sensitive: true))
        state.cancelInput()
        #expect(state.page == .failure(url: uri("gemini://a.com/s"), message: "Input cancelled."))
    }

    @Test func failureStatusUsesMetaOrDescription() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/x"] = .status(GeminiStatus(code: 41, meta: "Try later")!)
        transport.responses["gemini://a.com/y"] = .status(GeminiStatus(code: 51, meta: "")!)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/x")
        await settle(state)
        #expect(state.page == .failure(url: uri("gemini://a.com/x"), message: "Try later"))
        state.go(to: "gemini://a.com/y")
        await settle(state)
        if case .failure(_, let message) = state.page {
            #expect(!message.isEmpty)
        } else {
            Issue.record("expected failure page")
        }
    }

    @Test func clientCertChallengeWithoutIdentity() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/"] = .status(GeminiStatus(code: 60, meta: "Who are you?")!)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/")
        await settle(state)
        #expect(state.page == .clientCert(url: uri("gemini://a.com/"), message: "Who are you?"))
        #expect(transport.presentedIdentity == [false])
    }

    @Test func certMismatchTrustRefetches() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/"] = .certMismatch(storedFingerprint: [1], presentedFingerprint: [2])
        actor Trusted {
            var values: [(GeminiURI, [UInt8])] = []
            func append(_ uri: GeminiURI, _ fp: [UInt8]) { values.append((uri, fp)) }
        }
        let trusted = Trusted()
        let trusting = BrowserState(
            fetcher: transport.fetch,
            trust: { uri, fp in await trusted.append(uri, fp) },
            settings: AppSettings(requestTimeout: 30, autoFollowSameHostRedirects: true),
            bookmarks: BookmarkStore(persistenceURL: nil),
            history: HistoryStore(persistenceURL: nil),
            hosts: HostSettings(persistenceURL: nil)
        )
        trusting.go(to: "gemini://a.com/")
        await settle(trusting)
        #expect(trusting.page == .certMismatch(url: uri("gemini://a.com/"), stored: [1], presented: [2]))
        transport.responses["gemini://a.com/"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("ok".utf8), certificate: nil)
        trusting.trustCertificate()
        for _ in 0..<200 {
            if await trusted.values.count > 0 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        await settle(trusting)
        let logged = await trusted.values
        #expect(logged.count == 1)
        #expect(logged[0].0 == uri("gemini://a.com/"))
        #expect(logged[0].1 == [2])
        #expect(trusting.page == .gemtext(url: uri("gemini://a.com/"), blocks: [.text("ok")]))
    }

    @Test func noBoundIdentityDisplayNameByDefault() async {
        let transport = StubTransport()
        let state = makeState(transport)
        #expect(state.boundIdentityDisplayName == nil)
    }

    @Test func backForwardChrome() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/1"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("one".utf8), certificate: nil)
        transport.responses["gemini://a.com/2"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("two".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/1")
        await settle(state)
        state.go(to: "gemini://a.com/2")
        await settle(state)
        #expect(state.canGoBack == true)
        #expect(state.canGoForward == false)
        state.back()
        #expect(state.page == .gemtext(url: uri("gemini://a.com/1"), blocks: [.text("one")]))
        #expect(state.canGoForward == true)
        state.forward()
        #expect(state.page == .gemtext(url: uri("gemini://a.com/2"), blocks: [.text("two")]))
        #expect(state.canGoForward == false)
        #expect(state.canGoBack == true)
    }

    @Test func findMatchesAcrossBlocks() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/"] = .content(
            statusCode: 20,
            mimetype: "text/gemini", data: Data("# Gemini gemini\nplain gemini here".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/")
        await settle(state)
        state.find.query = "gemini"
        state.updateFind()
        #expect(state.find.matches.count == 3)
        #expect(state.find.target == FindModel.Target(segment: 0, occurrence: 0))
        state.find.next()
        state.find.next()
        #expect(state.find.target == FindModel.Target(segment: 1, occurrence: 0))
        state.find.next()
        #expect(state.find.target == FindModel.Target(segment: 0, occurrence: 0))
        state.find.previous()
        #expect(state.find.target == FindModel.Target(segment: 1, occurrence: 0))
    }

    @Test func toggleBookmark() async {
        let transport = StubTransport()
        transport.responses["gemini://a.com/"] = .content(statusCode: 20, mimetype: "text/gemini", data: Data("x".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/")
        await settle(state)
        #expect(state.isBookmarked == false)
        state.toggleBookmark()
        #expect(state.isBookmarked == true)
        state.toggleBookmark()
        #expect(state.isBookmarked == false)
    }

    @Test func textZoomStepsAndClamps() {
        let state = makeState(StubTransport())
        #expect(state.textZoomOffset == 0)
        #expect(state.canZoomOut == true)
        state.zoomIn()
        #expect(state.textZoomOffset == 1)
        state.zoomOut()
        state.zoomOut()
        #expect(state.textZoomOffset == -1)
        state.resetZoom()
        #expect(state.textZoomOffset == 0)
        for _ in 0..<100 { state.zoomIn() }
        #expect(state.textZoomOffset == AppSettings.maxTextZoomOffset)
        #expect(state.canZoomIn == false)
        for _ in 0..<100 { state.zoomOut() }
        #expect(state.textZoomOffset == AppSettings.minTextZoomOffset)
        #expect(state.canZoomOut == false)
    }

    @Test func textZoomFactorScalesGeometrically() {
        #expect(PageZoom().factor == 1)
        #expect(PageZoom(steps: 1).factor > 1)
        #expect(PageZoom(steps: -1).factor < 1)
        let oneStep = PageZoom(steps: 1).factor
        #expect(abs(PageZoom(steps: 2).factor - oneStep * oneStep) < 1e-9)
    }

    @Test func contentResponseStoresStatusCodeAndCertificate() async {
        let transport = StubTransport()
        let presented = PresentedCertificateInfo(
            fingerprint: [1, 2, 3],
            notValidBefore: Date(timeIntervalSince1970: 0),
            notValidAfter: Date(timeIntervalSinceNow: 60 * 60 * 24),
            dnsNames: ["a.com"],
            subjectSummary: nil
        )
        transport.responses["gemini://a.com/"] = .content(
            statusCode: 21, mimetype: "text/gemini", data: Data("x".utf8), certificate: presented)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/")
        await settle(state)
        #expect(state.lastStatusCode == 21)
        #expect(state.lastCertificate?.dnsNames == ["a.com"])
    }

    @Test func goingBackClearsCertificateDetails() async {
        let transport = StubTransport()
        let presented = PresentedCertificateInfo(
            fingerprint: [1, 2, 3],
            notValidBefore: Date(timeIntervalSince1970: 0),
            notValidAfter: Date(timeIntervalSinceNow: 60 * 60 * 24),
            dnsNames: ["a.com"],
            subjectSummary: nil
        )
        transport.responses["gemini://a.com/"] = .content(
            statusCode: 20, mimetype: "text/gemini", data: Data("a".utf8), certificate: presented)
        transport.responses["gemini://a.com/b"] = .content(
            statusCode: 20, mimetype: "text/gemini", data: Data("b".utf8), certificate: nil)
        let state = makeState(transport)
        state.go(to: "gemini://a.com/")
        await settle(state)
        state.go(to: "gemini://a.com/b")
        await settle(state)
        state.back()
        #expect(state.lastStatusCode == nil)
        #expect(state.lastCertificate == nil)
    }

    @Test func certificateNameMatchesHost() {
        #expect(BrowserState.certificateNameMatches(host: "a.com", dnsNames: ["a.com"]) == true)
        #expect(BrowserState.certificateNameMatches(host: "A.COM", dnsNames: ["a.com"]) == true)
        #expect(BrowserState.certificateNameMatches(host: "b.a.com", dnsNames: ["*.a.com"]) == true)
        #expect(BrowserState.certificateNameMatches(host: "a.com", dnsNames: ["*.a.com"]) == false)
        #expect(BrowserState.certificateNameMatches(host: "c.b.a.com", dnsNames: ["*.a.com"]) == false)
        #expect(BrowserState.certificateNameMatches(host: "b.com", dnsNames: ["a.com"]) == false)
        #expect(BrowserState.certificateNameMatches(host: "a.com", dnsNames: []) == false)
    }
}

private extension PageState {
    var failureMessage: String? {
        if case .failure(_, let message) = self { return message }
        return nil
    }
}

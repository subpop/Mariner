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
import Observation

/// Home page preference, mirroring Safari's blank / homepage / custom URL choice.
enum HomePage: String, Hashable, Sendable, CaseIterable {
    case blank
    case welcome
    case url

    var label: String {
        switch self {
        case .blank: "Blank page"
        case .welcome: "Welcome page"
        case .url: "Custom URL"
        }
    }
}

/// Search engine preference: a built-in template or a custom one.
enum SearchEngine: String, Hashable, Sendable, CaseIterable {
    case kennedy
    case custom

    var label: String {
        switch self {
        case .kennedy: "Kennedy (gemi.dev)"
        case .custom: "Custom…"
        }
    }

    /// Search URL template; the query replaces `{query}`.
    /// Nil for `.custom`, which uses `AppSettings.searchURL` instead.
    var template: String? {
        switch self {
        case .kennedy: "gemini://kennedy.gemi.dev/search?{query}"
        case .custom: nil
        }
    }
}

/// User preferences, persisted in UserDefaults with built-in fallbacks.
@Observable @MainActor
final class AppSettings {
    static let defaultTimeout: TimeInterval = 30
    static let defaultHomePageURL = "gemini://geminiprotocol.net/"
    static let defaultSearchURL = "gemini://kennedy.gemi.dev/search?{query}"

    var requestTimeout: TimeInterval {
        didSet {
            if requestTimeout <= 0 { requestTimeout = Self.defaultTimeout }
            persist()
        }
    }
    var autoFollowSameHostRedirects: Bool {
        didSet { persist() }
    }
    /// Which page Home navigates to.
    var homePage: HomePage {
        didSet { persist() }
    }
    /// URL loaded when `homePage` is `.url`. Kept when switching kinds.
    var homePageURL: String {
        didSet { persist() }
    }
    /// Search engine used for address-bar queries.
    var searchEngine: SearchEngine {
        didSet { persist() }
    }
    /// Custom search template, used when `searchEngine` is `.custom`.
    /// Kept when switching engines. The query replaces `{query}`.
    var searchURL: String {
        didSet { persist() }
    }

    /// Active search template for the selected engine.
    var searchTemplate: String {
        searchEngine.template ?? searchURL
    }

    /// Zoom bounds, in steps. Each step scales page fonts (see PageZoom).
    static let minTextZoomOffset = -3
    static let maxTextZoomOffset = 6

    /// Page text zoom steps. Persisted.
    var textZoomOffset: Int {
        didSet {
            // Guarded: assigning here re-enters didSet (as with requestTimeout below).
            let clamped = min(max(textZoomOffset, Self.minTextZoomOffset), Self.maxTextZoomOffset)
            if clamped != textZoomOffset {
                textZoomOffset = clamped
            }
            persist()
        }
    }

    /// Whether bookmarks sync via iCloud key-value storage. Persisted.
    var iCloudBookmarkSync: Bool {
        didSet { persist() }
    }

    private let defaults: UserDefaults?

    init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        requestTimeout = defaults.double(forKey: Self.timeoutKey).nonZeroOr(Self.defaultTimeout)
        autoFollowSameHostRedirects = defaults.object(forKey: Self.autoFollowKey) as? Bool ?? true
        homePage = HomePage(rawValue: defaults.string(forKey: Self.homePageKey) ?? "") ?? .welcome
        homePageURL = defaults.string(forKey: Self.homePageURLKey) ?? Self.defaultHomePageURL
        searchEngine = SearchEngine(rawValue: defaults.string(forKey: Self.searchEngineKey) ?? "") ?? .kennedy
        searchURL = defaults.string(forKey: Self.searchURLKey) ?? Self.defaultSearchURL
        textZoomOffset = min(max(defaults.integer(forKey: Self.textZoomKey), Self.minTextZoomOffset), Self.maxTextZoomOffset)
        iCloudBookmarkSync = defaults.object(forKey: Self.iCloudBookmarkSyncKey) as? Bool ?? true
    }

    /// In-memory variant for previews and tests.
    init(requestTimeout: TimeInterval,
         autoFollowSameHostRedirects: Bool,
         homePage: HomePage = .welcome,
         homePageURL: String = defaultHomePageURL,
         searchEngine: SearchEngine = .kennedy,
         searchURL: String = defaultSearchURL,
         textZoomOffset: Int = 0,
         iCloudBookmarkSync: Bool = true) {
        defaults = nil
        self.requestTimeout = requestTimeout
        self.autoFollowSameHostRedirects = autoFollowSameHostRedirects
        self.homePage = homePage
        self.homePageURL = homePageURL
        self.searchEngine = searchEngine
        self.searchURL = searchURL
        self.textZoomOffset = min(max(textZoomOffset, Self.minTextZoomOffset), Self.maxTextZoomOffset)
        self.iCloudBookmarkSync = iCloudBookmarkSync
    }

    private func persist() {
        defaults?.set(requestTimeout, forKey: Self.timeoutKey)
        defaults?.set(autoFollowSameHostRedirects, forKey: Self.autoFollowKey)
        defaults?.set(homePage.rawValue, forKey: Self.homePageKey)
        defaults?.set(homePageURL, forKey: Self.homePageURLKey)
        defaults?.set(searchEngine.rawValue, forKey: Self.searchEngineKey)
        defaults?.set(searchURL, forKey: Self.searchURLKey)
        defaults?.set(textZoomOffset, forKey: Self.textZoomKey)
        defaults?.set(iCloudBookmarkSync, forKey: Self.iCloudBookmarkSyncKey)
    }

    private static let timeoutKey = "requestTimeout"
    private static let autoFollowKey = "autoFollowSameHostRedirects"
    private static let homePageKey = "homePage"
    private static let homePageURLKey = "homePageURL"
    private static let searchEngineKey = "searchEngine"
    private static let searchURLKey = "searchURL"
    private static let textZoomKey = "textZoomOffset"
    private static let iCloudBookmarkSyncKey = "iCloudBookmarkSync"
}

private extension Double {
    func nonZeroOr(_ defaultValue: Double) -> Double {
        self > 0 ? self : defaultValue
    }
}

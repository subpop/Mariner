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

/// Everything the browser can display for the current navigation.
enum PageState: Equatable {
    case blank
    case welcome
    case loading(GeminiURI)
    case gemtext(url: GeminiURI, blocks: [GemtextBlock])
    case plainText(url: GeminiURI, mime: String, text: String)
    case binary(url: GeminiURI, mime: String, byteCount: Int)
    case image(url: GeminiURI, mime: String, data: Data)
    case input(url: GeminiURI, prompt: String, sensitive: Bool)
    case failure(url: GeminiURI?, message: String)
    case certMismatch(url: GeminiURI, stored: [UInt8], presented: [UInt8])
    case redirectPrompt(current: GeminiURI, proposed: GeminiURI)
    case clientCert(url: GeminiURI, message: String)

    /// Text segments searched by find-in-page, in display order.
    var searchableTexts: [String] {
        switch self {
        case .gemtext(_, let blocks): return blocks.map(\.searchableText)
        case .plainText(_, _, let text): return [text]
        default: return []
        }
    }

    /// Title for history entries.
    func historyTitle(fallback: String) -> String {
        if case .gemtext(_, let blocks) = self,
            let heading = blocks.first(where: { $0.isHeading })
        {
            return heading.plainText
        }
        return fallback
    }
}

extension GemtextBlock {
    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }

    var plainText: String {
        switch self {
        case .text(let s), .bullet(let s), .quote(let s), .pre(let s): return s
        case .heading(_, let s): return s
        case .table(let rows): return rows.map { $0.joined(separator: " ") }.joined(separator: " ")
        case .link(_, let label): return label ?? ""
        }
    }

    var searchableText: String {
        switch self {
        case .link(let url, let label): return [label, url].compactMap { $0 }.joined(separator: " ")
        default: return plainText
        }
    }
}

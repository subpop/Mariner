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

/// Find-in-page state: query, matches, and the selected target.
@Observable @MainActor
final class FindModel {
    /// One query occurrence: a segment index plus the occurrence within it.
    struct Match: Equatable {
        let segment: Int
        let occurrence: Int
    }

    /// The occurrence the page view scrolls to and highlights.
    struct Target: Equatable {
        let segment: Int
        let occurrence: Int
    }

    var isVisible = false
    var query = ""
    private(set) var matches: [Match] = []
    private(set) var currentIndex = 0
    private(set) var target: Target?

    /// Recomputes matches for the given text segments (in display order).
    func update(for texts: [String]) {
        matches = []
        currentIndex = 0
        target = nil
        guard !query.isEmpty else { return }
        for (index, text) in texts.enumerated() {
            let count = findRanges(in: text, query: query).count
            for occurrence in 0..<count {
                matches.append(Match(segment: index, occurrence: occurrence))
            }
        }
        if let first = matches.first {
            target = Target(segment: first.segment, occurrence: first.occurrence)
        }
    }

    func next() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
        selectCurrent()
    }

    func previous() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
        selectCurrent()
    }

    /// Hides the bar and clears the search.
    func hide() {
        isVisible = false
        query = ""
        matches = []
        currentIndex = 0
        target = nil
    }

    private func selectCurrent() {
        let match = matches[currentIndex]
        target = Target(segment: match.segment, occurrence: match.occurrence)
    }
}

/// Case- and diacritic-insensitive occurrences of `query` in `text`.
func findRanges(in text: String, query: String) -> [Range<String.Index>] {
    guard !query.isEmpty else { return [] }
    var ranges: [Range<String.Index>] = []
    var from = text.startIndex
    while from < text.endIndex,
        let match = text.range(
            of: query, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex)
    {
        ranges.append(match)
        from = match.upperBound
    }
    return ranges
}

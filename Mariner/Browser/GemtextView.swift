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

/// Text with every query occurrence marked; the targeted one strongly.
func highlightedText(_ text: String, query: String, highlightOccurrence: Int?) -> Text {
    guard !query.isEmpty else { return Text(text) }
    let ranges = findRanges(in: text, query: query)
    guard !ranges.isEmpty else { return Text(text) }
    var attributed = AttributedString()
    var cursor = text.startIndex
    for (index, range) in ranges.enumerated() {
        attributed += AttributedString(String(text[cursor..<range.lowerBound]))
        var container = AttributeContainer()
        container.backgroundColor = index == highlightOccurrence ? .orange : .yellow.opacity(0.45)
        var mark = AttributedString(String(text[range]))
        mark.mergeAttributes(container)
        attributed += mark
        cursor = range.upperBound
    }
    attributed += AttributedString(String(text[cursor...]))
    return Text(attributed)
}

/// Link context-menu actions surfaced from a gemtext link row. The raw
/// target and optional label travel with the action; resolution happens in
/// `BrowserState` so the menu and navigation agree on the target.
enum LinkMenuAction {
    case copy
    case newTab
    case newWindow
    case bookmark
}

/// SwiftUI-native gemtext document: selectable text, link buttons, find highlight.
struct GemtextView: View {
    let blocks: [GemtextBlock]
    var findQuery = ""
    var findTarget: FindModel.Target?
    var zoom = PageZoom()
    var onOpenLink: (String) -> Void
    var onLinkMenu: (LinkMenuAction, String, String?) -> Void = { _, _, _ in }
    var isLinkBookmarked: (String) -> Bool = { _ in false }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(blocks.indices, id: \.self) { index in
                        blockView(blocks[index], index: index)
                            .id(index)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .textSelection(.enabled)
            .onChange(of: findTarget) { _, target in
                if let target {
                    withAnimation {
                        proxy.scrollTo(target.segment, anchor: .center)
                    }
                }
            }
        }
    }

    private func highlight(forSegment index: Int, in text: String) -> Text {
        let occurrence: Int? = findTarget?.segment == index ? findTarget?.occurrence : nil
        return highlightedText(text, query: findQuery, highlightOccurrence: occurrence)
    }

    @ViewBuilder
    private func blockView(_ block: GemtextBlock, index: Int) -> some View {
        switch block {
        case .text(let text):
            highlight(forSegment: index, in: text)
        case .heading(let level, let text):
            highlight(forSegment: index, in: text)
                .font(level == 1 ? zoom.title1 : level == 2 ? zoom.title2 : zoom.title3)
                .padding(.top, 4)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline) {
                Text("•").foregroundStyle(.secondary)
                highlight(forSegment: index, in: text)
            }
        case .quote(let text):
            HStack(alignment: .top) {
                Image(systemName: "quote.opening")
                    .foregroundStyle(.secondary.opacity(0.4))
                    .font(.title)
                highlight(forSegment: index, in: text)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
        case .pre(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(zoom.mono)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.hidden)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.05))
            .clipShape(.rect(cornerRadius: 6))
        case .table(let rows):
            TableBlockView(
                rows: rows,
                segment: index,
                findQuery: findQuery,
                findTarget: findTarget,
                zoom: zoom
            )
        case .link(let url, let label):
            Button {
                onOpenLink(url)
            } label: {
                HStack {
                    Image(systemName: isExternalLink(url) ? "globe" : "arrow.up.right")
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text(label ?? url)
                        if label != nil {
                            Text(url)
                                .font(zoom.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
            }
            .buttonStyle(.link)
            .pointerStyle(.link)
            .help(url)
            .contextMenu {
                Button("Copy Link", systemImage: "doc.on.doc") {
                    onLinkMenu(.copy, url, label)
                }
                // External links open in the system browser, which manages
                // its own tabs and bookmarks — only gemini links get the rest.
                if !isExternalLink(url) {
                    Button("Open in New Tab", systemImage: "plus.square.on.square") {
                        onLinkMenu(.newTab, url, label)
                    }
                    Button("Open in New Window", systemImage: "macwindow") {
                        onLinkMenu(.newWindow, url, label)
                    }
                    Divider()
                    Button(
                        isLinkBookmarked(url) ? "Remove Bookmark" : "Bookmark This Link",
                        systemImage: "bookmark"
                    ) {
                        onLinkMenu(.bookmark, url, label)
                    }
                }
            }
        }
    }

    /// True when the link target carries a non-gemini scheme, meaning it will
    /// be handed to the system instead of fetched by Mariner. Mirrors the
    /// scheme check in `BrowserState.openLink`.
    private func isExternalLink(_ raw: String) -> Bool {
        guard
            let scheme = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?
                .scheme?.lowercased()
        else {
            return false
        }
        return scheme != "gemini"
    }
}

/// Native grid for a parsed ` ```table ` block; the first row is the header.
struct TableBlockView: View {
    let rows: [[String]]
    let segment: Int
    var findQuery = ""
    var findTarget: FindModel.Target?
    var zoom = PageZoom()

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { column in
                            cell(rows[row][column], header: row == 0)
                        }
                    }
                    if row == 0, rows.count > 1 {
                        Divider()
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .font(zoom.body)
        }
        .scrollIndicators(.hidden)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05))
        .clipShape(.rect(cornerRadius: 6))
    }

    private func cell(_ text: String, header: Bool) -> Text {
        let occurrence = findTarget?.segment == segment ? findTarget?.occurrence : nil
        let highlighted = highlightedText(
            text, query: findQuery, highlightOccurrence: occurrence)
        return header ? highlighted.bold() : highlighted
    }
}

#Preview {
    GemtextView(
        blocks: GemtextParser.parse(
            """
            # Welcome to Gemini
            A minimal protocol for a-edge publishing.
            ## Getting started
            * Fast pages
            * No tracking
            > Simplicity is a feature.
            ```
            gemini://example.com/
            ```
            => gemini://geminiprotocol.net/ Gemini project
            => https://example.com/ An https link
            Trailing prose with Gemini mentioned twice: gemini gemini.
            ```table
            | Engine | Tier |
            | :----- | ---: |
            | arm    | 2    |
            ```
            """
        ),
        findQuery: "gemini",
        findTarget: FindModel.Target(segment: 7, occurrence: 0),
        onOpenLink: { _ in }
    )
}

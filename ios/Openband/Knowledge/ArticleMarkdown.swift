import Foundation

/// The slice of Markdown the articles use: `## ` headings, paragraphs and `- ` bullets, one per
/// line. Inline emphasis and links are left to `AttributedString` at render time. A run of
/// bullet lines becomes one list, so a view can lay it out as a list rather than as paragraphs.
enum ArticleMarkdown {
    enum Block: Hashable {
        case heading(String)
        case paragraph(String)
        case bullets([String])
    }

    /// A heading and everything under it, which is what one screen section renders.
    struct Section: Identifiable, Hashable {
        /// The index in the article, because two sections may share a heading.
        let id: Int
        /// Nil for the blocks before the first heading.
        let heading: String?
        let blocks: [Block]
    }

    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var bullets: [String] = []

        func closeList() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bullets(bullets))
            bullets = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if text.hasPrefix("## ") {
                closeList()
                blocks.append(.heading(String(text.dropFirst(3))))
            } else if text.hasPrefix("- ") {
                bullets.append(String(text.dropFirst(2)))
            } else {
                closeList()
                blocks.append(.paragraph(text))
            }
        }
        closeList()
        return blocks
    }

    /// The article split at its headings. A heading with nothing under it is dropped, so an empty
    /// section never draws a card.
    static func sections(_ markdown: String) -> [Section] {
        var sections: [Section] = []
        var heading: String?
        var pending: [Block] = []

        func close() {
            guard !pending.isEmpty else { return }
            sections.append(Section(id: sections.count, heading: heading, blocks: pending))
            pending = []
        }

        for block in blocks(markdown) {
            if case .heading(let text) = block {
                close()
                heading = text
            } else {
                pending.append(block)
            }
        }
        close()
        return sections
    }
}

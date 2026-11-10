import SwiftUI

/// The health library: a list of articles, and the article itself.
///
/// It hangs off Coach rather than taking a tab of its own. The tab bar is full at five (see
/// `AppTab`), and of the five Coach is the one already about food, the body and what a number
/// means rather than about measuring it — so reference material belongs behind it. It is also
/// the one part of Coach that works with no API key, which gives the keyless screen something
/// to do. Move and Sleep link to nothing here; if that turns out to be wanted, the route takes
/// an article id and any screen can push one.
struct LearnView: View {
    private let articles = Knowledge.articles

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                ListCard {
                    ForEach(Array(articles.enumerated()), id: \.element.id) { index, article in
                        NavigationLink(value: Route.article(article.id)) {
                            ArticleRow(article: article, showsDivider: index < articles.count - 1)
                        }
                        .buttonStyle(.fbRow)
                    }
                }
                Footnote(String(localized: "Each one says what is known, what is a population average and what is still argued about. Reference material, not advice about you."))
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.top, FBSpace.xs)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(String(localized: "Learn"))
    }
}

/// An article as a row: icon, title, and the one line that says what is inside.
struct ArticleRow: View {
    let article: Article
    var showsDivider = true

    var body: some View {
        ListRow(title: article.title, subtitle: article.subtitle, systemImage: article.icon,
                showsDivider: showsDivider)
    }
}

/// One article: a section per heading, then its sources.
struct ArticleView: View {
    let articleID: String

    private var article: Article? { Knowledge.article(articleID) }

    var body: some View {
        ScrollView {
            if let article {
                VStack(alignment: .leading, spacing: FBSpace.l) {
                    Footnote(article.subtitle)
                    ForEach(ArticleMarkdown.sections(article.markdown)) { section in
                        VStack(alignment: .leading, spacing: FBSpace.xs) {
                            if let heading = section.heading {
                                SectionHeader(title: heading)
                            }
                            Card {
                                VStack(alignment: .leading, spacing: FBSpace.s) {
                                    ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                                        BlockView(block: block)
                                    }
                                }
                            }
                        }
                    }
                    sources(article.sources)
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.xs)
                .padding(.bottom, FBSpace.xl)
            }
        }
        .fbScreen()
        .navigationTitle(article?.title ?? String(localized: "Learn"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sources(_ sources: [ArticleSource]) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "Sources"))
            Card {
                VStack(alignment: .leading, spacing: FBSpace.s) {
                    ForEach(sources, id: \.text) { source in
                        SourceLink(source: source)
                    }
                }
            }
            Footnote(String(localized: "Nothing here is medical advice. Ask a doctor or a dietitian before changing how you eat or train."))
        }
    }
}

/// A citation that opens where it was published. No new colour: the arrow carries the
/// affordance, because body text is never orange.
private struct SourceLink: View {
    let source: ArticleSource

    var body: some View {
        let label = HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
            Text(source.text)
                .textStyle(.subhead)
                .foregroundStyle(.textBody)
                // A Link centres its label; a citation is a paragraph and sets left.
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.textTertiary)
                .accessibilityHidden(true)
        }
        if let url = URL(string: source.url) {
            Link(destination: url) { label }
                .accessibilityAddTraits(.isLink)
        } else {
            label
        }
    }
}

/// A paragraph, or a bulleted list. Inline Markdown (emphasis, links) is rendered where it
/// appears; a body that has none costs nothing.
private struct BlockView: View {
    let block: ArticleMarkdown.Block

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text)
                .textStyle(.headline)
                .foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(inline(text))
                .textStyle(.body)
                .foregroundStyle(.textBody)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
                        Text(verbatim: "·").accessibilityHidden(true)
                        Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                    .textStyle(.body)
                    .foregroundStyle(.textBody)
                }
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

#Preview("Learn") {
    FBPreviewMatrix {
        ListCard {
            ForEach(Array(Knowledge.load(bundle: .main, language: "en").prefix(3).enumerated()),
                    id: \.element.id) { index, article in
                ArticleRow(article: article, showsDivider: index < 2)
            }
        }
    }
}

#Preview("Article") {
    NavigationStack {
        ArticleView(articleID: "fat-loss")
    }
}

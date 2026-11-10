import Foundation

/// One article in the health library.
///
/// The text is not in Swift and not in the string catalogue. It lives in
/// `Resources/Knowledge/Knowledge.<language>.json`, one file per language: the bodies are a few
/// hundred words of Markdown each, which would drown a source file and make the catalogue
/// unreadable, and a file per language keeps each one reviewable and diffable on its own.
/// `ios/tests/knowledge` checks that the two files stay in step, so "both languages ship
/// complete" is a check rather than a promise.
struct Article: Identifiable, Hashable, Decodable, Sendable {
    let id: String
    /// SF Symbol for the list row.
    let icon: String
    let title: String
    /// The line under the title in the list: "Calorie deficit, NEAT, metabolic rate".
    let subtitle: String
    /// One Markdown block per element: a `## ` heading, a paragraph, or a `- ` bullet.
    let body: [String]
    /// Listed at the end of the article, as published.
    let sources: [ArticleSource]

    var markdown: String { body.joined(separator: "\n") }
}

/// A citation and where to read it. The citation is left in the language it was published in.
struct ArticleSource: Hashable, Decodable, Sendable {
    let text: String
    let url: String
}

/// The library, decoded once for the reader's language.
enum Knowledge {
    struct File: Decodable {
        let language: String
        let articles: [Article]
    }

    static let articles: [Article] = load()

    static func article(_ id: String) -> Article? { articles.first { $0.id == id } }

    /// English is the source language and the fallback: a language with no file of its own, or a
    /// file that will not decode, reads the English one rather than showing an empty screen.
    static func load(bundle: Bundle = .main, language: String? = nil) -> [Article] {
        let preferred = language ?? bundle.preferredLocalizations.first.map {
            String($0.prefix(2)).lowercased()
        } ?? "en"
        for name in preferred == "en" ? ["en"] : [preferred, "en"] {
            guard let url = bundle.url(forResource: "Knowledge.\(name)", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let articles = try? decode(data) else { continue }
            return articles
        }
        return []
    }

    static func decode(_ data: Data) throws -> [Article] {
        try JSONDecoder().decode(File.self, from: data).articles
    }
}

import Foundation

// The health library: the Markdown parser, and the two article files.
//
//   cd ios/tests/knowledge
//   swiftc ../../Openband/Knowledge/*.swift main.swift -o /tmp/knowledge_tests && /tmp/knowledge_tests
//
// The repo's rule is that English and Turkish both ship complete, so the file checks below are
// the check behind that: same articles in the same order, same sources, nothing empty, and no
// article still carrying its English text in the Turkish file.

var passed = 0
var failed = 0
var group = ""

func section(_ name: String) {
    group = name
    print("-- \(name)")
}

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
    } else {
        failed += 1
        print("FAIL \(group) :: \(name) \(detail())")
    }
}

// MARK: markdown

section("markdown")

let sample = """
Lead paragraph.
## A heading
First.
- one
- two
Second.
## Trailing heading with nothing under it
"""

let blocks = ArticleMarkdown.blocks(sample)
check("every block is kept", blocks.count == 6, "got \(blocks.count)")
check("the lead is a paragraph", blocks.first == .paragraph("Lead paragraph."))
check("## is a heading", blocks[1] == .heading("A heading"))
check("a run of bullets is one list", blocks[3] == .bullets(["one", "two"]))
check("a paragraph after a list stands alone", blocks[4] == .paragraph("Second."))

let blank = ArticleMarkdown.blocks("One.\n\n\nTwo.\n   \n")
check("blank lines are not blocks", blank == [.paragraph("One."), .paragraph("Two.")])

let sections = ArticleMarkdown.sections(sample)
check("the lead gets a section with no heading", sections.first?.heading == nil)
check("a heading starts a section", sections.count == 2, "got \(sections.count)")
check("the second section is the heading's", sections[1].heading == "A heading")
check("an empty heading draws nothing", !sections.contains { $0.blocks.isEmpty })
check("section ids are distinct", Set(sections.map(\.id)).count == sections.count)

// MARK: the files

section("files")

func load(_ language: String) -> [Article] {
    let path = "../../Openband/Resources/Knowledge/Knowledge.\(language).json"
    guard let data = FileManager.default.contents(atPath: path) else {
        print("FAIL files :: cannot read \(path)")
        failed += 1
        return []
    }
    do {
        return try Knowledge.decode(data)
    } catch {
        print("FAIL files :: \(language) will not decode: \(error)")
        failed += 1
        return []
    }
}

let en = load("en")
let tr = load("tr")

check("English decodes", !en.isEmpty)
check("Turkish decodes", !tr.isEmpty)
check("both languages carry the same articles in the same order", en.map(\.id) == tr.map(\.id),
      "\(en.map(\.id)) vs \(tr.map(\.id))")
check("article ids are unique", Set(en.map(\.id)).count == en.count)
check("the same icon in both", en.map(\.icon) == tr.map(\.icon))

for (article, other) in zip(en, tr) {
    let id = article.id
    for (language, a) in [("en", article), ("tr", other)] {
        let words = a.markdown.split(whereSeparator: \.isWhitespace).count
        check("\(id) · \(language) has a title", !a.title.isEmpty)
        check("\(id) · \(language) has a subtitle for the row", !a.subtitle.isEmpty)
        check("\(id) · \(language) is a few hundred words", words >= 200 && words <= 900, "got \(words)")
        check("\(id) · \(language) is structured", ArticleMarkdown.sections(a.markdown).count >= 3)
        check("\(id) · \(language) opens with a heading or a paragraph",
              ArticleMarkdown.blocks(a.markdown).isEmpty == false)
        check("\(id) · \(language) cites something", a.sources.count >= 3, "got \(a.sources.count)")
        check("\(id) · \(language) has no stray Markdown headings in a block",
              !ArticleMarkdown.blocks(a.markdown).contains {
                  if case .paragraph(let t) = $0 { return t.hasPrefix("#") }
                  return false
              })
        for source in a.sources {
            check("\(id) · \(language) · a source has a citation", source.text.count > 30, source.text)
            check("\(id) · \(language) · \(source.url) is https", source.url.hasPrefix("https://"))
            check("\(id) · \(language) · \(source.url) is a URL", URL(string: source.url) != nil)
        }
    }
    check("\(id) cites the same sources in both", article.sources.map(\.url) == other.sources.map(\.url))
    check("\(id) is actually translated", article.title != other.title && article.markdown != other.markdown)
    check("\(id) · tr is written in Turkish",
          other.markdown.unicodeScalars.contains { "çğıöşüÇĞİÖŞÜâîû".unicodeScalars.contains($0) })
}

check("the list is worth a screen", en.count >= 5, "got \(en.count)")

// MARK: result

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)

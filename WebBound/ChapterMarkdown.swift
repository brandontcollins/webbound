//
//  ChapterMarkdown.swift
//  WebBound
//
//  Markdown + YAML-frontmatter is the editable on-disk format for a scraped
//  chapter. Users may edit these files between `scrape` and `build`, and the
//  EPUB will reflect their changes.
//
//  Format:
//      ---
//      number: 42
//      title: "Chapter 42: Something Happens"
//      url: https://example.com/chapter-42
//      ---
//
//      First paragraph of body text.
//
//      Second paragraph.
//
//  Rules:
//    * The frontmatter block is required. Delimiters are `---` on their own
//      lines, LF line endings.
//    * `title` is YAML-double-quoted (we always quote on write; on read we
//      accept quoted or bare).
//    * The body is split into paragraphs on blank lines. Multiple consecutive
//      non-empty lines inside a paragraph are joined with a single space so
//      editors can hard-wrap without affecting the EPUB.
//

import Foundation

enum MarkdownError: Error, CustomStringConvertible {
    case missingFrontmatter
    case malformedFrontmatter

    var description: String {
        switch self {
        case .missingFrontmatter:  return "Chapter markdown is missing YAML frontmatter."
        case .malformedFrontmatter: return "Chapter markdown frontmatter is malformed."
        }
    }
}

enum ChapterMarkdown {

    // MARK: - Filename

    /// `ch-0042.md` (4-digit zero-padded by chapter number). For refs
    /// without a parsed number falls back to a URL-derived name.
    static func filename(for ref: ChapterRef) -> String {
        if let n = ref.number {
            return String(format: "ch-%04d.md", n)
        }
        let safe = ref.url
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "ch-x-\(safe).md"
    }

    /// Legacy 5-digit markdown name — read-only fallback for cache written by
    /// earlier builds. On the next write, these get cleaned up.
    static func legacy5DigitMarkdownFilename(for ref: ChapterRef) -> String {
        if let n = ref.number {
            return String(format: "ch-%05d.md", n)
        }
        let safe = ref.url
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "ch-x-\(safe).md"
    }

    /// Legacy JSON names from pre-markdown builds.
    static func legacyJSONFilename(for ref: ChapterRef) -> String {
        if let n = ref.number {
            return String(format: "ch-%05d.json", n)
        }
        let safe = ref.url
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "ch-x-\(safe).json"
    }

    /// Also match the 4-digit JSON form for completeness.
    static func legacyJSON4DigitFilename(for ref: ChapterRef) -> String {
        if let n = ref.number {
            return String(format: "ch-%04d.json", n)
        }
        let safe = ref.url
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "ch-x-\(safe).json"
    }

    // MARK: - Write

    static func write(_ chapter: Chapter, to url: URL) throws {
        var md = "---\n"
        if let n = chapter.ref.number {
            md += "number: \(n)\n"
        }
        md += "title: \(yamlQuote(chapter.ref.title))\n"
        md += "url: \(chapter.ref.url)\n"
        md += "---\n\n"
        md += chapter.paragraphs.joined(separator: "\n\n")
        md += "\n"
        try md.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Read

    static func read(from url: URL) throws -> Chapter {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try parse(raw)
    }

    static func parse(_ raw: String) throws -> Chapter {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            throw MarkdownError.missingFrontmatter
        }
        let afterOpen = normalized.index(normalized.startIndex, offsetBy: 4)
        guard let closeRange = normalized.range(of: "\n---\n", range: afterOpen..<normalized.endIndex)
            ?? normalized.range(of: "\n---", range: afterOpen..<normalized.endIndex) else {
            throw MarkdownError.malformedFrontmatter
        }
        let frontmatter = String(normalized[afterOpen..<closeRange.lowerBound])
        // Body may be empty if the user hasn't filled in paragraphs yet.
        let bodyStart = closeRange.upperBound
        let body = bodyStart < normalized.endIndex ? String(normalized[bodyStart...]) : ""

        var number: Int?
        var title = ""
        var urlString = ""
        for line in frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard let (key, value) = parseYAMLLine(s) else { continue }
            switch key {
            case "number":  number = Int(value)
            case "title":   title = yamlUnquote(value)
            case "url":     urlString = yamlUnquote(value)
            default: break
            }
        }

        let paragraphs = splitParagraphs(body)
        let ref = ChapterRef(url: urlString, title: title, number: number)
        return Chapter(ref: ref, paragraphs: paragraphs)
    }

    // MARK: - Helpers

    private static func yamlQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func yamlUnquote(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }
        let inner = String(trimmed.dropFirst().dropLast())
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseYAMLLine(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let colonIdx = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let value = String(trimmed[trimmed.index(after: colonIdx)...])
            .trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    /// Groups non-empty lines into paragraphs separated by blank lines.
    /// Lines inside a paragraph are joined with a single space so the user
    /// can hard-wrap in their editor without producing paragraph breaks.
    private static func splitParagraphs(_ body: String) -> [String] {
        var out: [String] = []
        var buf: [String] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !buf.isEmpty {
                    out.append(buf.joined(separator: " "))
                    buf.removeAll()
                }
            } else {
                buf.append(line)
            }
        }
        if !buf.isEmpty {
            out.append(buf.joined(separator: " "))
        }
        return out
    }
}

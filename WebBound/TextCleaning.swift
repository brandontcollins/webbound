//
//  TextCleaning.swift
//  WebBound
//
//  Swift counterparts to the JS cleaning logic in NovelLiveScraper. Used by
//  the `review` command to find and (optionally) remove issues already baked
//  into cached chapter markdown.
//
//  Rules (must match the JS extractor):
//    * Deduplicate paragraphs longer than DUP_MIN_LEN. Short lines are left
//      alone so dialog like "Yes." or "Begin." can legitimately repeat.
//    * Strip tokens that look like obfuscated novel-aggregator domain names
//      ("freēwēbηovel.c૦m") by folding common homoglyphs to ASCII and
//      matching against a brand/TLD list. Only tokens containing non-ASCII
//      characters are examined, so legitimate URLs the author embedded
//      survive untouched.
//

import Foundation

enum TextCleaning {

    static let dupMinLen = 40

    /// Known novel-aggregator brands. Matched as substrings against the
    /// letter-folded, lowercase form of a token.
    static let brands: [String] = [
        "freewebnovel","novellive","wuxiaworld","webnovel","readnovelfull",
        "novelfull","lightnovelreader","novelpub","royalroad","scribblehub",
        "noveltranslate","bestlightnovel","novelbuddy","novelcool",
        "wnmtl","mtlnovel","ranobes","ranobe","wtr-lab","syosetu"
    ]

    /// Exact substring markers that indicate a paragraph is injected
    /// scaffolding, not story content. If any of these appear anywhere in a
    /// paragraph, drop the whole paragraph.
    static let boilerplatePhrases: [String] = [
        "Visit and read more novel to help us",
        "Thank you so much!",
        "New novel are published on",
        "New novels are published on",
        "Follow current novels on",
        "Please read on our website",
        "Chapters are updated on",
        "Enjoy reading at"
    ]

    /// Promotional fragments that get appended to the end of a paragraph
    /// with no closing punctuation ("...the nurses. Experience new stories
    /// on empire"). We strip only the tail — the preceding legitimate
    /// sentence stays.
    /// Each pattern captures the preserved sentence terminator (possibly
    /// followed by closing quotes/parens) as group 1. The match itself
    /// consumes the terminator PLUS the trailing promo phrase; replacing
    /// with "$1" keeps the terminator and strips the phrase.
    static let boilerplateTailPatterns: [NSRegularExpression] = {
        // Allowed closing characters that may legitimately follow the
        // sentence terminator before the promo phrase begins.
        //   " '  smart-double-right  smart-single-right  »  )  ]
        let closers = #"["'”’»\)\]]*"#

        // Each pattern anchors on either a preceding sentence terminator
        // (keeping that terminator + any closing marks as group 1) OR the
        // start of the paragraph (group 1 empty — the whole paragraph is
        // the promo). Replacing the match with "$1" preserves the
        // terminator in the first case and empties the paragraph in the
        // second so the downstream filter drops it.
        let specs: [String] = [
            // Case 1: lowercase "empire" at end of paragraph, no closing
            // punctuation. Case-sensitive, so "Newbon Empire" survives.
            #"([.!?]\#(closers)|^)\s*[^.!?]{1,120}?\bempire\s*$"#,
            // Case 2: literal "My Virtual Library Empire" at end, no closing
            // punctuation.
            #"([.!?]\#(closers)|^)\s*[^.!?]{0,120}?My Virtual Library Empire\s*$"#
        ]
        return specs.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Returns the paragraph with the first-matching promo tail stripped,
    /// plus the matched substring (for auditing). The sentence terminator
    /// and any closing quotes/parens that immediately followed it are
    /// preserved. If no match, returns the original text unchanged and nil.
    static func stripBoilerplateTail(from text: String) -> (cleaned: String, removedTail: String?) {
        for regex in boilerplateTailPatterns {
            let range = NSRange(text.startIndex..., in: text)
            guard let m = regex.firstMatch(in: text, range: range),
                  let matchRange = Range(m.range, in: text),
                  m.numberOfRanges >= 2,
                  let keepRange = Range(m.range(at: 1), in: text) else { continue }
            let keptPrefix = String(text[keepRange])
            let fullMatch = String(text[matchRange])
            // The "removed" portion is the full match minus the preserved
            // prefix (so what the user sees as "removed" is exactly what
            // disappears from the paragraph).
            let removed = String(fullMatch.dropFirst(keptPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            var result = text
            result.replaceSubrange(matchRange, with: keptPrefix)
            return (result.trimmingCharacters(in: .whitespaces), removed)
        }
        return (text, nil)
    }

    /// Homoglyph → ASCII map. Mirrors (and extends) the JS table. Keys may
    /// be any Unicode scalar; values are plain ASCII characters.
    static let homoglyph: [Character: Character] = [
        // a
        "а":"a","ɑ":"a","ạ":"a","ă":"a","ā":"a","ȧ":"a","α":"a","Α":"a","А":"a","ꓮ":"a",
        // b
        "ь":"b","Ь":"b","ƅ":"b","ɓ":"b","Β":"b","β":"b","В":"b","ß":"b","ꓐ":"b",
        // c
        "с":"c","ϲ":"c","ƈ":"c","ⅽ":"c","С":"c","ꓚ":"c","ҫ":"c",
        // d
        "ɖ":"d","ď":"d","ɗ":"d","ⅾ":"d","ꓓ":"d",
        // e
        "ē":"e","ё":"e","е":"e","є":"e","ẹ":"e","ĕ":"e","ȅ":"e","Ε":"e","ε":"e","Е":"e","ꓰ":"e",
        // f
        "ƒ":"f","ẝ":"f","ꓝ":"f",
        // g
        "ɡ":"g","ğ":"g","ɢ":"g","ɠ":"g","ց":"g","ꓖ":"g",
        // h
        "ɥ":"h","һ":"h","ħ":"h","ʜ":"h","Η":"h","Н":"h","ꓧ":"h",
        // i
        "і":"i","ɪ":"i","ι":"i","ï":"i","í":"i","ì":"i","ī":"i","Ι":"i","І":"i","1":"i","!":"i","ꓲ":"i",
        // j
        "ʝ":"j","ј":"j","Ј":"j","ꓙ":"j",
        // k
        "ĸ":"k","к":"k","К":"k","Κ":"k","κ":"k","ꓗ":"k",
        // l
        "ʟ":"l","ł":"l","ʃ":"l","Ⅼ":"l","ⅼ":"l","ꓡ":"l",
        // m
        "м":"m","ɱ":"m","Μ":"m","М":"m","ꓟ":"m",
        // n
        "η":"n","ñ":"n","ń":"n","ņ":"n","ⁿ":"n","ɴ":"n","Ν":"n","ꓠ":"n",
        // o
        "ο":"o","о":"o","ö":"o","ô":"o","ō":"o","ø":"o","õ":"o","ơ":"o","Ο":"o","О":"o",
        "૦":"o","०":"o","੦":"o","0":"o","Ȏ":"o","ȯ":"o","ȱ":"o","ȍ":"o","ꓳ":"o",
        // p
        "р":"p","ρ":"p","Ρ":"p","Р":"p","ꓑ":"p",
        // q
        "ʛ":"q","ɋ":"q","ꓭ":"q",
        // r
        "ʀ":"r","ŕ":"r","ř":"r","ꭆ":"r","ꓣ":"r","ɍ":"r",
        // s
        "ѕ":"s","ś":"s","ʂ":"s","Ș":"s","ș":"s","Ѕ":"s","ꓢ":"s","ş":"s","ƨ":"s",
        // t
        "ƭ":"t","т":"t","ţ":"t","Τ":"t","τ":"t","Т":"t","ꓔ":"t",
        // u
        "ɐ":"u","ų":"u","ü":"u","ú":"u","ù":"u","ū":"u","ʊ":"u","υ":"u","ꓴ":"u",
        // v
        "ѵ":"v","ν":"v","ⅴ":"v","Ⅴ":"v","ꓦ":"v",
        // w
        "ʍ":"w","ẘ":"w","ѡ":"w","Ѡ":"w","ꓪ":"w",
        // x
        "х":"x","χ":"x","Χ":"x","Х":"x","ⅹ":"x","Ⅹ":"x","ꓫ":"x",
        // y
        "ʏ":"y","ƴ":"y","у":"y","ý":"y","ÿ":"y","Υ":"y","Ү":"y","ꓬ":"y",
        // z
        "ʐ":"z","ž":"z","ƶ":"z","Ζ":"z","Ź":"z","ꓜ":"z"
    ]

    /// Fold a string to ASCII using the homoglyph table + NFKD. Combining
    /// marks and zero-width characters are stripped. Case is normalized to
    /// lower.
    static func dewatermark(_ text: String) -> String {
        let decomposed = text.decomposedStringWithCompatibilityMapping
        var out = ""
        out.reserveCapacity(decomposed.count)
        for scalar in decomposed.unicodeScalars {
            // Combining marks
            if (0x0300...0x036F).contains(scalar.value) { continue }
            // Zero-width chars
            switch scalar.value {
            case 0x200B, 0x200C, 0x200D, 0xFEFF: continue
            default: break
            }
            let ch = Character(scalar)
            if let mapped = homoglyph[ch] {
                out.append(mapped)
            } else {
                out.append(ch)
            }
        }
        return out.lowercased()
    }

    /// Returns true if a whitespace-delimited token looks like an obfuscated
    /// scraper watermark. Only non-ASCII-containing tokens are examined, so
    /// legitimate URLs or author-embedded references survive.
    static func isWatermarkToken(_ token: String) -> Bool {
        guard token.unicodeScalars.contains(where: { $0.value > 0x7F }) else {
            return false
        }
        let folded = dewatermark(token)
        let letters = folded.filter { $0.isLetter || $0.isNumber }
        for brand in brands {
            if letters.contains(brand) { return true }
        }
        // Domain-shaped: /[a-z0-9]{3,}\.[a-z0-9]{2,}/
        return domainRegex.firstMatch(
            in: folded,
            range: NSRange(folded.startIndex..., in: folded)
        ) != nil
    }

    private static let domainRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"[a-z0-9]{3,}\.[a-z0-9]{2,}"#)
    }()

    /// Removes watermark tokens from a single paragraph.
    /// Returns the cleaned text and the list of tokens that were stripped
    /// (for audit reporting).
    static func stripWatermarks(from paragraph: String) -> (cleaned: String, removed: [String]) {
        // Fast path — no non-ASCII, nothing to do.
        guard paragraph.unicodeScalars.contains(where: { $0.value > 0x7F }) else {
            return (paragraph, [])
        }
        // Split while preserving whitespace separators.
        let parts = paragraph.split(
            separator: " ",
            omittingEmptySubsequences: false
        ).map(String.init)
        var keptTokens: [String] = []
        var removed: [String] = []
        for tok in parts {
            if tok.isEmpty { keptTokens.append(tok); continue }
            if isWatermarkToken(tok) {
                removed.append(tok)
            } else {
                keptTokens.append(tok)
            }
        }
        if removed.isEmpty { return (paragraph, []) }
        // Collapse consecutive whitespace left behind by removed tokens.
        let joined = keptTokens.joined(separator: " ")
        let collapsed = joined
            .replacingOccurrences(
                of: #"\s{2,}"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespaces)
        return (collapsed, removed)
    }

    // MARK: - Chapter-level cleanup

    struct CleaningReport {
        var deduped: [(index: Int, text: String)] = []
        var watermarks: [(index: Int, before: String, after: String, tokens: [String])] = []
        var droppedParagraphs: [(index: Int, reason: String, text: String)] = []
        var tailsStripped: [(index: Int, tail: String, cleaned: String)] = []
        var titleNormalized: (before: String, after: String)? = nil

        var hasChanges: Bool {
            !deduped.isEmpty
                || !watermarks.isEmpty
                || !droppedParagraphs.isEmpty
                || !tailsStripped.isEmpty
                || titleNormalized != nil
        }
    }

    private static func containsBoilerplate(_ text: String) -> Bool {
        for needle in boilerplatePhrases {
            if text.contains(needle) { return true }
        }
        return false
    }

    private static func hasLetter(_ text: String) -> Bool {
        for ch in text where ch.isLetter { return true }
        return false
    }

    /// Apply all paragraph-level filters: boilerplate drop, letterless drop,
    /// watermark strip, orphan-after-strip drop, dedupe. Returns the cleaned
    /// paragraphs and an itemized report. Indices in the report are 1-based
    /// positions in the ORIGINAL paragraph list.
    static func clean(paragraphs: [String]) -> (cleaned: [String], report: CleaningReport) {
        var report = CleaningReport()
        var seenLong = Set<String>()
        var out: [String] = []
        for (idx, raw) in paragraphs.enumerated() {
            let i = idx + 1

            // 1) Boilerplate drop.
            if containsBoilerplate(raw) {
                report.droppedParagraphs.append((i, "boilerplate phrase", raw))
                continue
            }

            // 2) Letterless drop (just numbers/timestamps/punctuation).
            if !hasLetter(raw) {
                report.droppedParagraphs.append((i, "no letters (likely timestamp/garbage)", raw))
                continue
            }

            // 3) Watermark strip.
            let (afterWatermark, removedTokens) = stripWatermarks(from: raw)
            if !removedTokens.isEmpty {
                report.watermarks.append((
                    index: i,
                    before: raw,
                    after: afterWatermark,
                    tokens: removedTokens
                ))
            }
            if afterWatermark.isEmpty {
                // Full paragraph was watermark. Already reported above.
                continue
            }

            // 3a) Orphan drop AFTER watermark removal only. The watermark
            //     filter can leave stubs like "New novel are published on."
            //     because it chopped a word out of a semi-boilerplate
            //     sentence. If that happened and the remainder is short,
            //     drop the paragraph. Does NOT apply to tail stripping,
            //     which is surgical and leaves legitimate sentences intact.
            if !removedTokens.isEmpty && afterWatermark.count < 25 {
                report.droppedParagraphs.append((i, "orphan stub after watermark removal", afterWatermark))
                continue
            }

            // 3b) Promotional tail strip. Catches site injections like
            //    "...the nurses. Experience new stories on empire"
            //    "...the king said. My Virtual Library Empire"
            //    "Experience more content on My Virtual Library Empire"
            //    (standalone paragraph form)
            let (afterTail, removedTail) = stripBoilerplateTail(from: afterWatermark)
            let working: String
            if let tail = removedTail {
                report.tailsStripped.append((
                    index: i,
                    tail: tail,
                    cleaned: afterTail
                ))
                working = afterTail
            } else {
                working = afterWatermark
            }
            if working.isEmpty { continue }

            // 5) Re-check for boilerplate after stripping.
            if containsBoilerplate(working) {
                report.droppedParagraphs.append((i, "boilerplate phrase (post-strip)", working))
                continue
            }

            // 6) Dedupe long paragraphs.
            if working.count >= dupMinLen {
                if seenLong.contains(working) {
                    report.deduped.append((index: i, text: working))
                    continue
                }
                seenLong.insert(working)
            }
            out.append(working)
        }
        return (out, report)
    }
}

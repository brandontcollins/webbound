//
//  NovelLiveScraper.swift
//  WebBound
//
//  Site-specific extraction for novellive.app, implemented as JS
//  queries against the live DOM in a WKWebView — avoids any HTML parsing
//  in Swift and keeps us resilient to messy, ad-laden markup.
//

import Foundation

enum ScraperError: Error, CustomStringConvertible {
    case badURL(String)
    case missingMetadata(String)
    case rateLimited

    var description: String {
        switch self {
        case .badURL(let s): return "Bad URL: \(s)"
        case .missingMetadata(let s): return "Missing metadata: \(s)"
        case .rateLimited: return "Rate limited by site (access speed too fast)."
        }
    }
}

@MainActor
final class NovelLiveScraper {
    let renderer: WebRenderer
    let settlingDelay: TimeInterval

    init(renderer: WebRenderer, settlingDelay: TimeInterval = 1.0) {
        self.renderer = renderer
        self.settlingDelay = settlingDelay
    }

    private func load(_ urlString: String, maxAttempts: Int = 3) async throws {
        guard let url = URL(string: urlString) else { throw ScraperError.badURL(urlString) }
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try await renderer.load(url, timeout: 45)
                try await renderer.waitForCloudflareClearance(timeout: 30)
                if settlingDelay > 0 {
                    try await Task.sleep(for: .milliseconds(Int(settlingDelay * 1000)))
                }
                return
            } catch {
                lastError = error
                let backoff = 2 * attempt
                let stderr = FileHandle.standardError
                stderr.write(Data("    retry \(attempt)/\(maxAttempts) after error (\(error)); backing off \(backoff)s\n".utf8))
                try? await Task.sleep(for: .seconds(backoff))
            }
        }
        throw lastError ?? ScraperError.badURL(urlString)
    }

    // MARK: - Metadata

    func fetchMetadata(bookURL: String) async throws -> BookMetadata {
        try await load(bookURL)
        struct Raw: Codable {
            var title: String?
            var author: String?
            var cover: String?
            var desc: String?
            var status: String?
            var genre: String?
        }
        let raw: Raw = try await renderer.evaluateJSON(#"""
          function m(prop) {
            const el = document.querySelector(`meta[property="${prop}"]`);
            return el ? el.getAttribute('content') : null;
          }
          return {
            title: m('og:novel:novel_name') || document.title,
            author: m('og:novel:author'),
            cover: m('og:image'),
            desc: m('og:description'),
            status: m('og:novel:status'),
            genre: m('og:novel:genre')
          };
        """#, as: Raw.self)

        guard let title = raw.title, !title.isEmpty else {
            throw ScraperError.missingMetadata("title")
        }

        let slug = URL(string: bookURL)?.lastPathComponent ?? "book"
        let genres = (raw.genre ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return BookMetadata(
            title: title,
            author: raw.author,
            coverImageURL: raw.cover,
            description: raw.desc,
            genres: genres,
            status: raw.status,
            sourceURL: bookURL,
            slug: slug
        )
    }

    // MARK: - Table of Contents

    /// Returns the highest page number in the pagination `<select id="indexselect">`.
    /// The widget is only present on paginated pages (`/book/<slug>/N`), so this
    /// loads page 2 to read it.
    func fetchTotalTOCPages(bookURL: String) async throws -> Int {
        try await load("\(bookURL)/2")
        let total: Int = try await renderer.evaluateJSON(#"""
          const sel = document.querySelector('#indexselect');
          if (!sel) return 1;
          let max = 1;
          for (const opt of sel.options) {
            const v = parseInt(opt.value, 10);
            if (!isNaN(v) && v > max) max = v;
          }
          return max;
        """#, as: Int.self)
        return max(total, 1)
    }

    /// Returns all chapter refs from a single TOC page. Dedupes by URL within
    /// the page (page 1 contains both "latest" and "chapter list" sections
    /// which may overlap). Throws `rateLimited` if the site serves its
    /// "access speed too fast" page, which we treat as a transient error.
    func fetchTOCPage(bookURL: String, page: Int) async throws -> [ChapterRef] {
        let pageURL = page <= 1 ? bookURL : "\(bookURL)/\(page)"
        try await load(pageURL)
        struct RawRef: Codable { var url: String; var title: String }
        let refs: [RawRef] = try await renderer.evaluateJSON(#"""
          const links = document.querySelectorAll('a.con[href*="/chapter-"]');
          const seen = new Set();
          const out = [];
          for (const a of links) {
            const href = a.href;
            // Drop the site's rate-limit sentinel; we throw at the Swift layer.
            if (href.indexOf('/chapter-error') !== -1) continue;
            if (seen.has(href)) continue;
            seen.add(href);
            const titleAttr = a.getAttribute('title');
            const title = (titleAttr && titleAttr.trim()) ? titleAttr.trim()
                                                         : a.textContent.trim();
            out.push({ url: href, title: title });
          }
          return out;
        """#, as: [RawRef].self)

        // Rate-limit signature: the page body screams "access speed is too fast"
        // and either we got zero chapter links or only an error placeholder.
        let title = (try? await renderer.evaluateString("document.title")) ?? ""
        let bodyText = (try? await renderer.evaluateString(
            "(document.body ? document.body.innerText : '').slice(0, 1000)"
        )) ?? ""
        let combined = (title + " " + bodyText).lowercased()
        if combined.contains("access speed is too fast")
            || combined.contains("your access speed")
            || refs.isEmpty {
            throw ScraperError.rateLimited
        }

        return refs.map { raw in
            Self.normalize(ChapterRef(
                url: raw.url,
                title: raw.title,
                number: Self.parseChapterNumber(from: raw.title)
            ))
        }
    }

    // MARK: - Chapter body

    func fetchChapter(ref: ChapterRef) async throws -> Chapter {
        try await load(ref.url)
        let paragraphs: [String] = try await renderer.evaluateJSON(#"""
          const src = document.querySelector('.txt');
          if (!src) return [];
          const clone = src.cloneNode(true);
          // Strip ad containers, scripts, iframes, duplicate chapter title.
          clone.querySelectorAll(
            'script, style, iframe, noscript, ins, .PUBFUTURE, ' +
            '[class*="pf-config"], [class*="pf-wrapper"], [class*="pf-banner"], ' +
            '[class*="pf-passback"], [data-widget-id], [id^="pf-"], ' +
            'a[rel*="sponsored"], h4'
          ).forEach(e => e.remove());

          // Site boilerplate — exact substrings that mean the paragraph is
          // injected scaffolding, not story content.
          const boilerplate = [
            'Visit and read more novel to help us update chapter',
            'Visit and read more novel to help us',
            'Thank you so much!',
            'New novel are published on',
            'New novels are published on',
            'Follow current novels on',
            'Please read on our website',
            'Chapters are updated on',
            'Enjoy reading at'
          ];
          const isBoilerplate = (txt) => {
            for (const needle of boilerplate) {
              if (txt.indexOf(needle) !== -1) return true;
            }
            return false;
          };

          // Mid-paragraph promotional tails. The site appends a short promo
          // fragment to the end of a paragraph with NO closing punctuation.
          // Two signatures we strip (case-sensitive):
          //   1. ends in lowercase "empire"       e.g. "...on empire"
          //   2. ends in "My Virtual Library Empire"
          // Each regex captures the preserved terminator + optional closing
          // quotes/parens as group 1 so we can keep them intact.
          const BOILERPLATE_TAIL_PATTERNS = [
            /([.!?]["'”’»\)\]]*|^)\s*[^.!?]{1,120}?\bempire\s*$/,
            /([.!?][”’»’»\)\]]*|^)\s*[^.!?]{0,120}?My Virtual Library Empire\s*$/
          ];
          const stripBoilerplateTail = (txt) => {
            for (const re of BOILERPLATE_TAIL_PATTERNS) {
              const m = txt.match(re);
              if (!m) continue;
              const keptPrefix = m[1];
              const matchStart = m.index;
              const matchEnd = m.index + m[0].length;
              return (txt.substring(0, matchStart) + keptPrefix + txt.substring(matchEnd)).trim();
            }
            return txt.trim();
          };

          // Watermark/homoglyph detection: some chapters embed obfuscated
          // domain names like "freēwēbηovel.c૦m" using lookalike Unicode
          // chars (ē/η/૦ instead of e/n/o-shaped-digit). Strip any whitespace-
          // separated token that, after folding to ASCII, looks like a known
          // scraper-aggregator brand or a URL — but ONLY if it contained
          // non-ASCII chars (so legit URLs the author put in survive).
          const BRANDS = [
            'freewebnovel','novellive','wuxiaworld','webnovel','readnovelfull',
            'novelfull','lightnovelreader','novelpub','royalroad','scribblehub',
            'noveltranslate','bestlightnovel','novelbuddy','novelcool',
            'wnmtl','mtlnovel','ranobes','ranobe','wtr-lab','syosetu'
          ];
          // Common homoglyph → ASCII mappings. Also strip combining marks.
          const HOMOGLYPH = {
            // a
            'а':'a','ɑ':'a','ạ':'a','ă':'a','ā':'a','ā':'a','ȧ':'a','α':'a','Α':'a','А':'a','ꓮ':'a',
            // b
            'ь':'b','Ь':'b','ƅ':'b','ɓ':'b','Β':'b','β':'b','В':'b','ß':'b','ꓐ':'b',
            // c
            'с':'c','ϲ':'c','ƈ':'c','ⅽ':'c','С':'c','ꓚ':'c','ҫ':'c',
            // d
            'ɖ':'d','ď':'d','ɗ':'d','ⅾ':'d','ꓓ':'d',
            // e
            'ē':'e','ё':'e','е':'e','є':'e','ẹ':'e','ĕ':'e','ȅ':'e','Ε':'e','ε':'e','Е':'e','ꓰ':'e',
            // f
            'ƒ':'f','ẝ':'f','ꓝ':'f',
            // g
            'ɡ':'g','ğ':'g','ɢ':'g','ɠ':'g','ց':'g','ꓖ':'g',
            // h
            'ɥ':'h','һ':'h','ħ':'h','ʜ':'h','Η':'h','Н':'h','ꓧ':'h',
            // i
            'і':'i','ɪ':'i','ι':'i','ï':'i','í':'i','ì':'i','ī':'i','Ι':'i','І':'i','1':'i','!':'i','ꓲ':'i',
            // j
            'ʝ':'j','ј':'j','Ј':'j','ꓙ':'j',
            // k
            'ĸ':'k','к':'k','К':'k','Κ':'k','κ':'k','ꓗ':'k',
            // l
            'ʟ':'l','ł':'l','ʃ':'l','Ⅼ':'l','ⅼ':'l','ꓡ':'l',
            // m
            'м':'m','ɱ':'m','Μ':'m','М':'m','ꓟ':'m',
            // n
            'η':'n','ñ':'n','ń':'n','ņ':'n','ⁿ':'n','ɴ':'n','Ν':'n','ꓠ':'n',
            // o
            'ο':'o','о':'o','ö':'o','ô':'o','ō':'o','ø':'o','õ':'o','ơ':'o','Ο':'o','О':'o',
            '૦':'o','०':'o','੦':'o','0':'o','Ȏ':'o','ȯ':'o','ȱ':'o','ȍ':'o','ꓳ':'o',
            // p
            'р':'p','ρ':'p','Ρ':'p','Р':'p','ꓑ':'p',
            // q
            'ʛ':'q','ɋ':'q','ꓭ':'q',
            // r
            'ʀ':'r','ŕ':'r','ř':'r','ꭆ':'r','ꓣ':'r','ɍ':'r',
            // s
            'ѕ':'s','ś':'s','ʂ':'s','Ș':'s','ș':'s','Ѕ':'s','ꓢ':'s','ş':'s','ƨ':'s',
            // t
            'ƭ':'t','т':'t','ţ':'t','Τ':'t','τ':'t','Т':'t','ꓔ':'t',
            // u
            'ɐ':'u','ų':'u','ü':'u','ú':'u','ù':'u','ū':'u','ʊ':'u','υ':'u','ꓴ':'u',
            // v
            'ѵ':'v','ν':'v','ⅴ':'v','Ⅴ':'v','ꓦ':'v',
            // w
            'ʍ':'w','ẘ':'w','ѡ':'w','Ѡ':'w','ꓪ':'w',
            // x
            'х':'x','χ':'x','Χ':'x','Х':'x','ⅹ':'x','Ⅹ':'x','ꓫ':'x',
            // y
            'ʏ':'y','ƴ':'y','у':'y','ý':'y','ÿ':'y','Υ':'y','Ү':'y','ꓬ':'y',
            // z
            'ʐ':'z','ž':'z','ƶ':'z','Ζ':'z','Ź':'z','ꓜ':'z'
          };
          const dewatermark = (txt) => {
            // Strip zero-width + combining marks first.
            let s = txt.normalize('NFKD')
                       .replace(/[​-‍﻿]/g, '')
                       .replace(/[̀-ͯ]/g, '');
            let out = '';
            for (const c of s) {
              out += (HOMOGLYPH[c] !== undefined ? HOMOGLYPH[c] : c);
            }
            return out.toLowerCase();
          };
          const stripWatermarks = (text) => {
            // Fast path — no non-ASCII, no need to process.
            if (!/[^\x00-\x7f]/.test(text)) return text;
            const parts = text.split(/(\s+)/);
            const kept = [];
            for (const tok of parts) {
              if (/^\s*$/.test(tok)) { kept.push(tok); continue; }
              if (!/[^\x00-\x7f]/.test(tok)) { kept.push(tok); continue; }
              const folded = dewatermark(tok);
              const letters = folded.replace(/[^a-z0-9]/g, '');
              let isWatermark = false;
              for (const b of BRANDS) {
                if (letters.indexOf(b) !== -1) { isWatermark = true; break; }
              }
              if (!isWatermark && /[a-z0-9]{3,}\.[a-z0-9]{2,}/.test(folded)) {
                // Obfuscated URL-shaped token.
                isWatermark = true;
              }
              if (isWatermark) continue;
              kept.push(tok);
            }
            return kept.join('').replace(/\s{2,}/g, ' ').trim();
          };

          // Some chapter pages re-render a block of paragraphs (ABAB pattern)
          // likely due to a template bug on the source site. Dedupe long
          // paragraphs we've already emitted. Short lines like "Yes." or
          // "Begin." are allowed to repeat since legitimate dialog may use
          // the same short line more than once in the same chapter.
          const DUP_MIN_LEN = 40;
          const seenLong = new Set();

          const out = [];
          for (const p of clone.querySelectorAll('p')) {
            // Normalise NBSP → regular space, collapse whitespace.
            let t = p.textContent.replace(/ /g, ' ').replace(/\s+/g, ' ').trim();
            if (!t) continue;
            if (isBoilerplate(t)) continue;
            // Drop paragraphs with no letters (e.g. "10:19", "---", "...", "123").
            if (!/[A-Za-z]/.test(t)) continue;
            const original = t;
            t = stripWatermarks(t);
            if (!t) continue;  // was pure watermark
            // If watermark stripping consumed meaningful content, the leftover
            // is likely injected framing ("New novel are published on."). Drop
            // the paragraph entirely when it collapsed below a credible length.
            if (t !== original && t.length < 25) continue;
            // Strip trailing promo fragments like "...nurses. Experience
            // new stories on empire" that get appended with no punctuation.
            t = stripBoilerplateTail(t);
            if (!t) continue;
            if (isBoilerplate(t)) continue;  // re-check after stripping
            if (t.length >= DUP_MIN_LEN) {
              if (seenLong.has(t)) continue;
              seenLong.add(t);
            }
            out.push(t);
          }
          return out;
        """#, as: [String].self)

        return Chapter(ref: ref, paragraphs: paragraphs)
    }

    // MARK: - Generic chapter extraction (alternate sources)

    /// Diagnostic result from `fetchChapterFromAlternateSource` so the caller
    /// (add-chapter) can tell the user which strategy worked.
    struct AlternateFetchResult {
        var chapter: Chapter
        var strategy: String
        var attempts: [(strategy: String, paragraphs: Int)]
        /// Title extracted from the alt page itself (from og:title/<title>/h1),
        /// or empty if nothing credible was found. Not yet normalized.
        var extractedTitle: String
    }

    /// Fetches a chapter from an arbitrary URL — possibly on a different site.
    /// Strategy ladder:
    ///   1. `--selector` override (if provided) → extract <p> children
    ///   2. Markers: paragraphs between `.chapter-start` and `.chapter-end`
    ///      (used by novellive.app AND freewebnovel.com)
    ///   3. Known container selectors (.txt, #chapter-content, etc.)
    ///   4. Fallback to `document.body`
    func fetchChapterFromAlternateSource(
        url: String,
        number: Int?,
        title: String?,
        overrideSelector: String? = nil,
        minParagraphs: Int = 3
    ) async throws -> AlternateFetchResult {
        try await load(url)

        let selectors: [String] = [
            ".txt",                 // novellive.app
            "#chapter-content",
            ".chapter-content",
            "#chapter_content",
            ".chapter_content",
            ".entry-content",       // WordPress
            ".post-content",
            "#content .text",
            "article .content",
            "article",
            "main"
        ]

        let overrideJS: String
        if let s = overrideSelector, !s.isEmpty {
            let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "'", with: "\\'")
            overrideJS = "'\(esc)'"
        } else {
            overrideJS = "null"
        }

        let selList = "[" + selectors.map { s in
            let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "'", with: "\\'")
            return "'\(esc)'"
        }.joined(separator: ",") + "]"

        struct Raw: Decodable {
            var strategy: String
            var attempts: [Attempt]
            var paragraphs: [String]
            var extractedTitle: String
            struct Attempt: Decodable { var strategy: String; var paragraphs: Int }
        }

        // Pass the expected chapter number to JS so it can match "Chapter N"
        // substrings specifically rather than guessing.
        let expectedNumJS = number.map(String.init) ?? "null"

        let raw: Raw = try await renderer.evaluateJSON(#"""
          const OVERRIDE = \#(overrideJS);
          const SELECTORS = \#(selList);
          const MIN = \#(minParagraphs);
          const EXPECTED_NUM = \#(expectedNumJS);

          const BOILERPLATE = [
            'Visit and read more novel to help us',
            'Thank you so much!',
            'Please read on our website',
            'New novel are published on',
            'New novels are published on',
            'Follow current novels on'
          ];
          const isBoilerplate = (t) => BOILERPLATE.some(b => t.indexOf(b) !== -1);

          const JUNK_SELECTOR =
            'script, style, iframe, noscript, ins, nav, header, footer, aside, ' +
            '.ad, .ads, .advertisement, .pub, [class*="ad-"], [id*="ad-"], ' +
            '[class*="pf-"], [data-widget-id], [id^="pf-"], a[rel*="sponsored"]';

          const cleanParagraph = (p) => {
            let t = p.textContent.replace(/ /g, ' ').replace(/\s+/g, ' ').trim();
            if (!t) return null;
            if (!/[A-Za-z]/.test(t)) return null;   // letterless (10:19, ---, 123)
            if (isBoilerplate(t)) return null;
            return t;
          };

          const extractFromContainer = (root) => {
            const clone = root.cloneNode(true);
            clone.querySelectorAll(JUNK_SELECTOR).forEach(e => e.remove());
            const out = [];
            const ps = clone.querySelectorAll('p');
            if (ps.length === 0) {
              // No <p> tags — split on newlines.
              const text = clone.innerText || clone.textContent || '';
              for (const line of text.split(/\n+/)) {
                const t = line.replace(/\s+/g, ' ').trim();
                if (!t || !/[A-Za-z]/.test(t) || isBoilerplate(t)) continue;
                out.push(t);
              }
              return out;
            }
            for (const p of ps) {
              const t = cleanParagraph(p);
              if (t !== null) out.push(t);
            }
            return out;
          };

          // Strategy 1 (markers): paragraphs that are siblings between
          // .chapter-start and .chapter-end. Handles sites where content isn't
          // wrapped in a single container (e.g. freewebnovel.com).
          const extractBetweenMarkers = () => {
            const start = document.querySelector('.chapter-start');
            const end = document.querySelector('.chapter-end');
            if (!start || !end) return null;
            // Walk the common ancestor's children. Find the index of each
            // marker among the ancestor's descendants in document order.
            const range = document.createRange();
            range.setStartAfter(start);
            range.setEndBefore(end);
            const frag = range.cloneContents();
            // frag is a DocumentFragment; extract <p> only.
            frag.querySelectorAll(JUNK_SELECTOR).forEach(e => e.remove());
            const out = [];
            frag.querySelectorAll('p').forEach(p => {
              const t = cleanParagraph(p);
              if (t !== null) out.push(t);
            });
            return out;
          };

          // Title extraction — look at og:title, <title>, chapter-title
          // elements, and h1/h2 near the content. If we know the chapter
          // number, we only accept candidates that contain "Chapter N".
          const extractTitle = () => {
            const candidates = [];
            const og = document.querySelector('meta[property="og:title"]');
            if (og) candidates.push(og.getAttribute('content') || '');
            const docTitle = document.title || '';
            if (docTitle) candidates.push(docTitle);
            for (const sel of [
              '.chapter-title', 'h1.chapter-title', 'h2.chapter-title',
              '.chapter-name', '.chap-title'
            ]) {
              const el = document.querySelector(sel);
              if (el) candidates.push((el.textContent || '').trim());
            }
            // Known novel-aggregator brand names used as site suffixes.
            const BRAND_SUFFIX = /(Free Web Novel|Novel Live|Novels? Online|Ranobes|Wuxia ?World|Webnovel|Royal ?Road|Scribble ?Hub|Light ?Novel|MTL ?Novel|NovelPub|NovelBuddy|NovelCool|NovelFull)/i;
            const chapterRe = EXPECTED_NUM !== null
              ? new RegExp('[Cc]hapter\\s+' + EXPECTED_NUM + '\\b[^|\\u2014]*')
              : /[Cc]hapter\s+\d+\b[^|—]*/;
            for (const raw of candidates) {
              if (!raw) continue;
              const m = raw.match(chapterRe);
              if (!m) continue;
              let title = m[0].trim();
              // Strip trailing site branding if present.
              const brand = title.match(BRAND_SUFFIX);
              if (brand && brand.index > 0) {
                const trimTo = title.lastIndexOf(' - ', brand.index);
                if (trimTo > 0) {
                  title = title.substring(0, trimTo).trim();
                } else {
                  title = title.substring(0, brand.index).replace(/[\s\-–—|:]+$/, '').trim();
                }
              }
              // Also strip pipe-separated trailing junk.
              title = title.replace(/\s*\|.*$/, '').trim();
              if (title) return title;
            }
            return '';
          };
          const extracted = extractTitle();

          const attempts = [];

          // 1. Override selector
          if (OVERRIDE) {
            const root = document.querySelector(OVERRIDE);
            const paras = root ? extractFromContainer(root) : [];
            attempts.push({ strategy: `--selector ${OVERRIDE}`, paragraphs: paras.length });
            if (paras.length >= MIN) {
              return { strategy: `--selector ${OVERRIDE}`, attempts: attempts, paragraphs: paras, extractedTitle: extracted };
            }
          }

          // 2. Markers
          const mark = extractBetweenMarkers();
          if (mark !== null) {
            attempts.push({ strategy: 'between .chapter-start and .chapter-end markers', paragraphs: mark.length });
            if (mark.length >= MIN) {
              return { strategy: 'between .chapter-start and .chapter-end markers', attempts: attempts, paragraphs: mark, extractedTitle: extracted };
            }
          }

          // 3. Known containers
          for (const sel of SELECTORS) {
            const root = document.querySelector(sel);
            if (!root) continue;
            const paras = extractFromContainer(root);
            attempts.push({ strategy: `container ${sel}`, paragraphs: paras.length });
            if (paras.length >= MIN) {
              return { strategy: `container ${sel}`, attempts: attempts, paragraphs: paras, extractedTitle: extracted };
            }
          }

          // 4. document.body
          const body = extractFromContainer(document.body);
          attempts.push({ strategy: 'document.body (last resort)', paragraphs: body.length });
          return {
            strategy: 'document.body (last resort)',
            attempts: attempts,
            paragraphs: body,
            extractedTitle: extracted
          };
        """#, as: Raw.self)

        // Prefer the title extracted from the alt page itself. Fall back to
        // the caller-supplied title, then to a bare "Chapter N" if neither.
        let fromPage = raw.extractedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle: String
        if !fromPage.isEmpty {
            effectiveTitle = fromPage
        } else if let t = title, !t.isEmpty {
            effectiveTitle = t
        } else {
            effectiveTitle = number.map { "Chapter \($0)" } ?? "Chapter"
        }
        let ref = Self.normalize(ChapterRef(url: url, title: effectiveTitle, number: number))
        let chapter = Chapter(ref: ref, paragraphs: raw.paragraphs)
        return AlternateFetchResult(
            chapter: chapter,
            strategy: raw.strategy,
            attempts: raw.attempts.map { ($0.strategy, $0.paragraphs) },
            extractedTitle: fromPage
        )
    }

    // MARK: - Gap probing

    /// Follows the `#next` link on `fromChapterURL`. Returns the next chapter
    /// as a ChapterRef, or nil if there is no next link (end of book / dead
    /// link). The caller can compare the returned chapter number against the
    /// expected gap number to decide whether a chapter was recovered or
    /// whether the gap is a real site skip.
    func probeNextChapter(fromChapterURL url: String) async throws -> ChapterRef? {
        try await load(url)
        struct NextInfo: Codable { var href: String; var title: String }
        let info: NextInfo = try await renderer.evaluateJSON(#"""
          const n = document.querySelector('#next');
          if (!n) return { href: '', title: '' };
          const raw = n.getAttribute('href') || '';
          if (!raw || raw.indexOf('reload') !== -1 || raw.startsWith('javascript')) {
            return { href: '', title: '' };
          }
          return { href: n.href, title: n.getAttribute('title') || '' };
        """#, as: NextInfo.self)
        guard !info.href.isEmpty else { return nil }
        let number = Self.parseChapterNumber(from: info.title)
                 ?? Self.parseChapterNumberFromURL(info.href)
        return ChapterRef(url: info.href, title: info.title, number: number)
    }

    // MARK: - Images

    /// Downloads an image by navigating the WKWebView to it (bypassing
    /// Cloudflare for media subdomains) and re-encoding via canvas.
    /// Returns (bytes, mimeType) or nil if the image couldn't be captured.
    func downloadImage(urlString: String) async throws -> (Data, String)? {
        try await load(urlString)
        // Give the image a moment to decode after Cloudflare clears.
        try await Task.sleep(for: .milliseconds(1000))
        let dataURL = try await renderer.evaluateString(#"""
          (function(){
            const img = document.images[0];
            if (!img || !img.complete || img.naturalWidth === 0) return '';
            const canvas = document.createElement('canvas');
            canvas.width = img.naturalWidth;
            canvas.height = img.naturalHeight;
            canvas.getContext('2d').drawImage(img, 0, 0);
            try { return canvas.toDataURL('image/jpeg', 0.92); }
            catch (e) { return ''; }
          })();
        """#)
        guard dataURL.hasPrefix("data:") else { return nil }
        let parts = dataURL.split(separator: ",", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let header = String(parts[0])
        let b64 = String(parts[1])
        let mime = header
            .replacingOccurrences(of: "data:", with: "")
            .split(separator: ";").first.map(String.init) ?? "image/jpeg"
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (data, mime)
    }

    // MARK: - Helpers

    static func parseChapterNumber(from title: String) -> Int? {
        // Matches "Chapter 2003", "Chapter 42:", "Chapter 7 -", "chapter 1"
        let pattern = #"[Cc]hapter\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(title.startIndex..., in: title)
        guard let match = regex.firstMatch(in: title, range: range),
              let numRange = Range(match.range(at: 1), in: title) else { return nil }
        return Int(title[numRange])
    }

    /// Canonicalizes a chapter title to "Chapter N: Title" or "Chapter N" when
    /// there's no title. Accepts any of these inputs:
    ///   "Chapter 864 - 864: Get Into A Rhythm" → "Chapter 864: Get Into A Rhythm"
    ///   "Chapter 882 882: History Lesson"       → "Chapter 882: History Lesson"
    ///   "Chapter 290 290"                        → "Chapter 290"
    ///   "Chapter 864: Get Into A Rhythm"        → unchanged
    ///   "Chapter 100 Get Into A Rhythm"         → "Chapter 100: Get Into A Rhythm"
    ///   "Chapter 100 - Title"                    → "Chapter 100: Title"
    ///   "Chapter: 100 Title"                     → "Chapter 100: Title"
    ///   "Ch. 100: Title"                         → "Chapter 100: Title"
    ///   "Chapter 1998"                           → "Chapter 1998"
    ///   "Chapter 911: Somebody Call 911"        → unchanged (not a prefix dup)
    static func cleanChapterTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Groups:
        //   1 = chapter number
        //   2 = everything after (title, possibly empty)
        // We tolerate "Chapter", "Ch", or "Ch." with optional ":" / dash
        // between the word and the number. Then we optionally consume a
        // duplicate copy of the same number (\1 backreference, bounded so
        // we don't eat prefixes of a longer number). Finally we strip any
        // leading separators before the title.
        let pattern = #"^\s*(?:[Cc]hapter|[Cc]h\.?)\s*[:\-–—]?\s*(\d+)(?:\s*[:\-–—\s]\s*\1(?!\d))?\s*[:\-–—]*\s*(.*?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return trimmed
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let m = regex.firstMatch(in: trimmed, range: range),
              let numRange = Range(m.range(at: 1), in: trimmed) else {
            return trimmed
        }
        let numStr = String(trimmed[numRange])
        let rest = Range(m.range(at: 2), in: trimmed)
            .map { String(trimmed[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        if rest.isEmpty {
            return "Chapter \(numStr)"
        }
        return "Chapter \(numStr): \(rest)"
    }

    /// Returns a ChapterRef with title normalized via `cleanChapterTitle` and
    /// number re-parsed if nil.
    static func normalize(_ ref: ChapterRef) -> ChapterRef {
        let cleanedTitle = cleanChapterTitle(ref.title)
        let number = ref.number ?? parseChapterNumber(from: cleanedTitle)
                                ?? parseChapterNumberFromURL(ref.url)
        return ChapterRef(url: ref.url, title: cleanedTitle, number: number)
    }

    /// Parses the chapter number from a URL like
    /// `/book/<slug>/chapter-123-foo-bar`.
    static func parseChapterNumberFromURL(_ url: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"/chapter-(\d+)"#) else { return nil }
        let range = NSRange(url.startIndex..., in: url)
        guard let match = regex.firstMatch(in: url, range: range),
              let numRange = Range(match.range(at: 1), in: url) else { return nil }
        return Int(url[numRange])
    }
}

//
//  main.swift
//  WebBound
//

import Foundation
import AppKit

// MARK: - CLI parsing

struct CLIOptions {
    var mode: Mode
    var url: String
    var outputPath: String?
    var cacheDir: String?
    var batchSize: Int = 25
    var chunkSize: Int?         // if set, fetch at most this many chapters then exit cleanly
    var delayMs: Int = 800
    var fromChapter: Int?       // 1-based chapter number
    var toChapter: Int?
    var noPrompt: Bool = false
    var refreshTOC: Bool = false
    // add-chapter options
    var chapterNumber: Int?
    var altSourceURL: String?
    var altSelector: String?
    var chapterTitle: String?

    var fixReview: Bool = false

    enum Mode { case dumpHTML, scrape, buildOnly, addChapter, review, migrate }
}

func printUsage() {
    FileHandle.standardError.write(Data((usageText() + "\n").utf8))
}

func usageText() -> String {
    """
    WebBound — download free web novels to EPUB.

    USAGE
      webbound dump <url>
          Debug: fetch URL through WKWebView (past Cloudflare) and print HTML.

      webbound scrape <book-url> [options]
          Fetch metadata, TOC, chapters, and cover image into the cache.
          State is resumable: re-run to continue where it left off.
          Does NOT produce an EPUB — run `build` after scraping.
          The URL is only required on the first run; after that you can pass
          just the slug (the cache dir name).

      webbound build <book> [options]
          Assemble the EPUB from the cached chapter markdown + cover.
          You can hand-edit chapters/ch-NNNN.md between scrape and build.
          <book> is the slug (cache dir name) or the original URL.

      webbound add-chapter <book> --number N [--to M] --source <url> [opts]
          Fetch one or more chapters from an alternate source URL and store
          them in the cache. A subsequent `build` or `scrape` picks them up.

          Single: --number N
          Range:  --number N --to M (inclusive)

          If --to is used, the source URL must either contain the literal
          placeholder "{number}" or end with a chapter number that we can
          auto-substitute. Examples:
              --source 'https://alt.com/.../chapter-{number}'
              --source 'https://alt.com/.../chapter-1766'  (auto, with --to 1795)

      webbound migrate <book> [--cache <dir>]
          Rename legacy 5-digit chapter filenames (ch-NNNNN.md) to the
          current 4-digit form (ch-NNNN.md). Skips any file whose target
          name already exists. Does not touch anything else.

      webbound review <book> [--fix] [--cache <dir>]
          Lint every cached chapter markdown and report issues:
          duplicate paragraphs, embedded homoglyph watermarks (e.g.
          "freēwēbηovel.c૦m"), zero-paragraph chapters, and chapters with
          suspiciously few paragraphs. Pass --fix to rewrite the .md files
          in place with duplicates/watermarks removed.

    OPTIONS (scrape / build)
      --output <path>     Output .epub path (default: <slug>.epub)
      --cache <dir>       Cache directory (default: ./.webbound/<slug>)
      --batch <N>         Pause for Enter every N chapters (default: 25, 0 = never)
      --chunk <N>         Fetch at most N chapters this run, then exit cleanly.
                          Resumable: re-invoke to continue. Great for scripts/loops.
      --delay <ms>        Delay between chapter fetches (default: 800)
      --from <N>          Start at chapter number N (default: 1)
      --to <N>            Stop at chapter number N (default: all)
      --no-prompt         Don't pause between batches
      --refresh-toc       Re-fetch TOC even if cached

    OPTIONS (add-chapter)
      --number <N>        Chapter number this entry represents (required)
      --source <url>      Alternate-source URL to fetch (required)
      --selector <css>    CSS selector for the content root (optional,
                          tries sensible defaults if omitted)
      --title <string>    Chapter title (optional; default: "Chapter N")
      --cache <dir>       Same cache as scrape (default: ./.webbound/<slug>)

    """
}

/// Result of CLI arg parsing. `.helpRequested` means the user explicitly asked
/// for help (exit 0); nil means a usage error (exit 64).
enum ParseResult {
    case ok(CLIOptions)
    case helpRequested
    case usageError
}

func parseArgs(_ argv: [String]) -> ParseResult {
    // No subcommand at all — show help.
    guard argv.count >= 2 else { return .helpRequested }
    switch argv[1] {
    case "--help", "-h", "help":
        return .helpRequested
    default: break
    }
    guard argv.count >= 3 else { return .usageError }
    let mode: CLIOptions.Mode
    switch argv[1] {
    case "dump":        mode = .dumpHTML
    case "scrape":      mode = .scrape
    case "build":       mode = .buildOnly
    case "add-chapter": mode = .addChapter
    case "review":      mode = .review
    case "migrate":     mode = .migrate
    default: return .usageError
    }
    var opts = CLIOptions(mode: mode, url: argv[2])

    var i = 3
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--output":
            i += 1; guard i < argv.count else { return .usageError }
            opts.outputPath = argv[i]
        case "--cache":
            i += 1; guard i < argv.count else { return .usageError }
            opts.cacheDir = argv[i]
        case "--batch":
            i += 1; guard i < argv.count, let n = Int(argv[i]) else { return .usageError }
            opts.batchSize = n
        case "--chunk":
            i += 1; guard i < argv.count, let n = Int(argv[i]) else { return .usageError }
            opts.chunkSize = n > 0 ? n : nil
        case "--delay":
            i += 1; guard i < argv.count, let n = Int(argv[i]) else { return .usageError }
            opts.delayMs = n
        case "--from":
            i += 1; guard i < argv.count, let n = Int(argv[i]) else { return .usageError }
            opts.fromChapter = n
        case "--to":
            i += 1; guard i < argv.count, let n = Int(argv[i]) else { return .usageError }
            opts.toChapter = n
        case "--no-prompt":
            opts.noPrompt = true
        case "--refresh-toc":
            opts.refreshTOC = true
        case "--number":
            i += 1; guard i < argv.count, let n = Int(argv[i]) else { return .usageError }
            opts.chapterNumber = n
        case "--source":
            i += 1; guard i < argv.count else { return .usageError }
            opts.altSourceURL = argv[i]
        case "--selector":
            i += 1; guard i < argv.count else { return .usageError }
            opts.altSelector = argv[i]
        case "--title":
            i += 1; guard i < argv.count else { return .usageError }
            opts.chapterTitle = argv[i]
        case "--fix":
            opts.fixReview = true
        case "--help", "-h":
            return .helpRequested
        default:
            FileHandle.standardError.write(Data("Unknown option: \(a)\n".utf8))
            return .usageError
        }
        i += 1
    }
    return .ok(opts)
}

// MARK: - Logging helpers

func logln(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

// MARK: - Book identity resolution

/// Identifies a book from the user's first positional arg + optional --cache.
/// Accepts:
///   * A full URL (http:// or https://) — slug comes from the last path
///     component.
///   * A bare slug — resolves to ./.webbound/<slug>/ (or --cache).
///   * A directory path — the basename becomes the slug.
///
/// If `requireURL` is true, we also need a book-source URL. The URL comes
/// from either the argument itself (when it's a URL) or metadata.json in
/// the cache. Returns nil + logs an error if resolution fails.
struct BookIdentity {
    var slug: String
    var cacheRoot: URL
    /// Source URL for the book on the primary site. May be nil for cache-only
    /// commands (build/review/migrate) when the user passed just a slug and
    /// metadata.json is missing.
    var bookURL: String?
}

func resolveBook(arg: String, cacheOverride: String?, requireURL: Bool) -> BookIdentity? {
    let fm = FileManager.default
    let isURL = arg.hasPrefix("http://") || arg.hasPrefix("https://")

    let slug: String
    let cacheRoot: URL

    if let override = cacheOverride {
        cacheRoot = URL(fileURLWithPath: override)
        if isURL {
            slug = URL(string: arg)?.lastPathComponent ?? cacheRoot.lastPathComponent
        } else {
            slug = cacheRoot.lastPathComponent
        }
    } else if isURL {
        slug = URL(string: arg)?.lastPathComponent ?? "book"
        cacheRoot = URL(fileURLWithPath: ".webbound").appendingPathComponent(slug)
    } else {
        // Treat as slug or path. If it looks like a path with separators or
        // exists as a directory on disk, use it directly. Otherwise it's a
        // bare slug under ./.webbound/.
        let argURL = URL(fileURLWithPath: arg)
        var isDir: ObjCBool = false
        if arg.contains("/") || (fm.fileExists(atPath: argURL.path, isDirectory: &isDir) && isDir.boolValue) {
            cacheRoot = argURL
            slug = argURL.lastPathComponent
        } else {
            slug = arg
            cacheRoot = URL(fileURLWithPath: ".webbound").appendingPathComponent(slug)
        }
    }

    // Determine the book URL. If the user passed one, use it; otherwise try
    // metadata.json inside the cache.
    var bookURL: String? = isURL ? arg : nil
    if bookURL == nil {
        let metaURL = cacheRoot.appendingPathComponent("metadata.json")
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(BookMetadata.self, from: data) {
            bookURL = meta.sourceURL
        }
    }

    if requireURL && bookURL == nil {
        logln("Could not determine book URL. Pass the full URL as the first")
        logln("argument, or run `scrape <url>` once so metadata.json exists at")
        logln("\(cacheRoot.path).")
        return nil
    }

    // Sanity check: for non-URL first-arg + cache-only commands, make sure
    // the cache actually exists; otherwise we're being asked about a book
    // that was never scraped.
    if !isURL && !fm.fileExists(atPath: cacheRoot.path) {
        logln("No cache found at \(cacheRoot.path).")
        logln("Did you mean one of these?")
        let base = URL(fileURLWithPath: ".webbound")
        if let entries = try? fm.contentsOfDirectory(atPath: base.path) {
            for e in entries.sorted() {
                logln("  \(e)")
            }
        }
        return nil
    }

    return BookIdentity(slug: slug, cacheRoot: cacheRoot, bookURL: bookURL)
}

// MARK: - Entry point / run loop

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let parsed = parseArgs(CommandLine.arguments)
switch parsed {
case .helpRequested:
    // Print to stdout so `webbound --help | less` works naturally.
    print(usageText())
    exit(0)
case .usageError:
    printUsage()
    exit(64)
case .ok(let opts):
    Task { @MainActor in
        let code = await runCLI(opts: opts)
        exit(code)
    }
    app.run()
}

// MARK: - Dispatch

@MainActor
func runCLI(opts: CLIOptions) async -> Int32 {
    switch opts.mode {
    case .dumpHTML:
        return await runDumpHTML(url: opts.url)
    case .scrape:
        return await runScrape(opts: opts, fetch: true)
    case .buildOnly:
        return await runScrape(opts: opts, fetch: false)
    case .addChapter:
        return await runAddChapter(opts: opts)
    case .review:
        return await runReview(opts: opts)
    case .migrate:
        return await runMigrate(opts: opts)
    }
}

@MainActor
func runDumpHTML(url urlString: String) async -> Int32 {
    guard let url = URL(string: urlString) else {
        logln("Invalid URL: \(urlString)"); return 64
    }
    let renderer = WebRenderer()
    do {
        logln("Loading \(url.absoluteString)...")
        try await renderer.load(url)
        logln("Initial navigation finished. Waiting for Cloudflare clearance (if any)...")
        try await renderer.waitForCloudflareClearance(timeout: 30)
        try await Task.sleep(for: .seconds(2))
        let html = try await renderer.html()
        print(html)
        return 0
    } catch {
        logln("Error: \(error)")
        return 1
    }
}

// MARK: - Scrape pipeline

@MainActor
func runScrape(opts: CLIOptions, fetch: Bool) async -> Int32 {
    // Scrape mode needs a book URL (either from argv or metadata.json).
    // Build mode is cache-only.
    guard let id = resolveBook(arg: opts.url, cacheOverride: opts.cacheDir, requireURL: fetch) else {
        return 1
    }
    let slug = id.slug
    let cacheRoot = id.cacheRoot
    // Downstream code still uses `bookURL` as the primary site URL. For
    // build mode this may be nil (that's OK — we don't call the network).
    let bookURL: String = id.bookURL ?? opts.url
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheRoot.appendingPathComponent("chapters"),
                               withIntermediateDirectories: true)
    } catch {
        logln("Could not create cache dir \(cacheRoot.path): \(error)")
        return 1
    }

    let metadataURL = cacheRoot.appendingPathComponent("metadata.json")
    let tocURL = cacheRoot.appendingPathComponent("toc.json")
    let coverURL = cacheRoot.appendingPathComponent("cover.bin")
    let coverMetaURL = cacheRoot.appendingPathComponent("cover.meta")

    let renderer = WebRenderer()
    let scraper = NovelLiveScraper(renderer: renderer, settlingDelay: 0.8)

    // 1. Metadata
    let metadata: BookMetadata
    if fm.fileExists(atPath: metadataURL.path),
       let data = try? Data(contentsOf: metadataURL),
       let decoded = try? JSONDecoder().decode(BookMetadata.self, from: data) {
        logln("Using cached metadata.")
        metadata = decoded
    } else if fetch {
        do {
            logln("Fetching book metadata...")
            metadata = try await scraper.fetchMetadata(bookURL: bookURL)
            try JSONEncoder.pretty.encode(metadata).write(to: metadataURL)
            logln("  title:   \(metadata.title)")
            logln("  author:  \(metadata.author ?? "(unknown)")")
            logln("  status:  \(metadata.status ?? "(unknown)")")
            logln("  genres:  \(metadata.genres.joined(separator: ", "))")
        } catch {
            logln("Metadata fetch failed: \(error)")
            return 1
        }
    } else {
        logln("No cached metadata and --build does not fetch. Run `scrape` first.")
        return 1
    }

    // 2. Table of contents
    let toc: [ChapterRef]
    if !opts.refreshTOC, fm.fileExists(atPath: tocURL.path),
       let data = try? Data(contentsOf: tocURL),
       let decoded = try? JSONDecoder().decode([ChapterRef].self, from: data) {
        logln("Using cached TOC: \(decoded.count) chapters.")
        toc = decoded
    } else if fetch {
        do {
            logln("Fetching TOC...")
            let totalPages = try await scraper.fetchTotalTOCPages(bookURL: bookURL)
            logln("  \(totalPages) TOC pages to crawl.")
            let tocPagesDir = cacheRoot.appendingPathComponent("toc-pages")
            try fm.createDirectory(at: tocPagesDir, withIntermediateDirectories: true)

            var seen = Set<String>()
            var collected: [ChapterRef] = []
            for page in 1...totalPages {
                let pageCache = tocPagesDir.appendingPathComponent(String(format: "page-%04d.json", page))
                var refs: [ChapterRef] = []

                // Prefer a cached, well-formed page.
                if fm.fileExists(atPath: pageCache.path),
                   let data = try? Data(contentsOf: pageCache),
                   let decoded = try? JSONDecoder().decode([ChapterRef].self, from: data),
                   !decoded.isEmpty,
                   !decoded.contains(where: { $0.url.contains("/chapter-error") }) {
                    refs = decoded
                } else {
                    // Fetch with explicit rate-limit backoff / retries.
                    var attempt = 0
                    while attempt < 4 {
                        attempt += 1
                        do {
                            refs = try await scraper.fetchTOCPage(bookURL: bookURL, page: page)
                            try JSONEncoder.pretty.encode(refs).write(to: pageCache)
                            if opts.delayMs > 0 {
                                try await Task.sleep(for: .milliseconds(opts.delayMs))
                            }
                            break
                        } catch ScraperError.rateLimited {
                            let backoff = 5 * attempt
                            logln("  ! TOC page \(page): rate-limited; sleeping \(backoff)s before retry \(attempt)/4")
                            try? await Task.sleep(for: .seconds(backoff))
                        } catch {
                            if attempt >= 4 { throw error }
                            logln("  ! TOC page \(page) error \(error); retry \(attempt)/4")
                            try? await Task.sleep(for: .seconds(3))
                        }
                    }
                    if refs.isEmpty {
                        logln("  ! TOC page \(page): still empty after retries; skipping")
                    }
                }

                var newOnPage = 0
                for ref in refs where !seen.contains(ref.url) {
                    seen.insert(ref.url)
                    collected.append(ref)
                    newOnPage += 1
                }
                logln("  TOC page \(page)/\(totalPages): +\(newOnPage) new (total \(collected.count))")
            }
            // Sort by parsed chapter number; chapters without a number go to the end.
            collected.sort { lhs, rhs in
                switch (lhs.number, rhs.number) {
                case let (l?, r?): return l < r
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return lhs.title < rhs.title
                }
            }
            toc = collected
            try JSONEncoder.pretty.encode(toc).write(to: tocURL)
            logln("TOC complete: \(toc.count) chapters.")
        } catch {
            logln("TOC fetch failed: \(error)")
            return 1
        }
    } else {
        logln("No cached TOC. Run `scrape` first.")
        return 1
    }

    // 2b. Gap reconciliation — ensure chapter numbers are contiguous.
    //     For each missing number, follow the preceding chapter's #next link:
    //       - if it lands on the missing number → recover + add to TOC
    //       - if it skips past (or no next) → confirmed site gap
    //     Also drop any ChapterRef without a parsed number.
    // Also normalize titles (collapse duplicate "Chapter N - N:" prefixes
    // that occur in some source entries).
    var tocMutable: [ChapterRef] = toc
        .filter { $0.number != nil }  // drop error placeholders
        .map(NovelLiveScraper.normalize)
    var tocChanged = (tocMutable != toc.filter { $0.number != nil })

    if fetch, !tocMutable.isEmpty {
        tocMutable.sort { ($0.number ?? 0) < ($1.number ?? 0) }
        let numbers = Set(tocMutable.compactMap(\.number))
        let maxN = numbers.max() ?? 0
        let minN = numbers.min() ?? 1
        let gaps = (minN...maxN).filter { !numbers.contains($0) }

        if !gaps.isEmpty {
            logln("")
            logln("TOC gap check: \(gaps.count) missing chapter number(s) in \(minN)..\(maxN):")
            logln("  \(gaps.prefix(20).map(String.init).joined(separator: ", "))\(gaps.count > 20 ? ", ..." : "")")
            logln("Probing each gap via the preceding chapter's next-link...")

            var confirmedSiteGaps: [Int] = []
            var recovered: [ChapterRef] = []
            var knownByNumber: [Int: ChapterRef] = Dictionary(
                uniqueKeysWithValues: tocMutable.compactMap { ref in ref.number.map { ($0, ref) } }
            )

            for gap in gaps {
                // Find the nearest known chapter number < gap.
                var probeFromNumber: Int? = nil
                for candidate in stride(from: gap - 1, through: minN, by: -1) {
                    if knownByNumber[candidate] != nil {
                        probeFromNumber = candidate
                        break
                    }
                }
                guard let fromNum = probeFromNumber,
                      let fromRef = knownByNumber[fromNum] else {
                    logln("  gap \(gap): no earlier chapter to probe from; skipping")
                    continue
                }
                do {
                    if let next = try await scraper.probeNextChapter(fromChapterURL: fromRef.url) {
                        if let n = next.number, n == gap {
                            logln("  gap \(gap): recovered — \(next.title)")
                            recovered.append(next)
                            knownByNumber[gap] = next
                        } else if let n = next.number, n > gap {
                            logln("  gap \(gap): site skipped (ch \(fromNum).next → ch \(n))")
                            confirmedSiteGaps.append(gap)
                        } else {
                            logln("  gap \(gap): unexpected next \(next.number.map(String.init) ?? "?") — recording as missing")
                            confirmedSiteGaps.append(gap)
                        }
                    } else {
                        logln("  gap \(gap): no next link from ch \(fromNum); recording as missing")
                        confirmedSiteGaps.append(gap)
                    }
                } catch {
                    logln("  gap \(gap): probe error (\(error)); skipping")
                }
                if opts.delayMs > 0 {
                    try? await Task.sleep(for: .milliseconds(opts.delayMs))
                }
            }

            if !recovered.isEmpty {
                tocMutable.append(contentsOf: recovered)
                tocChanged = true
                logln("Recovered \(recovered.count) missing chapter(s).")
            }
            if !confirmedSiteGaps.isEmpty {
                logln("Confirmed \(confirmedSiteGaps.count) site gap(s) (chapters never existed on source).")
                logln("")
                logln("To fill a gap from an alternate source, run:")
                for gap in confirmedSiteGaps.prefix(5) {
                    logln("  webbound add-chapter \(slug) \\")
                    logln("      --number \(gap) --source <alt-url> [--selector <css>] [--title \"...\"]")
                }
                if confirmedSiteGaps.count > 5 {
                    logln("  (+ \(confirmedSiteGaps.count - 5) more)")
                }
                logln("")
            }
        }
    }

    // Always sort by chapter number so EPUB and cached toc.json are canonical.
    tocMutable.sort { ($0.number ?? Int.max) < ($1.number ?? Int.max) }

    // ONLY rewrite toc.json in scrape mode. Build mode is strictly read-only
    // on the cache — never touch files other than the output EPUB.
    if fetch, tocChanged || toc != tocMutable {
        do {
            try JSONEncoder.pretty.encode(tocMutable).write(to: tocURL)
            logln("TOC rewritten: \(tocMutable.count) chapters (sorted, deduped).")
        } catch {
            logln("Warning: could not rewrite toc.json: \(error)")
        }
    }
    let finalTOC = tocMutable

    // 3. Chapters
    let fromCh = opts.fromChapter ?? 1
    let toCh = opts.toChapter ?? Int.max

    let targetRefs = finalTOC.filter { ref in
        guard let n = ref.number else { return false }
        return n >= fromCh && n <= toCh
    }

    // Returns true if the current run hit its `--chunk` limit and more
    // uncached chapters remain. When this happens we skip EPUB generation
    // so successive chunk runs don't rezip 2000 files each time.
    var hitChunkLimit = false

    if fetch, !targetRefs.isEmpty {
        logln("Fetching chapters \(fromCh)..\(min(toCh, finalTOC.compactMap(\.number).max() ?? toCh)) (\(targetRefs.count) target)")
        var fetchedThisRun = 0
        var batchCount = 0
        for (idx, ref) in targetRefs.enumerated() {
            if chapterIsCached(cacheRoot: cacheRoot, ref) {
                continue
            }
            do {
                let chapter = try await scraper.fetchChapter(ref: ref)
                let numStr = ref.number.map(String.init) ?? "?"
                // Refuse to persist a zero-paragraph chapter — the fetch was
                // probably rate-limited or hit a site-interstitial. Leaving no
                // .md on disk lets the next run retry this chapter.
                if chapter.paragraphs.isEmpty {
                    logln("  ! [\(idx + 1)/\(targetRefs.count)] ch \(numStr): 0 paragraphs — not saved. Likely rate-limited; next run will retry.")
                } else {
                    try saveChapterMarkdown(cacheRoot: cacheRoot, chapter)
                    fetchedThisRun += 1
                    batchCount += 1
                    logln("  [\(idx + 1)/\(targetRefs.count)] ch \(numStr): \(ref.title) (\(chapter.paragraphs.count) paragraphs)")
                }
            } catch {
                logln("  ! failed \(ref.title): \(error)")
                // Keep going — a single flaky chapter shouldn't abort the run.
            }

            // Chunk limit — exit cleanly so the caller can re-invoke to resume.
            if let chunk = opts.chunkSize, fetchedThisRun >= chunk {
                // Count how many uncached chapters remain in the target range.
                let remaining = targetRefs.dropFirst(idx + 1).filter {
                    !chapterIsCached(cacheRoot: cacheRoot, $0)
                }.count
                if remaining > 0 {
                    hitChunkLimit = true
                    logln("")
                    logln("Chunk complete: fetched \(fetchedThisRun) chapter(s) this run; \(remaining) still uncached.")
                    logln("Re-run the same command to continue, or run `build` to assemble a partial EPUB now.")
                }
                break
            }

            if opts.delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(opts.delayMs))
            }

            if !opts.noPrompt && opts.batchSize > 0 && batchCount >= opts.batchSize && idx < targetRefs.count - 1 {
                batchCount = 0
                let remaining = targetRefs.count - (idx + 1)
                print("")
                print("--- Fetched \(fetchedThisRun) this run. \(remaining) chapters remaining.")
                print("    [Enter] continue   [q + Enter] stop and build EPUB from what's cached")
                if let line = readLine(), line.trimmingCharacters(in: .whitespaces).lowercased() == "q" {
                    logln("Stopping on user request.")
                    break
                }
            }
        }
        logln("Fetched \(fetchedThisRun) new chapter(s) this run.")
    }

    if hitChunkLimit {
        return 0  // partial scrape — user will scrape more + run build later.
    }

    // Cover download — only in scrape mode. Cached result is picked up by build.
    if fetch {
        let haveCachedCover = fm.fileExists(atPath: coverURL.path)
            && fm.fileExists(atPath: coverMetaURL.path)
        let cachedLooksValid: Bool = {
            guard haveCachedCover,
                  let cached = try? Data(contentsOf: coverURL),
                  !looksLikeHTML(cached),
                  let mime = try? String(contentsOf: coverMetaURL, encoding: .utf8),
                  mime.hasPrefix("image/") else { return false }
            _ = cached
            return true
        }()
        if !cachedLooksValid, let imgURLStr = metadata.coverImageURL {
            logln("Downloading cover: \(imgURLStr)")
            do {
                if let (data, mime) = try await scraper.downloadImage(urlString: imgURLStr) {
                    try? data.write(to: coverURL)
                    try? mime.write(to: coverMetaURL, atomically: true, encoding: .utf8)
                    logln("  cover: \(data.count) bytes, \(mime)")
                } else {
                    logln("  (cover download returned no data, continuing without cover)")
                }
            } catch {
                logln("  (cover download failed: \(error) — continuing without cover)")
            }
        }
        // scrape is now complete. EPUB assembly happens via `build`.
        logln("")
        logln("Scrape complete. Run `webbound build \(slug)` to assemble the EPUB.")
        return 0
    }

    // ---- build mode only below ----

    // Load cover from cache (scrape wrote it; if missing we proceed sans cover).
    var coverData: Data? = nil
    var coverMediaType: String? = nil
    if fm.fileExists(atPath: coverURL.path),
       fm.fileExists(atPath: coverMetaURL.path),
       let cached = try? Data(contentsOf: coverURL),
       !looksLikeHTML(cached),
       let mime = try? String(contentsOf: coverMetaURL, encoding: .utf8),
       mime.hasPrefix("image/") {
        coverData = cached
        coverMediaType = mime
    }

    // 5. Load all cached chapters, in TOC order. For each entry whose TOC
    // title is bare "Chapter N", try to backfill the real title from the
    // chapter's own markdown. Alert the user about any entries that still
    // have no title after this pass.
    var chapters: [Chapter] = []
    var backfilledTitles: [(number: Int, from: String, to: String)] = []
    var missingTitles: [(number: Int, file: String)] = []
    for ref in finalTOC {
        guard let cached = loadCachedChapter(cacheRoot: cacheRoot, ref) else {
            continue
        }
        let normalizedTOCTitle = NovelLiveScraper.cleanChapterTitle(ref.title)
        let normalizedMDTitle = NovelLiveScraper.cleanChapterTitle(cached.ref.title)
        let tocHasTitle = normalizedTOCTitle.contains(":")
        let mdHasTitle = normalizedMDTitle.contains(":")

        var effectiveTitle = normalizedTOCTitle
        if !tocHasTitle && mdHasTitle {
            effectiveTitle = normalizedMDTitle
            if let n = ref.number {
                backfilledTitles.append((number: n, from: normalizedTOCTitle, to: normalizedMDTitle))
            }
        }
        if !effectiveTitle.contains(":"), let n = ref.number {
            let fname = ChapterMarkdown.filename(for: ref)
            missingTitles.append((number: n, file: fname))
        }

        let finalRef = ChapterRef(
            url: cached.ref.url,
            title: effectiveTitle,
            number: cached.ref.number ?? ref.number
        )
        chapters.append(Chapter(ref: finalRef, paragraphs: cached.paragraphs))
    }
    // Final safety: ensure chapters are in strict numeric order.
    chapters.sort { ($0.ref.number ?? Int.max) < ($1.ref.number ?? Int.max) }

    if !backfilledTitles.isEmpty {
        logln("Title backfill from chapter markdown (TOC had bare \"Chapter N\"):")
        for b in backfilledTitles.prefix(10) {
            logln("  ch \(b.number): \"\(b.from)\" → \"\(b.to)\"")
        }
        if backfilledTitles.count > 10 {
            logln("  (+ \(backfilledTitles.count - 10) more)")
        }
    }

    if !missingTitles.isEmpty {
        logln("")
        logln("WARNING: \(missingTitles.count) chapter(s) have no title (stored as bare \"Chapter N\"):")
        let preview = missingTitles.prefix(15).map { "\($0.number)" }.joined(separator: ", ")
        let suffix = missingTitles.count > 15 ? ", …" : ""
        logln("  chapter numbers: \(preview)\(suffix)")
        logln("  To recover titles, re-fetch these from an alternate source:")
        logln("    webbound add-chapter \(slug) \\")
        logln("        --number N [--to M] --source 'https://alt-site.com/.../chapter-N'")
        logln("")
    }

    if chapters.isEmpty {
        logln("No chapters cached — nothing to build.")
        return 1
    }

    // 6. Write EPUB
    let outputPath = opts.outputPath.map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: "\(slug).epub")
    logln("Writing EPUB (\(chapters.count) chapters) to \(outputPath.path) ...")
    let stderrIsTTY = isatty(fileno(stderr)) != 0
    var writer = EPUBWriter(
        metadata: metadata,
        chapters: chapters,
        outputPath: outputPath,
        coverData: coverData,
        coverMediaType: coverMediaType
    )
    // Progress reporter: redraws a single line on a TTY, or prints one line
    // per phase milestone when stderr is piped.
    var lastReportedChapter = 0
    var lastEmittedKey = ""   // dedup for non-TTY end-of-phase messages
    writer.progress = { phase, current, total in
        if stderrIsTTY {
            // Build a 30-wide bar for phases with real progress.
            let barWidth = 30
            let frac = total > 0 ? Double(current) / Double(total) : 0
            let fill = max(0, min(barWidth, Int(frac * Double(barWidth))))
            let bar = String(repeating: "█", count: fill)
                + String(repeating: "░", count: barWidth - fill)
            let line: String
            if phase == "chapters" {
                line = "  [\(bar)] \(phase): \(current)/\(total)"
            } else {
                line = "  \(phase)..."
            }
            // \r rewinds the cursor so the next write overwrites this one.
            // \u{1B}[K clears to end of line in case the new line is shorter.
            FileHandle.standardError.write(Data("\r\u{1B}[K\(line)".utf8))
            if phase == "done" {
                FileHandle.standardError.write(Data("\n".utf8))
            }
        } else {
            // Non-TTY: emit a line every 10% of chapters, plus one on
            // completion of each non-chapter phase. Guarantees no duplicates
            // when a phase emits both start (0) and end (1) events.
            if phase == "chapters" {
                let step = max(1, total / 10)
                if current - lastReportedChapter >= step || current == total {
                    lastReportedChapter = current
                    FileHandle.standardError.write(
                        Data("  chapters: \(current)/\(total)\n".utf8)
                    )
                }
            } else if phase != "done" && current == total {
                let key = "\(phase):done"
                if key != lastEmittedKey {
                    lastEmittedKey = key
                    FileHandle.standardError.write(Data("  \(phase) done\n".utf8))
                }
            }
        }
    }
    do {
        try writer.write()
        logln("Done. \(outputPath.path)")
        return 0
    } catch {
        logln("EPUB write failed: \(error)")
        return 1
    }
}

// MARK: - migrate

@MainActor
func runMigrate(opts: CLIOptions) async -> Int32 {
    guard let id = resolveBook(arg: opts.url, cacheOverride: opts.cacheDir, requireURL: false) else {
        return 1
    }
    let cacheRoot = id.cacheRoot
    let chaptersDir = cacheRoot.appendingPathComponent("chapters")
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
        at: chaptersDir,
        includingPropertiesForKeys: nil
    ) else {
        logln("No chapters directory at \(chaptersDir.path)")
        return 1
    }

    // Match exactly 5 digits (not 4, not 6) so we don't re-rename files that
    // already migrated, and don't touch unrelated names.
    let legacyRegex = try! NSRegularExpression(pattern: #"^ch-(\d{5})\.md$"#)

    var renamed = 0
    var collisions: [(from: String, to: String)] = []
    var errors: [(file: String, error: String)] = []

    for file in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let name = file.lastPathComponent
        let r = NSRange(name.startIndex..., in: name)
        guard let m = legacyRegex.firstMatch(in: name, range: r),
              let numRange = Range(m.range(at: 1), in: name),
              let num = Int(name[numRange]) else {
            continue
        }
        let target = chaptersDir.appendingPathComponent(String(format: "ch-%04d.md", num))
        if fm.fileExists(atPath: target.path) {
            collisions.append((from: name, to: target.lastPathComponent))
            continue
        }
        do {
            try fm.moveItem(at: file, to: target)
            renamed += 1
            logln("renamed \(name) → \(target.lastPathComponent)")
        } catch {
            errors.append((file: name, error: "\(error)"))
        }
    }

    logln("")
    logln("Summary:")
    logln("  renamed:    \(renamed)")
    logln("  collisions: \(collisions.count) (both 5-digit and 4-digit exist; left legacy file in place)")
    for c in collisions.prefix(10) {
        logln("    \(c.from) ↔ \(c.to)")
    }
    if collisions.count > 10 {
        logln("    (+ \(collisions.count - 10) more)")
    }
    logln("  errors:     \(errors.count)")
    for e in errors.prefix(5) {
        logln("    \(e.file): \(e.error)")
    }
    return errors.isEmpty ? 0 : 1
}

// MARK: - review

/// Short, context-preserving excerpt for the console report. Keeps BOTH
/// ends of long strings so the user can see where the removal starts and
/// where it ends — the trailing part is often the diagnostic bit.
private func excerpt(_ s: String, max: Int = 200) -> String {
    guard s.count > max else { return s }
    let headLen = max * 2 / 3
    let tailLen = max - headLen - 3  // 3 for " … "
    let head = s.prefix(headLen)
    let tail = s.suffix(tailLen)
    return "\(head) … \(tail)"
}

@MainActor
func runReview(opts: CLIOptions) async -> Int32 {
    guard let id = resolveBook(arg: opts.url, cacheOverride: opts.cacheDir, requireURL: false) else {
        return 1
    }
    let cacheRoot = id.cacheRoot
    let chaptersDir = cacheRoot.appendingPathComponent("chapters")
    let fm = FileManager.default

    guard let files = try? fm.contentsOfDirectory(
            at: chaptersDir,
            includingPropertiesForKeys: nil
          ).filter({ $0.pathExtension == "md" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    else {
        logln("No chapters directory at \(chaptersDir.path)")
        return 1
    }
    if files.isEmpty {
        logln("No cached chapter markdown found at \(chaptersDir.path)")
        return 1
    }

    print("Reviewing \(files.count) chapter markdown file(s) in \(chaptersDir.path)")
    print(opts.fixReview ? "Mode: FIX (will rewrite .md files in place)" : "Mode: report only (pass --fix to apply)")
    print("")

    var chaptersWithDupes = 0
    var chaptersWithWatermarks = 0
    var chaptersWithPromoTail = 0
    var chaptersWithTitleChange = 0
    var chaptersMissingTitle: [(number: Int, file: String)] = []
    var chaptersEmpty = 0
    var chaptersSmall = 0
    var totalDupesRemoved = 0
    var totalWatermarksStripped = 0
    var totalPromoTailsStripped = 0
    var filesRewritten = 0
    // Paragraph-count stats — collected from non-empty chapters.
    // Keeping (count, filename, title) so we can name the min/max outliers.
    var paragraphStats: [(count: Int, file: String, title: String)] = []
    paragraphStats.reserveCapacity(files.count)

    // Load the existing TOC so we can propose repairs: title backfill from
    // the chapter markdown, and inserting entries for chapters that exist as
    // .md but are missing from toc.json.
    let tocFileURL = cacheRoot.appendingPathComponent("toc.json")
    var tocEntries: [ChapterRef] = []
    if fm.fileExists(atPath: tocFileURL.path),
       let data = try? Data(contentsOf: tocFileURL),
       let decoded = try? JSONDecoder().decode([ChapterRef].self, from: data) {
        tocEntries = decoded
    }
    var tocByNumber: [Int: ChapterRef] = Dictionary(
        uniqueKeysWithValues: tocEntries.compactMap { ref in ref.number.map { ($0, ref) } }
    )
    var tocTitleBackfills: [(number: Int, from: String, to: String)] = []
    var tocEntriesAdded: [ChapterRef] = []

    // Collect the audit log here so we can also persist it as review.log.
    var auditLines: [String] = []
    func audit(_ line: String) { auditLines.append(line); print(line) }

    for file in files {
        guard let chapter = try? ChapterMarkdown.read(from: file) else {
            audit("\(file.lastPathComponent): (unreadable, skipping)")
            continue
        }

        // Health checks that don't depend on cleaning.
        if chapter.paragraphs.isEmpty {
            chaptersEmpty += 1
            audit("\(file.lastPathComponent): ZERO paragraphs — likely rate-limited at scrape; rerun to refetch")
            audit("")
            continue
        }
        paragraphStats.append((
            count: chapter.paragraphs.count,
            file: file.lastPathComponent,
            title: chapter.ref.title
        ))
        if chapter.paragraphs.count < 5 {
            chaptersSmall += 1
            audit("\(file.lastPathComponent): only \(chapter.paragraphs.count) paragraph(s) — possibly truncated extraction")
        }

        var (cleaned, report) = TextCleaning.clean(paragraphs: chapter.paragraphs)

        // Title normalization — collapse "Chapter 100 Hello", "Chapter: 100 X",
        // etc. to "Chapter 100: Hello".
        let normalizedTitle = NovelLiveScraper.cleanChapterTitle(chapter.ref.title)
        if normalizedTitle != chapter.ref.title {
            report.titleNormalized = (before: chapter.ref.title, after: normalizedTitle)
        }

        // Missing title: after normalization, the stored title is just
        // "Chapter N" with no suffix. The scrape couldn't recover a title or
        // the alternate source extraction skipped it. User can refetch from
        // an alt source to get the real title.
        let hasRealTitle = normalizedTitle.contains(":")
        let isMissingTitle = !hasRealTitle
        if isMissingTitle, let n = chapter.ref.number {
            chaptersMissingTitle.append((number: n, file: file.lastPathComponent))
        }

        // TOC repair: compare this chapter's data against toc.json.
        if let n = chapter.ref.number {
            if let existing = tocByNumber[n] {
                let tocTitleNormalized = NovelLiveScraper.cleanChapterTitle(existing.title)
                let tocHasRealTitle = tocTitleNormalized.contains(":")
                if !tocHasRealTitle && hasRealTitle {
                    tocTitleBackfills.append((
                        number: n,
                        from: tocTitleNormalized,
                        to: normalizedTitle
                    ))
                    tocByNumber[n] = ChapterRef(
                        url: existing.url,
                        title: normalizedTitle,
                        number: n
                    )
                }
            } else {
                // No TOC entry for this cached chapter — propose adding one.
                let newRef = ChapterRef(
                    url: chapter.ref.url,
                    title: normalizedTitle,
                    number: n
                )
                tocEntriesAdded.append(newRef)
                tocByNumber[n] = newRef
            }
        }

        guard report.hasChanges || isMissingTitle else { continue }

        audit("\(file.lastPathComponent) — \(chapter.ref.title)")
        if isMissingTitle {
            audit("  Missing title — stored as just \"\(normalizedTitle)\" with no subtitle. Re-fetch from an alternate source to recover.")
        }

        if let t = report.titleNormalized {
            audit("  Title normalized:")
            audit("    before: \(t.before)")
            audit("    after:  \(t.after)")
        }

        if !report.tailsStripped.isEmpty {
            chaptersWithPromoTail += 1
            totalPromoTailsStripped += report.tailsStripped.count
            audit("  Promo tail(s) stripped: \(report.tailsStripped.count)")
            for t in report.tailsStripped {
                audit("    paragraph #\(t.index):")
                audit("      removed: \(t.tail)")
                audit("      kept:    \(excerpt(t.cleaned))")
            }
        }

        if !report.watermarks.isEmpty {
            chaptersWithWatermarks += 1
            totalWatermarksStripped += report.watermarks.reduce(0) { $0 + $1.tokens.count }
            audit("  Watermark tokens stripped: \(report.watermarks.reduce(0){$0+$1.tokens.count}) across \(report.watermarks.count) paragraph(s)")
            for hit in report.watermarks {
                audit("    paragraph #\(hit.index), tokens: \(hit.tokens.joined(separator: ", "))")
                audit("      before: \(excerpt(hit.before))")
                audit("      after:  \(excerpt(hit.after))")
            }
        }

        if !report.deduped.isEmpty {
            chaptersWithDupes += 1
            totalDupesRemoved += report.deduped.count
            audit("  Duplicate paragraphs removed: \(report.deduped.count)")
            for dup in report.deduped {
                audit("    at #\(dup.index) (len=\(dup.text.count)): \(excerpt(dup.text, max: 160))")
            }
        }

        if report.titleNormalized != nil {
            chaptersWithTitleChange += 1
        }

        audit("")

        if opts.fixReview {
            let newRef = ChapterRef(
                url: chapter.ref.url,
                title: normalizedTitle,
                number: chapter.ref.number
            )
            let fixedChapter = Chapter(ref: newRef, paragraphs: cleaned)
            do {
                try ChapterMarkdown.write(fixedChapter, to: file)
                filesRewritten += 1
            } catch {
                audit("  ! failed to rewrite \(file.lastPathComponent): \(error)")
            }
        }
    }

    // TOC repair report + persistence.
    var tocWasRewritten = false
    if !tocTitleBackfills.isEmpty || !tocEntriesAdded.isEmpty {
        audit("")
        audit("TOC repair:")
        if !tocTitleBackfills.isEmpty {
            audit("  Title backfill from chapter markdown (TOC had bare \"Chapter N\"):")
            for b in tocTitleBackfills.prefix(10) {
                audit("    ch \(b.number): \"\(b.from)\" → \"\(b.to)\"")
            }
            if tocTitleBackfills.count > 10 {
                audit("    (+ \(tocTitleBackfills.count - 10) more)")
            }
        }
        if !tocEntriesAdded.isEmpty {
            audit("  Chapters present as .md but missing from toc.json:")
            for added in tocEntriesAdded.prefix(10) {
                audit("    ch \(added.number ?? -1): \(added.title)")
            }
            if tocEntriesAdded.count > 10 {
                audit("    (+ \(tocEntriesAdded.count - 10) more)")
            }
        }

        if opts.fixReview {
            let merged = tocByNumber.values
                .sorted { ($0.number ?? Int.max) < ($1.number ?? Int.max) }
            do {
                try JSONEncoder.pretty.encode(merged).write(to: tocFileURL)
                tocWasRewritten = true
                audit("  toc.json rewritten (\(merged.count) entries).")
            } catch {
                audit("  ! failed to rewrite toc.json: \(error)")
            }
        }
        audit("")
    }

    // Summary.
    // Paragraph-count stats
    let avg: Double
    let median: Int
    let minEntry: (count: Int, file: String, title: String)?
    let maxEntry: (count: Int, file: String, title: String)?
    if paragraphStats.isEmpty {
        avg = 0; median = 0; minEntry = nil; maxEntry = nil
    } else {
        let total = paragraphStats.reduce(0) { $0 + $1.count }
        avg = Double(total) / Double(paragraphStats.count)
        let sorted = paragraphStats.sorted { $0.count < $1.count }
        median = sorted[sorted.count / 2].count
        minEntry = sorted.first
        maxEntry = sorted.last
    }

    print("Summary:")
    print("  files scanned:              \(files.count)")
    print("  chapters with duplicates:   \(chaptersWithDupes) (\(totalDupesRemoved) paragraph(s) \(opts.fixReview ? "removed" : "would be removed"))")
    print("  chapters with watermarks:   \(chaptersWithWatermarks) (\(totalWatermarksStripped) token(s) \(opts.fixReview ? "stripped" : "would be stripped"))")
    print("  chapters with promo tails:  \(chaptersWithPromoTail) (\(totalPromoTailsStripped) tail(s) \(opts.fixReview ? "stripped" : "would be stripped"))")
    print("  chapters with title changes: \(chaptersWithTitleChange) (\(opts.fixReview ? "normalized" : "would be normalized"))")
    print("  chapters missing a title:   \(chaptersMissingTitle.count)  (stored as bare \"Chapter N\")")
    if !chaptersMissingTitle.isEmpty {
        let preview = chaptersMissingTitle.prefix(10)
            .map { "\($0.number)" }
            .joined(separator: ", ")
        let suffix = chaptersMissingTitle.count > 10 ? ", …" : ""
        print("    chapter numbers: \(preview)\(suffix)")
    }
    print("  chapters with 0 paragraphs: \(chaptersEmpty)  (require rescrape)")
    print("  chapters with < 5 paras:    \(chaptersSmall)  (manually inspect)")
    print(String(format: "  paragraphs/chapter:         avg %.1f, median %d (across %d non-empty)",
                 avg, median, paragraphStats.count))
    if let mn = minEntry {
        print("    min: \(mn.count) — \(mn.file) (\(mn.title))")
    }
    if let mx = maxEntry {
        print("    max: \(mx.count) — \(mx.file) (\(mx.title))")
    }
    print("  toc entries added:          \(tocEntriesAdded.count) (\(opts.fixReview ? (tocWasRewritten ? "added" : "not written") : "would be added"))")
    print("  toc title backfills:        \(tocTitleBackfills.count) (\(opts.fixReview ? (tocWasRewritten ? "applied" : "not written") : "would be applied"))")
    if opts.fixReview {
        print("  .md files rewritten:        \(filesRewritten)")
    }

    // Persist audit log so the user has a durable record of what changed.
    if !auditLines.isEmpty {
        let logURL = cacheRoot.appendingPathComponent("review.log")
        let header = "Review log — \(ISO8601DateFormatter().string(from: Date()))\n" +
                     "Mode: \(opts.fixReview ? "FIX" : "report-only")\n" +
                     "Scanned \(files.count) file(s) in \(chaptersDir.path)\n\n"
        let body = header + auditLines.joined(separator: "\n")
        try? body.write(to: logURL, atomically: true, encoding: .utf8)
        print("\nFull log: \(logURL.path)")
    }

    // Return non-zero if issues were found and NOT fixed, so scripts can detect.
    let hadIssues = chaptersWithDupes + chaptersWithWatermarks + chaptersWithPromoTail
                  + chaptersWithTitleChange + chaptersEmpty
                  + chaptersMissingTitle.count
                  + tocTitleBackfills.count + tocEntriesAdded.count > 0
    if hadIssues && !opts.fixReview { return 1 }
    return 0
}

// MARK: - add-chapter

@MainActor
func runAddChapter(opts: CLIOptions) async -> Int32 {
    guard let number = opts.chapterNumber else {
        logln("add-chapter requires --number <N>"); return 64
    }
    guard let source = opts.altSourceURL, !source.isEmpty else {
        logln("add-chapter requires --source <url>"); return 64
    }

    guard let id = resolveBook(arg: opts.url, cacheOverride: opts.cacheDir, requireURL: false) else {
        return 1
    }
    let cacheRoot = id.cacheRoot
    let fm = FileManager.default
    let chaptersDir = cacheRoot.appendingPathComponent("chapters")
    do {
        try fm.createDirectory(at: chaptersDir, withIntermediateDirectories: true)
    } catch {
        logln("Could not create cache dir \(cacheRoot.path): \(error)"); return 1
    }

    // Determine the range: [--number, --to] inclusive. Default --to to --number.
    let endNumber = opts.toChapter ?? number
    guard endNumber >= number else {
        logln("--to (\(endNumber)) must be ≥ --number (\(number))"); return 64
    }
    let isRange = endNumber > number

    // Build URL substitution strategy.
    let urlBuilder: (Int) -> String?
    if source.contains("{number}") {
        urlBuilder = { n in source.replacingOccurrences(of: "{number}", with: "\(n)") }
    } else if let trailingDigitsRange = source.range(
        of: #"\d+/?$"#, options: .regularExpression
    ) {
        urlBuilder = { n in
            var copy = source
            let newDigits = source[trailingDigitsRange].hasSuffix("/") ? "\(n)/" : "\(n)"
            copy.replaceSubrange(trailingDigitsRange, with: newDigits)
            return copy
        }
    } else if !isRange {
        // Single-chapter mode doesn't need URL templating.
        urlBuilder = { _ in source }
    } else {
        logln("Range mode requires either '{number}' placeholder in --source")
        logln("or a trailing chapter number in the URL. Got: \(source)")
        return 64
    }

    let renderer = WebRenderer()
    let scraper = NovelLiveScraper(renderer: renderer, settlingDelay: 0.8)
    let tocURL = cacheRoot.appendingPathComponent("toc.json")

    // Load existing TOC (or start empty).
    var toc: [ChapterRef] = []
    if fm.fileExists(atPath: tocURL.path),
       let data = try? Data(contentsOf: tocURL),
       let decoded = try? JSONDecoder().decode([ChapterRef].self, from: data) {
        toc = decoded
    }

    var successCount = 0
    var failureCount = 0

    for n in number...endNumber {
        // Build this iteration's title.
        let userTitle = opts.chapterTitle.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let rawTitle: String
        if isRange {
            // In range mode, a single --title would be the same for every
            // chapter — not useful. Prefer the generic "Chapter N" default
            // which cleanChapterTitle preserves.
            rawTitle = "Chapter \(n)"
        } else if userTitle.isEmpty {
            rawTitle = "Chapter \(n)"
        } else if userTitle.lowercased().hasPrefix("chapter") {
            rawTitle = userTitle
        } else {
            rawTitle = "Chapter \(n): \(userTitle)"
        }
        let title = NovelLiveScraper.cleanChapterTitle(rawTitle)

        guard let iterSource = urlBuilder(n) else {
            logln("[\(n)] couldn't build URL from template; skipping")
            failureCount += 1
            continue
        }

        logln("")
        logln("[ch \(n)/\(endNumber)] fetching \(iterSource)")

        do {
            let result = try await scraper.fetchChapterFromAlternateSource(
                url: iterSource,
                number: n,
                title: title,
                overrideSelector: opts.altSelector
            )
            for attempt in result.attempts {
                logln("  - \(attempt.strategy): \(attempt.paragraphs) paragraph(s)")
            }
            logln("  winner: \(result.strategy) → \(result.chapter.paragraphs.count) paragraph(s)")
            if !result.extractedTitle.isEmpty {
                logln("  title from page: \(result.chapter.ref.title)")
            } else {
                logln("  title from page: (not found; using supplied/default)")
            }

            guard !result.chapter.paragraphs.isEmpty else {
                logln("  ! no content; skipping save. Try --selector <css>.")
                failureCount += 1
                continue
            }

            try saveChapterMarkdown(cacheRoot: cacheRoot, result.chapter)
            // Keep TOC in sync.
            toc.removeAll { $0.number == n }
            toc.append(result.chapter.ref)
            successCount += 1
            logln("  saved \(chapterMarkdownURL(cacheRoot: cacheRoot, result.chapter.ref).lastPathComponent)")
        } catch {
            logln("  ! fetch error: \(error)")
            failureCount += 1
        }

        // Small delay between range iterations so we don't hammer the alt site.
        if isRange && n < endNumber {
            try? await Task.sleep(for: .milliseconds(opts.delayMs))
        }
    }

    // Persist TOC updates.
    toc.sort { ($0.number ?? Int.max) < ($1.number ?? Int.max) }
    do {
        try JSONEncoder.pretty.encode(toc).write(to: tocURL)
        logln("")
        logln("toc.json updated (\(toc.count) entries).")
    } catch {
        logln("Warning: couldn't update toc.json: \(error)")
    }
    logln("Done: \(successCount) saved, \(failureCount) failed.")
    return failureCount == 0 ? 0 : 1
}

/// Returns the full URL for a cached chapter in markdown form (4-digit).
func chapterMarkdownURL(cacheRoot: URL, _ ref: ChapterRef) -> URL {
    cacheRoot
        .appendingPathComponent("chapters")
        .appendingPathComponent(ChapterMarkdown.filename(for: ref))
}

/// All possible cache file paths for a given ref, in preferred order:
/// current (4-digit .md), legacy 5-digit .md, legacy 5-digit .json,
/// legacy 4-digit .json.
private func chapterCacheURLs(cacheRoot: URL, _ ref: ChapterRef) -> [URL] {
    let dir = cacheRoot.appendingPathComponent("chapters")
    return [
        dir.appendingPathComponent(ChapterMarkdown.filename(for: ref)),
        dir.appendingPathComponent(ChapterMarkdown.legacy5DigitMarkdownFilename(for: ref)),
        dir.appendingPathComponent(ChapterMarkdown.legacyJSONFilename(for: ref)),
        dir.appendingPathComponent(ChapterMarkdown.legacyJSON4DigitFilename(for: ref))
    ]
}

/// True if we already have chapter content for `ref` under any supported name.
func chapterIsCached(cacheRoot: URL, _ ref: ChapterRef) -> Bool {
    let fm = FileManager.default
    return chapterCacheURLs(cacheRoot: cacheRoot, ref)
        .contains { fm.fileExists(atPath: $0.path) }
}

/// Load a cached chapter — tries 4-digit markdown first, then the 5-digit
/// legacy markdown, then both JSON variants. Returns nil if nothing works.
func loadCachedChapter(cacheRoot: URL, _ ref: ChapterRef) -> Chapter? {
    let fm = FileManager.default
    let urls = chapterCacheURLs(cacheRoot: cacheRoot, ref)
    // Try markdown first (first two entries).
    for url in urls.prefix(2) where fm.fileExists(atPath: url.path) {
        if let ch = try? ChapterMarkdown.read(from: url) { return ch }
    }
    // Fall back to JSON.
    for url in urls.dropFirst(2) where fm.fileExists(atPath: url.path) {
        if let data = try? Data(contentsOf: url),
           let ch = try? JSONDecoder().decode(Chapter.self, from: data) {
            return ch
        }
    }
    return nil
}

/// Persist a chapter to the cache in 4-digit markdown form. If a legacy
/// 5-digit markdown or JSON file exists for the same chapter, remove it so
/// the cache naturally migrates to the shorter name.
func saveChapterMarkdown(cacheRoot: URL, _ chapter: Chapter) throws {
    let dest = chapterMarkdownURL(cacheRoot: cacheRoot, chapter.ref)
    try ChapterMarkdown.write(chapter, to: dest)
    let fm = FileManager.default
    for stale in chapterCacheURLs(cacheRoot: cacheRoot, chapter.ref).dropFirst()
        where fm.fileExists(atPath: stale.path) && stale.path != dest.path {
        try? fm.removeItem(at: stale)
    }
}

/// Checks the first few bytes for an HTML opening sequence — used to detect
/// when a Cloudflare interstitial got saved to disk under the guise of being
/// an image.
func looksLikeHTML(_ data: Data) -> Bool {
    let head = data.prefix(32)
    guard let s = String(data: head, encoding: .utf8)?.lowercased() else { return false }
    return s.contains("<!doctype html") || s.contains("<html")
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

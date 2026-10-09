//
//  EPUBWriter.swift
//  WebBound
//
//  Assembles an EPUB 3 package from BookMetadata + ordered Chapters.
//

import Foundation

enum EPUBWriterError: Error, CustomStringConvertible {
    case zipFailed(String)
    case noChapters

    var description: String {
        switch self {
        case .zipFailed(let s): return "zip failed: \(s)"
        case .noChapters: return "No chapters to write."
        }
    }
}

struct EPUBWriter {
    let metadata: BookMetadata
    /// Must be pre-sorted in reading order.
    let chapters: [Chapter]
    let outputPath: URL
    /// Optional JPEG/PNG bytes for the cover image.
    let coverData: Data?
    let coverMediaType: String?   // e.g. "image/jpeg"
    /// Optional progress reporter. Called as the writer advances through its
    /// phases: "chapters", "nav", "opf", "zip:mimetype", "zip:deflate",
    /// "done". `current` and `total` are phase-local counters; when total is
    /// 1 the phase has no meaningful progress fraction.
    var progress: ((_ phase: String, _ current: Int, _ total: Int) -> Void)? = nil

    func write() throws {
        guard !chapters.isEmpty else { throw EPUBWriterError.noChapters }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("webbound-epub-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let metaInf = tempDir.appendingPathComponent("META-INF")
        let oebps = tempDir.appendingPathComponent("OEBPS")
        let chapsDir = oebps.appendingPathComponent("chapters")
        let stylesDir = oebps.appendingPathComponent("styles")
        try fm.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try fm.createDirectory(at: oebps, withIntermediateDirectories: true)
        try fm.createDirectory(at: chapsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: stylesDir, withIntermediateDirectories: true)

        // mimetype — must be first entry and stored uncompressed.
        try "application/epub+zip".write(
            to: tempDir.appendingPathComponent("mimetype"),
            atomically: true,
            encoding: .utf8
        )

        // META-INF/container.xml
        try container.write(
            to: metaInf.appendingPathComponent("container.xml"),
            atomically: true,
            encoding: .utf8
        )

        // styles/style.css
        try css.write(
            to: stylesDir.appendingPathComponent("style.css"),
            atomically: true,
            encoding: .utf8
        )

        // Build manifest + spine while writing chapter files.
        var manifestItems: [String] = [
            #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
            #"<item id="css" href="styles/style.css" media-type="text/css"/>"#
        ]
        var spineItems: [String] = []

        // Cover (optional) — must appear before chapters in the spine.
        var coverMeta = ""
        if let coverData, !coverData.isEmpty, let coverMediaType {
            let ext = coverMediaType.hasSuffix("png") ? "png" : "jpg"
            let coverImgHref = "cover.\(ext)"
            try coverData.write(to: oebps.appendingPathComponent(coverImgHref))
            manifestItems.insert(
                #"<item id="cover-img" href="\#(coverImgHref)" media-type="\#(coverMediaType)" properties="cover-image"/>"#,
                at: 0
            )
            let coverXHTML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head>
              <title>Cover</title>
              <link rel="stylesheet" type="text/css" href="styles/style.css"/>
            </head>
            <body class="cover">
              <img src="\(coverImgHref)" alt="Cover"/>
            </body>
            </html>
            """
            try coverXHTML.write(
                to: oebps.appendingPathComponent("cover.xhtml"),
                atomically: true,
                encoding: .utf8
            )
            manifestItems.insert(
                #"<item id="cover-page" href="cover.xhtml" media-type="application/xhtml+xml"/>"#,
                at: 1
            )
            spineItems.append(#"<itemref idref="cover-page"/>"#)
            coverMeta = #"<meta name="cover" content="cover-img"/>"#
        }

        // Chapter XHTML
        var navEntries: [String] = []
        let totalChapters = chapters.count
        for (idx, ch) in chapters.enumerated() {
            let id = String(format: "ch%04d", idx + 1)
            let href = "chapters/\(id).xhtml"
            let xhtml = chapterXHTML(ch)
            try xhtml.write(
                to: oebps.appendingPathComponent(href),
                atomically: true,
                encoding: .utf8
            )
            manifestItems.append(
                #"<item id="\#(id)" href="\#(href)" media-type="application/xhtml+xml"/>"#
            )
            spineItems.append(#"<itemref idref="\#(id)"/>"#)
            navEntries.append(
                #"<li><a href="\#(href)">\#(escapeXML(ch.ref.title))</a></li>"#
            )
            progress?("chapters", idx + 1, totalChapters)
        }

        // nav.xhtml (EPUB 3)
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
          <title>Table of Contents</title>
          <link rel="stylesheet" type="text/css" href="styles/style.css"/>
        </head>
        <body>
          <nav epub:type="toc" id="toc">
            <h1>Table of Contents</h1>
            <ol>
        \(navEntries.map { "      " + $0 }.joined(separator: "\n"))
            </ol>
          </nav>
        </body>
        </html>
        """
        try nav.write(
            to: oebps.appendingPathComponent("nav.xhtml"),
            atomically: true,
            encoding: .utf8
        )
        progress?("nav", 1, 1)

        // content.opf
        let opf = buildOPF(manifestItems: manifestItems, spineItems: spineItems, coverMeta: coverMeta)
        try opf.write(
            to: oebps.appendingPathComponent("content.opf"),
            atomically: true,
            encoding: .utf8
        )
        progress?("opf", 1, 1)

        // Zip to a temp path alongside the destination, then atomically
        // move into place. This guarantees we never leave the destination
        // in a half-written state and never delete the user's existing EPUB
        // before we've successfully built its replacement.
        let tempOutput = outputPath.appendingPathExtension("partial-\(UUID().uuidString)")
        progress?("zip:mimetype", 0, 1)
        try zipRun(args: ["-X0", tempOutput.path, "mimetype"], cwd: tempDir)
        progress?("zip:mimetype", 1, 1)

        // Rough file count so the deflate progress bar is meaningful.
        // chapters + nav.xhtml + content.opf + container.xml + style.css,
        // plus 1 if we wrote a cover image + cover.xhtml.
        let estimatedFiles = chapters.count + 4 + (coverData != nil ? 2 : 0)
        progress?("zip:deflate", 0, estimatedFiles)
        try zipRunStreaming(
            args: ["-Xr6D", tempOutput.path, "META-INF", "OEBPS"],
            cwd: tempDir,
            total: estimatedFiles
        )
        progress?("zip:deflate", estimatedFiles, estimatedFiles)

        if fm.fileExists(atPath: outputPath.path) {
            _ = try fm.replaceItemAt(outputPath, withItemAt: tempOutput)
        } else {
            try fm.moveItem(at: tempOutput, to: outputPath)
        }
        progress?("done", 1, 1)
    }

    // MARK: - Pieces

    private var container: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }

    private var css: String {
        """
        @namespace epub "http://www.idpf.org/2007/ops";
        /* Let the reader (iBooks etc.) own page padding — it already
           reserves safe-area insets for overlays and buttons. Stacking
           our own body margin on top of that wastes space. */
        body { font-family: Georgia, serif; line-height: 1.45; margin: 0; padding: 0; }
        body.cover { margin: 0; padding: 0; text-align: center; }
        body.cover img { max-width: 100%; max-height: 100%; }
        .chapter-header { text-align: center; margin: 0.8em 0 0.8em; }
        .chapter-header .chapter-number {
            font-size: 1em;
            font-weight: normal;
            letter-spacing: 0.1em;
            text-transform: uppercase;
            margin: 0 0 0.3em;
            color: #555;
        }
        .chapter-header .chapter-title {
            font-size: 1.4em;
            font-weight: bold;
            margin: 0;
            line-height: 1.2;
        }
        h1 { text-align: center; margin: 0.6em 0 0.6em; font-size: 1.3em; }
        p { text-indent: 1.5em; margin: 0 0 0.25em; }
        nav#toc ol { list-style: none; padding-left: 0; }
        nav#toc li { margin: 0.25em 0; }
        """
    }

    private func chapterXHTML(_ ch: Chapter) -> String {
        // Keep <title> (page title in reader metadata) as the full single
        // line. For the visible heading, split at the first ": " so e-readers
        // show "Chapter N" and the subtitle on separate lines without
        // depending on word-wrap.
        let fullTitle = escapeXML(ch.ref.title)
        let header: String
        if let colonRange = ch.ref.title.range(of: ": "),
           colonRange.lowerBound > ch.ref.title.startIndex {
            let numPart = escapeXML(String(ch.ref.title[..<colonRange.lowerBound]))
            let subtitle = escapeXML(String(ch.ref.title[colonRange.upperBound...]))
            header = """
              <header class="chapter-header">
                <p class="chapter-number">\(numPart)</p>
                <h1 class="chapter-title">\(subtitle)</h1>
              </header>
            """
        } else {
            // No subtitle — just render "Chapter N" as the heading.
            header = """
              <header class="chapter-header">
                <h1 class="chapter-number">\(fullTitle)</h1>
              </header>
            """
        }
        let body = ch.paragraphs
            .map { "    <p>\(escapeXML($0))</p>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
          <title>\(fullTitle)</title>
          <link rel="stylesheet" type="text/css" href="../styles/style.css"/>
        </head>
        <body>
        \(header)
        \(body)
        </body>
        </html>
        """
    }

    private func buildOPF(manifestItems: [String], spineItems: [String], coverMeta: String) -> String {
        let bookID = "urn:webbound:\(metadata.slug)"
        let title = escapeXML(metadata.title)
        let author = escapeXML(metadata.author ?? "Unknown")
        let desc = escapeXML(metadata.description ?? "")
        let indent = "    "
        let manifest = manifestItems.map { indent + $0 }.joined(separator: "\n")
        let spine = spineItems.map { indent + $0 }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" xml:lang="en">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="BookId">\(bookID)</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:creator>\(author)</dc:creator>
            <dc:language>en</dc:language>
            <dc:description>\(desc)</dc:description>
            <meta property="dcterms:modified">\(iso8601Now())</meta>
            \(coverMeta)
          </metadata>
          <manifest>
        \(manifest)
          </manifest>
          <spine>
        \(spine)
          </spine>
        </package>
        """
    }

    // MARK: - Utilities

    private func escapeXML(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&":  r += "&amp;"
            case "<":  r += "&lt;"
            case ">":  r += "&gt;"
            case "\"": r += "&quot;"
            case "'":  r += "&apos;"
            default:
                // Strip ASCII control chars (except tab/newline/CR) which are
                // not legal in XML 1.0 and would corrupt the EPUB.
                let scalar = ch.unicodeScalars.first!.value
                if scalar < 0x20 && scalar != 0x09 && scalar != 0x0A && scalar != 0x0D {
                    continue
                }
                r.append(ch)
            }
        }
        return r
    }

    private func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    /// Variant of `zipRun` that captures stdout line-by-line, reports a tick
    /// of progress for each "adding:" line (one per file zip visits), and
    /// surfaces the final stderr tail if it fails. Blocks until exit.
    private func zipRunStreaming(args: [String], cwd: URL, total: Int) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = args
        p.currentDirectoryURL = cwd

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        var buffer = Data()
        var count = 0
        let outHandle = outPipe.fileHandleForReading
        let reporter = progress
        outHandle.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            buffer.append(d)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                if let s = String(data: line, encoding: .utf8), s.hasPrefix("  adding:") {
                    count += 1
                    reporter?("zip:deflate", min(count, total), total)
                }
            }
        }

        try p.run()
        p.waitUntilExit()
        outHandle.readabilityHandler = nil
        _ = outHandle.availableData  // drain

        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw EPUBWriterError.zipFailed("exit \(p.terminationStatus): \(err)")
        }
    }

    private func zipRun(args: [String], cwd: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = args
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw EPUBWriterError.zipFailed("exit \(p.terminationStatus): \(out)")
        }
    }
}

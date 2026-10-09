//
//  Models.swift
//  WebBound
//

import Foundation

struct BookMetadata: Codable {
    var title: String
    var author: String?
    var coverImageURL: String?
    var description: String?
    var genres: [String]
    var status: String?
    var sourceURL: String
    var slug: String
}

struct ChapterRef: Codable, Hashable, Equatable {
    var url: String
    var title: String       // e.g. "Chapter 1: No Second Chances"
    var number: Int?        // parsed from title; nil if unparseable
}

struct Chapter: Codable {
    var ref: ChapterRef
    /// Clean text paragraphs. Ad containers, scripts, and site boilerplate
    /// (e.g. "Visit and read more novel to help us update chapter quickly...")
    /// are already stripped at extraction time.
    var paragraphs: [String]
}

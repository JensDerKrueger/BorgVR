import Foundation

/// Bounded metadata search shared by automation clients; never reads voxel payloads.
@MainActor
final class BorgVRDatasetSearch {
  private struct Page {
    let snapshot: UUID
    let query: String
    let hits: [[String: Any]]
    let catalogCount: Int
    let unavailable: Int
    let offset: Int
    let expires: Date
  }
  private var pages: [String: Page] = [:]

  func search(query: String, limit: Int, cursor: String?,
              load: () async throws -> [BorgVRMCPDatasetCatalogEntry]) async throws -> [String: Any] {
    guard query.unicodeScalars.count <= 256, query.utf8.count <= 1024,
          cursor == nil || cursor!.utf8.count <= 128, (1...20).contains(limit) else {
      throw BorgVRMCPCommandError.invalidArgument("Use a query of at most 256 characters and a limit of 1...20.")
    }
    pages = pages.filter { $0.value.expires > Date() }
    let page: Page
    if let cursor {
      guard let stored = pages[cursor], stored.query == query else {
        throw BorgVRMCPCommandError.invalidArgument("Search cursor expired or belongs to another query. Start a new search.")
      }
      page = stored
    } else {
      let terms = query.split(whereSeparator: \.isWhitespace).map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
      guard terms.count <= 12 else { throw BorgVRMCPCommandError.invalidArgument("Use at most twelve search terms.") }
      let entries = try await load()
      try Task.checkCancellation()
      guard entries.count <= BorgVRMCPCatalogBudget.maximumEntries else { throw BorgVRMCPCatalogError.tooManyEntries }
      var hits: [(score: Int, value: [String: Any])] = []
      for entry in entries {
        try Task.checkCancellation()
        guard !entry.id.isEmpty, entry.id.utf8.count <= 128 else { continue }
        let metadata = entry.metadata
        var fields = [("description", Self.safeText(entry.description, limit: 2048))]
        if let metadata {
          fields += [("longDescription", Self.safeText(metadata.longDescription, limit: 8192)),
                     ("meta", Self.safeText(metadata.meta, limit: 16384))]
          fields += metadata.provenance.prefix(64).map { ("provenance", Self.safeText($0.text, limit: 1024)) }
        }
        let normalized = fields.map { $0.1.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        guard terms.allSatisfy({ term in normalized.contains { $0.contains(term) } }) else { continue }
        var evidence: [[String: String]] = []
        for (index, field) in fields.enumerated() where !field.1.isEmpty {
          guard terms.isEmpty || terms.contains(where: { normalized[index].contains($0) }) else { continue }
          let range = terms.compactMap { field.1.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.first
          let start = range.map { field.1.index($0.lowerBound, offsetBy: -80, limitedBy: field.1.startIndex) ?? field.1.startIndex } ?? field.1.startIndex
          evidence.append(["field": field.0, "excerpt": String(String.UnicodeScalarView(field.1[start...].unicodeScalars.prefix(320)))])
          if evidence.count == 3 { break }
        }
        var hit: [String: Any] = ["id": entry.id, "description": String(fields[0].1.prefix(512)),
          "evidence": evidence, "metadataAvailable": metadata != nil,
          "sourceKinds": Array(Set(entry.sources.map(\.kind))).sorted()]
        if let metadata {
          hit["dimensions"] = metadata.dimensions
          hit["channelInterpretation"] = metadata.channelInterpretation
        }
        hits.append((terms.filter { normalized[0].contains($0) }.count, hit))
      }
      hits.sort {
        if $0.score != $1.score { return $0.score > $1.score }
        let a = $0.value["description"] as? String ?? "", b = $1.value["description"] as? String ?? ""
        return a == b ? ($0.value["id"] as! String) < ($1.value["id"] as! String) : a < b
      }
      // Cursors retain at most two bounded result sets, not full metadata or credentials.
      if Set(pages.values.map(\.snapshot)).count >= 2, let oldest = pages.values.min(by: { $0.expires < $1.expires }) {
        pages = pages.filter { $0.value.snapshot != oldest.snapshot }
      }
      page = Page(snapshot: UUID(), query: query, hits: hits.map(\.value), catalogCount: entries.count,
                  unavailable: entries.filter { $0.metadata == nil }.count, offset: 0,
                  expires: Date().addingTimeInterval(300))
    }
    let end = min(page.offset + limit, page.hits.count)
    var result: [String: Any] = ["query": query, "matches": Array(page.hits[page.offset..<end]),
      "totalMatches": page.hits.count, "catalogCount": page.catalogCount,
      "metadataUnavailableCount": page.unavailable, "hasMore": end < page.hits.count,
      "coverage": "available_catalog_metadata_only",
      "note": "Metadata matches are evidence about labels, not verified image contents. Configured sources may be unreachable; source completeness is not verified. Search uses all query terms, ignoring case and accents; try translated keywords or synonyms if needed."]
    if end < page.hits.count {
      if pages.count >= 512 { pages.removeAll() }
      let token = UUID().uuidString
      pages[token] = Page(snapshot: page.snapshot, query: query, hits: page.hits, catalogCount: page.catalogCount,
                          unavailable: page.unavailable, offset: end, expires: page.expires)
      result["nextCursor"] = token
    }
    return result
  }

  private static func safeText(_ text: String, limit: Int) -> String {
    var value = String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    for pattern in [#"(?i)\b(?:https?|file|s3)://\S+"#,
                    #"(?:^|\s)(?:/|~/|[A-Za-z]:\\)\S+"#,
                    #"(?i)\b(?:token|password|secret|api[_-]?key)\s*[:=]\s*\S+"#] {
      if let regex = try? NSRegularExpression(pattern: pattern) {
        value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: " [redacted]")
      }
    }
    return value
  }
}

#if os(macOS)
import Foundation

enum BorgVRAutoImportMode: String, CaseIterable {
  case automatic, guided
}

enum BorgVRAutoImportManifest {
  static let filename = "import.json"
  static let maximumByteCount = 1024 * 1024
  static let maximumEntryCount = 1024
  static let example = """
  [
    {
      "source": "scan.nrrd",
      "destination": "head.data",
      "description": "Head scan",
      "sourceDate": "2026-11-01T10:30:00Z",
      "sourceNote": "Downloaded from https://example.org/scan",
      "sizeMeters": [0.2, 0.15, 0.1]
    },
    {
      "source": "dicom-series"
    }
  ]
  """

  struct Entry: Decodable {
    let source: String
    let destination: String?
    let description: String?
    let sizeMeters: [Double]?
    let sourceDate: String?
    let sourceNote: String?

    init(source: String, destination: String? = nil, description: String? = nil, sizeMeters: [Double]? = nil,
         sourceDate: String? = nil, sourceNote: String? = nil) {
      self.source = source
      self.destination = destination
      self.description = description
      self.sizeMeters = sizeMeters
      self.sourceDate = sourceDate
      self.sourceNote = sourceNote
    }

    var physicalSize: Vec3<Float>? {
      sizeMeters.map { Vec3(x: Float($0[0]), y: Float($0[1]), z: Float($0[2])) }
    }

    var provenance: [BORGVRProvenanceEntry] {
      guard let sourceDate, let sourceNote, let date = BORGVRProvenanceEntry.parseDate(sourceDate) else { return [] }
      return [BORGVRProvenanceEntry(sourceNote, date: date)]
    }
  }

  enum ManifestError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
      switch self { case .invalid(let detail): "Invalid import.json: \(detail)" }
    }
  }

  static func isBasename(_ name: String) -> Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != "." && name != ".." &&
      name.utf8.count <= 255 && !name.contains("/") && !name.contains("\\") &&
      name.rangeOfCharacter(from: .controlCharacters) == nil
  }

  static func isReserved(_ name: String) -> Bool {
    ["log.txt", filename].contains(name.lowercased())
  }

  static func decode(_ data: Data, inputNames: Set<String>) throws -> [Entry] {
    guard data.count <= maximumByteCount else { throw ManifestError.invalid("File is too large.") }
    let entries = try JSONDecoder().decode([Entry].self, from: data)
    guard entries.count <= maximumEntryCount else { throw ManifestError.invalid("Too many entries.") }
    var sources: Set<String> = []
    for entry in entries {
      guard isBasename(entry.source), !isReserved(entry.source), inputNames.contains(entry.source),
            sources.insert(entry.source).inserted else {
        throw ManifestError.invalid("Each source must name a distinct direct entry in the input directory.")
      }
      if let destination = entry.destination {
        guard isBasename(destination) else { throw ManifestError.invalid("Destination must be a filename.") }
        let ext = URL(fileURLWithPath: destination).pathExtension
        guard isBasename(destination), !isReserved(destination),
              ext.isEmpty || ext.lowercased() == "data",
              (ext.isEmpty ? destination.utf8.count + 5 : destination.utf8.count) <= 255 else {
          throw ManifestError.invalid("Destination must be a .data filename without a directory path.")
        }
      }
      if let description = entry.description,
         description.utf8.count > 16 * 1024 || description.rangeOfCharacter(from: .controlCharacters) != nil {
        throw ManifestError.invalid("Description is too long or contains control characters.")
      }
      if let size = entry.sizeMeters {
        guard size.count == 3, size.allSatisfy({ $0.isFinite && Float($0).isFinite && Float($0) > 0 }) else {
          throw ManifestError.invalid("sizeMeters must contain three positive finite lengths in meters.")
        }
      }
      if entry.sourceDate != nil || entry.sourceNote != nil {
        guard let date = entry.sourceDate, date.utf8.count <= 64, BORGVRProvenanceEntry.parseDate(date) != nil,
          let note = entry.sourceNote, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          note.utf8.count <= 16 * 1024, note.rangeOfCharacter(from: .controlCharacters) == nil else {
          throw ManifestError.invalid("sourceDate and sourceNote must be supplied together, with an ISO-8601 date/time and a non-empty text.")
        }
      }
    }
    return entries
  }
}
#endif

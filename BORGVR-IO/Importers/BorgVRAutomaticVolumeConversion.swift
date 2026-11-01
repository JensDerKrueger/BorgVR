#if os(macOS)
import Foundation

enum BorgVRAutomaticVolumeConversion {
  /// Probes readers rather than relying on an extension. Returns original inputs for cleanup.
  static func convert(
    source: URL, destination: URL, settings: BorgVRVolumeConversionSettings,
    logger: LoggerBase?, cancellationToken: BorgVRVolumeConversionCancellationToken,
    description: String? = nil, physicalSizeMeters: Vec3<Float>? = nil,
    provenance: [BORGVRProvenanceEntry] = [], toolIdentification: String = BORGVRToolIdentification.current,
    validateSources: @escaping ([URL]) throws -> Void
  ) throws -> [URL] {
    let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    let cancellationCheck = { try cancellationToken.checkCancellation() }
    let request: (BorgVRVolumeConversionSource) -> BorgVRVolumeConversionRequest = {
      BorgVRVolumeConversionRequest(source: $0, destinationURL: destination,
        datasetDescription: description ?? source.deletingPathExtension().lastPathComponent,
        metaDescription: "", settings: settings, physicalSizeMeters: physicalSizeMeters,
        provenance: provenance + [BORGVRProvenanceEntry("Auto-import source: \(source.absoluteString)")],
        toolIdentification: toolIdentification)
    }
    var readers: [(String, () throws -> any VolumeFileParser)] = [
      ("Zarr", { try ZarrParser(filename: source.path, cancellationCheck: cancellationCheck) })
    ]
    if !isDirectory {
      readers += [
        ("QVIS", { try QVISParser(filename: source.path) }),
        ("NRRD", { try NRRDParser(filename: source.path, validateSource: { try validateSources([source, $0]) }) }),
        ("PVM", { try PVMParser(filename: source.path) }),
        ("IV3Dm", { try I3MParser(filename: source.path) })
      ]
      let preferred: String = switch source.pathExtension.lowercased() {
        case "dat": "QVIS"
        case "nrrd", "nhdr": "NRRD"
        case "pvm": "PVM"
        case "i3m", "zip": "IV3Dm"
        default: "Zarr"
      }
      readers.sort { $0.0 == preferred && $1.0 != preferred }
    }
    for (name, read) in readers {
      try cancellationToken.checkCancellation()
      let parser: any VolumeFileParser
      do { parser = try read() }
      catch is CancellationError { throw CancellationError() }
      catch { logger?.dev("Auto-import: \(name) reader did not accept \(source.lastPathComponent)."); continue }
      defer {
        if parser.dataIsTempCopy { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
      }
      let sources = [source] + parser.sourceFiles
      try validateSources(sources)
      logger?.info("Auto-import: reading \(source.lastPathComponent) as \(name).")
      try BorgVRVolumeConversionService.convert(request(.raw(BorgVRRawVolumeSource(
        url: URL(fileURLWithPath: parser.absoluteFilename), offset: parser.offset,
        size: parser.size, bytesPerComponent: parser.bytesPerComponent,
        componentCount: parser.components, voxelSpacing: parser.voxelSpacing
      ))), logger: logger, cancellationToken: cancellationToken)
      return sources
    }
    if isDirectory {
      try validateSources([source])
      logger?.info("Auto-import: trying \(source.lastPathComponent) as DICOM.")
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      let sources = try BorgVRVolumeConversionService.convertDICOMDirectory(source,
        request: request(.dicomDirectory(source)), stagedURL: destination,
        logger: logger, cancellationToken: cancellationToken)
      try validateSources(sources)
      return sources
    }
    throw CocoaError(.fileReadCorruptFile)
  }
}
#endif

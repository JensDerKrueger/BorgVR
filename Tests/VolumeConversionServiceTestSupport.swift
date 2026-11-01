import Foundation

enum DicomParser {
  static var decodedVolumes: [URL: DicomVolume] = [:]
  struct DicomOrientation: Equatable, Sendable {
    let xAxis: Vec3<Float>
    let yAxis: Vec3<Float>
    let zAxis: Vec3<Float>
  }

  struct DicomVolume {
    var sourceFiles: [URL] = []
    let voxelData: Data
    let width: Int
    let height: Int
    let depth: Int
    let bytesPerVoxel: Int
    let voxelSpacing: Vec3<Float>
    let orientation: DicomOrientation?
    let origin: Vec3<Float>?
    let frameOfReferenceUID: String?
    let isSigned: Bool
    let pixelPaddingValue: Int32?
    let modality: String?
    let patientName: String?
    let seriesDate: String?
    var provenance: [DicomProvenanceMetadata.Event] = []
  }

  enum Error: Swift.Error {
    case unavailableInUnitTest
  }

  static func decodeVolume(
    from urls: [URL],
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> DicomVolume {
    if let volume = urls.compactMap({ decodedVolumes[$0.resolvingSymlinksInPath().standardizedFileURL] }).first { return volume }
    throw Error.unavailableInUnitTest
  }
}

import Foundation

protocol VolumeFileParser {
  var absoluteFilename: String { get }
  var size: Vec3<Int> { get }
  var voxelSpacing: Vec3<Float> { get }
  var bytesPerComponent: Int { get }
  var components: Int { get }
  var offset: Int { get }
  var dataIsTempCopy: Bool { get }
}

enum VolumeFileParserFactory {
  enum Error: Swift.Error {
    case unavailableInUnitTest
  }

  static func parser(for filename: String) throws -> VolumeFileParser {
    throw Error.unavailableInUnitTest
  }
}

enum DicomParser {
  struct DicomVolume {
    let voxelData: Data
    let width: Int
    let height: Int
    let depth: Int
    let bytesPerVoxel: Int
    let voxelSpacing: Vec3<Float>
    let modality: String?
    let patientName: String?
    let seriesDate: String?
  }

  enum Error: Swift.Error {
    case unavailableInUnitTest
  }

  static func decodeVolume(
    from urls: [URL],
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> DicomVolume {
    throw Error.unavailableInUnitTest
  }
}

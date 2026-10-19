import Foundation

protocol LoggerBase {
  func progress(_ message: String, _ progress: Double)
}

final class BorgVRVolumeConversionCancellationToken {
  func checkCancellation() throws {}
}

private enum DICOMCodecStubError: Error {
  case unavailable
}

final class Jpeg2000Reader {
  struct Image {
    let width: Int
    let height: Int
    let pixels: [UInt8]
  }

  init(referenceStoredBitsForNormalization: Int? = nil) {}

  func read(data: Data) throws -> Image {
    throw DICOMCodecStubError.unavailable
  }
}

struct JpegLosslessImage {
  let pixels: [UInt8]
}

final class JpegLosslessReader {
  init() {}

  func read(data: Data) throws -> JpegLosslessImage {
    throw DICOMCodecStubError.unavailable
  }
}

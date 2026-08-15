import Foundation
import simd

struct TransferEditing {
  var red: Bool = false
  var green: Bool = false
  var blue: Bool = false
  var opacity: Bool = true
}

final class RenderingParameters: ObservableObject {
  private static let streamMagic: UInt32 = 0x5250_494F // "RPIO"
  private static let streamVersion: UInt16 = 1
  private static let sharePlayMagic: UInt32 = 0x4256_5350 // "BVSP"
  private static let sharePlayVersion: UInt16 = 1

  private static let defaultOrientation =
    simd_quatf(angle: 0.25, axis: SIMD3<Float>(1, 0, 0)) *
    simd_quatf(angle: -0.45, axis: SIMD3<Float>(0, 1, 0))

  @Published var orientation = RenderingParameters.defaultOrientation
  @Published var scale: Float = 1.0
  @Published var pan = SIMD2<Float>(0, 0)
  @Published var clippingTranslation = SIMD3<Float>(0, 0, 0)
  @Published var clipMin = SIMD3<Float>(0, 0, 0)
  @Published var clipMax = SIMD3<Float>(1, 1, 1)
  @Published var transferFunction = TransferFunction1D()
  @Published var transferEditing = TransferEditing()
  @Published var normIsoValue: Float = 0.1
  @Published var renderMode: RenderMode = .transferFunction1D
  @Published var brickVis = false

  @Published var minValue: Int = 0
  @Published var maxValue: Int = 1
  @Published var rangeMax: Int = 1

  var isoValue: Float {
    normIsoValue * Float(maxValue) / Float(max(rangeMax, 1))
  }

  func updateRanges(minValue: Int, maxValue: Int, rangeMax: Int) {
    self.minValue = minValue
    self.maxValue = maxValue
    self.rangeMax = rangeMax
    transferFunction.updateRanges(minValue: minValue, maxValue: maxValue, rangeMax: rangeMax)
  }

  func reset() {
    orientation = RenderingParameters.defaultOrientation
    scale = 1.0
    pan = SIMD2<Float>(0, 0)
    clippingTranslation = SIMD3<Float>(0, 0, 0)
    clipMin = SIMD3<Float>(0, 0, 0)
    clipMax = SIMD3<Float>(1, 1, 1)
    transferFunction.slicingPreset()
    transferEditing = TransferEditing()
    normIsoValue = 0.1
    renderMode = .transferFunction1D
    brickVis = false
  }

  enum UpdateKind {
    case full
    case stateOnly
    case transformOnly

    private static let includesTF: UInt16 = 1 << 0
    private static let transformOnlyFlag: UInt16 = 1 << 1

    var flags: UInt16 {
      switch self {
        case .full:
          return Self.includesTF
        case .stateOnly:
          return 0
        case .transformOnly:
          return Self.transformOnlyFlag
      }
    }

    static func from(flags: UInt16) -> UpdateKind {
      if (flags & transformOnlyFlag) != 0 {
        return .transformOnly
      }
      return (flags & includesTF) != 0 ? .full : .stateOnly
    }
  }

  func serialize(kind: UpdateKind) -> Data {
    var writer = DataWriter()

    writer.write(Self.streamMagic)
    writer.write(Self.streamVersion)
    writer.write(kind.flags)

    writer.writeQuat(orientation)
    writer.write(scale)
    writer.writeSIMD2(pan)

    if case .transformOnly = kind {
      return writer.data
    }

    writer.writeSIMD3(clippingTranslation)
    writer.writeSIMD3(clipMin)
    writer.writeSIMD3(clipMax)
    writer.write(normIsoValue)
    writer.write(renderMode.serialize())
    writer.write(UInt8(brickVis ? 1 : 0))
    writer.write(Int32(minValue))
    writer.write(Int32(maxValue))
    writer.write(Int32(rangeMax))

    if case .full = kind {
      let tfData = transferFunction.serialize()
      writer.write(UInt32(tfData.count))
      writer.writeRaw(tfData)
    }

    return writer.data
  }

  func serializeCommonSharePlayState(includeTransferFunction: Bool) -> Data {
    var writer = DataWriter()

    writer.write(Self.sharePlayMagic)
    writer.write(Self.sharePlayVersion)
    writer.write(SharePlayPacketKind.commonRenderState.rawValue)
    writer.write(UInt8(includeTransferFunction ? 1 : 0))

    writer.writeSIMD3(clipMin)
    writer.writeSIMD3(clipMax)
    writer.write(normIsoValue)
    writer.write(renderMode.serialize())
    writer.write(UInt8(brickVis ? 1 : 0))
    writer.write(Int32(minValue))
    writer.write(Int32(maxValue))
    writer.write(Int32(rangeMax))

    if includeTransferFunction {
      let tfData = transferFunction.serialize()
      writer.write(UInt32(tfData.count))
      writer.writeRaw(tfData)
    }

    return writer.data
  }

  func serializeScreenSharePlayTransform() -> Data {
    var writer = DataWriter()

    writer.write(Self.sharePlayMagic)
    writer.write(Self.sharePlayVersion)
    writer.write(SharePlayPacketKind.screenTransform.rawValue)
    writer.write(UInt8(0))

    writer.writeQuat(orientation)
    writer.write(scale)
    writer.writeSIMD2(pan)

    return writer.data
  }

  @discardableResult
  func applySharePlayUpdate(from data: Data) throws -> Bool {
    var reader = DataReader(data)
    let magic: UInt32 = try reader.read()
    guard magic == Self.sharePlayMagic else { return false }
    let version: UInt16 = try reader.read()
    guard version == Self.sharePlayVersion else { throw RenderingParametersUpdateError.unsupportedVersion(version) }
    let packetKindRaw: UInt8 = try reader.read()
    let flags: UInt8 = try reader.read()

    guard let packetKind = SharePlayPacketKind(rawValue: packetKindRaw) else {
      throw RenderingParametersUpdateError.unsupportedPacket(packetKindRaw)
    }

    switch packetKind {
      case .commonRenderState:
        try applyCommonSharePlayState(from: &reader, includesTransferFunction: (flags & 1) != 0)
      case .screenTransform:
        orientation = try reader.readQuat()
        scale = try reader.read()
        pan = try reader.readSIMD2()
      case .visionTransform:
        break
    }

    if !reader.isAtEnd {
      throw RenderingParametersUpdateError.trailingBytes(reader.remainingCount)
    }

    return true
  }

  @discardableResult
  func applyUpdate(from data: Data) throws -> UpdateKind {
    var reader = DataReader(data)

    let magic: UInt32 = try reader.read()
    guard magic == Self.streamMagic else { throw RenderingParametersUpdateError.badMagic }
    let version: UInt16 = try reader.read()
    guard version == Self.streamVersion else { throw RenderingParametersUpdateError.unsupportedVersion(version) }
    let flags: UInt16 = try reader.read()
    let kind = UpdateKind.from(flags: flags)

    orientation = try reader.readQuat()
    scale = try reader.read()
    pan = try reader.readSIMD2()

    if case .transformOnly = kind {
      return kind
    }

    clippingTranslation = try reader.readSIMD3()
    clipMin = try reader.readSIMD3()
    clipMax = try reader.readSIMD3()
    normIsoValue = try reader.read()
    renderMode = RenderMode.deserialize(try reader.read())
    brickVis = (try reader.read() as UInt8) != 0
    minValue = Int(try reader.read() as Int32)
    maxValue = Int(try reader.read() as Int32)
    rangeMax = Int(try reader.read() as Int32)

    if case .full = kind {
      let tfLength: UInt32 = try reader.read()
      let tfData = try reader.readRaw(Int(tfLength))
      objectWillChange.send()
      try? transferFunction.update(from: tfData)
    }

    transferFunction.updateRanges(minValue: minValue, maxValue: maxValue, rangeMax: rangeMax)

    if !reader.isAtEnd {
      throw RenderingParametersUpdateError.trailingBytes(reader.remainingCount)
    }

    return kind
  }

  private func applyCommonSharePlayState(from reader: inout DataReader, includesTransferFunction: Bool) throws {
    clipMin = try reader.readSIMD3()
    clipMax = try reader.readSIMD3()
    clippingTranslation = Self.translation(fromClipMin: clipMin, clipMax: clipMax)
    normIsoValue = try reader.read()
    renderMode = RenderMode.deserialize(try reader.read())
    brickVis = (try reader.read() as UInt8) != 0
    minValue = Int(try reader.read() as Int32)
    maxValue = Int(try reader.read() as Int32)
    rangeMax = Int(try reader.read() as Int32)

    if includesTransferFunction {
      let tfLength: UInt32 = try reader.read()
      let tfData = try reader.readRaw(Int(tfLength))
      objectWillChange.send()
      try? transferFunction.update(from: tfData)
    }

    transferFunction.updateRanges(minValue: minValue, maxValue: maxValue, rangeMax: rangeMax)
  }

  private static func translation(fromClipMin clipMin: SIMD3<Float>, clipMax: SIMD3<Float>) -> SIMD3<Float> {
    var translation = SIMD3<Float>(0, 0, 0)
    for axis in 0..<3 {
      if clipMin[axis] > 0 {
        translation[axis] = clipMin[axis]
      } else if clipMax[axis] < 1 {
        translation[axis] = clipMax[axis] - 1
      }
    }
    return translation
  }
}

private enum SharePlayPacketKind: UInt8 {
  case commonRenderState = 1
  case screenTransform = 2
  case visionTransform = 3
}

enum RenderingParametersUpdateError: Error, LocalizedError {
  case badMagic
  case unsupportedVersion(UInt16)
  case unsupportedPacket(UInt8)
  case outOfBounds
  case trailingBytes(Int)

  var errorDescription: String? {
    switch self {
      case .badMagic:
        return "Invalid rendering parameter update."
      case .unsupportedVersion(let version):
        return "Unsupported rendering parameter update version \(version)."
      case .unsupportedPacket(let packet):
        return "Unsupported rendering parameter update packet \(packet)."
      case .outOfBounds:
        return "Unexpected end of rendering parameter update."
      case .trailingBytes(let count):
        return "Rendering parameter update has \(count) trailing bytes."
    }
  }
}

private extension RenderMode {
  func serialize() -> UInt8 {
    switch self {
      case .transferFunction1D:
        return 0
      case .transferFunction1DLighting:
        return 1
      case .isoValue:
        return 2
    }
  }

  static func deserialize(_ rawValue: UInt8) -> RenderMode {
    switch rawValue {
      case 0:
        return .transferFunction1D
      case 1:
        return .transferFunction1DLighting
      case 2:
        return .isoValue
      default:
        return .transferFunction1D
    }
  }
}

private struct DataWriter {
  private(set) var data = Data()

  mutating func write<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { raw in
      data.append(contentsOf: raw)
    }
  }

  mutating func write(_ value: Float) {
    var bits = value.bitPattern.littleEndian
    withUnsafeBytes(of: &bits) { raw in
      data.append(contentsOf: raw)
    }
  }

  mutating func writeRaw(_ rawData: Data) {
    data.append(rawData)
  }

  mutating func writeSIMD2(_ value: SIMD2<Float>) {
    write(value.x)
    write(value.y)
  }

  mutating func writeSIMD3(_ value: SIMD3<Float>) {
    write(value.x)
    write(value.y)
    write(value.z)
  }

  mutating func writeQuat(_ value: simd_quatf) {
    let vector = value.vector
    write(vector.x)
    write(vector.y)
    write(vector.z)
    write(vector.w)
  }
}

private struct DataReader {
  private let data: Data
  private var offset = 0

  init(_ data: Data) {
    self.data = data
  }

  var isAtEnd: Bool { offset >= data.count }
  var remainingCount: Int { max(0, data.count - offset) }

  private mutating func copyBytes<T>(into value: inout T) throws {
    let size = MemoryLayout<T>.size
    guard offset + size <= data.count else { throw RenderingParametersUpdateError.outOfBounds }
    _ = withUnsafeMutableBytes(of: &value) { destination in
      data.copyBytes(to: destination, from: offset..<offset + size)
    }
    offset += size
  }

  mutating func read<T: FixedWidthInteger>() throws -> T {
    var raw = T.zero
    try copyBytes(into: &raw)
    return T(littleEndian: raw)
  }

  mutating func read() throws -> Float {
    var bits = UInt32.zero
    try copyBytes(into: &bits)
    return Float(bitPattern: bits.littleEndian)
  }

  mutating func readRaw(_ count: Int) throws -> Data {
    guard count >= 0, offset + count <= data.count else { throw RenderingParametersUpdateError.outOfBounds }
    let rawData = data.subdata(in: offset..<offset + count)
    offset += count
    return rawData
  }

  mutating func readSIMD2() throws -> SIMD2<Float> {
    SIMD2<Float>(try read(), try read())
  }

  mutating func readSIMD3() throws -> SIMD3<Float> {
    SIMD3<Float>(try read(), try read(), try read())
  }

  mutating func readQuat() throws -> simd_quatf {
    let x: Float = try read()
    let y: Float = try read()
    let z: Float = try read()
    let w: Float = try read()
    return simd_quatf(ix: x, iy: y, iz: z, r: w)
  }
}

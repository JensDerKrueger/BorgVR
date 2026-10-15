import Foundation
import Metal
import simd

struct TransferEditing {
  var red: Bool = false
  var green: Bool = false
  var blue: Bool = false
  var opacity: Bool = true
}

final class RenderingParameters: ObservableObject {
  private static let streamMagic: UInt32 = 0x5250_494F // "RPIO"
  private static let streamVersion: UInt16 = 5
  static let maximumTransferFunctionCount = 4

  private static let defaultOrientation =
    simd_quatf(angle: 0.25, axis: SIMD3<Float>(1, 0, 0)) *
    simd_quatf(angle: -0.45, axis: SIMD3<Float>(0, 1, 0))

  @Published var orientation = RenderingParameters.defaultOrientation
  @Published var scale: Float = 1.0
  @Published var pan = SIMD2<Float>(0, 0)
  @Published var clippingTranslation = SIMD3<Float>(0, 0, 0)
  @Published var clipMin = SIMD3<Float>(0, 0, 0)
  @Published var clipMax = SIMD3<Float>(1, 1, 1)
  let transferFunctions = (0..<maximumTransferFunctionCount).map { _ in TransferFunction1D() }
  @Published private(set) var componentCount = 1
  @Published var selectedTransferFunctionChannel = 0
  var transferFunction: TransferFunction1D {
    transferFunctions[min(max(selectedTransferFunctionChannel, 0), componentCount - 1)]
  }
  var activeTransferFunctions: ArraySlice<TransferFunction1D> {
    transferFunctions.prefix(componentCount)
  }
  @Published var transferEditing = TransferEditing()
  @Published var normIsoValue: Float = 0.1
  @Published var renderMode: RenderMode = .transferFunction1D
  @Published var brickVis = false
  @Published var lightDirection = BorgVRLightingState.default.direction
  @Published var ambientLightColor = BorgVRLightingState.default.ambientColor
  @Published var diffuseLightColor = BorgVRLightingState.default.diffuseColor
  @Published var specularLightColor = BorgVRLightingState.default.specularColor
  private(set) var viewportAspectRatio: Float = 1

  @Published var minValue: Int = 0
  @Published var maxValue: Int = 1
  @Published var rangeMax: Int = 1

  var isoValue: Float {
    normIsoValue * Float(maxValue) / Float(max(rangeMax, 1))
  }

  func updateRanges(minValue: Int, maxValue: Int, rangeMax: Int, componentCount: Int = 1) {
    self.minValue = minValue
    self.maxValue = maxValue
    self.rangeMax = rangeMax
    self.componentCount = min(max(componentCount, 1), Self.maximumTransferFunctionCount)
    selectedTransferFunctionChannel = min(selectedTransferFunctionChannel, self.componentCount - 1)
    updateTransferFunctionRanges()
  }

  func loadTransferFunction(from url: URL) throws {
    try transferFunction.load(from: url)
    transferFunction.updateRanges(minValue: minValue, maxValue: maxValue, rangeMax: rangeMax)
  }

  func loadTransferFunction(from data: Data) throws {
    try transferFunction.load(from: data)
    transferFunction.updateRanges(minValue: minValue, maxValue: maxValue, rangeMax: rangeMax)
  }

  @discardableResult
  func updateViewportAspectRatio(_ aspectRatio: Float) -> Bool {
    guard aspectRatio.isFinite, aspectRatio > 0 else { return false }
    guard abs(viewportAspectRatio - aspectRatio) > 0.0001 else { return false }
    viewportAspectRatio = aspectRatio
    return true
  }

  var screenViewState: BorgVRScreenViewState {
    BorgVRScreenViewState(
      orientation: orientation,
      scale: scale,
      pan: pan,
      viewportAspectRatio: viewportAspectRatio
    )
  }

  func reset() {
    orientation = RenderingParameters.defaultOrientation
    scale = 1.0
    pan = SIMD2<Float>(0, 0)
    clippingTranslation = SIMD3<Float>(0, 0, 0)
    clipMin = SIMD3<Float>(0, 0, 0)
    clipMax = SIMD3<Float>(1, 1, 1)
    for transferFunction in transferFunctions {
      transferFunction.reset()
    }
    selectedTransferFunctionChannel = 0
    transferEditing = TransferEditing()
    normIsoValue = 0.1
    renderMode = .transferFunction1D
    brickVis = false
    applyLightingState(.default)
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
    writer.write(Int64(minValue))
    writer.write(Int64(maxValue))
    writer.write(Int64(rangeMax))
    writer.writeSIMD3(lightDirection)
    writer.writeSIMD3(ambientLightColor)
    writer.writeSIMD3(diffuseLightColor)
    writer.writeSIMD3(specularLightColor)

    if case .full = kind {
      writeTransferFunctions(to: &writer)
    }

    return writer.data
  }

  func serializeCommonSharePlayState(includeTransferFunction: Bool) -> Data {
    var writer = DataWriter()

    writer.write(BorgVRSharePlayProtocol.magic)
    writer.write(BorgVRSharePlayProtocol.PacketKind.commonRenderState.rawValue)
    writer.write(UInt8(includeTransferFunction ? 1 : 0))

    writer.writeSIMD3(clipMin)
    writer.writeSIMD3(clipMax)
    writer.write(normIsoValue)
    writer.write(renderMode.serialize())
    writer.write(UInt8(brickVis ? 1 : 0))
    writer.write(Int64(minValue))
    writer.write(Int64(maxValue))
    writer.write(Int64(rangeMax))
    writer.writeSIMD3(lightDirection)
    writer.writeSIMD3(ambientLightColor)
    writer.writeSIMD3(diffuseLightColor)
    writer.writeSIMD3(specularLightColor)

    if includeTransferFunction {
      writeTransferFunctions(to: &writer)
    }

    return writer.data
  }

  func serializeScreenSharePlayTransform() -> Data {
    BorgVRScreenViewStateCodec.encode(screenViewState)
  }

  @discardableResult
  func applySharePlayUpdate(from data: Data) throws -> Bool {
    if let screenViewState = try BorgVRScreenViewStateCodec.decodeIfPresent(data) {
      apply(screenViewState)
      return true
    }

    var reader = DataReader(data)
    let magic: UInt32 = try reader.read()
    guard magic == BorgVRSharePlayProtocol.magic else { return false }
    let packetKindRaw: UInt8 = try reader.read()
    let flags: UInt8 = try reader.read()

    guard let packetKind = BorgVRSharePlayProtocol.PacketKind(rawValue: packetKindRaw) else {
      throw RenderingParametersUpdateError.unsupportedPacket(packetKindRaw)
    }

    switch packetKind {
      case .commonRenderState:
        try applyCommonSharePlayState(from: &reader, includesTransferFunction: (flags & 1) != 0)
      case .screenTransform:
        throw RenderingParametersUpdateError.unsupportedPacket(packetKindRaw)
      case .visionTransform:
        return true
      case .volumeMarkers, .spatialToolPreview, .volumeMeasurements:
        return true
    }

    if !reader.isAtEnd {
      throw RenderingParametersUpdateError.trailingBytes(reader.remainingCount)
    }

    return true
  }

  func apply(_ screenViewState: BorgVRScreenViewState) {
    orientation = screenViewState.orientation
    scale = screenViewState.scale
    pan = screenViewState.pan
  }

  @discardableResult
  func applyUpdate(from data: Data) throws -> UpdateKind {
    var reader = DataReader(data)

    let magic: UInt32 = try reader.read()
    guard magic == Self.streamMagic else { throw RenderingParametersUpdateError.badMagic }
    let version: UInt16 = try reader.read()
    guard version == 2 || version == 3 || version == Self.streamVersion else {
      throw RenderingParametersUpdateError.unsupportedVersion(version)
    }
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
    if version >= 3 {
      minValue = Int(try reader.read() as Int64)
      maxValue = Int(try reader.read() as Int64)
      rangeMax = Int(try reader.read() as Int64)
    } else {
      minValue = Int(try reader.read() as Int32)
      maxValue = Int(try reader.read() as Int32)
      rangeMax = Int(try reader.read() as Int32)
    }
    applyLightingState(BorgVRLightingState(
      direction: try reader.readSIMD3(),
      ambientColor: try reader.readSIMD3(),
      diffuseColor: try reader.readSIMD3(),
      specularColor: try reader.readSIMD3()
    ))

    if case .full = kind {
      objectWillChange.send()
      if version >= 4 {
        try readTransferFunctions(from: &reader)
      } else {
        let tfLength: UInt32 = try reader.read()
        let tfData = try reader.readRaw(Int(tfLength))
        try? transferFunctions[0].update(from: tfData)
      }
    }

    updateTransferFunctionRanges()

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
    minValue = Int(try reader.read() as Int64)
    maxValue = Int(try reader.read() as Int64)
    rangeMax = Int(try reader.read() as Int64)
    applyLightingState(BorgVRLightingState(
      direction: try reader.readSIMD3(),
      ambientColor: try reader.readSIMD3(),
      diffuseColor: try reader.readSIMD3(),
      specularColor: try reader.readSIMD3()
    ))

    if includesTransferFunction {
      objectWillChange.send()
      try readTransferFunctions(from: &reader)
    }

    updateTransferFunctionRanges()
  }

  func initTransferFunctionMetal(device: MTLDevice) {
    for transferFunction in transferFunctions {
      transferFunction.initMetal(device: device)
    }
  }

  func bindTransferFunctions(to encoder: MTLRenderCommandEncoder) throws {
    let indices = [
      TextureIndex.transferFunction.rawValue,
      TextureIndex.transferFunction2.rawValue,
      TextureIndex.transferFunction3.rawValue,
      TextureIndex.transferFunction4.rawValue
    ]
    for index in transferFunctions.indices {
      try transferFunctions[index].bind(to: encoder, index: indices[index])
    }
  }

  private func writeTransferFunctions(to writer: inout DataWriter) {
    // The selected editor channel is local UI state and must not be synchronized.
    writer.write(UInt8(componentCount))
    for transferFunction in activeTransferFunctions {
      let data = transferFunction.serialize()
      writer.write(UInt32(data.count))
      writer.writeRaw(data)
    }
  }

  private func readTransferFunctions(from reader: inout DataReader) throws {
    let count = Int(try reader.read() as UInt8)
    guard (1...Self.maximumTransferFunctionCount).contains(count) else {
      throw RenderingParametersUpdateError.unsupportedTransferFunctionCount(count)
    }
    componentCount = count
    // Keep the local editor selection, clamped to the received dataset channel count.
    selectedTransferFunctionChannel = min(selectedTransferFunctionChannel, count - 1)
    for index in 0..<count {
      let length: UInt32 = try reader.read()
      let data = try reader.readRaw(Int(length))
      try transferFunctions[index].update(from: data)
    }
  }

  private func updateTransferFunctionRanges() {
    for transferFunction in transferFunctions {
      transferFunction.updateRanges(minValue: minValue, maxValue: maxValue, rangeMax: rangeMax)
    }
  }

  private func applyLightingState(_ state: BorgVRLightingState) {
    let state = state.sanitized
    lightDirection = state.direction
    ambientLightColor = state.ambientColor
    diffuseLightColor = state.diffuseColor
    specularLightColor = state.specularColor
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

enum RenderingParametersUpdateError: Error, LocalizedError {
  case badMagic
  case unsupportedVersion(UInt16)
  case unsupportedPacket(UInt8)
  case outOfBounds
  case trailingBytes(Int)
  case unsupportedTransferFunctionCount(Int)

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
      case .unsupportedTransferFunctionCount(let count):
        return "Unsupported transfer-function count \(count)."
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

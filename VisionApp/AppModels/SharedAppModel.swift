import RealityKit

// MARK: - SharedAppModel

/**
 Contains all collaborative state that must be synchronized across multiple instances of the app in
 multi-user scenarios. It provides serialization and deserialization logic for network synchronization,
 ensuring that shared data is consistent between devices. Use this model for any state that belongs
 to the shared workspace, rather than a single user or device.
*/
@Observable
class SharedAppModel {
  /// Current world transformation matrix.
  var originFromWorldAnchorMatrix: simd_float4x4
  /// Current model transform.
  var modelTransform: Transform
  /// Last model transform.
  var lastModelTransform: Transform

  /// Minimum clipping bounds.
  var clipMin: SIMD3<Float>
  /// Maximum clipping bounds.
  var clipMax: SIMD3<Float>
  /// last translationvector used when the previous event ended
  var lastTranslationClipping: SIMD3<Float>

  /// The 1D transfer function for color mapping.
  var transferFunction: TransferFunction1D

  /// Normalized isovalue between 0.0 and 1.0.
  var normIsoValue: Float
  /// Computed isovalue in data units.
  var isoValue: Float {
    return normIsoValue * Float(maxValue) / Float(rangeMax)
  }

  /// The selected rendering mode.
  var renderMode: RenderMode
  /// Flag to show or hide bricks.
  var brickVis: Bool
  /// Minimum data value for ISO and TF mapping (presently unused).
  var minValue: Int = 0
  /// Maximum data value for ISO and TFmapping.
  var maxValue: Int = 1
  /// Maximum range value for scaling isovalue.
  var rangeMax: Int = 1
  /// A flag indicating that the atas should be emptied
  var purgeAtlas: Bool

  // Initialize after self is fully initialized to avoid using self too early.
  private var groupActivityHelper: GroupActivityHelper?

  /**
   Default initializer sets up placeholders, then calls `reset` and `updateRanges`
   to apply actual default parameters.
   */
  init() {
    originFromWorldAnchorMatrix = matrix_identity_float4x4
    modelTransform = .init()
    lastModelTransform = .init()
    clipMin = .zero
    clipMax = .zero
    lastTranslationClipping = .zero
    transferFunction = .init()
    normIsoValue = 0
    renderMode = .transferFunction1D
    brickVis = false
    purgeAtlas = false
    groupActivityHelper = GroupActivityHelper(self)

    reset()
    updateRanges(minValue: 0, maxValue: 1, rangeMax: 1)
  }

  func configureGroupActivities(runtimeAppModel: RuntimeAppModel) async {
    await groupActivityHelper?.configureSession(runtimeAppModel: runtimeAppModel)
  }

  func synchronize(kind: UpdateKind) {
    groupActivityHelper?.synchronize(kind: kind)
  }

  @MainActor func leaveGroupActivity() {
    groupActivityHelper?.leaveGroupActivity()
  }

  @MainActor func shutdownGroupsession() {
    groupActivityHelper?.shutdownGroupsession()
  }

  func openSharedView() {
    Task { @MainActor in
      await groupActivityHelper?.sendInitialData()
    }
  }

  /**
   Updates the min/max/range values and applies them to the transfer function.

   - Parameters:
   - minValue: The new minimum data value.
   - maxValue: The new maximum data value.
   - rangeMax: The overall maximum range value.
   */
  func updateRanges(minValue: Int, maxValue: Int, rangeMax: Int) {
    self.minValue = minValue
    self.maxValue = maxValue
    self.rangeMax = rangeMax
    self.transferFunction.updateRanges(
      minValue: minValue,
      maxValue: maxValue,
      rangeMax: rangeMax
    )
  }

  func loadTransform(from url: URL) throws {
    let transform = try Transform.load(from:url)
    self.modelTransform = transform
    self.lastModelTransform = transform
  }

  /**
   Resets all rendering parameters to default values.

   - Transforms are reset to identity.
   - Clipping bounds set to full volume.
   - Transfer function reset.
   - Isovalue set to 0.1.
   - Render mode set to `.transferFunction1D`.
   - Brick visibility disabled.
   */
  func reset() {
    let defaultTranslation = SIMD3<Float>(-0.5, 0.0, -1.0)
    let defaultScale = SIMD3<Float>(1, 1, 1)
    let defaultRotation: simd_quatf = simd_quatf(.identity)
    let defaultTransform = Transform(
      scale: defaultScale,
      rotation: defaultRotation,
      translation: defaultTranslation
    )

    originFromWorldAnchorMatrix = matrix_identity_float4x4
    modelTransform = defaultTransform
    lastModelTransform = defaultTransform
    clipMin = .init(0, 0, 0)
    clipMax = .init(1, 1, 1)
    lastTranslationClipping = .zero
    transferFunction.reset()
    normIsoValue = 0.1
    renderMode = .transferFunction1D
    brickVis = false
    purgeAtlas = false
  }

  // MARK: - RenderingParamaters Binary I/O for multi-user data exchange

  /// Magic identifier for serialized RenderingParamaters blobs.
  private static let streamMagic: UInt32 = 0x5250_414D // "RPAM"
  /// File format version.
  private static let streamVersion: UInt16 = 1

  enum UpdateKind {
    case full          // includes TF
    case stateOnly     // no TF
    case transformOnly // only transforms

    // Bit positions
    private static let includesTF: UInt16    = 1 << 0
    private static let transformOnlyFlag: UInt16 = 1 << 1

    /// Encode to flags.
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

    /// Decode from flags.
    static func from(flags: UInt16) -> UpdateKind {
      if (flags & transformOnlyFlag) != 0 {
        return .transformOnly
      }
      return (flags & includesTF) != 0 ? .full : .stateOnly
    }
  }

  func serialize(kind: UpdateKind) -> Data {
    var w = DataWriter()

    // Header
    w.write(Self.streamMagic)
    w.write(Self.streamVersion)
    w.write(kind.flags)

    // Transform (translation, rotation, scale)
    w.writeSIMD3(modelTransform.translation)
    w.writeQuat(modelTransform.rotation)
    w.writeSIMD3(modelTransform.scale)

    // LastTransform
    w.writeSIMD3(lastModelTransform.translation)
    w.writeQuat(lastModelTransform.rotation)
    w.writeSIMD3(lastModelTransform.scale)

    // Minimal packet ends here.
    if case .transformOnly = kind { return w.data }

    // Clip bounds
    w.writeSIMD3(clipMin)
    w.writeSIMD3(clipMax)
    w.writeSIMD3(lastTranslationClipping)

    // Scalar fields
    w.write(normIsoValue)
    w.write(renderMode.serialize())
    w.write(UInt8(brickVis ? 1 : 0))
    w.write(Int32(minValue))
    w.write(Int32(maxValue))
    w.write(Int32(rangeMax))
    w.write(UInt8(purgeAtlas ? 1 : 0))

    // Optional transfer function block
    if case .full = kind {
      let tfData = transferFunction.serialize()
      w.write(UInt32(tfData.count))
      w.writeRaw(tfData)
    }

    return w.data
  }

  /// Deserialize from a Data blob created by `serialize`.
  /// Initializes a fresh instance and populates all fields.
  convenience init(from data: Data) throws {
    self.init()
    _ = try applyUpdate(from: data) // reuse the in-place logic
  }

  // MARK: - In-place update (fast path for per-frame)

  /// Applies the serialized update to `self`. Returns the detected `UpdateKind`.
  @discardableResult
  func applyUpdate(from data: Data) throws -> UpdateKind {
    var r = DataReader(data)

    // Header
    let magic: UInt32 = try r.read()
    guard magic == Self.streamMagic else { throw SharedAppModelError.badMagic }
    let version: UInt16 = try r.read()
    guard version == Self.streamVersion else { throw SharedAppModelError.unsupportedVersion(version) }
    let flags: UInt16 = try r.read()
    let kind = UpdateKind.from(flags: flags)

    // Transforms (always present)
    let tTranslation = try r.readSIMD3()
    let tRotation    = try r.readQuat()
    let tScale       = try r.readSIMD3()
    let lTranslation = try r.readSIMD3()
    let lRotation    = try r.readQuat()
    let lScale       = try r.readSIMD3()

    // Assign transforms first (so consumers can react early if needed)
    self.modelTransform = Transform(scale: tScale, rotation: tRotation, translation: tTranslation)
    self.lastModelTransform = Transform(scale: lScale, rotation: lRotation, translation: lTranslation)

    // Early return for transform-only packets
    if case .transformOnly = kind {
      return kind
    }

    // State (no TF yet)
    self.clipMin = try r.readSIMD3()
    self.clipMax = try r.readSIMD3()
    self.lastTranslationClipping = try r.readSIMD3()
    self.normIsoValue = try r.read()
    self.renderMode = RenderMode.deserialize(try r.read())
    self.brickVis = (try r.read() as UInt8) != 0
    self.minValue = Int(try r.read() as Int32)
    self.maxValue = Int(try r.read() as Int32)
    self.rangeMax = Int(try r.read() as Int32)
    self.purgeAtlas = (try r.read() as UInt8) != 0

    // Optional TF
    if case .full = kind {
      let tfLen: UInt32 = try r.read()
      let tfData = try r.readRaw(Int(tfLen))
      try? self.transferFunction.update(from: tfData)
      // Make sure TF sees the new ranges (defensive)
    }

    // Keep TF’s range consistent even if TF blob does not follow.
    self.transferFunction.updateRanges(minValue: self.minValue,
                                       maxValue: self.maxValue,
                                       rangeMax: self.rangeMax)

    // Strictness check
    if !r.isAtEnd { throw SharedAppModelError.trailingBytes(r.remainingCount) }

    return kind
  }
}

// MARK: - Errors

enum SharedAppModelError: Error, CustomStringConvertible {
  case badMagic
  case unsupportedVersion(UInt16)
  case outOfBounds
  case trailingBytes(Int)

  var description: String {
    switch self {
      case .badMagic: return "Invalid magic header."
      case .unsupportedVersion(let v): return "Unsupported version \(v)."
      case .outOfBounds: return "Unexpected end of data."
      case .trailingBytes(let n): return "Trailing \(n) byte(s) after record."
    }
  }
}

private struct DataWriter {
  private(set) var data: Data

  init(capacity: Int = 256) {
    self.data = Data()
    self.data.reserveCapacity(capacity)
  }

  // MARK: - Primitives

  mutating func write<T: FixedWidthInteger>(_ v: T) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { raw in
      data.append(contentsOf: raw)
    }
  }

  mutating func write(_ f: Float) {
    var bits = f.bitPattern.littleEndian
    withUnsafeBytes(of: &bits) { raw in
      data.append(contentsOf: raw)
    }
  }

  mutating func writeRaw(_ d: Data) {
    data.append(d) // already a byte blob
  }

  // MARK: - Convenience

  mutating func writeSIMD3(_ v: SIMD3<Float>) {
    write(v.x); write(v.y); write(v.z)
  }

  mutating func writeQuat(_ q: simd_quatf) {
    let v = q.vector
    write(v.x); write(v.y); write(v.z); write(v.w)
  }
}

// MARK: - Reader

private struct DataReader {
  private let data: Data
  private var offset: Int = 0
  init(_ data: Data) { self.data = data }

  var isAtEnd: Bool { offset >= data.count }
  var remainingCount: Int { max(0, data.count - offset) }

  @inline(__always)
  private mutating func copyBytes<T>(into value: inout T) throws {
    let sz = MemoryLayout<T>.size
    guard offset + sz <= data.count else { throw SharedAppModelError.outOfBounds }
    _ = withUnsafeMutableBytes(of: &value) { dst in
      data.copyBytes(to: dst, from: offset ..< offset + sz)
    }
    offset += sz
  }

  @inline(__always)
  mutating func read<T: FixedWidthInteger>() throws -> T {
    var raw = T.zero
    try copyBytes(into: &raw)
    return T(littleEndian: raw)
  }

  mutating func read() throws -> Float {
    var bits = UInt32(0)
    try copyBytes(into: &bits)
    bits = bits.littleEndian
    return Float(bitPattern: bits)
  }

  mutating func readRaw(_ count: Int) throws -> Data {
    guard count >= 0, offset + count <= data.count else { throw SharedAppModelError.outOfBounds }
    let d = data.subdata(in: offset ..< offset + count)
    offset += count
    return d
  }

  mutating func readSIMD3() throws -> SIMD3<Float> {
    let x: Float = try read()
    let y: Float = try read()
    let z: Float = try read()
    return SIMD3<Float>(x, y, z)
  }

  mutating func readQuat() throws -> simd_quatf {
    let x: Float = try read()
    let y: Float = try read()
    let z: Float = try read()
    let w: Float = try read()
    return simd_quatf(ix: x, iy: y, iz: z, r: w)
  }
}


extension Transform {
  func save(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    let data = try encoder.encode(self)
    try data.write(to: url)
  }

  static func load(from url: URL) throws -> Transform {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    return try decoder.decode(Transform.self, from: data)
  }

  mutating func load(from url: URL) throws {
    let loaded = try Transform.load(from: url)
    self = loaded
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */


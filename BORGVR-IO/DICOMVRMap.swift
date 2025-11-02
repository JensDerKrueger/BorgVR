import Foundation

// MARK: - DicomTag

/// Represents a DICOM tag with group and element numbers.
public struct DicomTag: Equatable, Hashable {
  public let group: UInt16
  public let element: UInt16

  public init(_ group: UInt16, _ element: UInt16) {
    self.group = group
    self.element = element
  }

  /// 32-bit packed form ggggeeee for fast dictionary lookups.
  @inline(__always)
  public var packed: UInt32 {
    (UInt32(group) << 16) | UInt32(element)
  }

  static let transferSyntaxUID = DicomTag(0x0002, 0x0010)
  static let rows = DicomTag(0x0028, 0x0010)
  static let columns = DicomTag(0x0028, 0x0011)
  static let samplesPerPixel = DicomTag(0x0028, 0x0002)
  static let bitsAllocated = DicomTag(0x0028, 0x0100)
  static let bitsStored = DicomTag(0x0028, 0x0101)
  static let highBit = DicomTag(0x0028, 0x0102)
  static let pixelRepresentation = DicomTag(0x0028, 0x0103)
  static let sliceThickness = DicomTag(0x0018, 0x0050)
  static let pixelSpacing = DicomTag(0x0028, 0x0030)
  static let imagePositionPatient = DicomTag(0x0020, 0x0032)
  static let imageOrientationPatient = DicomTag(0x0020, 0x0037)
  static let instanceNumber = DicomTag(0x0020, 0x0013)
  static let pixelData = DicomTag(0x7FE0, 0x0010)
}

// MARK: - DicomVRMap (JSON-backed, no hardcoded tags)

/// Loads a DICOM VR dictionary from a JSON file and provides lookups.
/// - Supports two JSON shapes:
///   1) { "00080005": "CS", "00080016": "UI", ... }
///   2) { "00080005": { "vr":"CS", "name":"Specific Character Set" }, ... }
///
/// Place `dicom_vr_map.json` in your app bundle (or call `load(from:)`).
public enum DicomVRMap {

  /// Immutable in-memory map after load: packed tag -> VR String.
  public static var runtime: [UInt32: String] = {
    // Try default bundle load on first access
    if let url = Bundle.main.url(forResource: "DICOMVRMap", withExtension: "json"),
       let data = try? Data(contentsOf: url),
       let map = DicomVRMap.parseJSON(data: data) {
      return map
    }
    // If not found or parse fails, start empty (lookups will fall back to UL/UN).
    return [:]
  }()

  // MARK: Public API

  /// Returns the VR for a tag. Falls back to:
  /// - "UL" for any group length element (xxxx,0000)
  /// - "UN" when unknown
  @inlinable
  public static func vr(for tag: DicomTag) -> String {
    if tag.element == 0x0000 { return "UL" }         // group length
    if let vr = runtime[tag.packed] { return vr }
    return "UN"
  }

  /// Lookup using packed key (ggggeeee).
  @inlinable
  public static func vr(forPacked packed: UInt32) -> String {
    let element = UInt16(packed & 0xFFFF)
    if element == 0x0000 { return "UL" }
    return runtime[packed] ?? "UN"
  }

  /// Reload from a specific JSON file URL (overrides current map).
  /// - Returns `true` on success.
  @discardableResult
  public static func load(from url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url),
          let map = parseJSON(data: data) else { return false }
    runtime = map
    return true
  }

  /// Reload from raw JSON data (overrides current map).
  /// - Returns `true` on success.
  @discardableResult
  public static func load(from data: Data) -> Bool {
    guard let map = parseJSON(data: data) else { return false }
    runtime = map
    return true
  }

  /// Manually register/override entries at runtime (keys are DicomTag).
  public static func register(_ entries: [DicomTag: String]) {
    var copy = runtime
    for (t, vr) in entries { copy[t.packed] = vr }
    runtime = copy
  }

  // MARK: JSON parsing

  /// Accepts either:
  ///  - [String: String] (VR-only), or
  ///  - [String: { "vr": String, "name": String }]
  private static func parseJSON(data: Data) -> [UInt32: String]? {
    // Try the simplest shape first: [String:String]
    if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
      return parseVROnly(dict)
    }
    // Try the richer shape: [String:[String:Any]]
    if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      return parseVRWithObjects(dict)
    }
    return nil
  }

  private static func parseVROnly(_ dict: [String: String]) -> [UInt32: String] {
    var out: [UInt32: String] = [:]
    out.reserveCapacity(dict.count)
    for (rawKey, vr) in dict {
      if let packed = parseKeyToPacked(rawKey) {
        out[packed] = vr.uppercased()
      }
    }
    return out
  }

  private static func parseVRWithObjects(_ dict: [String: Any]) -> [UInt32: String] {
    var out: [UInt32: String] = [:]
    out.reserveCapacity(dict.count)
    for (rawKey, value) in dict {
      guard let obj = value as? [String: Any] else { continue }
      // Accept keys "vr" or "VR"
      let vr = (obj["vr"] as? String) ?? (obj["VR"] as? String)
      guard let vrStr = vr?.uppercased() else { continue }
      if let packed = parseKeyToPacked(rawKey) {
        out[packed] = vrStr
      }
    }
    return out
  }

  /// Normalize keys like "00080005", "0008,0005", "(0008,0005)" -> packed UInt32.
  /// Returns nil if the key cannot be parsed.
  private static func parseKeyToPacked(_ raw: String) -> UInt32? {
    // Strip everything except hex digits
    let hexOnly = raw.uppercased().filter { ("0"..."9").contains($0) || ("A"..."F").contains($0) }
    guard hexOnly.count == 8, let u = UInt32(hexOnly, radix: 16) else { return nil }
    return u
  }
}

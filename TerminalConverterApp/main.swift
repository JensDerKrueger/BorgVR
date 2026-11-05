import Foundation

enum ConverterInfo {
  static let version = "3.7"
  static let toolIdentification = "BorgVR Converter \(version)"

  static let banner = #"""
   ____                   __     ______
  | __ )  ___  _ __ __ _ \ \   / /  _ \
  |  _ \ / _ \| '__/ _` | \ \ / /| |_) |
  | |_) | (_) | | | (_| |  \ V / |  _ <
  |____/ \___/|_|  \__, |   \_/  |_| \_\
                   |___/
              Volume Converter \#(version)
  """#
}

// Create a logger for console output.
let logger = PrintfLogger(useColors: false, etaFormat: .mmss)

/**
 An enum representing the supported conversion modes.

 - DicomConversion: Converts DICOM files.
 - QVISConversion: Converts a QVIS volume.
 - DemoDataCreation: Generates demo volume data.
 */
enum Mode: String {
  case DicomConversion = "D"
  case ImageSequenceConversion = "S"
  case QVISConversion = "Q"
  case NRRDConversion = "N"
  case PVMConversion = "P"
  case I3MConversion = "I"
  case ZarrConversion = "Z"
  case UVFConversion = "V"
  case VFFConversion = "F"
  case FlatVolumeExport = "E"
  case BorgVRRepacking = "R"
  case DemoDataCreation = "C"
}

/**
 An enum representing the types of datasets for demo data creation.

 - LinearData: A dataset with linearly increasing values.
 - DoubleFractalData: A double-precision CPU Mandelbulb.
 - FloatFractalData: A single-precision Mandelbulb using Metal when available.
 - QuaternionJuliaData: A quaternion Julia set.
 - MandelboxData: A Mandelbox fractal.
 - GyroidData: A periodic gyroid field.
 - SheppLoganData: A 3D Shepp-Logan phantom.
 - FrequencyChirpData: A frequency chirp with brick-boundary calibration planes.
 - UInt32TestData: A scalar test volume spanning the complete UInt32 range.
 */
enum DatasetType: String {
  case LinearData = "L"
  case FloatFractalData = "F"
  case DoubleFractalData = "D"
  case QuaternionJuliaData = "J"
  case MandelboxData = "B"
  case GyroidData = "G"
  case SheppLoganData = "P"
  case FrequencyChirpData = "T"
  case UInt32TestData = "U"

  var analyticKind: AnalyticVolumeKind? {
    switch self {
      case .QuaternionJuliaData: .quaternionJulia
      case .MandelboxData: .mandelbox
      case .GyroidData: .gyroid
      case .SheppLoganData: .sheppLogan
      case .FrequencyChirpData: .frequencyChirp
      case .LinearData, .FloatFractalData, .DoubleFractalData, .UInt32TestData: nil
    }
  }

  var displayName: String {
    switch self {
      case .LinearData: "Linear"
      case .FloatFractalData: "Mandelbulb"
      case .DoubleFractalData: "Double-precision Mandelbulb"
      case .QuaternionJuliaData: "Quaternion Julia"
      case .MandelboxData: "Mandelbox"
      case .GyroidData: "Gyroid"
      case .SheppLoganData: "3D Shepp-Logan"
      case .FrequencyChirpData: "Frequency chirp"
      case .UInt32TestData: "UInt32 test pattern"
    }
  }

  func generationParameters(bytesPerComponent: Int, brickStride: Int) -> String {
    if let kind = analyticKind {
      return kind.provenanceDescription(bytesPerVoxel: bytesPerComponent, brickStride: brickStride)
    }
    switch self {
      case .FloatFractalData, .DoubleFractalData:
        return MandelbulbParameters.provenanceDescription(
          bytesPerVoxel: bytesPerComponent, doublePrecision: self == .DoubleFractalData)
      case .LinearData:
        return "Linear test pattern; scalar=(z*sizeY*sizeX+y*sizeX+x) modulo 2^\(bytesPerComponent * 8)."
      case .UInt32TestData:
        return "UInt32 full-range test; u=index/(size-1), or 0 for a singleton axis; scalar=round((u.x+2*u.y+4*u.z)/7*4294967295), saturated at 4294967295."
      default:
        preconditionFailure("Missing generator parameters")
    }
  }
}

func parseDatasetTypes(_ value: String) -> [DatasetType]? {
  let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
  guard !tokens.isEmpty else { return nil }
  let types = tokens.compactMap {
    DatasetType(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
  }
  return types.count == tokens.count ? types : nil
}

/**
 A structure encapsulating common parameters for volume conversion.

 These parameters are shared among different conversion modes.
 */
struct CommonParameters {
  let outputFilename: String
  let datasetDescription: String
  let maxBrickSize: Int
  let overlap: Int
}

/**
 Parameters specific to DICOM conversion mode.

 - inputDirectory: The directory containing the DICOM files.
 - common: Shared parameters such as output filename and brick configuration.
 */
struct DicomModeParameters {
  let inputDirectory: String
  let common: CommonParameters
  var physicalSizeMeters: Vec3<Float>? = nil
}

/**
 Parameters specific to QVIS conversion mode.

 - inputFilename: The path to the QVIS file.
 - common: Shared parameters such as output filename and brick configuration.
 */
struct HeaderFileModeParameters {
  let inputFilename: String
  let common: CommonParameters
}

/// Parameters for exporting one BorgVR LoD as a flat NRRD volume.
struct ExportModeParameters {
  let inputFilename: String
  let outputFilename: String
  let level: Int
}

struct RepackModeParameters {
  let inputFilename: String
  let common: CommonParameters
}

/**
 Parameters specific to demo data creation mode.

 - datasetTypes: The synthetic dataset variant generated for each channel.
 - byteDepth: The bit depth per voxel.
 - componentCount: The number of components per voxel.
 - sizeX: The volume size along the X axis.
 - sizeY: The volume size along the Y axis.
 - sizeZ: The volume size along the Z axis.
 - common: Shared parameters such as output filename and brick configuration.
 */
struct CreateModeParameters {
  let datasetTypes: [DatasetType]
  let byteDepth: Int
  let componentCount: Int
  let sizeX: Int
  let sizeY: Int
  let sizeZ: Int
  let common: CommonParameters
}

let executableName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let usageText = """
USAGE
  \(executableName) <mode> <arguments> [options]
  \(executableName) --help | -h
  \(executableName) --version | -v

MODES
  Import a volume
    D  DICOM directory           Q  QVIS (.dat + RAW)
    N  NRRD / NHDR               P  PVM / PVM2 / PVM3 (including DDS)
    I  IV3Dm (.i3m or ZIP)       Z  Zarr v3 / OME-Zarr 0.5 (.ozx / .zarr)
    V  UVF (.uvf, full-resolution volume only)
    F  VFF (.vff, scalar raster volume)

    \(executableName) <mode> <input> <output.data> <description> <brick> <overlap>

  S  Import filename-sorted RGB/RGBA image slices
    \(executableName) S <folder> <output.data> <description> \\
      <brick> <overlap> <size-x-m> <size-y-m> <size-z-m>
    Images must have identical dimensions; physical sizes describe the whole volume.

  E  Export a BorgVR LoD as uncompressed inline NRRD
    \(executableName) E <input.data> <output.nrrd> <lod>
    LoD 0 is the full-resolution original; higher values select stored coarse levels.

  R  Repack a BorgVR file with new brick, quantization or compression settings
    \(executableName) R <input.data> <output.data> <brick> <overlap>
    Rebuilds all LoDs from full resolution; retains metadata and source provenance.
    Creates a new UUID and appends conversion history. Source and output must differ.
    Requires temporary disk space for the decoded RAW volume (and quantized copy).

  C  Generate a synthetic volume
    \(executableName) C <algorithm> <bytes> <channels> <x> <y> <z> \\
      <output.data> <description> <brick> <overlap>

    L  Linear test data          F  Float Mandelbulb (Metal / CPU fallback)
    D  Double CPU Mandelbulb     J  Quaternion sine Julia set
    B  Mandelbox                G  Gyroid
    P  3D Shepp-Logan phantom    T  Frequency chirp / brick-boundary test
    U  Scalar UInt32 full-range test (requires bytes=4, channels=1)

    Use one algorithm for all channels, or a list in channel order, e.g. F,J.
    Bytes per component: 1, 2 or 4. Multi-channel generation supports 8/16 bits.

PARAMETERS
  <input>        Source file or directory, depending on the selected mode.
  <description>  Short dataset description; quote text containing spaces.
  <brick>        Positive brick size in voxels, e.g. 32 or 64.
  <overlap>      Positive overlap in voxels; mode R also accepts 0.
                 Twice the overlap must be smaller than the brick size.
  <x> <y> <z>    Positive voxel counts; <channels> is 1 through 4.

OPTIONS  (import, generation and repacking; not export mode E)
  --quantize-8bit
      Map each channel's observed value range to 0...255.
      Without this option, repacking retains the source sample precision.
  --no-lz4
      Disable outer LZ4 compression (enabled by default).
  --color-compression none|astc4x4|astc8x8
      RGB/RGBA brick encoding (default: none). Independent of LZ4.
      ASTC is lossy; the brick size must be a multiple of its footprint.
  --source-info <ISO8601-date-time> <source-text>
      Add provenance, e.g. 2026-11-01T10:30:00Z "Downloaded from archive".
      Repeat to supply multiple entries. Include a time zone in each timestamp.

  Size overrides for D/Q/N/P/I/Z/V/R only:
    --size-x <meters>        Set total X extent if physical size is missing.
    --force-size-x <meters>  Always override total X extent.
    Use only one size option, once. Y/Z proportions are preserved.

  Zarr: uint8/16/32, int8/16/32, float32/64; up to four channels, no time series.
  Codecs: raw bytes, Zstandard, gzip, CRC32C and indexed shards.

EXAMPLES
  \(executableName) N scan.nrrd scan.data "CT scan" 32 2
  \(executableName) R scan.data small.data 32 2 --quantize-8bit
  \(executableName) E scan.data scan.nrrd 0
  \(executableName) C F,J 2 2 512 512 512 fused.data "Fractals" 64 2
"""

func failUsage(_ message: String) -> Never {
  // Trusted help contains intentional line breaks, unlike sanitized log messages.
  FileHandle.standardError.write(Data("Error: \(message)\n\n\(usageText)\n".utf8))
  exit(1)
}

print(ConverterInfo.banner)

if CommandLine.arguments.count == 2 {
  switch CommandLine.arguments[1] {
    case "--version", "-v":
      exit(0)
    case "--help", "-h":
      print(usageText)
      exit(0)
    default:
      break
  }
}

/**
 Parses command-line arguments and returns the selected mode along with associated parameters.

 - Parameter args: The array of command-line arguments.
 - Returns: A tuple containing the selected `Mode` and its corresponding parameters (of type DModeParameters, QModeParameters, or CModeParameters).
 - Note: This function exits the application if the arguments are invalid.
 */
func parseArguments(_ args: [String]) -> (Mode, Any) {
  var result: (Mode, Any)

  guard args.count >= 2, let mode = Mode(rawValue: args[1]) else {
    failUsage("Missing or unknown conversion mode.")
  }

  result.0 = mode

  switch mode {
    case .DicomConversion, .ImageSequenceConversion:
      guard args.count == (mode == .ImageSequenceConversion ? 10 : 7) else {
        failUsage("Invalid number of arguments for mode \(mode.rawValue).")
      }
      guard let maxBrickSize = Int(args[5]), maxBrickSize > 0,
            let overlap = Int(args[6]), overlap > 0,
            overlap * 2 < maxBrickSize else {
        logger.error("Error: maxBrickSize and overlap must be positive, and twice the overlap must be smaller than the brick size.")
        exit(1)
      }
      var params = DicomModeParameters(
        inputDirectory: args[2],
        common: CommonParameters(
          outputFilename: args[3],
          datasetDescription: args[4],
          maxBrickSize: maxBrickSize,
          overlap: overlap
        )
      )
      if mode == .ImageSequenceConversion {
        guard let x = Float(args[7]), let y = Float(args[8]), let z = Float(args[9]),
              [x, y, z].allSatisfy({ $0.isFinite && $0 > 0 }) else {
          logger.error("Image sequences require finite positive X/Y/Z dimensions in meters.")
          exit(1)
        }
        params.physicalSizeMeters = Vec3(x: x, y: y, z: z)
      }
      result.1 = params

    case .QVISConversion, .NRRDConversion, .PVMConversion, .I3MConversion, .ZarrConversion, .UVFConversion, .VFFConversion:
      guard args.count == 7 else {
        failUsage("Invalid number of arguments for mode \(mode.rawValue).")
      }
      guard let maxBrickSize = Int(args[5]), maxBrickSize > 0,
            let overlap = Int(args[6]), overlap > 0,
            overlap * 2 < maxBrickSize else {
        logger.error("Error: maxBrickSize and overlap must be positive, and twice the overlap must be smaller than the brick size.")
        exit(1)
      }
      let params = HeaderFileModeParameters(
        inputFilename: args[2],
        common: CommonParameters(
          outputFilename: args[3],
          datasetDescription: args[4],
          maxBrickSize: maxBrickSize,
          overlap: overlap
        )
      )
      result.1 = params

    case .FlatVolumeExport:
      guard args.count == 5,
            let level = Int(args[4]), level >= 0 else {
        failUsage("Invalid arguments for mode E.")
      }
      result.1 = ExportModeParameters(
        inputFilename: args[2],
        outputFilename: args[3],
        level: level
      )

    case .BorgVRRepacking:
      guard args.count == 6,
            let brickSize = Int(args[4]), brickSize > 0,
            let overlap = Int(args[5]), overlap >= 0, overlap <= (brickSize - 1) / 2 else {
        failUsage("Invalid arguments for mode R.")
      }
      result.1 = RepackModeParameters(inputFilename: args[2],
        common: CommonParameters(outputFilename: args[3], datasetDescription: "",
          maxBrickSize: brickSize, overlap: overlap))

    case .DemoDataCreation:
      guard args.count == 12,
            let datasetTypes = parseDatasetTypes(args[2]),
            let byteDepth = Int(args[3]),
            [1, 2, 4].contains(byteDepth),
            let componentCount = Int(args[4]), componentCount > 0,
            let sizeX = Int(args[5]), sizeX > 0,
            let sizeY = Int(args[6]), sizeY > 0,
            let sizeZ = Int(args[7]), sizeZ > 0,
            let maxBrickSize = Int(args[10]), maxBrickSize > 0,
            let overlap = Int(args[11]), overlap > 0,
            overlap * 2 < maxBrickSize
      else {
        failUsage("Invalid arguments for mode C.")
      }
      guard datasetTypes.count == componentCount || datasetTypes.count == 1 else {
        logger.error("Error: Specify either one algorithm or exactly one algorithm per channel.")
        exit(1)
      }
      guard componentCount <= 4 else {
        logger.error("Error: The renderer supports at most four volume channels.")
        exit(1)
      }
      guard componentCount == 1 || byteDepth <= 2 else {
        logger.error("Error: Multi-channel volumes support at most 16 bits per channel.")
        exit(1)
      }
      guard !datasetTypes.contains(.UInt32TestData) || (byteDepth == 4 && componentCount == 1) else {
        logger.error("Error: UInt32 test data requires byte depth 4 and exactly one component.")
        exit(1)
      }
      guard datasetTypes.allSatisfy({ $0 == .LinearData }) ||
              (sizeX > 1 && sizeY > 1 && sizeZ > 1) else {
        logger.error("Error: Analytical volume generation requires at least two samples on every axis.")
        exit(1)
      }
      let params = CreateModeParameters(
        datasetTypes: datasetTypes.count == 1
          ? Array(repeating: datasetTypes[0], count: componentCount)
          : datasetTypes,
        byteDepth: byteDepth,
        componentCount: componentCount,
        sizeX: sizeX,
        sizeY: sizeY,
        sizeZ: sizeZ,
        common: CommonParameters(
          outputFilename: args[8],
          datasetDescription: args[9],
          maxBrickSize: maxBrickSize,
          overlap: overlap
        )
      )
      result.1 = params
  }

  return result
}

func parseImportOptions(_ arguments: [String]) -> (
  arguments: [String], provenance: [BORGVRProvenanceEntry], sizeXMeters: Float?, forceSizeX: Bool, colorCompression: Int, useLZ4: Bool, quantizeTo8Bit: Bool
) {
  var args = arguments
  var colorCompression = 0
  if let index = args.firstIndex(of: "--color-compression") {
    guard index + 1 < args.count, let value = ["none": 0, "astc4x4": 4, "astc8x8": 8][args[index + 1]] else {
      logger.error("--color-compression requires none, astc4x4, or astc8x8."); exit(1)
    }
    colorCompression = value
    args.removeSubrange(index...index + 1)
  }
  let useLZ4 = !args.contains("--no-lz4")
  args.removeAll { $0 == "--no-lz4" }
  let quantizeTo8Bit = args.contains("--quantize-8bit")
  args.removeAll { $0 == "--quantize-8bit" }
  if quantizeTo8Bit, args.count > 1, args[1] == "E" {
    logger.error("--quantize-8bit is not applicable to export mode.")
    exit(1)
  }
  var provenance: [BORGVRProvenanceEntry] = []
  while let index = args.firstIndex(of: "--source-info") {
    guard index + 2 < args.count, !args[index + 2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      logger.error("--source-info requires an ISO-8601 date/time and a non-empty source text.")
      exit(1)
    }
    guard let date = BORGVRProvenanceEntry.parseDate(args[index + 1]) else {
      logger.error("Invalid --source-info date/time; use ISO-8601 with a time zone, e.g. 2026-11-01T10:30:00Z.")
      exit(1)
    }
    provenance.append(BORGVRProvenanceEntry(args[index + 2], date: date))
    args.removeSubrange(index...index + 2)
  }
  guard provenance.isEmpty || args.count < 2 || args[1] != "E" else {
    logger.error("--source-info is not applicable to export mode.")
    exit(1)
  }
  var sizeXMeters: Float?
  var forceSizeX = false
  while let index = args.firstIndex(where: { $0 == "--size-x" || $0 == "--force-size-x" }) {
    guard sizeXMeters == nil, index + 1 < args.count,
          let value = Float(args[index + 1]), value.isFinite, value > 0 else {
      logger.error("Use either --size-x or --force-size-x once, followed by a finite positive length in meters.")
      exit(1)
    }
    sizeXMeters = value
    forceSizeX = args[index] == "--force-size-x"
    args.removeSubrange(index...index + 1)
  }
  if sizeXMeters != nil, args.count > 1, ["E", "C", "S"].contains(args[1]) {
    logger.error("--size-x and --force-size-x apply to import modes D/Q/N/P/I/Z/V/R only.")
    exit(1)
  }
  return (args, provenance, sizeXMeters, forceSizeX, colorCompression, useLZ4, quantizeTo8Bit)
}

func convertRawVolume(inputFilename: String,
                      offset: Int,
                      size: Vec3<Int>,
                      maxBrickSize: Int,
                      bytesPerComponent: Int,
                      componentCount: Int,
                      voxelSpacing: Vec3<Float>,
                      overlap: Int,
                      outputFilename: String,
                      datasetDescription: String,
                      metaDescription: String,
                      provenance: [BORGVRProvenanceEntry]) throws {
  try BorgVRVolumeConversionService.convert(
    BorgVRVolumeConversionRequest(
      source: .raw(
        BorgVRRawVolumeSource(
          url: URL(fileURLWithPath: inputFilename),
          offset: offset,
          size: size,
          bytesPerComponent: bytesPerComponent,
          componentCount: componentCount,
          voxelSpacing: voxelSpacing
        )
      ),
      destinationURL: URL(fileURLWithPath: outputFilename),
      datasetDescription: datasetDescription,
      metaDescription: metaDescription,
      settings: BorgVRVolumeConversionSettings(
        brickSize: maxBrickSize,
        overlap: overlap,
        useCompression: conversionUseLZ4,
        extensionStrategy: .fillZeroes,
        quantizeTo8Bit: conversionQuantizeTo8Bit,
        colorCompression: conversionColorCompression
      ),
      provenance: provenance,
      toolIdentification: ConverterInfo.toolIdentification
    ),
    logger: logger
  )
}

func convertDICOMStack(_ params: DicomModeParameters) {
  do {
    try BorgVRVolumeConversionService.convert(
      BorgVRVolumeConversionRequest(
        source: params.physicalSizeMeters == nil
          ? .dicomDirectory(URL(fileURLWithPath: params.inputDirectory, isDirectory: true))
          : .imageSequence(URL(fileURLWithPath: params.inputDirectory, isDirectory: true)),
        destinationURL: URL(fileURLWithPath: params.common.outputFilename),
        datasetDescription: params.common.datasetDescription,
        metaDescription: "",
        settings: conversionSettings(for: params.common),
        physicalSizeMeters: params.physicalSizeMeters,
        sizeXMeters: conversionSizeXMeters,
        forceSizeX: forceConversionSizeX,
        provenance: conversionProvenance,
        toolIdentification: ConverterInfo.toolIdentification
      ),
      logger: logger
    )
  } catch {
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
  }
}

func convertNRRDVolume(_ params: HeaderFileModeParameters) {
  convertFileVolume(params, formatName: "NRRD")
}

func convertPVMVolume(_ params: HeaderFileModeParameters) {
  convertFileVolume(params, formatName: "PVM")
}

/// Exports one level of a BorgVR dataset as a flat, uncompressed inline NRRD file.
func exportFlatVolume(_ params: ExportModeParameters) {
  do {
    _ = try BORGVRVolumeExporter.export(
      inputURL: URL(fileURLWithPath: params.inputFilename),
      outputURL: URL(fileURLWithPath: params.outputFilename),
      level: params.level,
      logger: logger
    )
  } catch {
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
  }
}


func convertQVISVolume(_ params: HeaderFileModeParameters) {
  convertFileVolume(params, formatName: "QVIS")
}

func repackBorgVRVolume(_ params: RepackModeParameters) {
  do {
    try BorgVRVolumeConversionService.convert(BorgVRVolumeConversionRequest(
      source: .borgVR(URL(fileURLWithPath: params.inputFilename)),
      destinationURL: URL(fileURLWithPath: params.common.outputFilename),
      datasetDescription: "", metaDescription: "", settings: conversionSettings(for: params.common),
      sizeXMeters: conversionSizeXMeters, forceSizeX: forceConversionSizeX,
      provenance: conversionProvenance, toolIdentification: ConverterInfo.toolIdentification),
      logger: logger)
  } catch {
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
  }
}

private func convertFileVolume(_ params: HeaderFileModeParameters, formatName: String) {
  do {
    let sourceURL = URL(fileURLWithPath: params.inputFilename)
    try BorgVRVolumeConversionService.convert(
      BorgVRVolumeConversionRequest(
        source: .file(sourceURL),
        destinationURL: URL(fileURLWithPath: params.common.outputFilename),
        datasetDescription: params.common.datasetDescription,
        metaDescription: "Converted from \(formatName) Volume \(sourceURL.deletingPathExtension().lastPathComponent)",
        settings: conversionSettings(for: params.common),
        sizeXMeters: conversionSizeXMeters,
        forceSizeX: forceConversionSizeX,
        provenance: conversionProvenance,
        toolIdentification: ConverterInfo.toolIdentification
      ),
      logger: logger
    )
  } catch {
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
  }
}

private func conversionSettings(
  for parameters: CommonParameters
) -> BorgVRVolumeConversionSettings {
  BorgVRVolumeConversionSettings(
    brickSize: parameters.maxBrickSize,
    overlap: parameters.overlap,
    useCompression: conversionUseLZ4,
    extensionStrategy: .fillZeroes,
    quantizeTo8Bit: conversionQuantizeTo8Bit,
    colorCompression: conversionColorCompression
  )
}

private func generateScalarVolume(datasetType: DatasetType,
                                  outputURL: URL,
                                  params: CreateModeParameters) throws -> String {
  switch datasetType {
    case .LinearData:
      try computeLinear(filename: outputURL.path,
                        sizeX: params.sizeX,
                        sizeY: params.sizeY,
                        sizeZ: params.sizeZ,
                        bytesPerVoxel: params.byteDepth,
                        componentCount: 1,
                        logger: logger)
      return "Linear data"
    case .UInt32TestData:
      try computeUInt32TestVolume(filename: outputURL.path,
                                  sizeX: params.sizeX,
                                  sizeY: params.sizeY,
                                  sizeZ: params.sizeZ,
                                  logger: logger)
      return "Scalar UInt32 full-range test data"
    case .DoubleFractalData:
      try computeMandelbulb(filename: outputURL.path,
                            sizeX: params.sizeX,
                            sizeY: params.sizeY,
                            sizeZ: params.sizeZ,
                            bytesPerVoxel: params.byteDepth,
                            logger: logger)
      return "Double-precision CPU Mandelbulb"
    case .FloatFractalData:
      let backend = try computeMandelbulbFloat(filename: outputURL.path,
                                               sizeX: params.sizeX,
                                               sizeY: params.sizeY,
                                               sizeZ: params.sizeZ,
                                               bytesPerVoxel: params.byteDepth,
                                               logger: logger)
      return backend.metaDescription
    case .QuaternionJuliaData,
         .MandelboxData,
         .GyroidData,
         .SheppLoganData,
         .FrequencyChirpData:
      guard let kind = datasetType.analyticKind else {
        preconditionFailure("Missing analytical volume kind")
      }
      let backend = try computeAnalyticVolume(
        kind: kind,
        filename: outputURL.path,
        sizeX: params.sizeX,
        sizeY: params.sizeY,
        sizeZ: params.sizeZ,
        bytesPerVoxel: params.byteDepth,
        brickStride: params.common.maxBrickSize - 2 * params.common.overlap,
        logger: logger
      )
      return "\(kind.displayName), generated using \(backend.displayName)"
  }
}

private func interleaveVolumeChannels(inputURLs: [URL],
                                      outputURL: URL,
                                      voxelCount: Int,
                                      bytesPerComponent: Int) throws {
  precondition(!inputURLs.isEmpty)
  if inputURLs.count == 1 {
    try FileManager.default.copyItem(at: inputURLs[0], to: outputURL)
    return
  }

  let inputFiles = try inputURLs.map { try MemoryMappedFile(filename: $0.path) }
  defer {
    for inputFile in inputFiles {
      try? inputFile.close()
    }
  }

  let expectedChannelSize = Int64(voxelCount * bytesPerComponent)
  guard inputFiles.allSatisfy({ $0.fileSize == expectedChannelSize }) else {
    throw CocoaError(.fileReadCorruptFile)
  }

  let outputFile = try MemoryMappedFile(
    filename: outputURL.path,
    size: expectedChannelSize * Int64(inputFiles.count)
  )
  defer { try? outputFile.close() }

  let sourceAddresses = inputFiles.map { UInt(bitPattern: $0.mappedMemory) }
  let outputAddress = UInt(bitPattern: outputFile.mappedMemory)
  let workerCount = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), voxelCount)
  let voxelsPerWorker = (voxelCount + workerCount - 1) / workerCount

  DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
    let start = worker * voxelsPerWorker
    let end = min(start + voxelsPerWorker, voxelCount)
    guard start < end,
          let outputPointer = UnsafeMutableRawPointer(bitPattern: outputAddress) else { return }

    switch bytesPerComponent {
      case 1:
        let destination = outputPointer.assumingMemoryBound(to: UInt8.self)
        let sources = sourceAddresses.compactMap {
          UnsafeRawPointer(bitPattern: $0)?.assumingMemoryBound(to: UInt8.self)
        }
        guard sources.count == inputFiles.count else { return }
        for voxel in start..<end {
          let destinationBase = voxel * sources.count
          for channel in sources.indices {
            destination[destinationBase + channel] = sources[channel][voxel]
          }
        }
      case 2:
        let destination = outputPointer.assumingMemoryBound(to: UInt16.self)
        let sources = sourceAddresses.compactMap {
          UnsafeRawPointer(bitPattern: $0)?.assumingMemoryBound(to: UInt16.self)
        }
        guard sources.count == inputFiles.count else { return }
        for voxel in start..<end {
          let destinationBase = voxel * sources.count
          for channel in sources.indices {
            destination[destinationBase + channel] = sources[channel][voxel]
          }
        }
      default:
        for voxel in start..<end {
          for channel in sourceAddresses.indices {
            guard let source = UnsafeRawPointer(bitPattern: sourceAddresses[channel]) else {
              continue
            }
            outputPointer.advanced(
              by: (voxel * sourceAddresses.count + channel) * bytesPerComponent
            ).copyMemory(
              from: source.advanced(by: voxel * bytesPerComponent),
              byteCount: bytesPerComponent
            )
          }
        }
    }
  }
}

/**
 Generates a synthetic volume dataset and converts it into the BorgVR file format.

 Depending on the specified dataset type, this function generates linear or Mandelbulb volume data, writes the raw data
 to a temporary file, and then converts the raw volume to the BorgVR format.

 - Parameter params: The parameters for demo data creation.
 */
func generateVolume(_ params: CreateModeParameters) {
  do {
    let tempDir = FileManager.default.temporaryDirectory
    let uuid = UUID().uuidString
    let tempURL = tempDir.appendingPathComponent(uuid)

    logger.info("Generating \(params.componentCount)-channel volume...")

    let channelURLs = params.datasetTypes.indices.map {
      tempDir.appendingPathComponent("\(uuid)-channel-\($0)")
    }
    defer {
      try? FileManager.default.removeItem(at: tempURL)
      for channelURL in channelURLs {
        try? FileManager.default.removeItem(at: channelURL)
        try? FileManager.default.removeItem(
          at: channelURL.deletingPathExtension().appendingPathExtension("dat")
        )
      }
    }

    var channelDescriptions: [String] = []
    var generationProvenance: [BORGVRProvenanceEntry] = []
    for (channel, datasetType) in params.datasetTypes.enumerated() {
      logger.info("Generating channel \(channel + 1)/\(params.componentCount): \(datasetType.displayName)")
      channelDescriptions.append(
        try generateScalarVolume(
          datasetType: datasetType,
          outputURL: channelURLs[channel],
          params: params
        )
      )
      generationProvenance.append(BORGVRProvenanceEntry(
        "Generated channel \(channel) using \(ConverterInfo.toolIdentification); algorithm=\(datasetType.rawValue); grid=\(params.sizeX)x\(params.sizeY)x\(params.sizeZ); output=UInt\(params.byteDepth * 8); backend=\(channelDescriptions[channel]); " +
        datasetType.generationParameters(bytesPerComponent: params.byteDepth,
                                         brickStride: params.common.maxBrickSize - 2 * params.common.overlap)
      ))
    }

    try interleaveVolumeChannels(
      inputURLs: channelURLs,
      outputURL: tempURL,
      voxelCount: params.sizeX * params.sizeY * params.sizeZ,
      bytesPerComponent: params.byteDepth
    )
    let metaDesc = channelDescriptions.enumerated().map {
      "Channel \($0.offset): \($0.element)"
    }.joined(separator: "; ")

    logger.info("Converting generated volume to BorgVR file format ...")

    try convertRawVolume(inputFilename: tempURL.path,
                         offset: 0,
                         size: Vec3<Int>(x: params.sizeX, y: params.sizeY, z: params.sizeZ),
                         maxBrickSize: params.common.maxBrickSize,
                         bytesPerComponent: params.byteDepth,
                         componentCount: params.componentCount,
                         voxelSpacing: Vec3<Float>(
                           x: 1 / Float(params.sizeX),
                           y: 1 / Float(params.sizeY),
                           z: 1 / Float(params.sizeZ)
                         ),
                         overlap: params.common.overlap,
                         outputFilename: params.common.outputFilename,
                         datasetDescription: params.common.datasetDescription,
                         metaDescription: metaDesc,
                         provenance: conversionProvenance + generationProvenance)

  } catch {
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
  }
}

let timer = HighResolutionTimer()
timer.start()
logger.setMinimumLogLevel(.info)
#if DEBUG
logger.warning("Running in debug mode. The program will perform significantly slower as in release mode.")
#endif
// Parse command-line arguments and execute the corresponding conversion or generation.
let importOptions = parseImportOptions(CommandLine.arguments)
let conversionProvenance = importOptions.provenance
let conversionSizeXMeters = importOptions.sizeXMeters
let forceConversionSizeX = importOptions.forceSizeX
let conversionColorCompression = importOptions.colorCompression
let conversionUseLZ4 = importOptions.useLZ4
let conversionQuantizeTo8Bit = importOptions.quantizeTo8Bit
let (mode, params) = parseArguments(importOptions.arguments)
switch mode {
  case .DicomConversion, .ImageSequenceConversion:
    guard let params = params as? DicomModeParameters else { exit(1) }
    convertDICOMStack(params)
  case .DemoDataCreation:
    guard let params = params as? CreateModeParameters else { exit(1) }
    generateVolume(params)
  case .QVISConversion:
    guard let params = params as? HeaderFileModeParameters else { exit(1) }
    convertQVISVolume(params)
  case .NRRDConversion:
    guard let params = params as? HeaderFileModeParameters else { exit(1) }
    convertNRRDVolume(params)
  case .PVMConversion:
    guard let params = params as? HeaderFileModeParameters else { exit(1) }
    convertPVMVolume(params)
  case .I3MConversion:
    guard let params = params as? HeaderFileModeParameters else { exit(1) }
    convertFileVolume(params, formatName: "IV3Dm")
  case .ZarrConversion:
    guard let params = params as? HeaderFileModeParameters else { exit(1) }
    convertFileVolume(params, formatName: "Zarr")
  case .UVFConversion:
    guard let params = params as? HeaderFileModeParameters else { exit(1) }
    convertFileVolume(params, formatName: "UVF")
  case .VFFConversion:
    guard let params = params as? HeaderFileModeParameters else { exit(1) }
    convertFileVolume(params, formatName: "VFF")
  case .FlatVolumeExport:
    guard let params = params as? ExportModeParameters else { exit(1) }
    exportFlatVolume(params)
  case .BorgVRRepacking:
    guard let params = params as? RepackModeParameters else { exit(1) }
    repackBorgVRVolume(params)
}

let total = timer.stop()
logger.info("Time elapsed: \(total) seconds")

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use,
 copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
 Software, and to permit persons to whom the Software is furnished to do so, subject
 to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

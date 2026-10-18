import Foundation

enum ConverterInfo {
  static let version = "3.0"

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
  case QVISConversion = "Q"
  case NRRDConversion = "N"
  case PVMConversion = "P"
  case FlatVolumeExport = "E"
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

/// A usage error message displayed when invalid parameters are provided.
let executableName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let usageErrorMessage = """
Invalid parameters.
Usage:

General
    \(executableName) --help | -h
    \(executableName) --version | -v

Mode D — Read DICOM files from a directory
    \(executableName) D <input_directory> <output_filename> <description> <max_brick_size> <overlap>
        input_directory   : Path to the directory containing DICOM files
        output_filename   : Name of the output file to create
        description       : Short description of the dataset
        max_brick_size    : Positive integer specifying the maximum brick size
        overlap           : Positive integer specifying the overlap between bricks

Mode Q — Read a QVIS file
    \(executableName) Q <input_filename> <output_filename> <description> <max_brick_size> <overlap>
        input_filename    : Path to the QVIS file
        output_filename   : Name of the output file to create
        description       : Short description of the dataset
        max_brick_size    : Positive integer specifying the maximum brick size
        overlap           : Positive integer specifying the overlap between bricks

Mode N — Read a NRRD or NHDR file
    \(executableName) N <input_filename> <output_filename> <description> <max_brick_size> <overlap>
        input_filename    : Path to the NRRD or NHDR file
        output_filename   : Name of the output file to create
        description       : Short description of the dataset
        max_brick_size    : Positive integer specifying the maximum brick size
        overlap           : Positive integer specifying the overlap between bricks

Mode P — Read a PVM, PVM2, or PVM3 file
    \(executableName) P <input_filename> <output_filename> <description> <max_brick_size> <overlap>
        input_filename    : Path to the PVM file (plain, DDS v3d, or DDS v3e)
        output_filename   : Name of the output file to create
        description       : Short description of the dataset
        max_brick_size    : Positive integer specifying the maximum brick size
        overlap           : Positive integer specifying the overlap between bricks

Mode E — Export one BorgVR LoD as an uncompressed NRRD volume
    \(executableName) E <input_filename> <output_filename> <lod>
        input_filename    : Path to the BorgVR .data file
        output_filename   : Name of the uncompressed inline .nrrd file to create
        lod               : LoD to export; 0 is the full-resolution original

Mode C — Create a volume file using a specified algorithm
    \(executableName) C <algorithm> <byte_depth> <component_count> <size_x> <size_y> <size_z> <output_filename> <description> <max_brick_size> <overlap>
        algorithm         : One algorithm for every channel, or a comma-separated list
                            with one algorithm per channel (for example F,J)
                            The list order defines channel 0, channel 1, and so on
                            L = linear
                            F = Float Mandelbulb with automatic Metal acceleration
                            D = Double CPU Mandelbulb
                            J = Quaternion sine Julia set
                            B = Mandelbox
                            G = Gyroid
                            P = 3D Shepp-Logan phantom
                            T = Frequency chirp and brick-boundary test
                            U = Scalar UInt32 full-range test volume
        byte_depth        : Bytes per component (1, 2, or 4)
        component_count   : Number of volume channels (1 through 4)
        size_x            : Volume size along X (positive integer)
        size_y            : Volume size along Y (positive integer)
        size_z            : Volume size along Z (positive integer)
        output_filename   : Name of the output volume file
        description       : Short description of the dataset
        max_brick_size    : Positive integer specifying the maximum brick size
        overlap           : Positive integer specifying the overlap between bricks
"""

print(ConverterInfo.banner)

if CommandLine.arguments.count == 2 {
  switch CommandLine.arguments[1] {
    case "--version", "-v":
      exit(0)
    case "--help", "-h":
      print(usageErrorMessage.replacingOccurrences(of: "Invalid parameters.\n", with: ""))
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
    logger.error(usageErrorMessage)
    exit(1)
  }

  result.0 = mode

  switch mode {
    case .DicomConversion:
      guard args.count == 7 else {
        logger.error("Error: Invalid number of arguments for mode D.\n\(usageErrorMessage)")
        exit(1)
      }
      guard let maxBrickSize = Int(args[5]), maxBrickSize > 0,
            let overlap = Int(args[6]), overlap > 0,
            overlap * 2 < maxBrickSize else {
        logger.error("Error: maxBrickSize and overlap must be positive, and twice the overlap must be smaller than the brick size.")
        exit(1)
      }
      let params = DicomModeParameters(
        inputDirectory: args[2],
        common: CommonParameters(
          outputFilename: args[3],
          datasetDescription: args[4],
          maxBrickSize: maxBrickSize,
          overlap: overlap
        )
      )
      result.1 = params

    case .QVISConversion, .NRRDConversion, .PVMConversion:
      guard args.count == 7 else {
        logger.error("Error: Invalid number of arguments for mode Q, N, or P.\n\(usageErrorMessage)")
        exit(1)
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
        logger.error("Error: Invalid arguments for mode E.\n\(usageErrorMessage)")
        exit(1)
      }
      result.1 = ExportModeParameters(
        inputFilename: args[2],
        outputFilename: args[3],
        level: level
      )

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
        logger.error("Error: Invalid arguments for mode C.\n\(usageErrorMessage)")
        exit(1)
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
                      metaDescription:String) throws {
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
        useCompression: true,
        extensionStrategy: .fillZeroes
      )
    ),
    logger: logger
  )
}

func convertDICOMStack(_ params: DicomModeParameters) {
  do {
    try BorgVRVolumeConversionService.convert(
      BorgVRVolumeConversionRequest(
        source: .dicomDirectory(
          URL(fileURLWithPath: params.inputDirectory, isDirectory: true)
        ),
        destinationURL: URL(fileURLWithPath: params.common.outputFilename),
        datasetDescription: params.common.datasetDescription,
        metaDescription: "",
        settings: conversionSettings(for: params.common)
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

private func convertFileVolume(_ params: HeaderFileModeParameters, formatName: String) {
  do {
    let sourceURL = URL(fileURLWithPath: params.inputFilename)
    try BorgVRVolumeConversionService.convert(
      BorgVRVolumeConversionRequest(
        source: .file(sourceURL),
        destinationURL: URL(fileURLWithPath: params.common.outputFilename),
        datasetDescription: params.common.datasetDescription,
        metaDescription: "Converted from \(formatName) Volume \(sourceURL.deletingPathExtension().lastPathComponent)",
        settings: conversionSettings(for: params.common)
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
    useCompression: true,
    extensionStrategy: .fillZeroes
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
    for (channel, datasetType) in params.datasetTypes.enumerated() {
      logger.info("Generating channel \(channel + 1)/\(params.componentCount): \(datasetType.displayName)")
      channelDescriptions.append(
        try generateScalarVolume(
          datasetType: datasetType,
          outputURL: channelURLs[channel],
          params: params
        )
      )
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
                         metaDescription: metaDesc)

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
let (mode, params) = parseArguments(CommandLine.arguments)
switch mode {
  case .DicomConversion:
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
  case .FlatVolumeExport:
    guard let params = params as? ExportModeParameters else { exit(1) }
    exportFlatVolume(params)
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

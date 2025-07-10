import Foundation

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
  case DemoDataCreation = "C"
}

/**
 An enum representing the types of datasets for demo data creation.

 - LinearData: A dataset with linearly increasing values.
 - FractalData: A dataset based on fractal (e.g., Mandelbulb) computation.
 */
enum DatasetType: String {
  case LinearData = "L"
  case FractalData = "F"
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

/**
 Parameters specific to demo data creation mode.

 - datasetType: The type of dataset to generate (LinearData or FractalData).
 - byteDepth: The bit depth per voxel.
 - componentCount: The number of components per voxel.
 - sizeX: The volume size along the X axis.
 - sizeY: The volume size along the Y axis.
 - sizeZ: The volume size along the Z axis.
 - common: Shared parameters such as output filename and brick configuration.
 */
struct CreateModeParameters {
  let datasetType: DatasetType
  let byteDepth: Int
  let componentCount: Int
  let sizeX: Int
  let sizeY: Int
  let sizeZ: Int
  let common: CommonParameters
}

/// A usage error message displayed when invalid parameters are provided.
let usageErrorMessage = """
Invalid parameters.
Usage:

Mode D — Read DICOM files from a directory
    (args[0]) D <input_directory> <output_filename> <description> <max_brick_size> <overlap>
        input_directory   : Path to the directory containing DICOM files
        output_filename   : Name of the output file to create
        description       : Short description of the dataset
        max_brick_size    : Positive integer specifying the maximum brick size
        overlap           : Positive integer specifying the overlap between bricks

Mode Q — Read a QVIS file
    (args[0]) Q <input_filename> <output_filename> <description> <max_brick_size> <overlap>
        input_filename    : Path to the QVIS file
        output_filename   : Name of the output file to create
        description       : Short description of the dataset
        max_brick_size    : Positive integer specifying the maximum brick size
        overlap           : Positive integer specifying the overlap between bricks

Mode N — Read a NRRD or NHDR file
    (args[0]) N <input_filename> <output_filename> <description> <max_brick_size> <overlap>
        input_filename    : Path to the QVIS file
        output_filename   : Name of the output file to create
        description       : Short description of the dataset
        max_brick_size    : Positive integer specifying the maximum brick size
        overlap           : Positive integer specifying the overlap between bricks

Mode C — Create a volume file using a specified algorithm
    (args[0]) C <L|F> <byte_depth> <component_count> <size_x> <size_y> <size_z> <output_filename> <description> <max_brick_size> <overlap>
        L or F            : Choose generation algorithm ('L' = linearly increasing, 'F' = Mandelbulb)
        byte_depth        : Bit depth per voxel (e.g., 1, 2)
        component_count   : Number of components per voxel (e.g., 1 for grayscale, 3 for RGB)
        size_x            : Volume size along X (positive integer)
        size_y            : Volume size along Y (positive integer)
        size_z            : Volume size along Z (positive integer)
        output_filename   : Name of the output volume file
        description       : Short description of the dataset
        max_brick_size    : Positive integer specifying the maximum brick size
        overlap           : Positive integer specifying the overlap between bricks
"""

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
            let overlap = Int(args[6]), overlap > 0 else {
        logger.error("Error: maxBrickSize and overlap must be positive integers.")
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

    case .QVISConversion, .NRRDConversion:
      guard args.count == 7 else {
        logger.error("Error: Invalid number of arguments for mode Q or N.\n\(usageErrorMessage)")
        exit(1)
      }
      guard let maxBrickSize = Int(args[5]), maxBrickSize > 0,
            let overlap = Int(args[6]), overlap > 0 else {
        logger.error("Error: maxBrickSize and overlap must be positive integers.")
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

    case .DemoDataCreation:
      guard args.count == 12,
            let datasetType = DatasetType(rawValue: args[2]),
            let byteDepth = Int(args[3]),
            let componentCount = Int(args[4]),
            let sizeX = Int(args[5]), sizeX > 0,
            let sizeY = Int(args[6]), sizeY > 0,
            let sizeZ = Int(args[7]), sizeZ > 0,
            let maxBrickSize = Int(args[10]), maxBrickSize > 0,
            let overlap = Int(args[11]), overlap > 0
      else {
        logger.error("Error: Invalid arguments for mode C.\n\(usageErrorMessage)")
        exit(1)
      }
      let params = CreateModeParameters(
        datasetType: datasetType,
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

/**
 Converts a raw volume file into the BorgVR file format.

 This function reads volume data from a raw file using a `RawFileAccessor` and then uses a `BrickedVolumeReorganizer`
 to partition the volume into bricks. The reorganized data is written to an output file.

 - Parameters:
 - inputFilename: The path to the raw input volume file.
 - size: A vector representing the dimensions (width, height, depth) of the volume.
 - maxBrickSize: The maximum brick size to use for partitioning the volume.
 - bytesPerVoxel: The number of bytes per voxel in the volume.
 - aspect: A vector representing the aspect ratio scaling for the volume.
 - overlap: The overlap between adjacent bricks.
 - outputFilename: The name of the output file to create.
 - description: A short description of the dataset.
 - Throws: An error if reading or reorganizing the volume fails.
 */
func convertRawVolume(inputFilename: String,
                      offset: Int,
                      size: Vec3<Int>,
                      maxBrickSize: Int,
                      bytesPerVoxel: Int,
                      aspect: Vec3<Float>,
                      overlap: Int,
                      outputFilename: String,
                      datasetDescription: String) throws {
  let volume = try RawFileAccessor(
    filename: inputFilename,
    size: size,
    bytesPerComponent: bytesPerVoxel,
    componentCount: 1,
    aspect: aspect,
    offset: offset,
    readOnly: true
  )

  // Create a reorganizer to partition the volume into bricks.
  let reorganizer = BrickedVolumeReorganizer(
    inputVolume: volume,
    brickSize: maxBrickSize,
    overlap: overlap,
    extensionStrategy: .fillZeroes
  )
  try reorganizer
    .reorganize(
      to: outputFilename,
      datasetDescription: datasetDescription,
      useCompressor: true,
      logger: logger
    )
}

/**
 Converts a DICOM dataset from a specified directory into a BorgVR file format.

 This function scans the input directory for DICOM files, decodes them into a volume,
 writes the raw volume to a temporary file, and then converts the raw volume to the BorgVR format.

 - Parameter params: The parameters for DICOM conversion.
 */
func convertDICOMStack(_ params: DicomModeParameters) {
  let directory = URL(fileURLWithPath: params.inputDirectory, isDirectory: true)

  do {
    let fileManager = FileManager.default
    let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let dicomFiles = files.filter { $0.isFileURL }

    logger.info("Scanning directory for DICOM files...")

    guard !dicomFiles.isEmpty else {
      logger.error("No files found in directory.")
      exit(1)
    }

    logger.info(String(format: "Found %d DICOM files.", dicomFiles.count))

    let dicomVolume = try DicomParser.decodeVolume(from: dicomFiles)

    let tempDir = FileManager.default.temporaryDirectory
    let uuid = UUID().uuidString
    let tempURL = tempDir.appendingPathComponent(uuid)

    logger.info("Converting DICOM stack to temporary raw file...")

    try dicomVolume.voxelData.withUnsafeBytes { try Data($0).write(to: tempURL) }

    logger.info("Converting raw file to BorgVR file format...")

    try convertRawVolume(inputFilename: tempURL.path,
                         offset: 0,
                         size: Vec3<Int>(x: dicomVolume.width,
                                         y: dicomVolume.height,
                                         z: dicomVolume.depth),
                         maxBrickSize: params.common.maxBrickSize,
                         bytesPerVoxel: dicomVolume.bytesPerVoxel,
                         aspect: Vec3<Float>(x: dicomVolume.scale.x,
                                             y: dicomVolume.scale.y,
                                             z: dicomVolume.scale.z),
                         overlap: params.common.overlap,
                         outputFilename: params.common.outputFilename,
                         datasetDescription: params.common.datasetDescription)

    try FileManager.default.removeItem(at: tempURL)
  } catch {
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
  }
}

/**
 Converts a NRRD volume file into the BorgVR file format.

 This function opens a NRRD volume using a header parser, determines the associated raw volume file,
 and then converts the raw volume to the BorgVR format.

 - Parameter params: The parameters for NRRD conversion.
 */
func convertNRRDVolume(_ params: HeaderFileModeParameters) {
  do {
    logger.info("Opening NRRD volume ...")

    let parser = try NRRDParser(filename: params.inputFilename)

    logger.info("Converting NRRD volume to BorgVR file format ...")

    try convertRawVolume(inputFilename: parser.absoluteFilename,
                         offset: parser.offset,
                         size: parser.size,
                         maxBrickSize: params.common.maxBrickSize,
                         bytesPerVoxel: parser.bytesPerComponent,
                         aspect: parser.sliceThickness,
                         overlap: params.common.overlap,
                         outputFilename: params.common.outputFilename,
                         datasetDescription: params.common.datasetDescription)

    if parser.dataIsTempCopy {
      try FileManager.default.removeItem(at: URL(fileURLWithPath: parser.absoluteFilename))
    }
  } catch {
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
  }
}


/**
 Converts a QVIS volume file into the BorgVR file format.

 This function opens a QVIS volume using a header parser, determines the associated raw volume file,
 and then converts the raw volume to the BorgVR format.

 - Parameter params: The parameters for QVIS conversion.
 */
func convertQVISVolume(_ params: HeaderFileModeParameters) {
  do {
    logger.info("Opening QVIS volume ...")

    let parser = try QVISParser(filename: params.inputFilename)

    logger.info("Converting QVIS volume to BorgVR file format ...")

    try convertRawVolume(inputFilename: parser.absoluteFilename,
                         offset: 0,
                         size: parser.size,
                         maxBrickSize: params.common.maxBrickSize,
                         bytesPerVoxel: parser.bytesPerComponent,
                         aspect: parser.sliceThickness,
                         overlap: params.common.overlap,
                         outputFilename: params.common.outputFilename,
                         datasetDescription: params.common.datasetDescription)
  } catch {
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
  }
}

/**
 Generates a synthetic volume dataset and converts it into the BorgVR file format.

 Depending on the specified dataset type (LinearData or FractalData), this function generates volume data using the
 appropriate algorithm, writes the raw data to a temporary file, and then converts the raw volume to the BorgVR format.

 - Parameter params: The parameters for demo data creation.
 */
func generateVolume(_ params: CreateModeParameters) {
  do {
    let tempDir = FileManager.default.temporaryDirectory
    let uuid = UUID().uuidString
    let tempURL = tempDir.appendingPathComponent(uuid)

    logger.info("Generating volume...")

    switch params.datasetType {
      case .LinearData:
        try computeLinear(filename: tempURL.path,
                          sizeX: params.sizeX,
                          sizeY: params.sizeY,
                          sizeZ: params.sizeZ,
                          bytesPerVoxel: params.byteDepth,
                          componentCount: params.componentCount,
                          logger: logger)
      case .FractalData:
        try computeMandelbulb(filename: tempURL.path,
                              sizeX: params.sizeX,
                              sizeY: params.sizeY,
                              sizeZ: params.sizeZ,
                              bytesPerVoxel: params.byteDepth,
                              logger: logger)
    }

    logger.info("Converting generated volume to BorgVR file format ...")

    try convertRawVolume(inputFilename: tempURL.path,
                         offset: 0,
                         size: Vec3<Int>(x: params.sizeX, y: params.sizeY, z: params.sizeZ),
                         maxBrickSize: params.common.maxBrickSize,
                         bytesPerVoxel: params.byteDepth,
                         aspect: Vec3<Float>(x: 1, y: 1, z: 1),
                         overlap: params.common.overlap,
                         outputFilename: params.common.outputFilename,
                         datasetDescription: params.common.datasetDescription)

    try FileManager.default.removeItem(at: tempURL)
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
}
let total = timer.stop()
logger.info("Time elapsed: \(total) seconds")

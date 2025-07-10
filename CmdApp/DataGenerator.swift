import Foundation

// MARK: - Mandelbulb Utility Functions

/**
 Computes the Euclidean radius of the point (x, y, z).

 - Parameters:
 - x: The x-coordinate.
 - y: The y-coordinate.
 - z: The z-coordinate.
 - Returns: The Euclidean distance from the origin.
 */
func radius(_ x: Double, _ y: Double, _ z: Double) -> Double {
  return sqrt(x * x + y * y + z * z)
}

/**
 Computes the azimuthal angle (phi) in radians for the point (x, y).

 - Parameters:
 - x: The x-coordinate.
 - y: The y-coordinate.
 - Returns: The angle in radians from the x-axis toward the y-axis.
 */
func phi(_ x: Double, _ y: Double) -> Double {
  return atan2(y, x)
}

/**
 Computes the polar angle (theta) in radians for the point (x, y, z).

 - Parameters:
 - x: The x-coordinate.
 - y: The y-coordinate.
 - z: The z-coordinate.
 - Returns: The angle in radians from the positive z-axis.
 */
func theta(_ x: Double, _ y: Double, _ z: Double) -> Double {
  return atan2(sqrt(x * x + y * y), z)
}

/**
 Computes the new x-coordinate value for the Mandelbulb iteration.

 - Parameters:
 - x: The current x-coordinate.
 - y: The current y-coordinate.
 - z: The current z-coordinate.
 - cx: The original x-coordinate offset.
 - n: The Mandelbulb exponent.
 - power: The computed power value (usually pow(r, n)).
 - Returns: The updated x-coordinate.
 */
func powerX(_ x: Double, _ y: Double, _ z: Double, _ cx: Double, _ n: Int, _ power: Double) -> Double {
  return cx + power * sin(theta(x, y, z) * Double(n)) * cos(phi(x, y) * Double(n))
}

/**
 Computes the new y-coordinate value for the Mandelbulb iteration.

 - Parameters:
 - x: The current x-coordinate.
 - y: The current y-coordinate.
 - z: The current z-coordinate.
 - cy: The original y-coordinate offset.
 - n: The Mandelbulb exponent.
 - power: The computed power value (usually pow(r, n)).
 - Returns: The updated y-coordinate.
 */
func powerY(_ x: Double, _ y: Double, _ z: Double, _ cy: Double, _ n: Int, _ power: Double) -> Double {
  return cy + power * sin(theta(x, y, z) * Double(n)) * sin(phi(x, y) * Double(n))
}

/**
 Computes the new z-coordinate value for the Mandelbulb iteration.

 - Parameters:
 - x: The current x-coordinate.
 - y: The current y-coordinate.
 - z: The current z-coordinate.
 - cz: The original z-coordinate offset.
 - n: The Mandelbulb exponent.
 - power: The computed power value (usually pow(r, n)).
 - Returns: The updated z-coordinate.
 */
func powerZ(_ x: Double, _ y: Double, _ z: Double, _ cz: Double, _ n: Int, _ power: Double) -> Double {
  return cz + power * cos(theta(x, y, z) * Double(n))
}

/**
 Computes the number of iterations for a Mandelbulb fractal for the given point.

 The algorithm iterates a complex transformation until the computed radius exceeds a bailout value,
 or until the maximum number of iterations is reached.

 - Parameters:
 - sx: The x-coordinate of the starting point.
 - sy: The y-coordinate of the starting point.
 - sz: The z-coordinate of the starting point.
 - n: The Mandelbulb exponent.
 - iMaxIterations: The maximum number of iterations allowed.
 - fBailout: The bailout threshold (if the radius exceeds this, iteration stops).
 - Returns: The number of iterations before the bailout condition is met (or iMaxIterations if never met).
 */
func computeMandelbulb(_ sx: Double, _ sy: Double, _ sz: Double,
                       _ n: Int, _ iMaxIterations: Int, _ fBailout: Double) -> Int {
  var fx: Double = 0
  var fy: Double = 0
  var fz: Double = 0
  var r: Double = radius(fx, fy, fz)

  for i in 0...iMaxIterations {
    let fPower = pow(r, Double(n))
    let fx_ = powerX(fx, fy, fz, sx, n, fPower)
    let fy_ = powerY(fx, fy, fz, sy, n, fPower)
    let fz_ = powerZ(fx, fy, fz, sz, n, fPower)

    fx = fx_
    fy = fy_
    fz = fz_
    r = radius(fx, fy, fz)

    if r > fBailout {
      return i
    }
  }
  return iMaxIterations
}

/**
 A convenience overload for computing the Mandelbulb fractal for a grid point.

 Converts grid coordinates (as UInt64) to a point in 3D space, and then computes the Mandelbulb iteration count.

 - Parameters:
 - sx: The x-coordinate on the grid.
 - sy: The y-coordinate on the grid.
 - sz: The z-coordinate on the grid.
 - n: The Mandelbulb exponent as UInt32.
 - iMaxIterations: The maximum number of iterations.
 - fBailout: The bailout threshold.
 - vTotalSize: The overall grid size as an IVec3.
 - Returns: The number of iterations computed for the point.
 */
func computeMandelbulb(_ sx: UInt64, _ sy: UInt64, _ sz: UInt64,
                       _ n: UInt32, _ iMaxIterations: Int,
                       _ fBailout: Double, _ vTotalSize: IVec3) -> Int {
  let bulbSize: Double = 2.25

  // Map grid coordinates to a point in 3D space.
  let x = bulbSize * Double(sx) / Double(vTotalSize.x - 1) - bulbSize / 2.0
  let y = bulbSize * Double(sy) / Double(vTotalSize.y - 1) - bulbSize / 2.0
  let z = bulbSize * Double(sz) / Double(vTotalSize.z - 1) - bulbSize / 2.0

  return computeMandelbulb(x, y, z, Int(n), iMaxIterations, fBailout)
}

// MARK: - File Output Functions

/**
 Generates a Mandelbulb fractal file by computing iteration counts for each point in a 3D grid,
 and writes the results as UInt8 values to a binary file.

 - Parameters:
 - filename: The output filename.
 - sizeX: The width in voxel
 - sizeY: The height in voxel
 - sizeZ: The depth in voxel
 - logger: An optional logger for progress and info messages.
 - bytesPerVoxel: 1=byte, 2=short, 4=int
 - Throws: An error if the file cannot be written or if a memory mapping error occurs.
 */
func computeMandelbulb(filename: String, sizeX: Int, sizeY: Int, sizeZ: Int,
                       bytesPerVoxel: Int, logger: LoggerBase? = nil) throws {
  let maxIterations: Int = (1 << (8*bytesPerVoxel) )-1    // Maximum iterations allowed.
  let bailout: Double = 100.0       // Bailout threshold.
  let n: Int = 8                  // Mandelbulb exponent.

  // Define the total grid size as a 3D vector.
  let totalSize = IVec3(x: sizeX, y: sizeY, z: sizeZ)

  // Open the file for writing in binary mode.
  let fileURL = URL(fileURLWithPath: filename)
  let memoryMappedFile = try MemoryMappedFile(filename: fileURL.path(), size: Int64(sizeX*sizeY*sizeZ*bytesPerVoxel))
  defer { try? memoryMappedFile.close() }

  let pointer = memoryMappedFile.mappedMemory

  // Loop over the 3D grid.
  for z in 0..<sizeZ {
    logger?.progress("Generating Mandelbulb", Double(z) / Double(sizeZ - 1))
    // Use concurrent processing on the y-dimension.
    DispatchQueue.concurrentPerform(iterations: sizeY) { y in
      for x in 0..<sizeX {
        // Compute the iteration count for the current point.
        let iterations = computeMandelbulb(UInt64(x),
                                           UInt64(y),
                                           UInt64(z),
                                           UInt32(n),
                                           maxIterations,
                                           bailout,
                                           totalSize)
        let pos = z * sizeY * sizeX + y * sizeX + x

        switch bytesPerVoxel {
          case 1:
            pointer.advanced(by: pos).storeBytes(of: UInt8(iterations), as: UInt8.self)
          case 2:
            pointer.advanced(by: pos*2).storeBytes(of: UInt16(iterations), as: UInt16.self)
          case 4:
            pointer.advanced(by: pos*4).storeBytes(of: UInt32(iterations), as: UInt32.self)
          default:
            fatalError("Unsupported bytes per voxel: \(bytesPerVoxel)")
        }
      }
    }
  }
  logger?.info("Finished writing Mandelbulb data to \(filename)")
  logger?.info("Writing metadata file...")
  writeMetadataFile(
    filename: filename,
    sizeX: sizeX,
    sizeY: sizeY,
    sizeZ: sizeZ,
    bytesPerVoxel: bytesPerVoxel,
    componentCount: 1
  )
}

/**
 Writes a metadata file for the generated Mandelbulb dataset.

 The metadata file contains information about the object file name, resolution, slice thickness,
 and other properties in a plain text format.

 - Parameters:
 - filename: The base filename (the metadata file will have the extension ".dat").
 - sizeX: The width in voxel
 - sizeY: The height in voxel
 - sizeZ: The depth in voxel
 - bytesPerVoxel: 1=byte, 2=short, 4=int
 - componentCount: number of voxel components
 */
func writeMetadataFile(filename: String, sizeX: Int, sizeY: Int, sizeZ: Int,
                       bytesPerVoxel: Int, componentCount: Int) {
  let metadataFilename = filename + ".dat"

  let format: String = {
    switch bytesPerVoxel {
    case 1:
      return "UCHAR"
    case 2:
      return "USHORT"
    case 4:
      return "UINT"
    default:
      fatalError("Unsupported bytes per voxel: \(bytesPerVoxel)")
    }
  }()

  let metadataContent = """
    ObjectFileName: \(filename)
    TaggedFileName: ---
    Resolution:     \(sizeX) \(sizeY) \(sizeZ)
    Components:     \(componentCount)
    SliceThickness: 1 1 1
    Format:         \(format)
    NbrTags:        0
    ObjectType:     TEXTURE_VOLUME_OBJECT
    ObjectModel:    RGBA
    GridType:       EQUIDISTANT
    """
  let metadataURL = URL(fileURLWithPath: metadataFilename)
  do {
    try metadataContent.write(to: metadataURL, atomically: true, encoding: .utf8)
  } catch {
    print("Error writing metadata file: \(error)")
  }
}

/**
 Generates a linear test file by writing sequential UInt8 values to a binary file.

 Each voxel in the 3D grid is assigned a value based on its position modulo 256.

 - Parameters:
 - filename: The output filename.
 - sizeX: The width in voxel
 - sizeY: The height in voxel
 - sizeZ: The depth in voxel
 - bytesPerVoxel: 1=byte, 2=short, 4=int
 - componentCount: number of voxel components
 - logger: An optional logger for progress and info messages.
 - Throws: An error if the file cannot be written.
 */
func computeLinear(filename: String, sizeX: Int, sizeY: Int, sizeZ: Int,
                   bytesPerVoxel: Int, componentCount: Int,
                   logger: LoggerBase? = nil) throws {
  let fileURL = URL(fileURLWithPath: filename)
  let memoryMappedFile = try MemoryMappedFile(filename: fileURL.path(),
                                              size: Int64(sizeX * sizeY * sizeZ *
                                                          bytesPerVoxel * componentCount))
  defer { try? memoryMappedFile.close() }

  let pointer = memoryMappedFile.mappedMemory

  // Loop over the 3D grid, assigning a value equal to pos % 256.
  for z in 0..<sizeZ {
    if sizeZ > 1 {
      logger?.progress("Generating Linear File", Double(z) / Double(sizeZ - 1))
    }
    DispatchQueue.concurrentPerform(iterations: sizeY) { y in
      for x in 0..<sizeX {
        let pos = z * sizeX * sizeY + y * sizeX + x
        for c in 0..<componentCount {
          switch bytesPerVoxel {
          case 1: pointer.advanced(by: pos*componentCount+c).storeBytes(
            of: UInt8((c+pos) % 256),
            as: UInt8.self
          );
          case 2: pointer.advanced(by: pos*2*componentCount+c*2).storeBytes(
            of: UInt16(c+pos % 65536),
            as: UInt16.self
          );
          case 4: pointer.advanced(by: pos*4*componentCount+c*4).storeBytes(
            of: UInt32((c+pos) % 4294967296),
            as: UInt32.self
          );
          default:
            fatalError("Unsupported bytes per voxel: \(bytesPerVoxel)")
          }
        }
      }
    }
  }
  logger?.info("Finished writing Linear File to \(filename)")
  logger?.info("Writing metadata file...")
  writeMetadataFile(filename: filename, sizeX: sizeX, sizeY: sizeY, sizeZ: sizeZ, bytesPerVoxel: bytesPerVoxel, componentCount: componentCount)
}

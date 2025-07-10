/**
 A local data source for volumetric brick data.

 LocalDataSource conforms to the DataSource protocol and provides access to local
 volumetric data using a BORGVRFileData instance.
 */
final class LocalDataSource: DataSource {

  /// The filename if the local BORGVRFileData
  let filename : String

  /// The underlying BORGVRFileData instance representing the local file.
  let localFile: BORGVRFileData

  /**
   Initializes a new LocalDataSource with the specified filename.

   - Parameter filename: The path to the local BorgVR data file.
   - Throws: An error if BORGVRFileData initialization fails.
   */
  init(filename: String, logger: LoggerBase? = nil) throws {
    try self.localFile = BORGVRFileData(filename: filename)
    self.filename = filename
    logger?.dev("LocalDataSource initialized")
  }

  /**
   Loads a brick from the local data source.

   - Parameters:
   - index: The index of the brick to load.
   - outputBuffer: A pointer to a memory area where the brick data will be written.
   - Throws: An error if the brick cannot be loaded.
   */
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try localFile.getBrick(index: index, outputBuffer: outputBuffer)
  }

  /**
   Loads the first brick from the local data source. In contrast to getBrick, this call is always synchronous.

   - Parameter outputBuffer: A pointer to a memory area where the brick data will be written.
   - Throws: An error if the first brick cannot be loaded.
   */
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try localFile.getFirstBrick(outputBuffer: outputBuffer)
  }

  /**
   Retrieves the metadata for the local dataset.

   - Returns: A BORGVRMetaData instance containing the dataset metadata.
   */
  func getMetadata() -> BORGVRMetaData {
    return localFile.getMetadata()
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 the Software, and to permit persons to whom the Software is furnished to do so,
 subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

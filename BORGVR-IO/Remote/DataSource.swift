/**
 A protocol representing a data source for volumetric brick data.

 This protocol defines the interface for retrieving brick data and dataset metadata.
 */
protocol DataSource {
  /**
   Loads a brick from the dataset at the specified index and writes its data into the
   provided output buffer.

   - Parameters:
   - index: The index of the brick to retrieve.
   - outputBuffer: A pointer to a memory area with sufficient capacity for the brick data.
   - Throws: An error if the brick cannot be loaded.
   */
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws

  /**
   Loads the first brick from the dataset and writes its data into the provided output buffer.
   In contrast to getBrick, this call is always synchronous.

   - Parameter outputBuffer: A pointer to a memory area with sufficient capacity for the brick data.
   - Throws: An error if the brick cannot be loaded.
   */
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws

  /**
   Retrieves the metadata for the dataset.

   - Returns: A `BORGVRMetaData` instance describing the dataset.
   */
  func getMetadata() -> BORGVRMetaData
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University
 of Duisburg-Essen

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

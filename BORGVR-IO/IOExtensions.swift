import Foundation

// MARK: - Data Extension

/**
 Initializes a Data instance from any value by reading its raw bytes.

 - Parameter value: The value to convert to Data.
 */
extension Data {
  init<T>(from value: T) {
    var value = value
    self = Swift.withUnsafeBytes(of: &value) { Data($0) }
  }
}

// MARK: - FileHandle Extensions

/**
 Provides convenience methods on FileHandle for reading and writing basic binary types
 (Float, Int64, Bool) and length-prefixed UTF-8 strings.
 */
extension FileHandle {

  /**
   Reads a 32-bit float from the current file position.

   - Returns: The Float read from the file.
   - Throws: An error if the expected number of bytes cannot be read.
   */
  func readFloat() throws -> Float {
    let size = MemoryLayout<Float>.size
    let data = self.readData(ofLength: size)

    guard data.count == size else {
      throw NSError(domain: "FileHandle", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to read float from file."])
    }

    return data.withUnsafeBytes { $0.load(as: Float.self) }
  }

  /**
   Reads a 64-bit integer from the file.

   - Returns: The Int64 read from the file.
   - Throws: An error if the expected number of bytes cannot be read.
   */
  func readInt64() throws -> Int64 {
    let size = MemoryLayout<Int64>.size
    let data = self.readData(ofLength: size)

    guard data.count == size else {
      throw NSError(domain: "FileHandle", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to read Int64 from file."])
    }

    return data.withUnsafeBytes { $0.load(as: Int64.self) }
  }

  /**
   Reads a Boolean value from the file.

   - Returns: The Bool read from the file.
   - Throws: An error if the expected number of bytes cannot be read.
   */
  func readBool() throws -> Bool {
    let size = MemoryLayout<Bool>.size
    let data = self.readData(ofLength: size)

    guard data.count == size else {
      throw NSError(domain: "FileHandle", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to read Bool from file."])
    }

    return data.withUnsafeBytes { $0.load(as: Bool.self) }
  }

  /**
   Reads a String from the file.

   This method expects the string to be stored with a 64-bit integer length prefix
   (number of bytes), followed by that many bytes of UTF-8 encoded text.

   - Returns: The String read from the file.
   - Throws: An error if the length cannot be read, if the specified number of bytes
   cannot be read, or if the data cannot be decoded as a UTF-8 string.
   */
  func readString() throws -> String {
    // Read the length of the string (as a 64-bit integer)
    let length = Int(try self.readInt64())
    // Read the specified number of bytes
    let data = self.readData(ofLength: length)

    guard data.count == length else {
      throw NSError(domain: "FileHandle", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to read String from file."])
    }

    // Decode the data as a UTF-8 string
    guard let string = String(data: data, encoding: .utf8) else {
      throw NSError(domain: "FileHandle", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to decode string from UTF-8 data."])
    }

    return string
  }

  /**
   Writes a String to the file in a binary format.

   The string is first encoded as UTF-8, then a 64-bit integer (representing the byte count)
   is written, followed by the UTF-8 data.

   - Parameter string: The string to write.
   - Throws: An error if the string cannot be encoded or the write fails.
   */
  func writeString(_ string: String) throws {
    // Convert the string to UTF-8 encoded data.
    guard let stringData = string.data(using: .utf8) else {
      throw NSError(domain: "FileHandle", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to encode string as UTF-8"])
    }

    // Create a 64-bit integer representing the number of bytes.
    let length: Int64 = Int64(stringData.count)

    // Write the length prefix.
    self.write(Data(from: length))

    // Write the actual string data.
    self.write(stringData)
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

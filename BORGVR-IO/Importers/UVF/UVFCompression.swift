import Foundation
import Darwin
import zlib

enum UVFCompression {
  static func decode(_ data: Data, codec: Int, size: Int) throws -> Data {
    // Bound individual brick allocations, independently of the full volume size.
    guard size > 0, size <= 512 << 20, !data.isEmpty, data.count <= 512 << 20 else {
      throw UVFParser.Error.invalid("brick exceeds decoder limits")
    }
    if codec == 0 {
      guard data.count == size else { throw UVFParser.Error.invalid("uncompressed brick size") }
      return data
    }
    if codec == 2 { return try UVFLZMADecoder.decode(data, size: size) }
    if codec == 3 { return try lz4(data, size: size) }
    var output = Data(count: size)
    if codec == 1 {
      var stream = z_stream()
      guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw UVFParser.Error.invalid("zlib initialization")
      }
      defer { inflateEnd(&stream) }
      let result = output.withUnsafeMutableBytes { destination in
        data.withUnsafeBytes { source in
          stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress!)
          stream.avail_in = uInt(data.count)
          stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress!
          stream.avail_out = uInt(size)
          return inflate(&stream, Z_FINISH)
        }
      }
      guard result == Z_STREAM_END, stream.total_out == size, stream.total_in == data.count else {
        throw UVFParser.Error.invalid("zlib brick")
      }
    } else if codec == 4 {
      // Public system libbz2 is shipped on macOS, iOS and visionOS. Resolve its
      // C entry point without requiring a bridging header or project linker edit.
      guard let library = dlopen("/usr/lib/libbz2.1.0.dylib", RTLD_LOCAL | RTLD_LAZY) else {
        throw UVFParser.Error.unsupported("system BZIP2 decoder is unavailable")
      }
      defer { dlclose(library) }
      guard let symbol = dlsym(library, "BZ2_bzBuffToBuffDecompress") else {
        throw UVFParser.Error.unsupported("system BZIP2 decoder is unavailable")
      }
      typealias Decode = @convention(c) (UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<UInt32>?,
                                        UnsafeMutablePointer<CChar>?, UInt32, Int32, Int32) -> Int32
      let decode = unsafeBitCast(symbol, to: Decode.self)
      var count = UInt32(size)
      let result = output.withUnsafeMutableBytes { destination in
        data.withUnsafeBytes { source in
          decode(destination.bindMemory(to: CChar.self).baseAddress, &count,
                 UnsafeMutablePointer(mutating: source.bindMemory(to: CChar.self).baseAddress), UInt32(data.count), 0, 0)
        }
      }
      guard result == 0, count == size else { throw UVFParser.Error.invalid("BZIP2 brick") }
    } else {
      throw UVFParser.Error.unsupported("brick compression \(codec)")
    }
    return output
  }

  private static func lz4(_ data: Data, size: Int) throws -> Data {
    var output = Data(count: size)
    try output.withUnsafeMutableBytes { destination in
      let out = destination.bindMemory(to: UInt8.self)
      var input = 0, position = 0
      func extended(_ base: Int) throws -> Int {
        var length = base
        if base == 15 {
          var next: Int
          repeat {
            guard input < data.count else { throw UVFParser.Error.invalid("truncated LZ4 length") }
            next = Int(data[input]); input += 1
            length = try uvfAdd(length, next)
          } while next == 255
        }
        return length
      }
      while input < data.count {
        let token = Int(data[input]); input += 1
        let literals = try extended(token >> 4)
        guard literals <= data.count - input, literals <= size - position else { throw UVFParser.Error.invalid("LZ4 literal bounds") }
        for i in 0..<literals { out[position + i] = data[input + i] }
        input += literals; position += literals
        if input == data.count { break }
        guard data.count - input >= 2 else { throw UVFParser.Error.invalid("LZ4 offset") }
        let distance = Int(data[input]) | Int(data[input + 1]) << 8
        input += 2
        let length = try uvfAdd(extended(token & 15), 4)
        guard distance > 0, distance <= position, length <= size - position else { throw UVFParser.Error.invalid("LZ4 match bounds") }
        for _ in 0..<length { out[position] = out[position - distance]; position += 1 }
      }
      guard position == size else { throw UVFParser.Error.invalid("LZ4 decoded size") }
    }
    return output
  }
}

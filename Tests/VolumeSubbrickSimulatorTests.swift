import Foundation
import Metal
import UIKit

struct BorgVRTransferFunctionSnapshot {
  let channel: Int
  let samples: [SIMD4<UInt8>]
  let revision: UInt64
}
enum VolumeAtlasError: Error { case failedToCreateTexture }
private struct TestFailure: Error { let message: String }

@main
final class VolumeSubbrickSimulatorTests: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    true
  }

  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Tests", sessionRole: session.role)
    configuration.delegateClass = SubbrickTestSceneDelegate.self
    return configuration
  }

  fileprivate static func execute() {
    DispatchQueue.main.async {
      let resultURL = URL.documentsDirectory.appendingPathComponent("result.txt")
      do {
        try Self.run()
        try "PASS\n".write(to: resultURL, atomically: true, encoding: .utf8)
        print("Simulator subbrick dispatch passed: ASTC 8x8 decode, partial/full threadgroups, cached reclassification and page bounds")
        exit(0)
      } catch {
        try? "FAIL: \(error)\n".write(to: resultURL, atomically: true, encoding: .utf8)
        print("Simulator subbrick dispatch FAILED: \(error)")
        exit(1)
      }
    }
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(message: message) }
  }

  private static func run() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw TestFailure(message: "Metal is required")
    }
    let side = 16, capacity = 80, grid = SIMD3(5, 4, 4)
    let metadata = BORGVRMetaData(width: 12, height: 12, depth: 12, componentCount: 4,
      bytePerComponent: 1, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
      brickSize: side, overlap: 2, minValue: 0, maxValue: 255,
      compression: false, datasetDescription: "Simulator subbricks", metaDescription: "")
    try metadata.setChannelInterpretation(.rgba.withASTC(blockSize: 8))
    let descriptor = MTLTextureDescriptor()
    descriptor.textureType = .type3D
    descriptor.pixelFormat = .rgba8Unorm
    descriptor.width = side * grid.x
    descriptor.height = side * grid.y
    descriptor.depth = side * grid.z
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      throw TestFailure(message: "Cannot allocate test atlas")
    }
    // Exercise the software-decoded ASTC path used by the simulator.
    for page in 0..<capacity {
      let alpha: UInt8 = page % 3 == 0 ? 0 : (page % 3 == 1 ? 64 : 255)
      var bytes = [UInt8](repeating: 128, count: side * side * side * 4)
      for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = alpha }
      let encoded = bytes.withUnsafeBufferPointer {
        BorgVRASTCCodec.encode($0.baseAddress!, brickSize: side, components: 4, blockSize: 8)
      }
      try encoded.withUnsafeBufferPointer { input in
        try bytes.withUnsafeMutableBufferPointer {
          try BorgVRASTCCodec.decode(input.baseAddress!, brickSize: side, components: 4,
            blockSize: 8, output: $0.baseAddress!)
        }
      }
      bytes.withUnsafeBytes {
        texture.replace(region: MTLRegionMake3D((page % grid.x) * side,
          ((page / grid.x) % grid.y) * side, (page / (grid.x * grid.y)) * side, side, side, side),
          mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
          bytesPerRow: side * 4, bytesPerImage: side * side * 4)
      }
    }
    for count in [1, 3, 31, 32, 33, 65] {
      let cache = try VolumeAtlasSubbrickCache(device: device, metadata: metadata, capacity: capacity, divisions: 2)
      for (iteration, epsilon) in [Float(0), 0.5, 0].enumerated() {
        guard let command = queue.makeCommandBuffer(),
              let readback = device.makeBuffer(length: cache.masks.length, options: .storageModeShared) else {
          throw TestFailure(message: "Cannot allocate test commands")
        }
        if iteration == 0 {
          let fill = command.makeBlitCommandEncoder()!
          fill.fill(buffer: cache.masks, range: 0..<cache.masks.length, value: 0xCD)
          fill.endEncoding()
        }
        try require(cache.prepare(command: command, primary: texture, secondary: nil,
          pages: Array(0..<count), transferFunctions: [], alphaEpsilon: epsilon), "Cannot prepare masks")
        let blit = command.makeBlitCommandEncoder()!
        blit.copy(from: cache.masks, sourceOffset: 0, to: readback, destinationOffset: 0, size: cache.masks.length)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        let masks = readback.contents().assumingMemoryBound(to: UInt32.self)
        for page in 0..<capacity {
          if page < count {
            let visible = page % 3 == 2 || (page % 3 == 1 && epsilon == 0)
            try require(masks[page * cache.maskStride] == (visible ? 2 : 0)
              && masks[page * cache.maskStride + 1] == (visible ? 255 : 0),
              "Wrong mask for page \(page), count \(count), epsilon \(epsilon)")
          } else {
            try require(masks[page * cache.maskStride] == 0xCDCDCDCD
              && masks[page * cache.maskStride + 1] == 0xCDCDCDCD,
              "Padded dispatch overwrote unselected page \(page)")
          }
        }
      }
      print("Simulator masks passed for \(count) resident pages")
    }
  }
}

final class SubbrickTestSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    window.makeKeyAndVisible()
    self.window = window
    VolumeSubbrickSimulatorTests.execute()
  }
}

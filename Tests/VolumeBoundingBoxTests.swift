import Foundation
import Metal
import simd

@main
private enum VolumeBoundingBoxTests {
  static func main() throws {
    for extent in [SIMD3<Float>(1, 1, 1), SIMD3(0.25, 0.5, 1), SIMD3(1, 0.001, 0.4)] {
      let box = VolumeBoundingBoxRenderer.geometry(extent: extent)
      precondition(box.vertices.count == 12 * 36 && box.normals.count == box.vertices.count,
        "The box must contain exactly twelve closed edge beams")
      var minimum = SIMD3<Float>(repeating: .infinity)
      var maximum = SIMD3<Float>(repeating: -.infinity)
      for i in box.vertices.indices {
        let point = box.vertices[i]
        precondition(point.x.isFinite && point.y.isFinite && point.z.isFinite)
        precondition(abs(simd_length(box.normals[i]) - 1) < 0.00001)
        minimum = simd_min(minimum, point)
        maximum = simd_max(maximum, point)
        // Every vertex belongs to an edge, never to a filled box face/interior.
        let edgeAxes = (0..<3).filter { abs(abs(point[$0]) - extent[$0] * 0.5) <= 0.00151 }
        precondition(edgeAxes.count >= 2, "Bounding box contains non-edge geometry")
      }
      precondition(simd_length(minimum + extent * 0.5) < 0.00001,
        "Beam thickness must not extend below the dataset bounds")
      precondition(simd_length(maximum - extent * 0.5) < 0.00001,
        "Beam thickness must not extend above the dataset bounds")
      for i in stride(from: 0, to: box.vertices.count, by: 3) {
        let face = simd_cross(box.vertices[i + 1] - box.vertices[i], box.vertices[i + 2] - box.vertices[i])
        precondition(simd_dot(face, box.normals[i]) > 0, "Incorrect bounding box winding")
      }
    }
    for extent in [SIMD3<Float>(0, 1, 1), SIMD3(-1, 1, 1), SIMD3(.nan, 1, 1)] {
      precondition(VolumeBoundingBoxRenderer.geometry(extent: extent).vertices.isEmpty)
    }
    print("Bounding box tests passed: twelve edges, anisotropic extents, finite normals, winding, invalid extents")
    try testRenderedColors()
  }

  private static func testRenderedColors() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      print("Bounding box GPU test skipped: no Metal device.")
      return
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let shaders = root.appendingPathComponent("AppSupport/Rendering/Shaders")
    let header = try String(contentsOf: shaders.appendingPathComponent("ShaderTypes.h"), encoding: .utf8)
    let source = try String(contentsOf: shaders.appendingPathComponent("ScreenOpaqueGeometryShaders.metal"), encoding: .utf8)
    let library = try device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + header + "\n" + source, options: nil)
    let pipeline = MTLRenderPipelineDescriptor()
    pipeline.vertexFunction = library.makeFunction(name: "screenVolumeMarkerVertex")
    pipeline.fragmentFunction = library.makeFunction(name: "screenVolumeMarkerFragment")
    pipeline.colorAttachments[0].pixelFormat = .rgba8Unorm
    pipeline.depthAttachmentPixelFormat = .depth32Float
    let state = try device.makeRenderPipelineState(descriptor: pipeline)
    let depthDescriptor = MTLDepthStencilDescriptor()
    depthDescriptor.depthCompareFunction = .less
    depthDescriptor.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!
    let size = 1024
    let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
    colorDescriptor.storageMode = .shared
    colorDescriptor.usage = .renderTarget
    let color = device.makeTexture(descriptor: colorDescriptor)!
    let depthTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
      width: size, height: size, mipmapped: false)
    depthTextureDescriptor.storageMode = .private
    depthTextureDescriptor.usage = .renderTarget
    let depth = device.makeTexture(descriptor: depthTextureDescriptor)!
    let renderer = VolumeBoundingBoxRenderer()

    func sample(_ x: Int, _ y: Int) -> SIMD4<UInt8> {
      var pixel = SIMD4<UInt8>.zero
      color.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
      return pixel
    }
    func draw(_ model: simd_float4x4, eye: SIMD3<Float>) throws {
      let descriptor = MTLRenderPassDescriptor()
      descriptor.colorAttachments[0].texture = color
      descriptor.colorAttachments[0].loadAction = .clear
      descriptor.colorAttachments[0].storeAction = .store
      descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
      descriptor.depthAttachment.texture = depth
      descriptor.depthAttachment.loadAction = .clear
      descriptor.depthAttachment.clearDepth = 1
      let buffer = queue.makeCommandBuffer()!
      let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)!
      encoder.setRenderPipelineState(state)
      encoder.setDepthStencilState(depthState)
      var projection = matrix_identity_float4x4
      projection.columns.3.z = 0.5
      var eye = eye
      encoder.setVertexBytes(&projection, length: MemoryLayout<simd_float4x4>.stride, index: 20)
      encoder.setVertexBytes(&eye, length: MemoryLayout<SIMD3<Float>>.stride, index: 22)
      renderer.render(device: device, encoder: encoder, extent: SIMD3(1.5, 1.25, 0.5), modelMatrix: model)
      encoder.endEncoding()
      buffer.commit()
      buffer.waitUntilCompleted()
      if let error = buffer.error { throw error }
    }

    try draw(matrix_identity_float4x4, eye: SIMD3(0, 0, -2))
    let red = sample(895, 831), green = sample(128, 192), midpoint = sample(512, 831)
    precondition(red.x > 250 && red.y < 5 && red.z < 5 && red.w == 255, "Expected +X to be red: \(red)")
    precondition(green.x < 5 && green.y > 250 && green.z < 5 && green.w == 255, "Expected +Y to be green: \(green)")
    precondition((124...132).contains(midpoint.x) && midpoint.y < 5 && midpoint.z < 5 && midpoint.w == 255,
      "Expected a continuous gradient along X: \(midpoint)")
    try draw(matrix_identity_float4x4, eye: SIMD3(5, -5, 5))
    precondition(sample(895, 831) == red && sample(128, 192) == green, "Box colors must be independent of lighting")
    var flipped = matrix_identity_float4x4
    flipped.columns.1.y = -1
    flipped.columns.2.z = -1
    try draw(flipped, eye: SIMD3(0, 0, -2))
    let blue = sample(128, 192)
    precondition(blue.x < 5 && blue.y < 5 && blue.z > 250 && blue.w == 255, "Expected +Z to be blue after rotation: \(blue)")
    print("Bounding box GPU test passed: dataset-local RGB, interpolated edges, rotation and unlit rendering")
  }
}

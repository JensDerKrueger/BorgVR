import Foundation
import Metal
import simd

private struct PrecisionFailure: Error { let message: String }

@main
private enum TFCompositingPrecisionTests {
  private static func source(_ url: URL) throws -> String {
    var result = ""
    for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines) {
      if (line.hasPrefix("#include") || line.hasPrefix("#import")),
         let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last {
        result += try source(url.deletingLastPathComponent().appendingPathComponent(
          String(line[line.index(after: first)..<last])).standardizedFileURL)
      } else {
        result += line + "\n"
      }
    }
    return result
  }

  private static let shader = """
    inline half4 underHalfPrecision(half4 current, half4 last) {
      half weight = (half(1) - last.a) * current.a;
      last.rgb = clamp(last.rgb + weight * current.rgb, half3(0), half3(1));
      last.a = min(half(1), last.a + weight);
      return last;
    }
    kernel void compareColorPrecision(
      device float4 *results [[buffer(0)]],
      uint index [[thread_position_in_grid]]) {
      const float alphas[8] = {1e-6, 1e-5, 1e-4, 1e-3, 0.01, 0.1, 0.5, 1.0};
      const uint lengths[5] = {8, 64, 512, 4096, 16384};
      float alpha = alphas[index % 8];
      uint length = lengths[(index / 8) % 5];
      uint channels = 1 + (index / 40) % 4;
      uint pattern = (index / 160) % 4;
      bool opaque = (index / 640) % 2 != 0;
      float4 reference = 0;
      half4 reduced = 0;
      half3 mixedRGB = 0;
      float mixedAlpha = 0;
      float4 mixedMath = 0;
      float interactionOpacity = 0, strongest = 0;
      uint picked = 0, steps = 0;
      for (uint step = 0; step < length; ++step) {
        for (uint channel = 0; channel < channels; ++channel) {
          float3 rgb = pattern == 0 ? float3(1) :
            fract(float3(0.37, 0.61, 0.83) * (float(step) * 0.31 + float(channel + 1)));
          // TF textures return half; alpha correction and picking stay float.
          half4 lookup = half4(half3(rgb), half(alpha));
          float4 current = float4(lookup);
          current.a = 1.0 - pow(1.0 - current.a, pattern == 3 ? 0.4 : 1.0);
          float contribution = (1.0 - interactionOpacity) * current.a;
          if (contribution > strongest) { strongest = contribution; picked = step * channels + channel; }
          interactionOpacity += contribution;
          if (!opaque || step < length / 2) {
            reference = underFloat(current, reference);
            reduced = underHalfPrecision(half4(current), reduced);
            float weight = (1.0 - mixedAlpha) * current.a;
            mixedRGB = clamp(mixedRGB + half(weight) * half3(current.rgb), half3(0), half3(1));
            mixedAlpha = min(1.0, mixedAlpha + weight);
            float mathWeight = (1.0 - mixedMath.a) * current.a;
            half3 weightedRGB = half(mathWeight) * half3(current.rgb);
            mixedMath.rgb = clamp(mixedMath.rgb + float3(weightedRGB), float3(0), float3(1));
            mixedMath.a = min(1.0, mixedMath.a + mathWeight);
          }
        }
        steps = step + 1;
        if (interactionOpacity > 0.99) break;
      }
      results[index * 5] = float4(half4(reference));
      results[index * 5 + 1] = float4(reduced);
      results[index * 5 + 2] = float4(half4(mixedRGB, half(mixedAlpha)));
      results[index * 5 + 3] = float4(half4(mixedMath));
      results[index * 5 + 4] = float4(float(steps), interactionOpacity, float(picked), alpha);
    }
    """

  static func main() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw PrecisionFailure(message: "Metal is required for color precision tests")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let helper = try source(root.appendingPathComponent("AppSupport/Rendering/Shaders/Helper.h"))
    let options = MTLCompileOptions()
    options.mathMode = .fast
    let library = try device.makeLibrary(source: helper + shader, options: options)
    let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "compareColorPrecision")!)
    let count = 1280
    let output = device.makeBuffer(length: count * 5 * MemoryLayout<SIMD4<Float>>.stride,
                                   options: .storageModeShared)!
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(output, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    if let error = command.error { throw error }
    let results = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: count * 5)
    for variant in 1...3 {
      var maximum: Float = 0, worst = 0, above8Bit = 0
      var squaredError: Double = 0
      for index in 0..<count {
        let reference = results[index * 5], actual = results[index * 5 + variant]
        for channel in 0..<4 {
          guard actual[channel].isFinite && actual[channel] >= 0 && actual[channel] <= 1 else {
            throw PrecisionFailure(message: "Non-finite/out-of-range color at \(index): \(actual)")
          }
          let error = abs(reference[channel] - actual[channel])
          squaredError += Double(error * error)
          if error > maximum { maximum = error; worst = index }
        }
        if (0..<4).contains(where: { abs(reference[$0] - actual[$0]) > 1.0 / 255.0 }) {
          above8Bit += 1
        }
      }
      let name = ["RGBA half", "RGB half / alpha float", "half RGB contribution / float accumulation"][variant - 1]
      print("\(name): max error \(maximum), RMSE \(sqrt(squaredError / Double(count * 4))), >1/255 in \(above8Bit)/\(count) rays")
      print("  worst case \(worst): reference \(results[worst * 5]), actual \(results[worst * 5 + variant]), (steps, opacity, pick, input alpha) \(results[worst * 5 + 4])")
      for limit: Float in [64, 512, 4096] {
        var maximum: Float = 0
        for index in 0..<count where results[index * 5 + 4].x <= limit {
          let reference = results[index * 5], actual = results[index * 5 + variant]
          maximum = max(maximum, (0..<4).map { abs(reference[$0] - actual[$0]) }.max()!)
        }
        print("  up to \(Int(limit)) samples: max error \(maximum)")
      }
    }
    print("Precision experiment completed; reported color differences are measurements, not pass tolerances")
  }
}

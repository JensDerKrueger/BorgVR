import SwiftUI
import simd

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct LightingEditorView: View {
  @Binding var lightDirection: SIMD3<Float>
  @Binding var ambientLightColor: SIMD3<Float>
  @Binding var diffuseLightColor: SIMD3<Float>
  @Binding var specularLightColor: SIMD3<Float>

  var usesPanelBackground = true
  var showsTitle = true
  var usesHorizontalLayout = false
  var onChange: () -> Void
  var onCommit: () -> Void
  var onClose: (() -> Void)?

  @ViewBuilder
  var body: some View {
    if usesPanelBackground {
      editorContent
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    } else {
      editorContent
    }
  }

  private var editorContent: some View {
    VStack(spacing: 18) {
      HStack {
        if showsTitle {
          Text("Lighting")
            .font(.headline)
        }
        Spacer()
        Button {
          resetLighting()
        } label: {
          Label("Reset", systemImage: "arrow.counterclockwise")
        }
        if let onClose {
          Button {
            onClose()
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close lighting editor")
          .help("Close lighting editor")
        }
      }

      if usesHorizontalLayout {
        HStack(alignment: .center, spacing: 16) {
          arcball(size: 132)
          colorControls
        }
        .frame(maxWidth: .infinity)
      } else {
        arcball(size: 220)
        colorControls
      }
    }
  }

  private func arcball(size: CGFloat) -> some View {
    LightingDirectionArcball(
      direction: $lightDirection,
      ambientColor: ambientLightColor,
      diffuseColor: diffuseLightColor,
      specularColor: specularLightColor,
      onChange: onChange,
      onCommit: onCommit
    )
    .frame(width: size, height: size)
    .accessibilityLabel("Light direction")
  }

  private var colorControls: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
      colorRow("Ambient light", color: $ambientLightColor)
      colorRow("Diffuse light", color: $diffuseLightColor)
      colorRow("Specular light", color: $specularLightColor)
    }
  }

  private func colorRow(
    _ title: LocalizedStringKey,
    color: Binding<SIMD3<Float>>
  ) -> some View {
    GridRow {
      Text(title)
      ColorPicker("", selection: colorBinding(color), supportsOpacity: false)
        .labelsHidden()
        .onChange(of: color.wrappedValue) {
          onChange()
        }
    }
  }

  private func colorBinding(_ value: Binding<SIMD3<Float>>) -> Binding<Color> {
    Binding(
      get: {
        Color(
          red: Double(value.wrappedValue.x),
          green: Double(value.wrappedValue.y),
          blue: Double(value.wrappedValue.z)
        )
      },
      set: { newColor in
        value.wrappedValue = Self.components(of: newColor)
      }
    )
  }

  private func resetLighting() {
    let defaults = BorgVRLightingState.default
    lightDirection = defaults.direction
    ambientLightColor = defaults.ambientColor
    diffuseLightColor = defaults.diffuseColor
    specularLightColor = defaults.specularColor
    onChange()
    onCommit()
  }

  private static func components(of color: Color) -> SIMD3<Float> {
    #if os(macOS)
    let rgb = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
    return SIMD3<Float>(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
    #else
    var red: CGFloat = 1
    var green: CGFloat = 1
    var blue: CGFloat = 1
    var alpha: CGFloat = 1
    UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return SIMD3<Float>(Float(red), Float(green), Float(blue))
    #endif
  }
}

private struct LightingDirectionArcball: View {
  @Binding var direction: SIMD3<Float>
  let ambientColor: SIMD3<Float>
  let diffuseColor: SIMD3<Float>
  let specularColor: SIMD3<Float>
  let onChange: () -> Void
  let onCommit: () -> Void

  @State private var dragStartDirection: SIMD3<Float>?
  @State private var dragStartVector: SIMD3<Float>?

  var body: some View {
    GeometryReader { geometry in
      Image(
        decorative: sphereImage(),
        scale: 1,
        orientation: .up
      )
      .resizable()
      .interpolation(.high)
      .clipShape(Circle())
      .overlay(Circle().stroke(.white.opacity(0.24), lineWidth: 1))
      .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
      .contentShape(Circle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let start = arcballVector(at: value.startLocation, in: geometry.size)
            let current = arcballVector(at: value.location, in: geometry.size)
            if dragStartDirection == nil {
              dragStartDirection = normalizedDirection
              dragStartVector = start
            }
            guard let initialDirection = dragStartDirection,
                  let initialVector = dragStartVector else { return }
            let rotation = simd_quatf(from: initialVector, to: current)
            direction = simd_normalize(rotation.act(initialDirection))
            onChange()
          }
          .onEnded { _ in
            dragStartDirection = nil
            dragStartVector = nil
            onCommit()
          }
      )
    }
  }

  private var normalizedDirection: SIMD3<Float> {
    let state = BorgVRLightingState(
      direction: direction,
      ambientColor: ambientColor,
      diffuseColor: diffuseColor,
      specularColor: specularColor
    )
    return state.sanitized.direction
  }

  private func arcballVector(at point: CGPoint, in size: CGSize) -> SIMD3<Float> {
    let diameter = Float(max(1, min(size.width, size.height)))
    var x = Float(2 * point.x - size.width) / diameter
    var y = Float(size.height - 2 * point.y) / diameter
    let lengthSquared = x * x + y * y
    if lengthSquared <= 1 {
      return SIMD3<Float>(x, y, sqrt(1 - lengthSquared))
    }
    let inverseLength = 1 / sqrt(lengthSquared)
    x *= inverseLength
    y *= inverseLength
    return SIMD3<Float>(x, y, 0)
  }

  private func sphereImage() -> CGImage {
    let resolution = 144
    var pixels = [UInt8](repeating: 0, count: resolution * resolution * 4)
    let lighting = BorgVRLightingState(
      direction: direction,
      ambientColor: ambientColor,
      diffuseColor: diffuseColor,
      specularColor: specularColor
    ).sanitized

    for y in 0..<resolution {
      for x in 0..<resolution {
        let nx = (Float(x) + 0.5) / Float(resolution) * 2 - 1
        let ny = 1 - (Float(y) + 0.5) / Float(resolution) * 2
        let radiusSquared = nx * nx + ny * ny
        let offset = (y * resolution + x) * 4
        guard radiusSquared <= 1 else {
          pixels[offset + 3] = 0
          continue
        }

        let normal = SIMD3<Float>(nx, ny, sqrt(max(0, 1 - radiusSquared)))
        let diffuse = abs(simd_dot(normal, lighting.direction))
        let reflection = 2 * simd_dot(normal, lighting.direction) * normal - lighting.direction
        let specular = pow(max(reflection.z, 0), 8)
        let color = simd_clamp(
          lighting.ambientColor + lighting.diffuseColor * diffuse + lighting.specularColor * specular,
          SIMD3<Float>(repeating: 0),
          SIMD3<Float>(repeating: 1)
        )
        pixels[offset] = UInt8(color.x * 255)
        pixels[offset + 1] = UInt8(color.y * 255)
        pixels[offset + 2] = UInt8(color.z * 255)
        pixels[offset + 3] = 255
      }
    }

    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
      width: resolution,
      height: resolution,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: resolution * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent
    )!
  }
}

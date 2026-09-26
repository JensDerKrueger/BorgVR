import CoreGraphics
import CoreText
import Foundation
import Metal
import MetalKit
import simd

struct ScreenViewLabelTexture {
  let texture: MTLTexture
  let aspectRatio: Float
}

final class ScreenViewLabelTextureCache {
  private var entries: [String: ScreenViewLabelTexture] = [:]

  func texture(
    for text: String,
    accentColor: SIMD4<Float>,
    device: MTLDevice
  ) -> ScreenViewLabelTexture? {
    let key = cacheKey(text: text, color: accentColor)
    if let cached = entries[key] {
      return cached
    }
    guard let image = makeImage(text: text, accentColor: accentColor) else {
      return nil
    }

    do {
      let texture = try MTKTextureLoader(device: device).newTexture(
        cgImage: image,
        options: [
          .SRGB: true,
          .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
          .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ]
      )
      texture.label = "Screen View Label: \(text)"
      let result = ScreenViewLabelTexture(
        texture: texture,
        aspectRatio: Float(image.width) / Float(image.height)
      )
      entries[key] = result
      return result
    } catch {
      return nil
    }
  }

  private func cacheKey(text: String, color: SIMD4<Float>) -> String {
    let components = [color.x, color.y, color.z].map {
      String(Int((min(max($0, 0), 1) * 255).rounded()))
    }
    return "\(components.joined(separator: ":"))|\(text)"
  }

  private func makeImage(text: String, accentColor: SIMD4<Float>) -> CGImage? {
    let font = CTFontCreateUIFontForLanguage(.system, 34, nil) ??
      CTFontCreateWithName("Helvetica" as CFString, 34, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String):
        CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    ]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes)
    )

    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let horizontalPadding: CGFloat = 28
    let verticalPadding: CGFloat = 14
    let width = max(Int(ceil(textWidth + 2 * horizontalPadding)), 96)
    let height = max(Int(ceil(ascent + descent + 2 * verticalPadding)), 64)
    let bytesPerRow = width * 4

    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
        CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
      return nil
    }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))

    let rect = CGRect(x: 2, y: 2, width: CGFloat(width - 4), height: CGFloat(height - 4))
    let path = CGPath(
      roundedRect: rect,
      cornerWidth: CGFloat(height) * 0.28,
      cornerHeight: CGFloat(height) * 0.28,
      transform: nil
    )
    context.addPath(path)
    context.setFillColor(CGColor(red: 0.035, green: 0.045, blue: 0.06, alpha: 0.88))
    context.fillPath()
    context.addPath(path)
    context.setStrokeColor(CGColor(
      red: CGFloat(accentColor.x),
      green: CGFloat(accentColor.y),
      blue: CGFloat(accentColor.z),
      alpha: 1
    ))
    context.setLineWidth(4)
    context.strokePath()

    context.textPosition = CGPoint(
      x: horizontalPadding,
      y: (CGFloat(height) - ascent - descent) * 0.5 + descent
    )
    CTLineDraw(line, context)
    return context.makeImage()
  }
}

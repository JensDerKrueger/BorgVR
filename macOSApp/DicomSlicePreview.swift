import SwiftUI
import CoreGraphics
import CoreImage

// MARK: - Public View

struct DicomSlicePreview: View {
  @ObservedObject var model: DicomSlicePreviewModel

  init(directory: URL? = nil) {
    self.model = DicomSlicePreviewModel(directory: directory)
  }

  init(model: DicomSlicePreviewModel) {
    self.model = model
  }

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        ZStack {
          Rectangle()
            .fill(.black)
            .overlay(alignment: .center) {
              if let image = model.displayImage {
                image
                  .resizable()
                  .interpolation(.none)
                  .scaledToFit()
              } else {
                Text("No slice loaded")
                  .foregroundStyle(.white.opacity(0.7))
              }
            }

          GeometryReader { geo in
            Color.clear
              .contentShape(Rectangle())
              .gesture(
                DragGesture(minimumDistance: 0)
                  .onChanged { value in
                    model.updateTransferFromDrag(
                      translation: value.translation,
                      viewSize: geo.size
                    )
                  }
                  .onEnded { _ in
                    model.endTransferDrag()
                  }
              )
          }
        }
        .aspectRatio(model.aspectRatio, contentMode: .fit)

        VStack(alignment: .leading) {
          Text(model.modality ?? "")
          Text(model.patientName ?? "")
          Text(model.seriesDate ?? "")
          Text(model.bitsStored.map { String(format: NSLocalizedString("converter_bpp_format", comment: "bits per pixel format, e.g. '12 bits/pixel'"), $0) } ?? "")
          Spacer()
        }
      }
      Slider(
        value: Binding(
          get: { Double(model.currentSliceIndex) },
          set: { newValue in
            model.setSliceIndex(Int(newValue.rounded()))
          }
        ),
        in: 0.0...max(0.0, Double(model.sliceCount - 1))
      )
      .disabled(model.sliceCount <= 1)

      if model.sliceCount > 0 {
        Text("\(model.currentSliceIndex + 1) / \(model.sliceCount)")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .onAppear {
      model.loadInitialIfPossible()
    }
  }
}

// MARK: - Model

@MainActor
final class DicomSlicePreviewModel: ObservableObject {
  @Published private(set) var directory: URL?
  @Published private(set) var sliceUrls: [URL] = []

  @Published private(set) var width: Int = 0
  @Published private(set) var height: Int = 0
  @Published private(set) var bytesPerVoxel: Int = 1

  @Published private(set) var modality: String? = nil
  @Published private(set) var patientName: String? = nil
  @Published private(set) var seriesDate: String? = nil
  @Published private(set) var bitsStored: UInt16? = nil

  @Published private(set) var sliceCount: Int = 0
  @Published private(set) var currentSliceIndex: Int = 0
  @Published private(set) var displayImage: Image?

  @Published private(set) var runningMaxValue: UInt32 = 0

  @Published var sigmoidCenter: Double = 0.25
  @Published var sigmoidSlope: Double = 12.0

  var aspectRatio: CGFloat {
    guard height > 0 else { return 1.0 }
    return CGFloat(width) / CGFloat(height)
  }

  private var dragStartCenter: Double?
  private var dragStartSlope: Double?

  init(directory: URL? = nil) {
    self.directory = directory
  }

  func setDirectory(_ directory: URL) {
    self.directory = directory

    // Reset state for new series/directory
    runningMaxValue = 0
    displayImage = nil
    sliceUrls = []
    sliceCount = 0
    width = 0
    height = 0
    bytesPerVoxel = 1

    do {
      let fileManager = FileManager.default
      let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      let candidateFiles = urls.filter { $0.isFileURL }

      var valid: [URL] = []
      for url in candidateFiles {
        if (try? DicomParser.parseDicomHeader(from: url)) != nil {
          valid.append(url)
        }
      }

      sliceUrls = valid.sorted { $0.lastPathComponent < $1.lastPathComponent }
      sliceCount = sliceUrls.count

      if let first = sliceUrls.first {
        let meta = try readSliceMetadata(from: first)
        width = meta.width
        height = meta.height
        bytesPerVoxel = meta.bytesPerVoxel
        modality = meta.modality
        patientName = meta.patientName
        seriesDate = meta.seriesDate
        bitsStored = meta.bitsStored
      }

      // Start in the middle (and actually display that slice)
      if sliceCount > 0 {
        currentSliceIndex = sliceCount / 2
        computeInitialMaxValueEstimate()
        updateCanvasForSlice(index: currentSliceIndex)
      } else {
        currentSliceIndex = 0
        displayImage = nil
      }
    } catch {
      sliceUrls = []
      sliceCount = 0
      width = 0
      height = 0
      bytesPerVoxel = 1
      currentSliceIndex = 0
      displayImage = nil
      runningMaxValue = 0
    }
  }

  func computeInitialMaxValueEstimate() {
    do {
      let pixelCount = width * height
      
      // try to get a good estimate what the max value is by looking
      // at the first and last slice as well as the center slice
      // which happens in updateCanvasForSlice
      let slicesToTest = [0, sliceCount - 1]
      for i in slicesToTest {
        let sliceData = try getSlice(from: sliceUrls[i])
        let sliceMaxValue = computeSliceMaxValue(sliceData: sliceData, pixelCount: pixelCount)
        if sliceMaxValue > runningMaxValue {
          runningMaxValue = sliceMaxValue
        }
      }
    } catch {
      return;
    }
  }
  
  func loadInitialIfPossible() {
    guard sliceCount > 0 else {
      displayImage = nil
      return
    }
    // Ensure we show the middle (or whatever currentSliceIndex is)
    let clamped = max(0, min(currentSliceIndex, sliceCount - 1))
    currentSliceIndex = clamped

    computeInitialMaxValueEstimate()

    updateCanvasForSlice(index: clamped)
  }

  func setSliceIndex(_ index: Int) {
    guard sliceCount > 0 else { return }
    let clamped = max(0, min(index, sliceCount - 1))
    guard clamped != currentSliceIndex else { return }
    currentSliceIndex = clamped
    updateCanvasForSlice(index: clamped)
  }

  private func updateCanvasForSlice(index: Int) {
    guard index >= 0, index < sliceUrls.count else { return }

    do {
      let sliceData = try getSlice(from: sliceUrls[index])
      displayImage = makeDisplayImageFromSlice(sliceData: sliceData)
    } catch {
      return
    }
  }

  // MARK: - Metadata / decode

  struct sliceMetadata {
    let width: Int
    let height: Int
    let bytesPerVoxel: Int
    let patientName: String?
    let modality: String?
    let seriesDate: String?
    let bitsStored: UInt16?
  }

  private func readSliceMetadata(from url: URL) throws -> sliceMetadata {
    let file = try DicomParser.parseDicomHeader(from: url)
    let slice = try DicomParser.openSlice(from: file)

    let width = Int(slice.columns)
    let height = Int(slice.rows)

    let bitsAllocated = Int(slice.bitsAllocated ?? 8)
    let bytesPerVoxel = max(1, bitsAllocated / 8)

    return sliceMetadata(
      width: width,
      height: height,
      bytesPerVoxel: bytesPerVoxel,
      patientName: slice.patientName,
      modality: slice.modality,
      seriesDate: slice.seriesDate,
      bitsStored: slice.bitsStored
    )
  }

  private func getSlice(from url: URL) throws -> [UInt8] {
    guard width > 0, height > 0 else { return [] }

    let file = try DicomParser.parseDicomHeader(from: url)
    let slice = try DicomParser.openSlice(from: file)
    return try slice.decodedPixels(using: file.transferSyntax.pixelDataEncoding)
  }

  // MARK: - Transfer function interaction

  func updateTransferFromDrag(translation: CGSize, viewSize: CGSize) {
    if dragStartCenter == nil { dragStartCenter = sigmoidCenter }
    if dragStartSlope == nil { dragStartSlope = sigmoidSlope }

    guard let startCenter = dragStartCenter,
          let startSlope = dragStartSlope else { return }

    let dx = Double(translation.width / max(1.0, viewSize.width))
    let dy = Double(translation.height / max(1.0, viewSize.height))

    sigmoidCenter = clamp01(startCenter + dx)

    let slopeFactor = exp(-dy * 3.0)
    sigmoidSlope = max(0.1, startSlope * slopeFactor)

    updateCanvasForSlice(index: currentSliceIndex)
  }

  func endTransferDrag() {
    dragStartCenter = nil
    dragStartSlope = nil
  }

  private func clamp01(_ v: Double) -> Double {
    max(0.0, min(1.0, v))
  }

  // MARK: - Rendering

  private func makeDisplayImageFromSlice(sliceData: [UInt8]) -> Image? {
    guard width > 0, height > 0 else { return nil }

    let pixelCount = width * height
    let expectedCount = pixelCount * max(1, bytesPerVoxel)
    guard sliceData.count >= expectedCount else { return nil }

    let sliceMaxValue = computeSliceMaxValue(sliceData: sliceData, pixelCount: pixelCount)
    if sliceMaxValue > runningMaxValue {
      runningMaxValue = sliceMaxValue
    }

    let denom = max(1.0, Double(runningMaxValue))

    var rgba = [UInt8](repeating: 0, count: pixelCount * 4)

    switch bytesPerVoxel {
      case 1:
        for i in 0..<pixelCount {
          let v = Double(sliceData[i]) / denom
          let y = sigmoid(x: v, center: sigmoidCenter, slope: sigmoidSlope)
          let out = UInt8(max(0.0, min(1.0, y)) * 255.0)

          let o = i * 4
          rgba[o + 0] = out
          rgba[o + 1] = out
          rgba[o + 2] = out
          rgba[o + 3] = 255
        }

      case 2:
        for i in 0..<pixelCount {
          let sample = readUInt16LE(sliceData, i * 2)
          let v = Double(sample) / denom
          let y = sigmoid(x: v, center: sigmoidCenter, slope: sigmoidSlope)
          let out = UInt8(max(0.0, min(1.0, y)) * 255.0)

          let o = i * 4
          rgba[o + 0] = out
          rgba[o + 1] = out
          rgba[o + 2] = out
          rgba[o + 3] = 255
        }

      case 4:
        for i in 0..<pixelCount {
          let sample = readUInt32LE(sliceData, i * 4)
          let v = Double(sample) / denom
          let y = sigmoid(x: v, center: sigmoidCenter, slope: sigmoidSlope)
          let out = UInt8(max(0.0, min(1.0, y)) * 255.0)

          let o = i * 4
          rgba[o + 0] = out
          rgba[o + 1] = out
          rgba[o + 2] = out
          rgba[o + 3] = 255
        }

      default:
        return nil
    }

    guard let cgImage = makeCGImageFromRgba(rgba: rgba, width: width, height: height) else {
      return nil
    }
    return Image(decorative: cgImage, scale: 1.0, orientation: .up)
  }

  private func computeSliceMaxValue(sliceData: [UInt8], pixelCount: Int) -> UInt32 {
    switch bytesPerVoxel {
      case 1:
        let m = sliceData.prefix(pixelCount).max() ?? 0
        return UInt32(m)

      case 2:
        var m: UInt16 = 0
        for i in 0..<pixelCount {
          let v = readUInt16LE(sliceData, i * 2)
          if v > m { m = v }
        }
        return UInt32(m)

      case 4:
        var m: UInt32 = 0
        for i in 0..<pixelCount {
          let v = readUInt32LE(sliceData, i * 4)
          if v > m { m = v }
        }
        return m

      default:
        return 0
    }
  }

  private func readUInt16LE(_ data: [UInt8], _ index: Int) -> UInt16 {
    let lo = UInt16(data[index])
    let hi = UInt16(data[index + 1]) << 8
    return lo | hi
  }

  private func readUInt32LE(_ data: [UInt8], _ index: Int) -> UInt32 {
    let b0 = UInt32(data[index])
    let b1 = UInt32(data[index + 1]) << 8
    let b2 = UInt32(data[index + 2]) << 16
    let b3 = UInt32(data[index + 3]) << 24
    return b0 | b1 | b2 | b3
  }

  private func sigmoid(x: Double, center: Double, slope: Double) -> Double {
    1.0 / (1.0 + exp(-slope * (x - center)))
  }

  private func makeCGImageFromRgba(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel

    guard rgba.count >= bytesPerRow * height else { return nil }

    return rgba.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return nil }

      let colorSpace = CGColorSpaceCreateDeviceRGB()
      let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

      guard let context = CGContext(
        data: UnsafeMutableRawPointer(mutating: base),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
      ) else { return nil }

      return context.makeImage()
    }
  }
}


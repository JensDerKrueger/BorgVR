import AppKit
import Foundation
import ImageIO
import Metal
import simd
import UniformTypeIdentifiers
@testable import BorgVR

private enum Failure: Error { case failed(String) }
private func expect(_ condition: Bool, _ message: String) throws {
  if !condition { throw Failure.failed(message) }
}

private func testPairedScreenshotReadback() throws -> (positions: BorgVRScreenshotPositions, preview: Data) {
  guard let device = MTLCreateSystemDefaultDevice(),
        let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer() else {
    throw Failure.failed("Metal is unavailable for the screenshot test")
  }
  func texture(_ format: MTLPixelFormat) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 4, height: 4, mipmapped: false)
    descriptor.storageMode = .shared
    return device.makeTexture(descriptor: descriptor)!
  }
  let rgba = texture(.bgra8Unorm), depth = texture(.r32Float)
  let region = MTLRegionMake2D(0, 0, 4, 4)
  let colors = [UInt8](repeating: 255, count: 64)
  colors.withUnsafeBytes { rgba.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
  var depths = [Float](repeating: -1, count: 16)
  depths[0] = 0.25
  func writeDepth() {
    depths.withUnsafeBytes { depth.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
  }
  writeDepth()
  var projection = matrix_identity_float4x4
  projection.columns.0.x = 2
  projection.columns.1.y = 2
  projection.columns.3.x = -1
  projection.columns.3.y = -1
  let readback = try MetalScreenshotEncoder.encodePairedReadback(
    color: rgba, depth: depth, textureToClip: projection, commandBuffer: commandBuffer
  )
  commandBuffer.commit()
  commandBuffer.waitUntilCompleted()
  try expect(commandBuffer.status == .completed, "Paired Metal readback failed")
  depths[0] = 0.75
  writeDepth()
  guard let positions = readback.positionReadback?.positions() else { throw Failure.failed("Missing position buffer") }
  try expect(positions.position(x: 0.125, y: 0.125) == SIMD3(0.125, 0.875, 0.25)
             && positions.position(x: 1, y: 1) == nil, "Snapshot pixels were not paired or immutable")
  let png = try MetalScreenshotEncoder.pngData(from: readback.color)
  let preview = try MetalScreenshotEncoder.pngImage(from: readback.color, maxWidth: 2)
  let uncapped = try MetalScreenshotEncoder.pngImage(from: readback.color, maxWidth: 100)
  try expect(preview.width == 2 && preview.height == 2 && positions.width == 4 && positions.height == 4,
    "Preview dimensions must not change the position buffer")
  try expect(uncapped.width == 4 && uncapped.height == 4 && uncapped.data == png, "Width cap upscaled the image")
  let rectangleBuffer = rgba.device.makeBuffer(length: 1024 * 120, options: .storageModeShared)!
  let rectangle = MetalScreenshotReadback(buffer: rectangleBuffer, width: 200, height: 120, bytesPerRow: 1024)
  let scaled = try MetalScreenshotEncoder.pngImage(from: rectangle, maxWidth: 100)
  try expect(scaled.width == 100 && scaled.height == 60, "Screenshot did not preserve the aspect ratio")
  let archive = try positions.archive(png: png)
  try expect(archive.prefix(8) == Data("BVRPOS1\n".utf8) && archive.subdata(in: 20..<(20 + png.count)) == png,
    "Invalid extended screenshot header or PNG payload")
  let offset = (20 + png.count + 3) & ~3
  let firstZ = archive.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self) }
  let nextX = archive.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self) }
  try expect(archive.count == offset + 16 * 12 && Float(bitPattern: UInt32(littleEndian: firstZ)) == 0.25
             && Float(bitPattern: UInt32(littleEndian: nextX)).isNaN, "Invalid XYZ encoding or no-hit marker")
  do {
    _ = try positions.archive(png: png, maximumBytes: archive.count - 1)
    throw Failure.failed("Inline size limit was not enforced")
  } catch MetalScreenshotError.inlineCaptureTooLarge {}
  return (positions, preview.data)
}

// Drive AppKit notifications explicitly without changing the user's desktop Space.
@MainActor
private final class FullscreenTestWindow: NSWindow {
  private(set) var toggleCount = 0
  private var simulatedFullscreen = false
  override var styleMask: NSWindow.StyleMask {
    get { simulatedFullscreen ? super.styleMask.union(.fullScreen) : super.styleMask }
    set { super.styleMask = newValue.subtracting(.fullScreen) }
  }
  override func toggleFullScreen(_ sender: Any?) {
    toggleCount += 1
    NotificationCenter.default.post(name: styleMask.contains(.fullScreen)
      ? NSWindow.willExitFullScreenNotification : NSWindow.willEnterFullScreenNotification, object: self)
  }

  func completeTransition(fullscreen: Bool) {
    simulatedFullscreen = fullscreen
    NotificationCenter.default.post(name: fullscreen
      ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification, object: self)
  }

  func closeDuringTransition() {
    simulatedFullscreen = false
    close()
  }
}

@MainActor
@main
struct MCPVisualizationTests {
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = try BORGVRMetaData(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let model = AppModel(), parameters = RenderingParameters(), settings = AppSettings()
    let preferenceKeys = AppSettings.values.keys.filter { $0.hasPrefix("renderBackground") ||
      ["screenFieldOfView", "parallelProjection"].contains($0) }
    let previous = Dictionary(uniqueKeysWithValues: preferenceKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
    defer {
      for key in preferenceKeys {
        if let value = previous[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
      }
    }
    let entry = AppModel.DatasetEntry(identifier: CommandLine.arguments[1], description: "Automation test",
      source: .local, uniqueId: metadata.uniqueID)
    model.openDataset(entry, automaticallyLoadState: true)
    guard case .opening(_, let requestID) = model.datasetSessionState else { fatalError() }
    model.prepareDatasetRenderer(key: model.activeDatasetRenderKey, metadata: metadata, requestID: requestID)
    _ = model.markRenderedDataset(key: model.activeDatasetRenderKey, requestID: requestID)
    // App-state TFs are CPU-only. The real renderer owns separate Metal copies.
    parameters.updateRanges(minValue: 0, maxValue: 255, rangeMax: 255, componentCount: 2)
    let session = ScreenBorgVRSession.screen(appModel: model, renderingParameters: parameters, appSettings: settings)
    let suiteName = "BorgVRMCPTests-\(UUID())"
    let isolated = UserDefaults(suiteName: suiteName)!
    defer { isolated.removePersistentDomain(forName: suiteName) }
    let store = BorgVRSettingsStore(defaultValues: ["oversampling": 2.0, "enableMCPServer": false,
      "mcpServerPort": 8765, "mcpAccessToken": ""], defaults: isolated)
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 200, height: 120)
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    defer { window.close(); panel.close() }
    let panelSize = panel.frame.size
    let windowAutomation = MacWindowAutomation()
    windowAutomation.commandExecutor = session
    session.configureRecordingContext { windowAutomation.recordingContextActions() }
    windowAutomation.attach(to: window)
    let service = BorgVRScreenCommandService(session: session, settingsStoreProvider: { store },
      windowAutomation: windowAutomation)
    try await service.openDataset(id: metadata.uniqueID)
    try expect(!model.automaticallyLoadsDatasetState, "Automation reused a dataset with automatic state loading enabled")
    do {
      _ = try BorgVRScreenCommandService(session: session).windowState()
      throw Failure.failed("Unavailable window was silently accepted")
    } catch is BorgVRMCPCommandError {}

    let ramp = BorgVRMCPTransferFunction(channel: 0, samples: [[0, 0, 0, 0], [255, 32, 16, 255]])
    let second = try service.transferFunction(channel: 1)
    try service.setTransferFunction(ramp)
    let first = try service.transferFunction(channel: 0)
    try expect(first.samples.count == TransferFunction1D.defaultEntryCount && first.samples.first == [0, 0, 0, 0]
      && first.samples.last == [255, 32, 16, 255], "Compact ramp resampling failed")
    try expect(try service.transferFunction(channel: 1) == second, "Changing one channel changed another")
    let tfURL = root.appendingPathComponent("color.tf1d")
    try service.saveTransferFunction(channel: 0, to: tfURL)
    try service.setTransferFunction(.init(channel: 0, samples: [[1, 2, 3, 4]]))
    try service.loadTransferFunction(channel: 0, from: tfURL)
    try expect(try service.transferFunction(channel: 0) == first, "Native TF file did not round-trip")

    let background = BorgVRMCPBackgroundState(mode: "gradient", primary: [0, 0, 0, 1], secondary: [0.2, 0.4, 0.6, 1])
    try service.setBackground(background)
    try service.setTransform(rotation: SIMD4(0, 0, 0, 1), translation: SIMD3(0.1, -0.2, 0), scale: SIMD3(repeating: 1.5))
    try service.setClipping(minimum: SIMD3(0.1, 0.2, 0), maximum: SIMD3(1, 0.9, 1))
    try service.setLighting(direction: SIMD3(1, 0, 0), ambient: SIMD3(repeating: 0.25), diffuse: nil, specular: nil)
    try service.setScreenProjection(fieldOfView: 70, parallel: true)
    let stateURL = root.appendingPathComponent("picture.json")
    try service.saveVisualizationState(to: stateURL)
    try service.reset(.all)
    try service.setBackground(.init(mode: "solid", primary: [1, 1, 1, 1], secondary: [0, 0, 0, 1]))
    try service.setScreenProjection(fieldOfView: 45, parallel: false)
    try service.loadVisualizationState(from: stateURL)
    let state = service.applicationState()
    try expect(state.transform.scale == [1.5, 1.5, 1.5] && state.clipMinimum == [0.1, 0.2, 0], "View/clipping roundtrip failed")
    try expect(state.lighting.ambient == [0.25, 0.25, 0.25] && settings.parallelProjection && settings.screenFieldOfView == 70,
      "Light/projection roundtrip failed")
    try expect(try service.transferFunction(channel: 0) == first, "Picture TF roundtrip failed")
    let restoredBackground = service.background()
    try expect(restoredBackground.mode == background.mode &&
      zip(restoredBackground.primary + restoredBackground.secondary, background.primary + background.secondary)
        .allSatisfy({ abs($0-$1) < 0.001 }), "Picture background roundtrip failed: \(restoredBackground)")
    do { try service.saveVisualizationState(to: stateURL); throw Failure.failed("Overwriting without opt-in succeeded") }
    catch is CocoaError {}
    let invalidURL = root.appendingPathComponent("invalid.json")
    var invalid = try JSONDecoder().decode(BorgVRMCPVisualizationDocument.self, from: Data(contentsOf: stateURL))
    invalid.transferFunctions[1].samples = [[1, 2, 3]]
    try JSONEncoder().encode(invalid).write(to: invalidURL)
    let before = session.currentSnapshot()
    do { try service.loadVisualizationState(from: invalidURL); throw Failure.failed("Invalid configuration accepted") }
    catch is BorgVRMCPCommandError {}
    try expect(session.currentSnapshot() == before, "Rejected file partially changed the visualization")

    // Exercise the actual MCP HTTP dispatcher, including schema visibility and input validation.
    let port = Int.random(in: 50000...60000)
    let server = BorgVRMCPServer(configuration: .init(enabled: true, port: port,
      allowRemoteConnections: false, accessToken: ""), commandService: service,
      logger: nil, stateDidChange: { _, _ in })
    server.start()
    defer { server.stop() }
    let deadline = ContinuousClock.now + .seconds(5)
    while !server.isRunning {
      if ContinuousClock.now >= deadline { throw Failure.failed("MCP listener did not start: \(server.lastError ?? "")") }
      try await Task.sleep(for: .milliseconds(10))
    }
    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
        "method": method, "params": params])
      let (data, _) = try await URLSession.shared.data(for: request)
      return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func tool(_ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
      let response = try await request("tools/call", ["name": name, "arguments": arguments])
      return response["result"] as! [String: Any]
    }
    let tools = try await request("tools/list")
    let names = Set(((tools["result"] as! [String: Any])["tools"] as! [[String: Any]]).compactMap { $0["name"] as? String })
    try expect(Set(["get_transfer_function", "set_transfer_function", "set_transfer_function_component",
      "save_transfer_function", "load_transfer_function",
      "get_background", "set_background", "save_visualization_state", "load_visualization_state",
      "save_settings", "load_settings", "reset_settings", "get_window_state", "resize_window",
      "set_fullscreen", "start_command_recording", "stop_command_recording", "replay_command_recording"]).isSubset(of: names), "MCP tools are missing")
    try expect(try await tool("get_window_state")["isError"] as? Bool != true, "MCP window getter failed")
    let resized = try await tool("resize_window", ["width": 900, "height": 640])
    try expect(resized["isError"] as? Bool != true, "MCP resize failed: \(resized)")
    try expect(try service.windowState().contentSizePoints == [900, 640], "Content-point resize mismatch")
    let scale = window.backingScaleFactor
    let frameWidth = Int(800 * scale), frameHeight = Int(600 * scale)
    let pixels = try await tool("resize_window", ["width": frameWidth, "height": frameHeight,
      "units": "pixels", "area": "frame"])
    try expect(pixels["isError"] as? Bool != true, "MCP frame-pixel resize failed")
    try expect(try service.windowState().frameSizePixels == [frameWidth, frameHeight], "Frame-pixel resize mismatch")
    try expect(panel.frame.size == panelSize, "Resize changed an unrelated panel")
    for arguments: [String: Any] in [["width": true, "height": 600], ["width": 1.5, "height": 600],
      ["width": 100, "height": 100], ["width": 900, "height": 600, "units": "invalid"]] {
      let rejected = try await tool("resize_window", arguments)
      try expect(rejected["isError"] as? Bool == true, "Invalid resize accepted: \(arguments)")
    }
    let fullscreen = try await tool("set_fullscreen", ["enabled": false])
    try expect(fullscreen["isError"] as? Bool != true && !window.styleMask.contains(.fullScreen),
      "Idempotent fullscreen setter failed")
    try await testFullscreenTransitions()
    _ = try await tool("reset_state", ["scope": "all"])
    let samples = (0..<256).map { [$0, 255-$0, 32, $0] }
    let afterReset = try await tool("set_transfer_function", ["channel": 0, "samples": samples])
    try expect(afterReset["isError"] as? Bool != true, "256-entry TF after reset failed: \(afterReset)")
    let afterResetTF = try service.transferFunction(channel: 0)
    try expect(afterResetTF.samples.count == TransferFunction1D.defaultEntryCount &&
      afterResetTF.samples.first == [0, 255, 32, 0] && afterResetTF.samples.last == [255, 0, 32, 255],
      "256-entry TF after reset did not resample/update correctly")
    let rejected = try await tool("set_transfer_function", ["samples": [[true, 1, 2, 3]]])
    try expect(rejected["isError"] as? Bool == true, "Boolean RGBA entry accepted")
    _ = try await tool("set_transfer_function", ["channel": 1, "samples": [[255, 0, 32, 100]]])
    let otherTF = try service.transferFunction(channel: 1)
    try expect(otherTF.samples.first == [255, 0, 32, 100], "MCP TF setter failed")
    let componentTool = "set_transfer_function_component"
    let points = [[0.25, 0.0], [0.75, 1.0]]
    let componentResult = try await tool(componentTool, ["channel": 0, "component": 2, "points": points])
    let componentReceipt = componentResult["structuredContent"] as? [String: Int]
    let rampTF = try service.transferFunction(channel: 0)
    try expect(componentReceipt == ["channel": 0, "component": 2, "pointCount": 2, "sampleCount": rampTF.samples.count],
      "The component setter should return a compact receipt")
    try expect(rampTF.samples.count == afterResetTF.samples.count, "The component setter must keep full TF resolution")
    for (index, row) in rampTF.samples.enumerated() {
      let original = afterResetTF.samples[index]
      let x = Double(index) / Double(rampTF.samples.count - 1)
      let blue = UInt8((min(1, max(0, (x - 0.25) * 2)) * 255).rounded())
      try expect(row == [original[0], original[1], blue, original[3]], "Unexpected component ramp at sample \(index)")
    }
    try expect(try service.transferFunction(channel: 1) == otherTF, "Another TF channel changed")
    let badPoints: [[[Any]]] = [[], [[0.25]], [[true, 0]], [[0.25, 1.1]], [[-0.1, 0]],
      [[0.25, 0], [0.25, 1]], [[0.75, 0], [0.25, 1]]]
    for rejectedPoints in badPoints {
      let result = try await tool(componentTool, ["channel": 0, "component": 2, "points": rejectedPoints])
      try expect(result["isError"] as? Bool == true, "Invalid component points accepted")
    }
    for arguments: [String: Any] in [["component": 2, "points": points], ["channel": 0, "component": 4, "points": points],
      ["channel": 0, "component": true, "points": points], ["channel": 0, "component": 2.5, "points": points]] {
      let result = try await tool(componentTool, arguments)
      try expect(result["isError"] as? Bool == true, "Invalid component command accepted")
    }
    try expect(try service.transferFunction(channel: 0) == rampTF, "Invalid component arguments changed the TF")

    let lastSample = rampTF.samples.count - 1
    let step = lastSample / 8
    let zigzag = [[Double(step) / Double(lastSample), 0], [Double(3 * step) / Double(lastSample), 1],
      [Double(5 * step) / Double(lastSample), 0], [Double(7 * step) / Double(lastSample), 1]]
    let zigzagResult = try await tool(componentTool, ["channel": 0, "component": 3, "points": zigzag])
    try expect(zigzagResult["isError"] as? Bool != true, "Multiple TF segments were rejected")
    let zigzagSamples = try service.transferFunction(channel: 0).samples
    for (index, expected) in [(0, 0), (step, 0), (2 * step, 128), (3 * step, 255), (4 * step, 128),
      (5 * step, 0), (6 * step, 128), (7 * step, 255), (lastSample, 255)] {
      try expect(abs(Int(zigzagSamples[index][3]) - expected) <= 1, "Wrong multi-segment alpha at sample \(index)")
      try expect(zigzagSamples[index].prefix(3) == rampTF.samples[index].prefix(3), "Alpha change altered a color")
    }
    try service.setTransferFunction(rampTF)

    let recording = try await tool("start_command_recording")
    try expect(recording["isError"] as? Bool != true && session.isCommandRecording,
      "MCP could not start recording: \(recording)")
    let recordingURL = root.appendingPathComponent("mcp-recording.gsc")
    _ = try await tool("resize_window", ["width": 870, "height": 660])
    _ = try await tool("set_background", ["mode": "solid", "primary": [0.2, 0.3, 0.4, 1]])
    _ = try await tool(componentTool, ["channel": 0, "component": 3, "points": [[0.5, 0.2]]])
    let recordedTF = try service.transferFunction(channel: 0)
    try expect(recordedTF.samples.allSatisfy { $0[3] == 51 }, "A single control point should set a constant")
    let stopped = try await tool("stop_command_recording", ["output_path": recordingURL.path])
    try expect(stopped["isError"] as? Bool != true && !session.isCommandRecording &&
      FileManager.default.fileExists(atPath: recordingURL.path), "MCP could not save recording: \(stopped)")
    try expect(try await tool("replay_command_recording", ["input_path": recordingURL.path])["isError"] as? Bool == true,
      "Replay accepted a recording without confirmation")
    try service.setTransferFunction(rampTF)
    try expect(try await tool("replay_command_recording", ["input_path": recordingURL.path, "confirm": true])["isError"] as? Bool != true,
      "MCP native recording replay failed")
    try expect(try service.transferFunction(channel: 0) == recordedTF, "The recorded component change did not replay exactly")
    _ = try await tool("set_background", ["mode": "solid", "primary": [0, 0, 0, 1]])
    try expect(service.background().primary == [0, 0, 0, 1], "MCP background setter failed")
    isolated.set(3.5, forKey: "oversampling")
    isolated.set("secret-token", forKey: "mcpAccessToken")
    let settingsURL = root.appendingPathComponent("backup.borgvrsettings")
    _ = try await tool("save_settings", ["output_path": settingsURL.path, "include_credentials": true])
    _ = try await tool("reset_settings", ["confirm": true])
    try expect(isolated.double(forKey: "oversampling") == 2 && isolated.string(forKey: "mcpAccessToken") == "secret-token",
      "MCP reset failed or disconnected its own transport")
    _ = try await tool("load_settings", ["input_path": settingsURL.path])
    try expect(isolated.double(forKey: "oversampling") == 3.5, "MCP settings backup was not restored")

    let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: 4, height: 4))
    let imageData = NSMutableData()
    let destination = CGImageDestinationCreateWithData(imageData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    let gradientCapture = try BorgVRMCPImage(pngData: imageData as Data, width: 4, height: 4, renderedFrame: 0)
      .composited(over: .init(mode: "gradient", primary: [1, 0, 0, 1], secondary: [0, 0, 1, 1]))
    let gradientSource = CGImageSourceCreateWithData(gradientCapture.pngData as CFData, nil)!
    let gradientImage = CGImageSourceCreateImageAtIndex(gradientSource, 0, nil)!
    let gradientBytes = gradientImage.dataProvider!.data! as Data
    let stride = gradientImage.bitsPerPixel / 8
    let lastRow = gradientImage.bytesPerRow * 3
    try expect(stride >= 3 && gradientBytes[0] > gradientBytes[2] &&
      gradientBytes[lastRow] < gradientBytes[lastRow+2], "Screenshot gradient is upside down")
    let paired = try testPairedScreenshotReadback()
    model.renderScreenshotHandler = { id, url, _, maxWidth, completion in
      do {
        let png = maxWidth == 2 ? paired.preview : imageData as Data
        try png.write(to: url!)
        model.screenshotCache.begin(id)
        model.screenshotCache.store(paired.positions, id: id, renderedFrame: 17)
        completion(.success(url!))
      } catch { completion(.failure(error)) }
    }
    _ = try await tool("start_command_recording")
    for alpha in [true, false] {
      let capture = try await tool("capture_screenshot", ["include_alpha": alpha,
        "output_path": root.appendingPathComponent("capture-\(alpha).png").path])
      try expect(capture["isError"] as? Bool != true, "MCP screenshot failed")
      let file = try Data(contentsOf: root.appendingPathComponent("capture-\(alpha).png"))
      let source = CGImageSourceCreateWithData(file as CFData, nil)!
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
      try expect((properties[kCGImagePropertyHasAlpha] as? Bool ?? false) == alpha, "Screenshot alpha option ignored")
    }
    let previewURL = root.appendingPathComponent("capture-preview.png")
    let preview = try await tool("capture_screenshot", ["max_width": 2, "output_path": previewURL.path])
    let previewInfo = preview["structuredContent"] as? [String: Any]
    try expect(previewInfo?["width"] as? Int == 2 && previewInfo?["height"] as? Int == 2,
      "MCP preview did not return the reduced dimensions")
    let previewPick = try await tool("pick_screenshot_positions", [
      "screenshot_id": previewInfo!["screenshotId"]!, "points": [["x": 0.125, "y": 0.125]]
    ])
    try expect((previewPick["structuredContent"] as? [String: Any])?["positions"] as? [[Double]] == [[0.125, 0.875, 0.25]],
      "Normalized picking changed after resizing the PNG")
    for width in [0, -1, true, 1.5, 16_385, "100", NSNull()] as [Any] {
      let invalid = try await tool("capture_screenshot", ["max_width": width])
      try expect(invalid["isError"] as? Bool == true, "MCP accepted an invalid screenshot width: \(width)")
    }
    let extendedURL = root.appendingPathComponent("extended.borgvrcapture")
    let saved = try await tool("capture_extended_screenshot", ["output_path": extendedURL.path])
    let savedID = (saved["structuredContent"] as! [String: Any])["screenshotId"] as! String
    let pickArgs: [String: Any] = ["screenshot_id": savedID,
      "points": [["x": 0.125, "y": 0.125], ["x": 0.875, "y": 0.875]]]
    let picked = try await tool("pick_screenshot_positions", pickArgs)
    let positions = (picked["structuredContent"] as! [String: Any])["positions"] as! [Any]
    try expect(positions[0] as? [Double] == [0.125, 0.875, 0.25] && positions[1] is NSNull,
      "Picking returned an incorrect position or background hit: \(picked)")
    let inline = try await tool("capture_extended_screenshot")
    let resource = (inline["content"] as! [[String: Any]])[0]["resource"] as! [String: Any]
    let savedBytes = try Data(contentsOf: extendedURL)
    try expect(Data(base64Encoded: resource["blob"] as! String) == savedBytes, "Inline and file captures differ")
    let expired = try await tool("pick_screenshot_positions", pickArgs)
    try expect((expired["structuredContent"] as? [String: Any])?["available"] as? Bool == false,
      "The previous screenshot remained accessible")
    let screenshotRecordingURL = root.appendingPathComponent("screenshot-recording.gsc")
    let screenshotRecording = try await tool("stop_command_recording", ["output_path": screenshotRecordingURL.path])
    try expect(screenshotRecording["isError"] as? Bool != true, "Screenshot recording failed: \(screenshotRecording)")
    for alpha in [true, false] { try FileManager.default.removeItem(at: root.appendingPathComponent("capture-\(alpha).png")) }
    try FileManager.default.removeItem(at: previewURL)
    try FileManager.default.removeItem(at: extendedURL)
    session.startCommandRecording()
    try service.setBackground(background)
    try await session.finishCommandRecording()
    let recordedCommands = try BorgVRRecordedGSC.commands(in: Data(session.recordedGSCScript().utf8))
    try expect(recordedCommands.contains { if case .setBackground = $0 { return true }; return false },
      "Background changes are not recordable")

    let runner = BorgVRScriptRunner()
    let stored = StoredAppModel()
    let sharePlay = SharePlayCoordinator(platformAdapter: MacSharePlayPlatformAdapter(
      storedAppModel: stored, serverController: BackgroundServerController()))
    runner.configure(appModel: model, renderingParameters: parameters, session: session,
      appSettings: settings, storedAppModel: stored, sharePlay: sharePlay,
      docking: DockingController(defaults: isolated), commandService: service)
    _ = try await service.resizeWindow(width: 800, height: 600, units: "points", area: "content")
    runner.runScript(at: recordingURL)
    let recordingDeadline = ContinuousClock.now + .seconds(15)
    while runner.isRunning {
      if ContinuousClock.now >= recordingDeadline { runner.stopScript(); throw Failure.failed("Recording replay timed out") }
      try await Task.sleep(for: .milliseconds(10))
    }
    try expect(runner.scriptLogText.contains("Script finished") &&
      (try service.windowState().contentSizePoints == [870, 660]),
      "MCP window recording did not round-trip: \(runner.scriptLogText)")
    runner.runScript(at: screenshotRecordingURL)
    let screenshotDeadline = ContinuousClock.now + .seconds(15)
    while runner.isRunning {
      if ContinuousClock.now >= screenshotDeadline { runner.stopScript(); throw Failure.failed("Screenshot replay timed out") }
      try await Task.sleep(for: .milliseconds(10))
    }
    try expect(runner.scriptLogText.contains("Script finished") &&
      FileManager.default.fileExists(atPath: root.appendingPathComponent("capture-true.png").path) &&
      FileManager.default.fileExists(atPath: root.appendingPathComponent("capture-false.png").path) &&
      FileManager.default.fileExists(atPath: extendedURL.path),
      "Screenshot destinations did not round-trip: \(runner.scriptLogText)")
    try expect(try Data(contentsOf: previewURL) == paired.preview, "Screenshot preview width did not survive GSC replay")
    let scriptURL = root.appendingPathComponent("roundtrip.gsc")
    let script = """
    fullscreen false
    resize 840 620
    resize \(frameWidth) \(frameHeight) pixels frame
    set window getwindowstate
    log $window
    settransferfunctionjson 0 '[[0,0,0,0],[12,34,56,255]]'
    settransferfunctioncomponent 0 2 '[[0.25,0],[0.35,1],[0.5,0],[0.75,1]]'
    set savedTF gettransferfunction 0
    settransferfunction 0 $savedTF
    background solid 0 0 0
    set savedBackground getbackground
    background solid 1 1 1
    setbackgroundstate "$savedBackground"
    savetf 0 "\(root.path)/script.tf1d"
    loadtf 0 "\(root.path)/script.tf1d"
    savestate "\(root.path)/script.json"
    reset
    loadstate "\(root.path)/script.json"
    savesettings "\(root.path)/script.borgvrsettings" true
    resetsettings
    loadsettings "\(root.path)/script.borgvrsettings"
    screenshot "\(root.path)/script.png" false
    screenshot "\(root.path)/script-preview.png" 2
    extendedscreenshot "\(root.path)/script-extended" false
    """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    runner.runScript(at: scriptURL)
    let scriptDeadline = ContinuousClock.now + .seconds(15)
    while runner.isRunning {
      if ContinuousClock.now >= scriptDeadline { runner.stopScript(); throw Failure.failed("GSC test timed out") }
      try await Task.sleep(for: .milliseconds(10))
    }
    try expect(runner.scriptLogText.contains("Script finished"), "GSC failed: \(runner.scriptLogText)")
    let scriptedCapture = try Data(contentsOf: root.appendingPathComponent("script-extended.borgvrcapture"))
    try expect(scriptedCapture.prefix(8) == Data("BVRPOS1\n".utf8), "GSC did not save the extended screenshot")
    try expect(try service.windowState().frameSizePixels == [frameWidth, frameHeight] &&
      runner.scriptLogText.contains("backingScaleFactor"), "GSC window commands/getter failed")
    let scriptedTF = try service.transferFunction(channel: 0).samples
    let peak = Int((Double(scriptedTF.count - 1) * 0.35).rounded())
    let dip = (scriptedTF.count - 1) / 2
    try expect(scriptedTF.last == [12, 34, 255, 255] && scriptedTF[peak][2] >= 250 && scriptedTF[dip][2] <= 5,
      "GSC multi-segment TF setter or TF restore failed")
    try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("script.png").path), "GSC screenshot was not saved")
    try expect(try Data(contentsOf: root.appendingPathComponent("script-preview.png")) == paired.preview,
      "GSC screenshot width was ignored")
    if let device = MTLCreateSystemDefaultDevice() { try testDeferredTFUpload(device: device) }
    try await testCommandRecordingRoundtrip(fixture: URL(fileURLWithPath: CommandLine.arguments[1]), directory: root)
    print("MCP/GSC visualization tests passed: live HTTP tools, main-window point/pixel resize, fullscreen notification/cancellation lifecycle, TF channels/files, picture roundtrip, validation/no-clobber, settings backup/reset/restore, screenshots, recording and real interpreter execution")
  }

  static func testFullscreenTransitions() async throws {
    let window = FullscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let automation = MacWindowAutomation()
    automation.attach(to: window)
    let enter = Task { try await automation.setFullscreen(true) }
    while window.toggleCount == 0 { await Task.yield() }
    try expect(try automation.windowState().transitioning, "Fullscreen did not wait for AppKit")
    do {
      _ = try await automation.setFullscreen(false)
      throw Failure.failed("Concurrent fullscreen change accepted")
    } catch is BorgVRMCPCommandError {}
    window.completeTransition(fullscreen: true)
    let entered = try await enter.value
    try expect(entered.fullscreen && !entered.transitioning, "Fullscreen completion state mismatch")
    _ = try await automation.setFullscreen(true)
    try expect(window.toggleCount == 1, "Idempotent fullscreen toggled again")
    let resize = Task { try await automation.resize(width: 850, height: 650, units: "points", area: "content") }
    while window.toggleCount == 1 { await Task.yield() }
    window.completeTransition(fullscreen: false)
    let resized = try await resize.value
    try expect(!resized.fullscreen && resized.contentSizePoints == [850, 650], "Resize did not await fullscreen exit")
    let cancelled = Task { try await automation.setFullscreen(true) }
    while window.toggleCount == 2 { await Task.yield() }
    cancelled.cancel()
    do { _ = try await cancelled.value; throw Failure.failed("Cancelled fullscreen operation completed") }
    catch is CancellationError {}
    window.completeTransition(fullscreen: true)
    // Drain the notification handler before checking close-while-waiting.
    while try automation.windowState().transitioning { await Task.yield() }
    let closing = Task { try await automation.setFullscreen(false) }
    while window.toggleCount == 3 { await Task.yield() }
    window.closeDuringTransition()
    do { _ = try await closing.value; throw Failure.failed("Closing the target did not abort fullscreen") }
    catch is BorgVRMCPCommandError {}
  }

  static func testDeferredTFUpload(device: MTLDevice) throws {
    let tf = TransferFunction1D(count: 2)
    try tf.updateData(with: [SIMD4(0, 0, 0, 0), SIMD4(12, 34, 56, 255)])
    tf.initMetal(device: device)
    let library = try device.makeLibrary(source: """
      #include <metal_stdlib>
      using namespace metal;
      vertex float4 vertexMain(uint id [[vertex_id]]) {
        const float2 points[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
        return float4(points[id], 0, 1);
      }
      fragment float4 fragmentMain(texture1d<float> tf [[texture(0)]]) {
        return tf.read(tf.get_width()-1);
      }
      """, options: nil)
    let pipeline = MTLRenderPipelineDescriptor()
    pipeline.vertexFunction = library.makeFunction(name: "vertexMain")
    pipeline.fragmentFunction = library.makeFunction(name: "fragmentMain")
    pipeline.colorAttachments[0].pixelFormat = .rgba8Unorm
    let state = try device.makeRenderPipelineState(descriptor: pipeline)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
      width: 1, height: 1, mipmapped: false)
    descriptor.usage = [.renderTarget]
    descriptor.storageMode = .shared
    let target = device.makeTexture(descriptor: descriptor)!
    let queue = device.makeCommandQueue()!
    func renderedColor() throws -> [UInt8] {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .dontCare
      pass.colorAttachments[0].storeAction = .store
      let command = queue.makeCommandBuffer()!
      let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
      encoder.setRenderPipelineState(state)
      try tf.bind(to: encoder, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      encoder.endEncoding()
      command.commit()
      command.waitUntilCompleted()
      if let error = command.error { throw error }
      var bytes = [UInt8](repeating: 0, count: 4)
      bytes.withUnsafeMutableBytes {
        target.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
      }
      return bytes
    }
    try expect(try renderedColor() == [12, 34, 56, 255], "Initial TF texture was not uploaded")
    try tf.updateData(with: [SIMD4(0, 0, 0, 0), SIMD4(200, 100, 50, 255)])
    try expect(try renderedColor() == [200, 100, 50, 255], "Deferred TF upload did not reach the GPU")
  }
}

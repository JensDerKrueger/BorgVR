import SwiftUI
import CompositorServices
import GroupActivities

struct ContentStageConfiguration: CompositorLayerConfiguration {

  var disableFoveation : Bool

  func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
    configuration.depthFormat = .depth32Float
    configuration.colorFormat = .bgra8Unorm_srgb

    let foveationEnabled = capabilities.supportsFoveation && !disableFoveation
    configuration.isFoveationEnabled = foveationEnabled

    let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationEnabled ? [.foveationEnabled] : []
    let supportedLayouts = capabilities.supportedLayouts(options: options)

    configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated
  }
}

@main
struct VisionApp: App {

  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  @State private var runtimeAppModel = RuntimeAppModel()
  @State private var sharedAppModel = SharedAppModel()
  @StateObject private var storedAppModel = StoredAppModel()

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openImmersiveSpace) private var openImmersiveSpace
  @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

  var body: some Scene {
    WindowGroup(id: "main") {
      ContentView()
        .frame(
          minWidth: runtimeAppModel.windowSize.width, maxWidth: runtimeAppModel.windowSize.width,
          minHeight: runtimeAppModel.windowSize.height, maxHeight: runtimeAppModel.windowSize.height
        )
        .trackView(name: "MainView")
        .environment(runtimeAppModel)
        .onOpenURL { url in
          Task {
            await handleOpenRequest(url:url)
          }
        }
        .task {
          GroupActivityHelper.registerGroupActivity()
        }
        .task {
          await NotificationHelper.requestAuthorization(storedAppModel:storedAppModel)
        }
        .task {
          await sharedAppModel.configureGroupActivities(runtimeAppModel:runtimeAppModel)
        }
    }
    .environment(runtimeAppModel)
    .environment(sharedAppModel)
    .environmentObject(storedAppModel)
    .windowResizability(.contentSize)
    .defaultSize(width:runtimeAppModel.windowSize.width,height:runtimeAppModel.windowSize.height)
    .onChange(of: scenePhase) {
      if scenePhase == .background {
        quitApp()
      }
    }
    .onChange(of: runtimeAppModel.immersiveSpaceIntent) { _, newValue in
      Task { @MainActor in
        switch newValue {
          case .open:  await openSpace()
          case .close: await closeSpace()
          default: break
        }
      }
    }

    // Transfer Function Editor Window
    WindowGroup(id: "TransferFunctionEditorView") {
      TransferFunctionEditorView()
        .trackView(name: "TransferFunctionEditorView")
        .environment(runtimeAppModel)
        .environment(sharedAppModel)
        .environmentObject(storedAppModel)
        .frame(
          minWidth: 400, maxWidth: 600,
          minHeight: 1050, maxHeight: 1050
        )
    }
    .windowResizability(.contentSize)
    .windowStyle(.plain)


    // Iso-Value Editor Window
    WindowGroup(id: "IsovalueEditorView") {
      IsovalueEditorView()
        .trackView(name: "IsovalueEditorView")
        .environment(runtimeAppModel)
        .environment(sharedAppModel)
        .frame(
          minWidth: 300,
          minHeight: 200
        )
    }
    .windowResizability(.contentSize)
    .windowStyle(.plain)

    // Performance Window
    WindowGroup(id: "PerformanceGraphView") {
      PerformanceGraphView()
        .trackView(name: "PerformanceGraphView")
        .environment(runtimeAppModel)
        .frame(
          minWidth: 300,
          minHeight: 200
        )
    }
    .windowResizability(.contentSize)

    // Advanced Settings Window
    WindowGroup(id: "ProfileView") {
      ProfileView()
        .trackView(name: "ProfileView")
        .environment(runtimeAppModel)
        .environment(sharedAppModel)
        .environmentObject(storedAppModel)
    }
    .windowResizability(.contentSize)
    .defaultSize(width:800,height:1200)

    // Logger Window
    WindowGroup(id: "LoggerView") {
      LoggerView(logger:runtimeAppModel.logger)
        .trackView(name: "LoggerView")
        .environment(runtimeAppModel)
        .frame(
          minWidth: 300,
          minHeight: 200
        )
    }
    .windowResizability(.contentSize)

    ImmersiveSpace(id: runtimeAppModel.immersiveSpaceID) {
      CompositorLayer(configuration: ContentStageConfiguration(disableFoveation: storedAppModel.disableFoveation)) {
        @MainActor layerRenderer in
        ImmersiveBootstrap.run(layerRenderer: layerRenderer,
                               runtimeAppModel: runtimeAppModel,
                               storedAppModel: storedAppModel,
                               sharedAppModel: sharedAppModel)
      }
    }
    .immersionStyle(selection: .constant(runtimeAppModel.mixedImmersionStyle ? .mixed : .full), in: runtimeAppModel.mixedImmersionStyle ? .mixed : .full)
    .handlesExternalEvents(matching: [groupActivityIdentifier])
  }

  func quitApp() {
    if runtimeAppModel.immersiveSpaceState == .open {
      Task { @MainActor in
        await dismissImmersiveSpace()
      }
    }
    runtimeAppModel.quitApp()
  }

  @MainActor
  private func openSpace() async {
    if runtimeAppModel.immersiveSpaceState == .open {
      runtimeAppModel.immersiveSpaceState = .inTransition
      await dismissImmersiveSpace()
    }

    runtimeAppModel.immersiveSpaceState = .inTransition
    switch await openImmersiveSpace(id: runtimeAppModel.immersiveSpaceID) {
      case .opened:
        runtimeAppModel.currentState = .renderData
      case .userCancelled, .error:
        fallthrough
      @unknown default:
        runtimeAppModel.immersiveSpaceState = .closed
    }

    if runtimeAppModel.groupSessionHost {
      sharedAppModel.openSharedView()
    }
    runtimeAppModel.immersiveSpaceIntent = .keepCurrent
  }

  @MainActor
  private func closeSpace() async {
    runtimeAppModel.immersiveSpaceState = .inTransition
    await dismissImmersiveSpace()
    runtimeAppModel.immersiveSpaceIntent = .keepCurrent
    runtimeAppModel.currentState = .selectData

    if runtimeAppModel.groupSessionHost {
      sharedAppModel.shutdownGroupsession()
    }

    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    if let activeDataset = runtimeAppModel.activeDataset {
      let autoURL = documentsDirectory.appendingPathComponent(activeDataset.uniqueId)
      if storedAppModel.autoloadTF {
        let fileURL = URL(
          fileURLWithPath: autoURL.deletingPathExtension().path() + ".tf1d"
        )
        try? sharedAppModel.transferFunction.save(to: fileURL)
      }
      if storedAppModel.autoloadTransform {
        let fileURL = URL(
          fileURLWithPath: autoURL.deletingPathExtension().path() + ".trafo"
        )
        try? sharedAppModel.modelTransform.save(to: fileURL)
      }
    }
  }

  @MainActor
  private func handleOpenRequest(url:URL) async {
    do {
      guard url.startAccessingSecurityScopedResource() else {
        throw FileError.noPermission("No Permission to access file \(url)")
      }
      defer { url.stopAccessingSecurityScopedResource() }

      let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
      guard let externalMeta = try? BORGVRMetaData(url: url) else {
        throw FileError.noPermission("Invalid file \(url)")
      }

      let localURL : URL
      if let existingURL = findlocalFile(id: externalMeta.uniqueID) {
        localURL = existingURL
      } else {
        guard let copyURL = copyFile(from: url, toDir: documentsDirectory, logger: nil) else {
          throw FileError
            .noPermission(
              "Unable to copy file \(url) to document directory"
            )
        }
        localURL = copyURL
      }

      runtimeAppModel.startImmersiveSpace(identifier: localURL.path(),
                                   description: externalMeta.description,
                                   source: .local,
                                   uniqueId: externalMeta.uniqueID,
                                   asGroupSessionHost: true)
    } catch {
      runtimeAppModel.logger.error(error.localizedDescription)
    }
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

//
//  VisionAppApp.swift
//  VisionApp
//
//  Created by Jens Krüger on 18.02.25.
//

import SwiftUI
import CompositorServices

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

  @State private var appModel = AppModel()
  @State private var renderingParamaters = RenderingParamaters()
  @StateObject private var appSettings = AppSettings()

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

  var body: some Scene {
    WindowGroup(id: "main") {
      ContentView()
        .frame(
          minWidth: appModel.windowSize.width, maxWidth: appModel.windowSize.width,
          minHeight: appModel.windowSize.height, maxHeight: appModel.windowSize.height
        )
        .trackView(name: "MainView")
        .environment(appModel)
    }
    .environment(appModel)
    .environment(renderingParamaters)
    .environmentObject(appSettings)
    .windowResizability(.contentSize)
    .defaultSize(width:appModel.windowSize.width,height:appModel.windowSize.height)
    .onChange(of: scenePhase) {
      if scenePhase == .background {
        quitApp()
      }
    }

    // Transfer Function Editor Window
    WindowGroup(id: "TransferFunctionEditorView") {
      TransferFunctionEditorView()
        .trackView(name: "TransferFunctionEditorView")
        .environment(appModel)
        .environment(renderingParamaters)
        .environmentObject(appSettings)
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
        .environment(appModel)
        .environment(renderingParamaters)
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
        .environment(appModel)
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
        .environment(appModel)
        .environment(renderingParamaters)
        .environmentObject(appSettings)
    }
    .windowResizability(.contentSize)
    .defaultSize(width:800,height:1200)

    // Logger Window
    WindowGroup(id: "LoggerView") {
      LoggerView(logger:appModel.logger)
        .trackView(name: "LoggerView")
        .environment(appModel)
        .frame(
          minWidth: 300,
          minHeight: 200
        )
    }
    .windowResizability(.contentSize)

    ImmersiveSpace(id: appModel.immersiveSpaceID) {
      CompositorLayer(configuration: ContentStageConfiguration(disableFoveation: appSettings.disableFoveation)) { @MainActor layerRenderer in

        let dataset : BORGVRDatasetProtocol
        do {
          switch appModel.datasetSource {
            case .Local:
              dataset = try BORGVRFileData(filename: appModel.activeDataset)
            case .Remote:
              let manager = BORGVRRemoteDataManager(
                host: appSettings.serverAddress,
                port: UInt16(appSettings.serverPort),
                logger:appModel.logger
              )
              try manager.connect(timeout: appSettings.timeout)

              if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {

                let fileURL = documentsURL.appendingPathComponent(
                  "\(appSettings.serverAddress)-\(appModel.activeDataset).data"
                )

                dataset = try manager.openDataset(
                  datasetID: Int(appModel.activeDataset)!,
                  timeout: appSettings.timeout,
                  localCacheFilename: appSettings.makeLocalCopy ? fileURL.path : nil
                )

              } else {
                dataset = try manager.openDataset(
                  datasetID: Int(appModel.activeDataset)!,
                  timeout: appSettings.timeout
                )
              }
          }
        } catch {
          return
        }

        let timer = CPUFrameTimer()
        appModel.timer = timer

        renderingParamaters.reset()

        if appModel.datasetSource == .Local {
          if appSettings.autoloadTF {
            let tfFilename = URL(fileURLWithPath: appModel.activeDataset).deletingPathExtension().path()+".tf1d"
            let fileURL = URL(fileURLWithPath: tfFilename)
            try? renderingParamaters.transferFunction.load(from: fileURL)
          }
          if appSettings.autoloadTransform {
            let tfFilename = URL(fileURLWithPath: appModel.activeDataset).deletingPathExtension().path()+".trafo"
            let fileURL = URL(fileURLWithPath: tfFilename)
            try? renderingParamaters.loadTransform(from: fileURL)
          }
        }

        renderingParamaters.updateRanges(minValue: dataset.getMetadata().minValue,
                                         maxValue: dataset.getMetadata().maxValue,
                                         rangeMax: dataset.getMetadata().rangeMax)
        Renderer
          .startRenderLoop(
            layerRenderer,
            appModel: appModel,
            appSetings: appSettings,
            renderingParamaters: renderingParamaters,
            timer: timer,
            dataset: dataset,
            logger: appModel.logger
          )

        let fullControlls = ImmersiveInteraction(
          renderingParamaters:  renderingParamaters
        )
        layerRenderer.onSpatialEvent = { events in
          fullControlls
            .handleSpatialEvents(events, appModel.interactionMode)
        }
      }
    }
    .immersionStyle(selection: .constant(appModel.mixedImmersionStyle ? .mixed : .full), in: appModel.mixedImmersionStyle ? .mixed : .full)
  }

  func quitApp() {
    if appModel.immersiveSpaceState == .open {
      Task { @MainActor in
        await dismissImmersiveSpace()
      }
    }
    appModel.quitApp()
  }
}


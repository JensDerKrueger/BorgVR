import Foundation
import SwiftUI
import CompositorServices

enum ImmersiveBootstrap {
  @MainActor
  static func run(layerRenderer: LayerRenderer,
                  runtimeAppModel: RuntimeAppModel,
                  storedAppModel: StoredAppModel,
                  sharedAppModel: SharedAppModel) {

    guard let activeDataset = runtimeAppModel.activeDataset else {
      return
    }

    // Acquire dataset (local vs remote)
    let dataset: BORGVRDatasetProtocol
    do {
      switch activeDataset.source {
        case .local, .builtIn:
          dataset = try BORGVRFileData(filename: activeDataset.identifier)

        case .remote(let address, let port):
          let manager = BORGVRRemoteDataManager(
            host: address,
            port: UInt16(port),
            logger: runtimeAppModel.logger,
            notifier: runtimeAppModel.notifier
          )
          try manager.connect(timeout: storedAppModel.timeout)

          if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {

            // make sure runtimeAppModel.activeDataset is an actual UUID
            let fileURLString: String?
            if UUID(uuidString: activeDataset.identifier) != nil {
              fileURLString = documentsURL.appendingPathComponent("\(activeDataset.identifier).data").path
            } else {
              fileURLString = nil
            }

            dataset = try manager.openDataset(
              datasetID: activeDataset.identifier,
              timeout: storedAppModel.timeout,
              localCacheFilename: storedAppModel.makeLocalCopy ? fileURLString : nil
            )

          } else {
            dataset = try manager.openDataset(
              datasetID: activeDataset.identifier,
              timeout: storedAppModel.timeout
            )
          }
      }
    } catch {
      // If dataset setup fails, just return and let the immersive space close/idle.
      return
    }

    runtimeAppModel.activeDatasetInfo = RuntimeAppModel.DatasetInfo(meta: dataset.getMetadata())

    // Timer setup
    let timer = CPUFrameTimer()
    runtimeAppModel.timer = timer

    // Reset rendering parameters and optionally autoload TF/Transform
    sharedAppModel.reset()

    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let autoURL = documentsDirectory.appendingPathComponent(activeDataset.uniqueId)

    if storedAppModel.autoloadTF {
      let fileURL = URL(
        fileURLWithPath: autoURL.deletingPathExtension().path() + ".tf1d"
      )
      try? sharedAppModel.transferFunction.load(from: fileURL)
      sharedAppModel.synchronize(kind: .full)
    }
    if storedAppModel.autoloadTransform {
      let fileURL = URL(
        fileURLWithPath: autoURL.deletingPathExtension().path() + ".trafo"
      )
      try? sharedAppModel.loadTransform(from: fileURL)
    }

    // Update value ranges from dataset metadata
    sharedAppModel.updateRanges(minValue: dataset.getMetadata().minValue,
                                maxValue: dataset.getMetadata().maxValue,
                                rangeMax: dataset.getMetadata().rangeMax)

    // Start renderer
    Renderer.startRenderLoop(
      layerRenderer,
      runtimeAppModel: runtimeAppModel,
      storedAppModel: storedAppModel,
      sharedAppModel: sharedAppModel,
      timer: timer,
      dataset: dataset,
      isHost: runtimeAppModel.groupSessionHost,
      logger: runtimeAppModel.logger
    )

    // Hook up spatial interactions
    let immersiveInteraction = ImmersiveInteraction(
      sharedAppModel: sharedAppModel
    )
    layerRenderer.onSpatialEvent = { events in
      immersiveInteraction.handleSpatialEvents(
        events,
        runtimeAppModel.interactionMode,
        runtimeAppModel.transferEditState
      )
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

import Foundation
@testable import BorgVR

@main
struct DatasetFirstFrameTests {
  @MainActor
  static func main() {
    let model = AppModel()
    let dataset = AppModel.DatasetEntry(identifier: "/tmp/first-frame.data",
      description: "First frame test", source: .local, uniqueId: UUID().uuidString)
    let metadata = BORGVRMetaData(width: 4, height: 4, depth: 4, componentCount: 1,
      bytePerComponent: 1, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
      brickSize: 4, overlap: 0, minValue: 0, maxValue: 255, compression: false,
      datasetDescription: "First frame test", metaDescription: "")

    model.openDataset(dataset)
    guard case .opening(_, let firstRequest) = model.datasetSessionState else {
      fatalError("Opening must keep the buffering UI visible")
    }
    let key = model.activeDatasetRenderKey
    precondition(model.datasetBufferingPhase == .loadingData)
    model.prepareDatasetRenderer(key: key, metadata: metadata, requestID: firstRequest)
    precondition(model.activeDatasetMetadata === metadata)
    precondition(!model.rendererHasActiveDataset, "Prepared resources are not a completed frame")
    precondition(model.datasetBufferingPhase == .preparingRenderer)
    model.setDatasetBufferingPhase(.renderingFirstFrame, requestID: firstRequest)
    precondition(!model.rendererHasActiveDataset)
    precondition(!model.markRenderedDataset(key: key, requestID: UUID()))
    precondition(!model.markRenderedDataset(key: "other", requestID: firstRequest))
    precondition(model.markRenderedDataset(key: key, requestID: firstRequest))
    precondition(model.rendererHasActiveDataset)
    precondition(!model.markRenderedDataset(key: key, requestID: firstRequest),
      "Later frames must not repeat the ready notification")

    // A late frame from the same dataset must not finish a subsequent opening.
    model.openDataset(dataset)
    guard case .opening(_, let secondRequest) = model.datasetSessionState else {
      fatalError("Reopening must start a new loading request")
    }
    precondition(firstRequest != secondRequest)
    precondition(model.datasetBufferingPhase == .loadingData)
    model.prepareDatasetRenderer(key: key, metadata: metadata, requestID: firstRequest)
    model.setDatasetBufferingPhase(.renderingFirstFrame, requestID: firstRequest)
    precondition(model.activeDatasetMetadata == nil)
    precondition(model.datasetBufferingPhase == .loadingData)
    precondition(!model.markRenderedDataset(key: key, requestID: firstRequest))
    precondition(!model.rendererHasActiveDataset)

    model.prepareDatasetRenderer(key: key, metadata: metadata, requestID: secondRequest)
    model.waitForSharePlayDataset(reason: .datasetSource)
    precondition(!model.markRenderedDataset(key: key, requestID: secondRequest),
      "A completed frame must not reopen a closed dataset")
    precondition(!model.rendererHasActiveDataset)
    print("Dataset first-frame readiness and stale completion tests passed")
  }
}

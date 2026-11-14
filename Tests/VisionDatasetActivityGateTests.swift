import Foundation

@main
struct VisionDatasetActivityGateTests {
  @MainActor
  static func main() throws {
    let gate = VisionDatasetActivityGate()
    func rejects(_ expected: VisionDatasetActivityGate.BusyError,
                 _ operation: () throws -> Void) {
      do {
        try operation()
        fatalError("Expected an activity conflict")
      } catch let error as VisionDatasetActivityGate.BusyError {
        precondition(String(describing: error) == String(describing: expected))
        precondition(!(error.errorDescription ?? "").isEmpty)
      } catch { fatalError("Unexpected error: \(error)") }
    }

    rejects(.renderer) { _ = try gate.beginImport(rendererIsIdle: false) }
    precondition(gate.canPrepareDataset)
    let importing = try gate.beginImport(rendererIsIdle: true)
    precondition(gate.isImporting && !gate.canPrepareDataset)
    rejects(.importing) { _ = try gate.beginImport(rendererIsIdle: true) }
    rejects(.importing) { _ = try gate.beginDatasetPreparation() }
    rejects(.importing) { try gate.checkRendererStart() }

    // A cancellation request or a stale completion must not release active work.
    gate.finishImport(UUID())
    rejects(.importing) { try gate.checkRendererStart() }
    gate.finishImport(importing)
    try gate.checkRendererStart()
    precondition(gate.canPrepareDataset)

    let preparing = try gate.beginDatasetPreparation()
    rejects(.preparing) { _ = try gate.beginImport(rendererIsIdle: true) }
    rejects(.preparing) { _ = try gate.beginDatasetPreparation() }
    gate.finishDatasetPreparation(UUID())
    precondition(gate.isPreparingDataset)
    // The owner of the preparation can start rendering, but imports stay blocked.
    try gate.checkRendererStart()
    gate.finishDatasetPreparation(preparing)
    precondition(gate.canPrepareDataset)

    let nextImport = try gate.beginImport(rendererIsIdle: true)
    gate.finishImport(importing)
    precondition(gate.isImporting)
    gate.finishImport(nextImport)
    precondition(gate.canPrepareDataset)

    func cancelledPreparation() throws {
      let id = try gate.beginDatasetPreparation()
      defer { gate.finishDatasetPreparation(id) }
      throw CancellationError()
    }
    do { try cancelledPreparation() }
    catch is CancellationError { }
    precondition(gate.canPrepareDataset)
    print("Vision activity gate passed: renderer/import exclusion, preparation, cancellation lifetime, stale completions")
  }
}

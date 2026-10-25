import Foundation

enum BORGVRRemoteDataManagerError: Error {
  case invalidResponse(reason: String)
  case timeout(seconds: TimeInterval)
  case sendFailed(Error)
  case receiveFailed(reason: String)
}

struct DatasetInfo { let id: String; let filename: String; let datasetDescription: String }
struct TransferFunctionInfo { let id: String; let filename: String; let transferFunctionDescription: String; let byteCount: Int }
struct MarkerFileInfo { let id: String; let filename: String; let datasetID: String; let markerDescription: String; let byteCount: Int }
struct MeasurementFileInfo { let id: String; let filename: String; let datasetID: String; let measurementDescription: String; let byteCount: Int }
struct MeshFileInfo { let id: UUID; let filename: String; let name: String; let meshDescription: String; let byteCount: Int }

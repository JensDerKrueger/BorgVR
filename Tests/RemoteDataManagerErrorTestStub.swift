import Foundation

enum BORGVRRemoteDataManagerError: Error {
  case invalidResponse(reason: String)
  case timeout(seconds: TimeInterval)
  case sendFailed(Error)
  case receiveFailed(reason: String)
}

import Foundation

struct ServerSyncEndpoint: Identifiable, Codable, Equatable {
  var id: UUID = UUID()
  var address: String
  var port: Int
  var password: String
  var intervalSeconds: Int

  var isUsable: Bool {
    !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    port >= 1 &&
    port <= 65535 &&
    intervalSeconds >= 10
  }

  static var empty: ServerSyncEndpoint {
    ServerSyncEndpoint(
      address: "",
      port: BorgVRSharedDefaults.datasetServerPort,
      password: "",
      intervalSeconds: 300
    )
  }
}

import Foundation

private enum Failure: Error { case failed(String) }

@MainActor
@main
private enum SettingsArchiveTests {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure.failed(message) }
  }

  static func main() throws {
    let suite = "BorgVRSettingsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var password = "private-secret"
    var failWrite = false
    var callbacks = 0
    let store = BorgVRSettingsStore(defaultValues: [
      "brickSize": 64, "brickOverlap": 2, "oversampling": 2.0,
      "sampleJitter": false, "atlasSizeMB": 512, "mcpAccessToken": "token",
      "webServerCertificateData": Data([1, 2, 3]), "oversamplingMode": "dynamic"
    ], defaults: defaults, overrides: [
      .init(key: "serverPassword", defaultValue: "", sensitive: true,
        read: { _ in password }, write: { password = $0 as! String }),
      .init(key: "zzFailure", defaultValue: false, read: { _ in false }, write: { _ in
        if failWrite { throw Failure.failed("simulated Keychain failure") }
      })
    ], maximumAtlasSizeMB: 2048, didImport: { callbacks += 1 })

    func data(_ settings: [String: Any], version: Int = 1) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["format": "BorgVR Settings",
        "formatVersion": version, "settings": settings])
    }
    func exported(_ secrets: Bool) throws -> [String: Any] {
      let root = try JSONSerialization.jsonObject(with: store.export(includeCredentials: secrets)) as! [String: Any]
      return root["settings"] as! [String: Any]
    }
    func reject(_ settings: [String: Any]) throws {
      do {
        let plan = try store.prepareImport(data(settings))
        try store.apply(plan)
      } catch is BorgVRSettingsArchiveError { return }
      throw Failure.failed("Invalid settings were accepted: \(settings)")
    }

    let clean = try exported(false)
    try expect(clean["brickSize"] as? Int == 64, "Unset defaults were omitted")
    try expect(clean["serverPassword"] == nil && clean["mcpAccessToken"] == nil
      && clean["webServerCertificateData"] == nil, "Export leaked credentials")
    let full = try exported(true)
    try expect(full["serverPassword"] as? String == password && full["mcpAccessToken"] as? String == "token",
      "Requested credentials were omitted")
    try expect(full["webServerCertificateData"] as? String == "AQID", "Certificate JSON encoding is not portable")

    let plan = try store.prepareImport(data([
      "brickSize": 32, "oversampling": 1.5, "sampleJitter": true,
      "futureSetting": ["unknown": true], "disableFoveation": true,
      "oversamplingMode": "future-mode"
    ], version: 999))
    try expect(plan.count == 3 && plan.ignoredCount == 3, "Unknown keys or enum values were not ignored")
    try expect(defaults.object(forKey: "brickSize") == nil, "Preparing an import already changed settings")
    try store.apply(plan)
    try expect(defaults.integer(forKey: "brickSize") == 32 && defaults.double(forKey: "oversampling") == 1.5,
      "Partial import did not apply supported settings")
    try expect(defaults.bool(forKey: "sampleJitter"), "Boolean did not round-trip")
    try expect(defaults.object(forKey: "brickOverlap") == nil && password == "private-secret",
      "Missing entries changed existing values")
    try expect(defaults.object(forKey: "futureSetting") == nil, "Unknown key was persisted")
    try expect(callbacks == 1, "Models were not notified after import")

    try reject(["brickSize": -1, "sampleJitter": false])
    try reject(["brickSize": 8, "brickOverlap": 4])
    try reject(["brickSize": 8.5])
    try reject(["sampleJitter": 1])
    try reject(["oversampling": true])
    try reject(["oversampling": "2.0"])
    try reject(["webServerCertificateData": "not base64!"])
    try expect(defaults.bool(forKey: "sampleJitter"), "Failed import applied some entries")

    try store.apply(store.prepareImport(data(["atlasSizeMB": 8192])))
    try expect(defaults.integer(forKey: "atlasSizeMB") == 2048, "Device memory limit was not respected")
    try store.apply(store.prepareImport(data(["serverPassword": "imported", "webServerCertificateData": "BAUG"])))
    try expect(password == "imported" && defaults.data(forKey: "webServerCertificateData") == Data([4, 5, 6]),
      "Credentials did not round-trip")

    failWrite = true
    do {
      try store.apply(store.prepareImport(data(["brickSize": 16, "zzFailure": true])))
      throw Failure.failed("Simulated write failure was ignored")
    } catch Failure.failed(let message) where message == "simulated Keychain failure" {}
    try expect(defaults.integer(forKey: "brickSize") == 32, "Failed write did not restore preceding settings")
    do {
      _ = try store.prepareImport(Data("{}".utf8))
      throw Failure.failed("Unrelated JSON was accepted")
    } catch is BorgVRSettingsArchiveError {}
    print("Settings archive tests passed: partial/forward imports, validation, secrets, limits, rollback")
  }
}

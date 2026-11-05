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
      "brickSize": 64, "brickOverlap": 2, "oversampling": 2.0, "importColorCompression": 0,
      "screenFieldOfView": 45.0, "parallelProjection": false,
      "showDatasetBoundingBox": false,
      "sampleJitter": false, "atlasCompression": 0, "alphaEpsilon": 0.0, "subbrickSkipping": true, "opacityAdaptiveSampling": true, "atlasSizeMB": 512, "mcpAccessToken": "token",
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
    try expect(clean["alphaEpsilon"] as? Double == 0, "Alpha epsilon must default to zero")
    try expect(clean["subbrickSkipping"] as? Bool == true, "Subbrick skipping must default to enabled")
    try expect(clean["opacityAdaptiveSampling"] as? Bool == true, "Opacity-adaptive sampling must default to enabled")
    try expect(clean["atlasCompression"] as? Int == 0, "ASTC must default to disabled")
    try expect(clean["screenFieldOfView"] as? Double == 45, "FOV must default to 45 degrees")
    try expect(clean["parallelProjection"] as? Bool == false, "Perspective must be the default")
    try expect(clean["showDatasetBoundingBox"] as? Bool == false, "Bounding box must default to hidden")
    try expect(clean["serverPassword"] == nil && clean["mcpAccessToken"] == nil
      && clean["webServerCertificateData"] == nil, "Export leaked credentials")
    let full = try exported(true)
    try expect(full["serverPassword"] as? String == password && full["mcpAccessToken"] as? String == "token",
      "Requested credentials were omitted")
    try expect(full["webServerCertificateData"] as? String == "AQID", "Certificate JSON encoding is not portable")

    let plan = try store.prepareImport(data([
      "brickSize": 32, "oversampling": 1.5, "sampleJitter": true, "atlasCompression": 8, "importColorCompression": 4, "alphaEpsilon": 0.007, "subbrickSkipping": false, "opacityAdaptiveSampling": false,
      "futureSetting": ["unknown": true], "disableFoveation": true,
      "oversamplingMode": "future-mode"
    ], version: 999))
    try expect(plan.count == 8 && plan.ignoredCount == 3, "Unknown keys or enum values were not ignored")
    try expect(defaults.object(forKey: "brickSize") == nil, "Preparing an import already changed settings")
    try store.apply(plan)
    try expect(defaults.integer(forKey: "brickSize") == 32 && defaults.double(forKey: "oversampling") == 1.5,
      "Partial import did not apply supported settings")
    try expect(defaults.bool(forKey: "sampleJitter"), "Boolean did not round-trip")
    try expect(!defaults.bool(forKey: "subbrickSkipping"), "Subbrick switch did not round-trip")
    try expect(!defaults.bool(forKey: "opacityAdaptiveSampling"), "Opacity-adaptive switch did not round-trip")
    try expect(defaults.integer(forKey: "atlasCompression") == 8, "ASTC selection did not round-trip")
    try expect(defaults.integer(forKey: "importColorCompression") == 4, "Stored ASTC selection did not round-trip")
    try expect(abs(defaults.double(forKey: "alphaEpsilon") - 0.007) < 1e-12, "Alpha epsilon did not round-trip")
    try expect(defaults.object(forKey: "brickOverlap") == nil && password == "private-secret",
      "Missing entries changed existing values")
    try expect(defaults.object(forKey: "futureSetting") == nil, "Unknown key was persisted")
    try expect(callbacks == 1, "Models were not notified after import")

    try store.apply(store.prepareImport(data(["screenFieldOfView": 67.5, "parallelProjection": true,
      "showDatasetBoundingBox": true])))
    try expect(defaults.double(forKey: "screenFieldOfView") == 67.5 && defaults.bool(forKey: "parallelProjection"),
      "Projection settings did not import")
    let projection = try exported(false)
    try expect(projection["screenFieldOfView"] as? Double == 67.5 && projection["parallelProjection"] as? Bool == true,
      "Projection settings did not export")
    try expect(defaults.bool(forKey: "showDatasetBoundingBox") && projection["showDatasetBoundingBox"] as? Bool == true,
      "Bounding box did not round-trip")
    try reject(["screenFieldOfView": 9])
    try reject(["screenFieldOfView": 121])
    try reject(["parallelProjection": 1])
    try reject(["showDatasetBoundingBox": 1])

    try reject(["brickSize": -1, "sampleJitter": false])
    try reject(["brickSize": 8, "brickOverlap": 4])
    try reject(["brickSize": 8.5])
    try reject(["sampleJitter": 1])
    try reject(["subbrickSkipping": 1])
    try reject(["opacityAdaptiveSampling": 1])
    try reject(["atlasCompression": true])
    try reject(["atlasCompression": 4.5])
    let unsupported = try store.prepareImport(data(["atlasCompression": 6]))
    try expect(unsupported.count == 0 && unsupported.ignoredCount == 1, "Unsupported ASTC modes must be ignored")
    try reject(["oversampling": true])
    try reject(["oversampling": "2.0"])
    try reject(["alphaEpsilon": -0.001])
    try reject(["alphaEpsilon": 1.001])
    try reject(["alphaEpsilon": true])
    try reject(["webServerCertificateData": "not base64!"])
    try expect(defaults.bool(forKey: "sampleJitter"), "Failed import applied some entries")

    try store.apply(store.prepareImport(data(["atlasSizeMB": 8192])))
    try expect(defaults.integer(forKey: "atlasSizeMB") == 2048, "Device memory limit was not respected")
    try expect(defaults.double(forKey: "screenFieldOfView") == 67.5 && defaults.bool(forKey: "parallelProjection"),
      "Partial import changed missing projection settings")
    try expect(defaults.bool(forKey: "showDatasetBoundingBox"), "Partial import changed bounding box visibility")
    try expect(abs(defaults.double(forKey: "alphaEpsilon") - 0.007) < 1e-12, "A missing epsilon entry changed the current value")
    try expect(!defaults.bool(forKey: "subbrickSkipping"), "Partial import changed a missing subbrick switch")
    try expect(!defaults.bool(forKey: "opacityAdaptiveSampling"), "Partial import changed a missing adaptive switch")
    try expect(defaults.integer(forKey: "atlasCompression") == 8, "Partial import changed a missing ASTC selection")
    try store.apply(store.prepareImport(data(["serverPassword": "imported", "webServerCertificateData": "BAUG"])))
    try expect(password == "imported" && defaults.data(forKey: "webServerCertificateData") == Data([4, 5, 6]),
      "Credentials did not round-trip")

    let automationBackup = try store.export(includeCredentials: true)
    defaults.set("keep-this-token", forKey: "mcpAccessToken")
    try store.resetForAutomation()
    try expect(defaults.integer(forKey: "brickSize") == 64 && password.isEmpty,
      "Automation reset did not restore registered defaults/credentials")
    try expect(defaults.string(forKey: "mcpAccessToken") == "keep-this-token",
      "Automation reset disconnected its own control connection")
    try store.importForAutomation(automationBackup)
    try expect(defaults.integer(forKey: "brickSize") == 32 && password == "imported",
      "Automation backup did not restore settings/credentials")
    try expect(defaults.string(forKey: "mcpAccessToken") == "keep-this-token",
      "Automation restore changed MCP authentication")

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

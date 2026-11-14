import Foundation

private enum Failure: Error { case failed(String) }

@MainActor
@main
private enum SettingsArchiveTests {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure.failed(message) }
  }

  static func main() throws {
    try verifyInterfaceVisibility()
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
      "foveationSamplingStrength": 1.0,
      "uiRenderModes": 7, "uiInteractionModes": 127, "uiPanelButtons": 31,
      "showModeResetButtons": true, "showPanelButtons": true, "showPerformanceButton": true,
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
    try expect(clean["foveationSamplingStrength"] as? Double == 1, "Foveation must preserve the previous sampling strength")
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
    try store.apply(store.prepareImport(data(["foveationSamplingStrength": 3.5])))
    let foveation = try exported(false)
    try expect(foveation["foveationSamplingStrength"] as? Double == 3.5,
      "Foveation strength did not round-trip")
    try reject(["foveationSamplingStrength": -0.1])
    try reject(["foveationSamplingStrength": 4.1])
    try reject(["foveationSamplingStrength": true])
    try store.apply(store.prepareImport(data(["uiRenderModes": 4, "uiInteractionModes": 32,
      "uiPanelButtons": 0, "showModeResetButtons": false, "showPanelButtons": false,
      "showPerformanceButton": false])))
    let interface = try exported(false)
    try expect(interface["uiRenderModes"] as? Int == 4 && interface["uiInteractionModes"] as? Int == 32 &&
      interface["uiPanelButtons"] as? Int == 0 && interface["showPanelButtons"] as? Bool == false &&
      interface["showModeResetButtons"] as? Bool == false && interface["showPerformanceButton"] as? Bool == false,
      "Interface visibility did not round-trip")
    for (key, maximum) in [("uiRenderModes", 7), ("uiInteractionModes", 127), ("uiPanelButtons", 31)] {
      try reject([key: -1])
      try reject([key: maximum + 1])
      try reject([key: true])
      try reject([key: 1.5])
    }
    try reject(["uiRenderModes": 0])
    try reject(["uiInteractionModes": 0])

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
    try expect(defaults.double(forKey: "foveationSamplingStrength") == 3.5,
      "Partial import changed a missing foveation strength")
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
    try expect(defaults.integer(forKey: "uiRenderModes") == 7 && defaults.integer(forKey: "uiInteractionModes") == 127 &&
      defaults.integer(forKey: "uiPanelButtons") == 31 && defaults.bool(forKey: "showPanelButtons"),
      "Settings reset did not restore interface visibility")
    try expect(defaults.double(forKey: "foveationSamplingStrength") == 1,
      "Settings reset did not restore foveation strength")
    try expect(defaults.integer(forKey: "brickSize") == 64 && password.isEmpty,
      "Automation reset did not restore registered defaults/credentials")
    try expect(defaults.string(forKey: "mcpAccessToken") == "keep-this-token",
      "Automation reset disconnected its own control connection")
    try store.importForAutomation(automationBackup)
    try expect(defaults.integer(forKey: "uiRenderModes") == 4 && defaults.integer(forKey: "uiInteractionModes") == 32 &&
      defaults.integer(forKey: "uiPanelButtons") == 0 && !defaults.bool(forKey: "showPanelButtons"),
      "Settings backup did not restore interface visibility")
    try expect(defaults.double(forKey: "foveationSamplingStrength") == 3.5,
      "Settings backup did not restore foveation strength")
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

  static func verifyInterfaceVisibility() throws {
    let all = InterfaceVisibility()
    try expect(all.renderModeIDs == [0, 1, 2] && all.interactionModes.count == 7 &&
      all.hasPanels && all.showsResets, "Default interface unexpectedly hides controls")
    for mask in 1...7 {
      let original = InterfaceVisibility(renderModes: mask)
      for active in all.renderModeIDs {
        let displayed = original.displayedRenderModeIDs(active: active, inSharePlay: true)
        let expected = Array(Set(original.renderModeIDs + [active])).sorted()
        try expect(displayed == expected, "Shared active mode was omitted or duplicated")
        try expect(original.displayedRenderModeIDs(active: active, inSharePlay: false) == original.renderModeIDs,
          "A temporary shared mode remained visible outside SharePlay")
        if !original.renderModeIDs.contains(active) {
          try expect(displayed.count > 1, "Single-mode UI did not reveal the shared mode")
          try expect(original.renderModes == mask && !original.renderModeIDs.contains(active),
            "Displaying the shared mode changed local permissions")
        }
        for allowed in original.renderModeIDs {
          try expect(original.displayedRenderModeIDs(active: allowed, inSharePlay: true) == original.renderModeIDs,
            "Temporary mode remained after selecting a local mode")
        }
      }
      try expect(original.displayedRenderModeIDs(active: 255, inSharePlay: true) == original.renderModeIDs,
        "Invalid remote mode was displayed")
      var visibility = InterfaceVisibility(renderModes: mask)
      for id in all.renderModeIDs {
        visibility.setRenderMode(id, enabled: false)
        try expect(!visibility.renderModeIDs.isEmpty, "The last rendering mode could be disabled")
      }
    }
    for mask in 1...127 {
      let original = InterfaceVisibility(interactions: mask)
      let enabled = original.interactionModes
      try expect(original.forDataset(supportsTransferFunctions: true) == original,
        "Scalar dataset filtering changed the saved interface")
      let color = original.forDataset(supportsTransferFunctions: false)
      try expect(!color.interactionModes.contains(.transferEditing) && !color.interactionModes.isEmpty,
        "Color volumes must hide transfer interaction and retain a usable mode")
      try expect(!color.showsPanel(.transfer) && !color.showsPanel(.lighting) &&
        !color.showsScreenPanel(.transfer) && !color.showsScreenPanel(.lighting),
        "Color volumes retained unsupported panels")
      try expect(original.interactions == mask && original.panels == InterfaceVisibility.allPanels,
        "Color volume filtering modified saved preferences")
      try expect(color.showsPanel(.objects) && color.showsPanel(.measurements) && color.showsPanel(.brush),
        "Color volumes lost supported spatial panels")
      try expect(original.showsScreenPanel(.lighting), "Lighting gained an unrelated interaction dependency")
      try expect(original.showsScreenPanel(.transfer) == enabled.contains(.transferEditing),
        "Transfer panel does not follow transfer interaction visibility")
      try expect(original.showsScreenPanel(.objects) == (enabled.contains(.drawing) || enabled.contains(.objectPlacement)),
        "Object panel must remain available for either drawing or placement")
      try expect(original.showsScreenPanel(.measurements) == enabled.contains(.measurement),
        "Measurement panel does not follow measurement interaction visibility")
      try expect(original.showsScreenPanel(.brush) == enabled.contains(.volumeEditing),
        "Brush panel does not follow volume-editing interaction visibility")
      try expect(InterfaceVisibility.Panel.allCases.allSatisfy { original.showsPanel($0) },
        "Interaction filtering hid visionOS panels needed by independent tools")
      var visibility = InterfaceVisibility(interactions: mask)
      for mode in InterfaceVisibility.Interaction.allCases {
        visibility.setInteraction(mode, enabled: false)
        try expect(!visibility.interactionModes.isEmpty, "The last interaction mode could be disabled")
      }
    }
    var visibility = InterfaceVisibility(renderModes: 0, interactions: 0)
    try expect(visibility.renderModeIDs == [0] && visibility.interactionModes == [.model],
      "Invalid persisted masks must provide a usable fallback")
    visibility.setRenderMode(2, enabled: true)
    visibility.setRenderMode(0, enabled: false)
    visibility.setInteraction(.measurement, enabled: true)
    visibility.setInteraction(.model, enabled: false)
    try expect(visibility.renderModeIDs == [2] && visibility.interactionModes == [.measurement],
      "Single-mode configuration does not preserve the chosen mode")
    for panel in InterfaceVisibility.Panel.allCases { visibility.setPanel(panel, enabled: false) }
    try expect(!visibility.hasPanels && visibility.panels == 0, "All panel buttons must be optional")
    visibility.panels = InterfaceVisibility.allPanels
    visibility.showsPanels = false
    try expect(!visibility.hasPanels && !visibility.showsPanel(.objects), "The panel-row switch was ignored")
    visibility.showsPanels = true
    try expect(visibility.showsPanel(.objects), "Hiding the row discarded its individual selections")
    visibility.interactions = InterfaceVisibility.Interaction.model.bit
    visibility.panels = InterfaceVisibility.Panel.objects.bit
    try expect(visibility.hasPanels && !visibility.hasScreenPanels,
      "Unavailable screen panels must not leave an empty button row; visionOS must retain them")
    visibility.setInteraction(.objectPlacement, enabled: true)
    try expect(visibility.hasScreenPanels, "Re-enabling placement did not restore its panel button")
    visibility.showsPanels = false
    try expect(!visibility.hasScreenPanels, "Screen panel visibility ignored the whole-row switch")
    print("Interface visibility tests passed: all masks, last-mode guards, temporary SharePlay modes and screen/spatial panels")
  }
}

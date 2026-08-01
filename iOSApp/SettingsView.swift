import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject var appSettings: AppSettings

  @State private var tempPort = ""
  @State private var tempServerAddress = ""
  @State private var tempTimeout = ""
  @State private var tempBrickSize = ""
  @State private var tempBrickOverlap = ""
  @State private var tempAtlasSize = ""
  @State private var tempHashSize = ""
  @State private var tempPixelError = ""
  @State private var tempOversampling = ""
  @State private var validationMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("Rendering") {
          Toggle("Transfer Functions automatisch laden/speichern", isOn: $appSettings.autoloadTF)
          Picker("Oversampling", selection: $appSettings.oversamplingMode) {
            Text("Statisch").tag(OversamplingMode.staticMode.rawValue)
            Text("Dynamisch").tag(OversamplingMode.dynamicMode.rawValue)
          }
          Picker("Hintergrund", selection: $appSettings.renderBackgroundMode) {
            ForEach(RenderBackgroundMode.allCases) { mode in
              Text(mode.label).tag(mode.rawValue)
            }
          }
          if appSettings.renderBackgroundMode == RenderBackgroundMode.solid.rawValue {
            ColorPicker("Farbe", selection: Binding(
              get: { appSettings.renderBackgroundPrimaryColor },
              set: { appSettings.renderBackgroundPrimaryColor = $0 }
            ), supportsOpacity: true)
          }
          if appSettings.renderBackgroundMode == RenderBackgroundMode.gradient.rawValue {
            ColorPicker("Farbe oben", selection: Binding(
              get: { appSettings.renderBackgroundPrimaryColor },
              set: { appSettings.renderBackgroundPrimaryColor = $0 }
            ), supportsOpacity: true)
            ColorPicker("Farbe unten", selection: Binding(
              get: { appSettings.renderBackgroundSecondaryColor },
              set: { appSettings.renderBackgroundSecondaryColor = $0 }
            ), supportsOpacity: true)
          }
          TextField("Oversampling", text: $tempOversampling)
            .keyboardType(.decimalPad)
          TextField("Atlasgröße (MB)", text: $tempAtlasSize)
            .keyboardType(.numberPad)
          TextField("Min. Hash-Table-Größe (MB)", text: $tempHashSize)
            .keyboardType(.numberPad)
          Picker("Log-Level", selection: $appSettings.logLevel) {
            ForEach(AppLogLevel.allCases) { level in
              Text(level.label).tag(level.rawValue)
            }
          }
        }

        Section("Import") {
          TextField("Brick-Größe", text: $tempBrickSize)
            .keyboardType(.numberPad)
          TextField("Überlappung", text: $tempBrickOverlap)
            .keyboardType(.numberPad)
          Toggle("Kompression", isOn: $appSettings.enableCompression)
          Picker("Ränder", selection: $appSettings.borderMode) {
            Text("Nullen").tag("zeroes")
            Text("Rand").tag("border")
            Text("Wiederholen").tag("repeat")
          }
        }

        Section("Remote-Datensätze") {
          ForEach(appSettings.servers) { server in
            HStack {
              Text("\(server.address):\(server.port)")
              Spacer()
              Button(role: .destructive) {
                appSettings.servers.removeAll { $0.id == server.id }
              } label: {
                Image(systemName: "trash")
              }
            }
          }

          TextField("Hostname", text: $tempServerAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          TextField("Port", text: $tempPort)
            .keyboardType(.numberPad)
          Button {
            addServer()
          } label: {
            Label("Server hinzufügen", systemImage: "plus")
          }
          TextField("Timeout", text: $tempTimeout)
            .keyboardType(.decimalPad)
          Toggle("Progressives Laden", isOn: $appSettings.progressiveLoading)
          Toggle("Lokale Kopie behalten", isOn: $appSettings.makeLocalCopy)
          Stepper(value: $appSettings.sharePlayServerPort, in: 1...65535) {
            Text(String(format: String(localized: "Ad-hoc Dataset-Server-Port: %d"), appSettings.sharePlayServerPort))
          }
        }

        Section("LOD") {
          TextField("Screen-Space-Pixelfehler", text: $tempPixelError)
            .keyboardType(.decimalPad)
          Stepper(value: $appSettings.initialBricks, in: 0...20000, step: 100) {
            Text(String(format: String(localized: "Initiale Bricks: %d"), appSettings.initialBricks))
          }
          Stepper(value: $appSettings.maxProbingAttempts, in: 1...512) {
            Text(String(format: String(localized: "Max. Suchversuche: %d"), appSettings.maxProbingAttempts))
          }
          Toggle("Low-res LOD mit anfordern", isOn: $appSettings.requestLowResLOD)
          Toggle("Bei fehlendem Brick stoppen", isOn: $appSettings.stopOnMiss)
          if appSettings.oversamplingMode == OversamplingMode.dynamicMode.rawValue {
            Stepper(value: $appSettings.dropFPS, in: 1...120) {
              Text(String(format: String(localized: "Drop FPS: %d"), appSettings.dropFPS))
            }
            Stepper(value: $appSettings.recoveryFPS, in: 1...120) {
              Text(String(format: String(localized: "Recovery FPS: %d"), appSettings.recoveryFPS))
            }
          }
        }

        if let validationMessage {
          Section {
            Text(validationMessage)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Einstellungen")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Zurück") {
            saveSettings()
            appModel.currentState = .start
          }
        }
      }
      .onAppear(perform: loadTemporaryValues)
      .onDisappear(perform: saveSettings)
    }
  }

  private func loadTemporaryValues() {
    tempPort = "12345"
    tempServerAddress = ""
    tempTimeout = String(appSettings.timeout)
    tempBrickSize = String(appSettings.brickSize)
    tempBrickOverlap = String(appSettings.brickOverlap)
    tempAtlasSize = String(appSettings.atlasSizeMB)
    tempHashSize = String(appSettings.minHashTableSize)
    tempPixelError = String(appSettings.screenSpaceError)
    tempOversampling = String(appSettings.oversampling)
  }

  private func saveSettings() {
    validationMessage = nil
    if let timeout = Double(tempTimeout.replacingOccurrences(of: ",", with: ".")), timeout > 0 {
      appSettings.timeout = timeout
    }
    if let brickSize = Int(tempBrickSize), brickSize >= 1 + appSettings.brickOverlap * 2 {
      appSettings.brickSize = brickSize
    }
    if let overlap = Int(tempBrickOverlap), overlap >= 1, appSettings.brickSize - overlap * 2 >= 1 {
      appSettings.brickOverlap = overlap
    }
    if let atlasSize = Int(tempAtlasSize), atlasSize >= 1 {
      appSettings.atlasSizeMB = atlasSize
    }
    if let hashSize = Int(tempHashSize), hashSize >= 1 {
      appSettings.minHashTableSize = hashSize
    }
    if let pixelError = Double(tempPixelError.replacingOccurrences(of: ",", with: ".")), pixelError > 0 {
      appSettings.screenSpaceError = pixelError
    }
    if let oversampling = Double(tempOversampling.replacingOccurrences(of: ",", with: ".")), oversampling > 0 {
      appSettings.oversampling = oversampling
    }
  }

  private func addServer() {
    guard !tempServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let port = UInt16(tempPort) else {
      validationMessage = String(localized: "Server braucht Hostname und Port zwischen 0 und 65535.")
      return
    }
    appSettings.servers.append(
      StoredServer(
        address: tempServerAddress.trimmingCharacters(in: .whitespacesAndNewlines),
        port: Int(port)
      )
    )
    tempServerAddress = ""
    validationMessage = nil
  }
}

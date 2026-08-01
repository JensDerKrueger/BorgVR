import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var storedAppModel: StoredAppModel

  @State private var serverAddress = ""
  @State private var serverPort = "12345"
  @State private var showDataDirectoryPicker = false

  var body: some View {
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
        Stepper(value: $appSettings.atlasSizeMB, in: 128...16384, step: 128) {
          Text("Atlasgröße: \(appSettings.atlasSizeMB) MB")
        }
        Stepper(value: $appSettings.minHashTableSize, in: 1...1024) {
          Text("Min. Hash-Table-Größe: \(appSettings.minHashTableSize) MB")
        }
        Picker("Log-Level", selection: $appSettings.logLevel) {
          ForEach(AppLogLevel.allCases) { level in
            Text(level.label).tag(level.rawValue)
          }
        }
      }

      Section("Import") {
        Stepper(value: $storedAppModel.brickSize, in: 8...512, step: 8) {
          Text("Brick-Größe: \(storedAppModel.brickSize)")
        }
        Stepper(value: $storedAppModel.brickOverlap, in: 1...16) {
          Text("Überlappung: \(storedAppModel.brickOverlap)")
        }
        Toggle("Kompression", isOn: $storedAppModel.enableCompression)
        Picker("Ränder", selection: $storedAppModel.borderModeString) {
          Text("Nullen").tag("zeroes")
          Text("Rand").tag("border")
          Text("Wiederholen").tag("repeat")
        }
      }

      Section("Hintergrundserver") {
        Toggle("Server automatisch starten", isOn: $storedAppModel.autoStartServer)
        HStack {
          Text(storedAppModel.dataDirectory)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button {
            showDataDirectoryPicker = true
          } label: {
            Image(systemName: "folder")
          }
          .help("Datenverzeichnis auswählen")
        }
        Stepper(value: $storedAppModel.port, in: 1...65535) {
          Text("Port: \(storedAppModel.port)")
        }
        Stepper(value: $storedAppModel.sharePlayServerPort, in: 1...65535) {
          Text("Ad-hoc Dataset-Server-Port: \(storedAppModel.sharePlayServerPort)")
        }
        Stepper(value: $storedAppModel.maxBricksPerGetRequest, in: 1...1000) {
          Text("Max. Bricks pro Anfrage: \(storedAppModel.maxBricksPerGetRequest)")
        }
      }

      Section("Externe Datenquellen") {
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

        HStack {
          TextField("Serveradresse", text: $serverAddress)
          TextField("Port", text: $serverPort)
            .frame(width: 90)
          Button {
            addRemoteServer()
          } label: {
            Image(systemName: "plus")
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Einstellungen")
    .fileImporter(
      isPresented: $showDataDirectoryPicker,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      if case let .success(urls) = result,
         let selectedURL = urls.first {
        storedAppModel.setDataDirectoryURL(selectedURL)
      }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Zurück") {
          appModel.currentState = .start
        }
      }
    }
  }

  private func addRemoteServer() {
    let trimmedAddress = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedAddress.isEmpty,
          let port = Int(serverPort),
          (1...65535).contains(port),
          !appSettings.servers.contains(where: { $0.address == trimmedAddress && $0.port == port }) else {
      return
    }
    appSettings.servers.append(
      StoredServer(
        address: trimmedAddress,
        port: port
      )
    )
    serverAddress = ""
  }
}

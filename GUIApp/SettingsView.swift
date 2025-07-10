import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var appModel
  @EnvironmentObject var appSettings: AppSettings

  @State private var tempPort: String = ""
  @State private var portError: String?

  @State private var tempBrickSize: String = ""
  @State private var brickSizeErrorMsg: String?

  @State private var tempBrickOverlap: String = ""
  @State private var brickOverlapErrorMsg: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("BorgVR Settings")
        .font(.title)
        .bold()
        .padding(.bottom, 10)

      GroupBox(label: Text("Dataset Server").bold()) {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Port:")
              .frame(width: 50, alignment: .trailing)
            TextField("Port Number", text: $tempPort, onCommit: validatePort)
              .onChange(of: tempPort) { validatePort() }
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .frame(width: 100)
              .onAppear { tempPort = String(appSettings.port) }
          }

          if let error = portError {
            Text(error).foregroundColor(.red).font(.caption).padding(.leading, 124)
          }

          HStack {
            Text("Autostart Server:")
              .frame(width: 120, alignment: .trailing)
            Toggle("", isOn: $appSettings.autoStartServer)
              .labelsHidden()
          }
        }
        .padding(.vertical, 4)
      }

      GroupBox(label: Text("Import Settings").bold()) {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Brick Size:")
              .frame(width: 120, alignment: .trailing)
            TextField("Brick Size", text: $tempBrickSize, onCommit: validateBrickSize)
              .onChange(of: tempBrickSize) { validateBrickSize() }
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .frame(width: 100)
              .onAppear { tempBrickSize = String(appSettings.brickSize) }
          }

          if let error = brickSizeErrorMsg {
            Text(error).foregroundColor(.red).font(.caption).padding(.leading, 124)
          }

          HStack {
            Text("Overlap:")
              .frame(width: 120, alignment: .trailing)
            TextField(
              "Overlap",
              text: $tempBrickOverlap,
              onCommit: validateBrickOverlap
            )
              .onChange(of: tempBrickOverlap) { validateBrickOverlap() }
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .frame(width: 100)
              .onAppear { tempBrickOverlap = String(appSettings.brickOverlap) }
          }

          if let error = brickOverlapErrorMsg {
            Text(error).foregroundColor(.red).font(.caption).padding(.leading, 124)
          }

          HStack {
            Text("Enable Last Minute Changes:")
              .frame(width: 215, alignment: .trailing)
            Toggle("", isOn: $appSettings.lastMinute)
              .labelsHidden()
          }

          HStack {
            Text("Compression:")
              .frame(width: 120, alignment: .trailing)
            Toggle("", isOn: $appSettings.enableCompression)
              .labelsHidden()
          }

          HStack {
            Text("Border Mode:")
              .frame(width: 120, alignment: .trailing)
            Picker("", selection: $appSettings.borderModeString) {
              Text("Zeroes").tag("zeroes")
              Text("Border").tag("border")
              Text("Repeat").tag("repeat")
            }
            .pickerStyle(SegmentedPickerStyle())
            .frame(width: 250)
          }
        }
        .padding(.vertical, 4)
      }

      Spacer()

    }
    .keyboardShortcut(.cancelAction)
    .padding(24)
    .frame(minWidth: 500, idealHeight: 500)
    Button("Back to Main Menu") {
      appModel.currentState = .start
    }
    .padding()
    .onDisappear {
      validatePort()
      validateBrickSize()
      validateBrickOverlap()
    }
  }

  private func validatePort() {
    if let port = UInt16(tempPort) {
      appSettings.port = Int(port)
      portError = nil
    } else {
      portError = "Invalid port. Must be between 0 and 65535."
    }
  }

  private func validateBrickSize() {
    if let size = Int(tempBrickSize), size >= 1 + appSettings.brickOverlap * 2 {
      appSettings.brickSize = size
      brickSizeErrorMsg = nil
    } else {
      brickSizeErrorMsg = "Must be ≥ 1 + overlap × 2."
    }
  }

  private func validateBrickOverlap() {
    if let overlap = Int(tempBrickOverlap), overlap >= 1, appSettings.brickSize - overlap * 2 >= 1 {
      appSettings.brickOverlap = overlap
      brickOverlapErrorMsg = nil
    } else {
      brickOverlapErrorMsg = "Must be ≥ 1 and brickSize − 2×overlap ≥ 1."
    }
  }
}

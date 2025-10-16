import SwiftUI

struct SettingsView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @EnvironmentObject var storedAppModel: StoredAppModel

  @State private var tempPort: String = ""
  @State private var portError: String?

  @State private var tempBrickCount: String = ""
  @State private var brickCountError: String?

  @State private var tempBrickSize: String = ""
  @State private var brickSizeErrorMsg: String?

  @State private var tempBrickOverlap: String = ""
  @State private var brickOverlapErrorMsg: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("BorgVR Settings")
          .font(.title)
          .bold()
      }

      TabView {
        // Server Tab
        VStack(alignment: .leading, spacing: 12) {
          GroupBox(label: Text("Dataset Server").bold()) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
              GridRow {
                Text("Port:")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                TextField("Port Number", text: $tempPort)
                  .onChange(of: tempPort) { validatePort() }
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .frame(width: 120)
                  .accentColor(.blue)
              }
              if let error = portError {
                GridRow {
                  EmptyView()
                  Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                }
              }
              GridRow {
                Text("Max. Brick Count Per Request:")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                TextField("Brick Count", text: $tempBrickCount)
                  .accentColor(.blue)
                  .onChange(of: tempBrickCount) { validateBrickCount() }
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .frame(width: 120)
              }
              if let error = brickCountError {
                GridRow {
                  EmptyView()
                  Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                }
              }
              GridRow {
                Text("Autostart Server:")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                Toggle("", isOn: $storedAppModel.autoStartServer)
                  .labelsHidden()
              }
            }
            .onAppear {
              tempPort = String(storedAppModel.port)
              tempBrickCount = String(storedAppModel.maxBricksPerGetRequest)
            }
            .padding(.vertical, 4)
          }
          Spacer(minLength: 0)
        }
        .tabItem {
          Label("Server", systemImage: "server.rack")
        }

        // Import Tab
        VStack(alignment: .leading, spacing: 12) {
          GroupBox(label: Text("Import Settings").bold()) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
              GridRow {
                Text("Brick Size:")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                TextField("Brick Size", text: $tempBrickSize, onCommit: validateBrickSize)
                  .onChange(of: tempBrickSize) { validateBrickSize() }
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .frame(width: 120)
                  .accentColor(.blue)
              }
              if let error = brickSizeErrorMsg {
                GridRow {
                  EmptyView()
                  Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                }
              }
              GridRow {
                Text("Overlap:")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                TextField("Overlap", text: $tempBrickOverlap, onCommit: validateBrickOverlap)
                  .onChange(of: tempBrickOverlap) { validateBrickOverlap() }
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .frame(width: 120)
                  .accentColor(.blue)
              }
              if let error = brickOverlapErrorMsg {
                GridRow {
                  EmptyView()
                  Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                }
              }
              GridRow {
                Text("Enable Last Minute Changes:")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 220, alignment: .trailing)
                Toggle("", isOn: $storedAppModel.lastMinute)
                  .labelsHidden()
              }
              GridRow {
                Text("Compression:")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                Toggle("", isOn: $storedAppModel.enableCompression)
                  .labelsHidden()
              }
              GridRow {
                Text("Border Mode:")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                Picker("", selection: $storedAppModel.borderModeString) {
                  Text("Zeroes").tag("zeroes")
                  Text("Border").tag("border")
                  Text("Repeat").tag("repeat")
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 280)
              }
            }
            .onAppear {
              tempBrickSize = String(storedAppModel.brickSize)
              tempBrickOverlap = String(storedAppModel.brickOverlap)
            }
            .padding(.vertical, 4)
          }
          Spacer(minLength: 0)
        }
        .tabItem {
          Label("Import", systemImage: "square.and.arrow.down")
        }
      }
      .frame(minWidth: 500, minHeight: 380)

      HStack {
        Button {
          revertToDefaults()
        } label: {
          Label("Revert to Defaults", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.bordered)
        .help("Restore all settings to their default values")

        Spacer()
        Button {
          runtimeAppModel.currentState = .start
        } label: {
          Label("Back to Main Menu", systemImage: "chevron.backward.circle")
        }
      }
    }
    .keyboardShortcut(.cancelAction)
    .padding(24)
    .onDisappear {
      validatePort()
      validateBrickSize()
      validateBrickOverlap()
    }
  }


  private func validateBrickCount() {
    if let brickCount = Int(tempBrickCount), brickCount >= 1, brickCount <= 1000 {
      storedAppModel.maxBricksPerGetRequest = brickCount
      brickCountError = nil
    } else {
      brickCountError = "Invalid Brick Count. Must be between 1 and 1000."
    }
  }

  private func validatePort() {
    if let port = UInt16(tempPort) {
      storedAppModel.port = Int(port)
      portError = nil
    } else {
      portError = "Invalid port. Must be between 0 and 65535."
    }
  }

  private func validateBrickSize() {
    if let size = Int(tempBrickSize), size >= 1 + storedAppModel.brickOverlap * 2 {
      storedAppModel.brickSize = size
      brickSizeErrorMsg = nil
    } else {
      brickSizeErrorMsg = "Must be ≥ 1 + overlap × 2."
    }
  }

  private func validateBrickOverlap() {
    if let overlap = Int(tempBrickOverlap), overlap >= 1, storedAppModel.brickSize - overlap * 2 >= 1 {
      storedAppModel.brickOverlap = overlap
      brickOverlapErrorMsg = nil
    } else {
      brickOverlapErrorMsg = "Must be ≥ 1 and brickSize − 2×overlap ≥ 1."
    }
  }

  private func revertToDefaults() {
    // Let the model own its defaults and publish updates
    storedAppModel.resetToDefaults()

    // Clear errors so the UI reflects the valid default state
    portError = nil
    brickSizeErrorMsg = nil
    brickOverlapErrorMsg = nil
  }
}


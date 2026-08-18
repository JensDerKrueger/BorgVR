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
        Text("settings_title")
          .font(.title)
          .bold()
      }

      TabView {
        // Server Tab
        VStack(alignment: .leading, spacing: 12) {
          GroupBox(label: Text("settings_server_group_title").bold()) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
              GridRow {
                Text("settings_port_label")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                TextField("settings_port_placeholder", text: $tempPort)
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
                Text("Server-Passwort")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                SecureField("Passwort (optional)", text: $storedAppModel.serverPassword)
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .frame(width: 220)
                  .accentColor(.blue)
              }
              GridRow {
                Text("settings_brickcount_label")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                TextField("settings_brickcount_placeholder", text: $tempBrickCount)
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
                Text("settings_autostart_label")
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
          Label("settings_tab_server", systemImage: "server.rack")
        }

        // Import Tab
        VStack(alignment: .leading, spacing: 12) {
          GroupBox(label: Text("settings_import_group_title").bold()) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
              GridRow {
                Text("settings_bricksize_label")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                TextField("settings_bricksize_placeholder", text: $tempBrickSize, onCommit: validateBrickSize)
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
                Text("settings_overlap_label")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                TextField("settings_overlap_placeholder", text: $tempBrickOverlap, onCommit: validateBrickOverlap)
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
                Text("settings_lastminute_label")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 220, alignment: .trailing)
                Toggle("", isOn: $storedAppModel.lastMinute)
                  .labelsHidden()
              }
              GridRow {
                Text("settings_compression_label")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                Toggle("", isOn: $storedAppModel.enableCompression)
                  .labelsHidden()
              }
              GridRow {
                Text("settings_border_label")
                  .gridColumnAlignment(.trailing)
                  .frame(minWidth: 120, alignment: .trailing)
                Picker("", selection: $storedAppModel.borderModeString) {
                  Text("settings_border_zeroes").tag("zeroes")
                  Text("settings_border_border").tag("border")
                  Text("settings_border_repeat").tag("repeat")
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
          Label("settings_tab_import", systemImage: "square.and.arrow.down")
        }
      }
      .frame(minWidth: 500, minHeight: 380)

      HStack {
        Button {
          revertToDefaults()
        } label: {
          Label("settings_button_revert", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.bordered)
        .help("settings_help_revert")

        Spacer()
        Button {
          runtimeAppModel.currentState = .start
        } label: {
          Label("settings_button_back", systemImage: "chevron.backward.circle")
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
      brickCountError = NSLocalizedString(
        "settings_error_brickcount_invalid",
        comment: "Invalid brick count error"
      )
    }
  }

  private func validatePort() {
    if let port = UInt16(tempPort) {
      storedAppModel.port = Int(port)
      portError = nil
    } else {
      portError = NSLocalizedString(
        "settings_error_port_invalid",
        comment: "Invalid port error"
      )
    }
  }

  private func validateBrickSize() {
    if let size = Int(tempBrickSize), size >= 1 + storedAppModel.brickOverlap * 2 {
      storedAppModel.brickSize = size
      brickSizeErrorMsg = nil
    } else {
      brickSizeErrorMsg = NSLocalizedString(
        "settings_error_bricksize_invalid",
        comment: "Invalid brick size error"
      )
    }
  }

  private func validateBrickOverlap() {
    if let overlap = Int(tempBrickOverlap),
       overlap >= 1,
       storedAppModel.brickSize - overlap * 2 >= 1 {
      storedAppModel.brickOverlap = overlap
      brickOverlapErrorMsg = nil
    } else {
      brickOverlapErrorMsg = NSLocalizedString(
        "settings_error_overlap_invalid",
        comment: "Invalid overlap error"
      )
    }
  }

  private func revertToDefaults() {
    storedAppModel.resetToDefaults()

    portError = nil
    brickSizeErrorMsg = nil
    brickOverlapErrorMsg = nil
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

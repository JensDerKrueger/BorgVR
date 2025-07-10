import SwiftUI

struct SettingsView: View {
  
  @Environment(AppModel.self) private var appModel
  @EnvironmentObject var appSettings: AppSettings
  
  // Temporary state for input validation
  @State private var tempPixelError: String = ""
  @State private var pixelErrorMsg: String?
  
  @State private var tempPort: String = ""
  @State private var portError: String?
  
  @State private var tempTimeout: String = ""
  @State private var timeoutError: String?
  
  @State private var tempInitialBricks: String = ""
  @State private var bricksErrorMsg: String?
  
  @State private var tempHashSize: String = ""
  @State private var hashErrorMsg: String?

  @State private var tempMaxProbingAttempts: String = ""
  @State private var probingErrorMsg: String?

  @State private var tempAtlasSize: String = ""
  @State private var atlasErrorMsg: String?
  
  @State private var tempOversampling: String = ""
  @State private var oversamplingErrorMsg: String?
  
  @State private var tempBrickSize: String = ""
  @State private var brickSizeErrorMsg: String?
  
  @State private var tempBrickOverlap: String = ""
  @State private var brickOverlapErrorMsg: String?
  
  var body: some View {
    VStack(spacing: 20) {
      Text("BorgVR Settings")
        .font(.largeTitle)
        .bold()
      
      TabView {
        // Rendering UI Tab
        Form {
          Section(header: Text("Rendering Interface").bold()) {
            Toggle(
              "Automatically Load and Save Transfer Functions",
              isOn: $appSettings.autoloadTF
            )
            Toggle(
              "Automatically Load and Save Tranformation",
              isOn: $appSettings.autoloadTransform
            )
            Toggle("Disable Foveation", isOn: $appSettings.disableFoveation)
          }
        }
        .tabItem { Label ("Rendering", systemImage: "display") }

        // Remote Datasets Tab
        Form {
          Section(header: Text("Remote Datasets").bold()) {
            HStack {
              Text("Hostname")
              Spacer()
              TextField("Enter hostname", text: $appSettings.serverAddress)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .frame(width: 200)
            }
            
            HStack {
              Text("Port Number")
              Spacer()
              TextField("Enter port", text: $tempPort, onCommit: validatePort)
                .onChange(of: tempPort) { validatePort() }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
                .frame(width: 100)
                .onAppear { tempPort = String(appSettings.serverPort) }
            }
            if let error = portError {
              Text(error).foregroundColor(.red).font(.caption)
            }
            
            HStack {
              Text("Timeout (seconds)")
              Spacer()
              TextField("Enter timeout", text: $tempTimeout, onCommit: validateTimeout)
                .onChange(of: tempTimeout) { validateTimeout() }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
                .frame(width: 100)
                .onAppear { tempTimeout = String(appSettings.timeout) }
            }
            if let error = timeoutError {
              Text(error).foregroundColor(.red).font(.caption)
            }
            Toggle("Progressive loading", isOn: $appSettings.progressiveLoading)
            Toggle("Store local version in progressive mode", isOn: $appSettings.makeLocalCopy)
          }
        }
        .tabItem { Label ("Remote", systemImage: "network") }
        
        
        // Import Tab
        Form {
          Section(header: Text("Import").bold()) {
            HStack {
              Text("Brick Size")
              Spacer()
              TextField("Brick size", text: $tempBrickSize, onCommit: validateBrickSize)
                .onChange(of: tempBrickSize) { validateBrickSize() }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
                .frame(width: 100)
                .onAppear { tempBrickSize = String(appSettings.brickSize) }
            }
            if let error = brickSizeErrorMsg {
              Text(error).foregroundColor(.red).font(.caption)
            }
            
            HStack {
              Text("Overlap")
              Spacer()
              TextField("Overlap", text: $tempBrickOverlap, onCommit: validateBrickOverlap)
                .onChange(of: tempBrickOverlap) { validateBrickOverlap() }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
                .frame(width: 100)
                .onAppear { tempBrickOverlap = String(appSettings.brickOverlap) }
            }
            if let error = brickOverlapErrorMsg {
              Text(error).foregroundColor(.red).font(.caption)
            }
            
            Toggle("Compression", isOn: $appSettings.enableCompression)
            
            Picker("Borders", selection: $appSettings.borderMode) {
              Text("zeroes").tag("zeroes")
              Text("border").tag("border")
              Text("repeat").tag("repeat")
            }
            .pickerStyle(.segmented)
          }
        }
        .tabItem { Label ("Import", systemImage: "folder.fill") }
        
        // Advanced Options Tab
        Form {
          Section(header: Text("Advanced Options").bold()) {
            HStack {
              Text("Screen-Space Pixel Error")
              Spacer()
              TextField("Pixel error", text: $tempPixelError, onCommit: validatePixelError)
                .onChange(of: tempPixelError) { validatePixelError() }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.decimalPad)
                .frame(width: 100)
                .onAppear { tempPixelError = String(appSettings.screenSpaceError) }
            }
            if let error = pixelErrorMsg {
              Text(error).foregroundColor(.red).font(.caption)
            }
            
            HStack {
              Text("Initial Bricks")
              Spacer()
              TextField("Brick count", text: $tempInitialBricks, onCommit: validateInitialBricks)
                .onChange(of: tempInitialBricks) { validateInitialBricks() }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
                .frame(width: 100)
                .onAppear { tempInitialBricks = String(appSettings.initialBricks) }
            }
            if let error = bricksErrorMsg {
              Text(error).foregroundColor(.red).font(.caption)
            }
            
            HStack {
              Text("Minimum Hash Table Size (MB)")
              Spacer()
              TextField("Min size", text: $tempHashSize, onCommit: validateMinHashSize)
                .onChange(of: tempHashSize) { validateMinHashSize() }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
                .frame(width: 100)
                .onAppear { tempHashSize = String(appSettings.minHashTableSize) }
            }
            if let error = hashErrorMsg {
              Text(error).foregroundColor(.red).font(.caption)
            }

            HStack {
              Text("Maximum Linear Probing attempts")
              Spacer()
              TextField("Attempts", text: $tempMaxProbingAttempts, onCommit: validateMaxProbingAttempts)
                .onChange(of: tempMaxProbingAttempts) { validateMaxProbingAttempts() }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
                .frame(width: 100)
                .onAppear { tempMaxProbingAttempts = String(appSettings.maxProbingAttempts) }
            }
            if let error = hashErrorMsg {
              Text(error).foregroundColor(.red).font(.caption)
            }

            HStack {
              Text("Atlas Size (MB)")
              Spacer()
              TextField("Atlas size", text: $tempAtlasSize, onCommit: validateAtlasSize)
                .onChange(of: tempAtlasSize) { validateAtlasSize() }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
                .frame(width: 100)
                .onAppear { tempAtlasSize = String(appSettings.atlasSizeMB) }
            }
            if let error = atlasErrorMsg {
              Text(error).foregroundColor(.red).font(.caption)
            }

            Toggle(
              "Request Low Res LOD",
              isOn: $appSettings.requestLowResLOD
            )
            Toggle(
              "Stop raycasting when a missing brick is hit",
              isOn: $appSettings.stopOnMiss
            )
            Toggle(
              "Show Profiling Options",
              isOn: $appSettings.showProfiling
            )

            VStack {
              Text("Oversampling Mode")
              
              Picker("Oversampling Mode", selection: $appSettings.oversamplingMode) {
                Text(OversamplingMode.staticMode.rawValue).tag(OversamplingMode.staticMode.rawValue)
                Text(OversamplingMode.dynamicMode.rawValue).tag(OversamplingMode.dynamicMode.rawValue)
              }
              .pickerStyle(.segmented)
              
              HStack {
                Text(appSettings.oversamplingMode == OversamplingMode.dynamicMode.rawValue ? "Base Oversampling" :"Oversampling")
                Spacer()
                TextField("Oversampling", text: $tempOversampling, onCommit: validateOversampling)
                  .onChange(of: tempOversampling) { validateOversampling() }
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .keyboardType(.decimalPad)
                  .frame(width: 100)
                  .onAppear { tempOversampling = String(appSettings.oversampling) }
              }
              if let error = oversamplingErrorMsg {
                Text(error).foregroundColor(.red).font(.caption)
              }
              
              if appSettings.oversamplingMode == OversamplingMode.dynamicMode.rawValue {
                HStack {
                  Text("Drop FPS")
                  Spacer()
                  TextField("Drop FPS", value: $appSettings.dropFPS, formatter: NumberFormatter())
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numberPad)
                    .frame(width: 100)
                }
                
                HStack {
                  Text("Recovery FPS")
                  Spacer()
                  TextField("Recovery FPS", value: $appSettings.recoveryFPS, formatter: NumberFormatter())
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numberPad)
                    .frame(width: 100)
                }
                
                if appSettings.dropFPS >= appSettings.recoveryFPS || appSettings.dropFPS <= 0 || appSettings.recoveryFPS <= 0 {
                  Text("Drop FPS must be less than Recovery FPS, and both must be positive integers.")
                    .foregroundColor(.red)
                    .font(.caption)
                }
              }

            }
          }
        }
        .tabItem { Label ("Advanced", systemImage: "gearshape.fill") }
      }
      
      Spacer()
      
      Button(action: { appModel.currentState = .start }) {
        Text("Back to Main Menu")
          .font(.headline)
          .padding()
          .frame(maxWidth: .infinity)
      }
      .background(RoundedRectangle(cornerRadius: 30).fill(Color.blue))
      .padding(.horizontal)
    }
    .padding()
    .onDisappear {
      validatePort()
      validateTimeout()
      validatePixelError()
      validateInitialBricks()
      validateMinHashSize()
      validateAtlasSize()
      validateOversampling()
      validateBrickSize()
      validateBrickOverlap()
    }
  }
  
  private func validateTimeout() {
    if let value = Double(tempTimeout), value > 0 {
      appSettings.timeout = Double(value)
      timeoutError = nil
    } else {
      timeoutError = "Invalid Timeout. Must be a positive float number (in seconds)."
    }
  }
  
  private func validatePort() {
    if let port = UInt16(tempPort) {
      appSettings.serverPort = Int(port)
      portError = nil
    } else {
      portError = "Invalid port. Must be a number between 0 and 65535."
    }
  }
  
  private func validatePixelError() {
    tempPixelError = tempPixelError.replacingOccurrences(of: ",", with: ".")
    if let value = Double(tempPixelError), value > 0 {
      appSettings.screenSpaceError = value
      pixelErrorMsg = nil
    } else {
      pixelErrorMsg = "Invalid pixel error. Must be a number greater than 0."
    }
  }
  
  private func validateInitialBricks() {
    if let value = Int(tempInitialBricks), value >= 0 {
      appSettings.initialBricks = value
      bricksErrorMsg = nil
    } else {
      bricksErrorMsg = "Invalid value. Must be a non-negative integer."
    }
  }


  private func validateMinHashSize() {
    if let value = Int(tempHashSize), value >= 1 {
      appSettings.minHashTableSize = value
      hashErrorMsg = nil
    } else {
      hashErrorMsg = "Invalid value. Must be an integer of at least 1."
    }
  }

  private func validateMaxProbingAttempts() {
    if let value = Int(tempMaxProbingAttempts), value >= 1 {
      appSettings.maxProbingAttempts = value
      hashErrorMsg = nil
    } else {
      hashErrorMsg = "Invalid value. Must be an integer of at least 1."
    }
  }
  
  private func validateAtlasSize() {
    if let value = Int(tempAtlasSize), value >= 1 {
      appSettings.atlasSizeMB = value
      atlasErrorMsg = nil
    } else {
      atlasErrorMsg = "Invalid value. Must be an integer of at least 1."
    }
  }
  
  private func validateOversampling() {
    tempOversampling = tempOversampling.replacingOccurrences(of: ",", with: ".")
    if let value = Double(tempOversampling), value > 0 {
      appSettings.oversampling = value
      oversamplingErrorMsg = nil
    } else {
      oversamplingErrorMsg = "Invalid oversampling. Must be a number greater than 0."
    }
  }
  
  private func validateBrickSize() {
    if let size = Int(tempBrickSize), size >= 1 + appSettings.brickOverlap * 2 {
      appSettings.brickSize = size
      brickSizeErrorMsg = nil
    } else {
      brickSizeErrorMsg = "Invalid brick size. Must be >= 1 + overlap * 2."
    }
  }
  
  private func validateBrickOverlap() {
    if let overlap = Int(tempBrickOverlap), overlap >= 1, appSettings.brickSize - overlap * 2 >= 1 {
      appSettings.brickOverlap = overlap
      brickOverlapErrorMsg = nil
    } else {
      brickOverlapErrorMsg = "Invalid overlap. Must be >= 1 and allow brickSize - 2*overlap >= 1."
    }
  }
}

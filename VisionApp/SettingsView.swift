import SwiftUI

struct SettingsView: View {
  
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @EnvironmentObject var storedAppModel: StoredAppModel
  
  // Temporary state for input validation
  @State private var tempPixelError: String = ""
  @State private var pixelErrorMsg: String?
  
  @State private var tempPort: String = ""
  @State private var portError: String?

  @State private var connectionValid = false
  @State private var connectionCheckTask: Task<Void, Never>? = nil

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
              isOn: $storedAppModel.autoloadTF
            )
            Toggle(
              "Automatically Load and Save Tranformation",
              isOn: $storedAppModel.autoloadTransform
            )
            Toggle("Disable Foveation", isOn: $storedAppModel.disableFoveation)
            Toggle(
              "Show Notifications (requires permission)",
              isOn: $storedAppModel.showNotifications
            )
            .onChange(of: storedAppModel.showNotifications) { _, newValue in
              if newValue {
                Task { await NotificationHelper.requestAuthorization(storedAppModel:storedAppModel) }
              }
            }
            Toggle(
              "Enable Voice Input (requires permission)",
              isOn: $storedAppModel.enableVoiceInput
            )
            .onChange(of: storedAppModel.enableVoiceInput) { _, newValue in
              if newValue {
                let voice = VoiceCommandService()
                voice.requestAuthorization()
                voice.startListening()
                voice.stopListening()
              }
            }
            Toggle(
              "Automatically Start Voice Input",
              isOn: $storedAppModel.autostartVoiceInput
            )
            Toggle(
              "Enable Voice Feedback",
              isOn: $storedAppModel.enableVoiceOutput
            )
          }
        }
        .tabItem { Label ("Rendering", systemImage: "display") }

        // Remote Datasets Tab
        Form {
          Section(header: Text("Remote Datasets").bold()) {
            HStack {
              Text("Hostname")
              Spacer()
              if connectionValid {
                Circle()
                  .fill(Color.green)
                  .frame(width: 12, height: 12)
                  .padding(.leading, 4)
              }
              TextField("Enter hostname", text: $storedAppModel.serverAddress)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .frame(width: 200)
            }
            
            HStack {
              Text("Port Number")
              Spacer()
              if connectionValid {
                Circle()
                  .fill(Color.green)
                  .frame(width: 12, height: 12)
                  .padding(.leading, 4)
              }
              TextField("Enter port", text: $tempPort, onCommit: validatePort)
                .onChange(of: tempPort) {
                  validatePort()
                }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
                .frame(width: 100)
                .onAppear {
                  tempPort = String(storedAppModel.serverPort)
                  connectionCheckTask = Task {
                    while !Task.isCancelled {
                      await validateConnection()
                      try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                    }
                  }
                }
                .onDisappear {
                  connectionCheckTask?.cancel()
                  connectionCheckTask = nil
                }
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
                .onAppear { tempTimeout = String(storedAppModel.timeout) }
            }
            if let error = timeoutError {
              Text(error).foregroundColor(.red).font(.caption)
            }
            Toggle("Progressive loading", isOn: $storedAppModel.progressiveLoading)
            Toggle("Store local version in progressive mode", isOn: $storedAppModel.makeLocalCopy)
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
                .onAppear { tempBrickSize = String(storedAppModel.brickSize) }
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
                .onAppear { tempBrickOverlap = String(storedAppModel.brickOverlap) }
            }
            if let error = brickOverlapErrorMsg {
              Text(error).foregroundColor(.red).font(.caption)
            }
            
            Toggle("Compression", isOn: $storedAppModel.enableCompression)
            
            Picker("Borders", selection: $storedAppModel.borderMode) {
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
                .onAppear { tempPixelError = String(storedAppModel.screenSpaceError) }
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
                .onAppear { tempInitialBricks = String(storedAppModel.initialBricks) }
            }
            if let error = bricksErrorMsg {
              Text(error).foregroundColor(.red).font(.caption)
            }
            
            HStack {
              Text("Size of Bricks represented by the Hash Table (MB)")
              Spacer()
              TextField("Min size", text: $tempHashSize, onCommit: validateMinHashSize)
                .onChange(of: tempHashSize) { validateMinHashSize() }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
                .frame(width: 100)
                .onAppear { tempHashSize = String(storedAppModel.minHashTableSize) }
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
                .onAppear { tempMaxProbingAttempts = String(storedAppModel.maxProbingAttempts) }
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
                .onAppear { tempAtlasSize = String(storedAppModel.atlasSizeMB) }
            }
            if let error = atlasErrorMsg {
              Text(error).foregroundColor(.red).font(.caption)
            }

            Toggle(
              "Request Low Res LOD",
              isOn: $storedAppModel.requestLowResLOD
            )
            Toggle(
              "Stop raycasting when a missing brick is hit",
              isOn: $storedAppModel.stopOnMiss
            )
            Toggle(
              "Show Profiling Options",
              isOn: $storedAppModel.showProfiling
            )

            VStack {
              Text("Oversampling Mode")
              
              Picker("Oversampling Mode", selection: $storedAppModel.oversamplingMode) {
                Text(OversamplingMode.staticMode.rawValue).tag(OversamplingMode.staticMode.rawValue)
                Text(OversamplingMode.dynamicMode.rawValue).tag(OversamplingMode.dynamicMode.rawValue)
              }
              .pickerStyle(.segmented)
              
              HStack {
                Text(storedAppModel.oversamplingMode == OversamplingMode.dynamicMode.rawValue ? "Base Oversampling" :"Oversampling")
                Spacer()
                TextField("Oversampling", text: $tempOversampling, onCommit: validateOversampling)
                  .onChange(of: tempOversampling) { validateOversampling() }
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .keyboardType(.decimalPad)
                  .frame(width: 100)
                  .onAppear { tempOversampling = String(storedAppModel.oversampling) }
              }
              if let error = oversamplingErrorMsg {
                Text(error).foregroundColor(.red).font(.caption)
              }
              
              if storedAppModel.oversamplingMode == OversamplingMode.dynamicMode.rawValue {
                HStack {
                  Text("Drop FPS")
                  Spacer()
                  TextField("Drop FPS", value: $storedAppModel.dropFPS, formatter: NumberFormatter())
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numberPad)
                    .frame(width: 100)
                }
                
                HStack {
                  Text("Recovery FPS")
                  Spacer()
                  TextField("Recovery FPS", value: $storedAppModel.recoveryFPS, formatter: NumberFormatter())
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numberPad)
                    .frame(width: 100)
                }
                
                if storedAppModel.dropFPS >= storedAppModel.recoveryFPS || storedAppModel.dropFPS <= 0 || storedAppModel.recoveryFPS <= 0 {
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
      
      Button(action: { runtimeAppModel.currentState = .start }) {
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
      storedAppModel.timeout = Double(value)
      timeoutError = nil
    } else {
      timeoutError = "Invalid Timeout. Must be a positive float number (in seconds)."
    }
  }
  
  private func validatePort() {
    if let port = UInt16(tempPort) {
      storedAppModel.serverPort = Int(port)
      portError = nil
    } else {
      portError = "Invalid port. Must be a number between 1 and 65535."
    }
  }

  private func validateConnection() async {
    if storedAppModel.serverPort == 0 || storedAppModel.serverAddress == "" {
      await MainActor.run {connectionValid = false}
      return
    }
    do{
      let manager = BORGVRRemoteDataManager(
        host: storedAppModel.serverAddress,
        port: UInt16(storedAppModel.serverPort),
        logger:nil,
        notifier: nil
      )
      try manager.connect(timeout: storedAppModel.timeout)
    } catch {
      await MainActor.run {connectionValid = false}
      return
    }
    await MainActor.run {connectionValid = true}
    return
  }

  private func validatePixelError() {
    tempPixelError = tempPixelError.replacingOccurrences(of: ",", with: ".")
    if let value = Double(tempPixelError), value > 0 {
      storedAppModel.screenSpaceError = value
      pixelErrorMsg = nil
    } else {
      pixelErrorMsg = "Invalid pixel error. Must be a number greater than 0."
    }
  }
  
  private func validateInitialBricks() {
    if let value = Int(tempInitialBricks), value >= 0 {
      storedAppModel.initialBricks = value
      bricksErrorMsg = nil
    } else {
      bricksErrorMsg = "Invalid value. Must be a non-negative integer."
    }
  }


  private func validateMinHashSize() {
    if let value = Int(tempHashSize), value >= 1 {
      storedAppModel.minHashTableSize = value
      hashErrorMsg = nil
    } else {
      hashErrorMsg = "Invalid value. Must be an integer of at least 1."
    }
  }

  private func validateMaxProbingAttempts() {
    if let value = Int(tempMaxProbingAttempts), value >= 1 {
      storedAppModel.maxProbingAttempts = value
      hashErrorMsg = nil
    } else {
      hashErrorMsg = "Invalid value. Must be an integer of at least 1."
    }
  }
  
  private func validateAtlasSize() {
    if let value = Int(tempAtlasSize), value >= 1 {
      storedAppModel.atlasSizeMB = value
      atlasErrorMsg = nil
    } else {
      atlasErrorMsg = "Invalid value. Must be an integer of at least 1."
    }
  }
  
  private func validateOversampling() {
    tempOversampling = tempOversampling.replacingOccurrences(of: ",", with: ".")
    if let value = Double(tempOversampling), value > 0 {
      storedAppModel.oversampling = value
      oversamplingErrorMsg = nil
    } else {
      oversamplingErrorMsg = "Invalid oversampling. Must be a number greater than 0."
    }
  }
  
  private func validateBrickSize() {
    if let size = Int(tempBrickSize), size >= 1 + storedAppModel.brickOverlap * 2 {
      storedAppModel.brickSize = size
      brickSizeErrorMsg = nil
    } else {
      brickSizeErrorMsg = "Invalid brick size. Must be >= 1 + overlap * 2."
    }
  }
  
  private func validateBrickOverlap() {
    if let overlap = Int(tempBrickOverlap), overlap >= 1, storedAppModel.brickSize - overlap * 2 >= 1 {
      storedAppModel.brickOverlap = overlap
      brickOverlapErrorMsg = nil
    } else {
      brickOverlapErrorMsg = "Invalid overlap. Must be >= 1 and allow brickSize - 2*overlap >= 1."
    }
  }
}

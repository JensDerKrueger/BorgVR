import SwiftUI

// MARK: - Server model for list

private enum ServerValidationStatus: Equatable {
  case unknown
  case validating
  case valid
  case invalid(String)
}

private struct ServerConfig: Identifiable, Equatable {
  let id: UUID = UUID()
  var address: String
  var port: String
  var password: String = ""
  var status: ServerValidationStatus = .unknown
}

struct SettingsView: View {

  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @EnvironmentObject var storedAppModel: StoredAppModel

  // Temporary state for input validation
  @State private var tempPixelError: String = ""
  @State private var pixelErrorMsg: String?

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

  // List of servers for UI editing; persisted via StoredAppModel.servers
  @State private var servers: [ServerConfig] = []
  @State private var isValidatingServers = false

  var body: some View {
    VStack(spacing: 20) {
      Text("settings_title_borgvr")
        .font(.largeTitle)
        .bold()

      TabView {
        // Rendering UI Tab
        Form {
          Section(header: Text("settings_section_rendering_interface").bold()) {
            Toggle(
              "settings_toggle_autoload_tf",
              isOn: $storedAppModel.autoloadTF
            )
            Toggle(
              "settings_toggle_autoload_transform",
              isOn: $storedAppModel.autoloadTransform
            )
            Toggle(
              "settings_toggle_disable_foveation",
              isOn: $storedAppModel.disableFoveation
            )
            Toggle(
              "settings_toggle_show_notifications",
              isOn: $storedAppModel.showNotifications
            )
            .onChange(of: storedAppModel.showNotifications) { _, newValue in
              if newValue {
                Task {
                  await NotificationHelper.requestAuthorization(
                    storedAppModel: storedAppModel
                  )
                }
              }
            }
            Toggle(
              "settings_toggle_enable_voice_input",
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
              "settings_toggle_autostart_voice",
              isOn: $storedAppModel.autostartVoiceInput
            )
            Toggle(
              "settings_toggle_enable_voice_feedback",
              isOn: $storedAppModel.enableVoiceOutput
            )
          }
        }
        .tabItem { Label("settings_tab_rendering", systemImage: "display") }

        // Remote Datasets Tab
        Form {
          Section(header: Text("settings_section_remote_datasets").bold()) {

            // Header + Add / Validate buttons
            HStack {
              Text("settings_servers")
                .font(.headline)
              Spacer()
              Button {
                addServer()
              } label: {
                Label("settings_label_add_servers", systemImage: "plus")
              }
              .buttonStyle(.bordered)

              Button {
                Task {
                  await validateAllServers()
                }
              } label: {
                HStack {
                  if isValidatingServers {
                    ProgressView()
                  }
                  Text("settings_validate_servers")
                }
              }
              .buttonStyle(.borderedProminent)
            }

            // List of server rows (backed by local ServerConfig array)
            ForEach($servers) { $server in
              ServerRowView(server: $server) {
                deleteServer(id: server.id)
              }
            }
          }
          .onAppear {
            // Initialize UI list from StoredAppModel.servers only once
            if servers.isEmpty {
              if storedAppModel.servers.isEmpty {
                servers = [ServerConfig(address: "", port: "")]
              } else {
                servers = storedAppModel.servers.map {
                  ServerConfig(address: $0.address, port: String($0.port), password: $0.password)
                }
              }
            }
            Task {
              await validateAllServers()
            }
          }

          HStack {
            Text("settings_label_timeout")
            Spacer()
            TextField(
              "settings_placeholder_timeout",
              text: $tempTimeout,
              onCommit: validateTimeout
            )
            .onChange(of: tempTimeout) { validateTimeout() }
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .keyboardType(.numberPad)
            .frame(width: 100)
            .onAppear { tempTimeout = String(storedAppModel.timeout) }
          }
          if let error = timeoutError {
            Text(error)
              .foregroundColor(.red)
              .font(.caption)
          }
          Toggle(
            "settings_toggle_progressive_loading",
            isOn: $storedAppModel.progressiveLoading
          )
          Toggle(
            "settings_toggle_store_local_copy",
            isOn: $storedAppModel.makeLocalCopy
          )
          HStack {
            Text("settings_label_shareplay_server_port")
            Spacer()
            TextField(
              "settings_placeholder_shareplay_server_port",
              value: $storedAppModel.sharePlayServerPort,
              formatter: NumberFormatter()
            )
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .keyboardType(.numberPad)
            .frame(width: 100)
          }
        }
        .tabItem { Label("settings_tab_remote", systemImage: "network") }

        // Import Tab
        Form {
          Section(header: Text("settings_section_import").bold()) {
            HStack {
              Text("settings_label_brick_size")
              Spacer()
              TextField(
                "settings_placeholder_brick_size",
                text: $tempBrickSize,
                onCommit: validateBrickSize
              )
              .onChange(of: tempBrickSize) { validateBrickSize() }
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .keyboardType(.numberPad)
              .frame(width: 100)
              .onAppear { tempBrickSize = String(storedAppModel.brickSize) }
            }
            if let error = brickSizeErrorMsg {
              Text(error)
                .foregroundColor(.red)
                .font(.caption)
            }

            HStack {
              Text("settings_label_overlap")
              Spacer()
              TextField(
                "settings_placeholder_overlap",
                text: $tempBrickOverlap,
                onCommit: validateBrickOverlap
              )
              .onChange(of: tempBrickOverlap) { validateBrickOverlap() }
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .keyboardType(.numberPad)
              .frame(width: 100)
              .onAppear {
                tempBrickOverlap = String(storedAppModel.brickOverlap)
              }
            }
            if let error = brickOverlapErrorMsg {
              Text(error)
                .foregroundColor(.red)
                .font(.caption)
            }

            Toggle(
              "settings_toggle_compression",
              isOn: $storedAppModel.enableCompression
            )

            Picker("settings_picker_borders", selection: $storedAppModel.borderMode) {
              Text("settings_border_zeroes").tag("zeroes")
              Text("settings_border_border").tag("border")
              Text("settings_border_repeat").tag("repeat")
            }
            .pickerStyle(.segmented)
          }
        }
        .tabItem { Label("settings_tab_import", systemImage: "folder.fill") }

        // Advanced Options Tab
        Form {
          Section(header: Text("settings_section_advanced_options").bold()) {
            HStack {
              Text("settings_label_screen_space_pixel_error")
              Spacer()
              TextField(
                "settings_placeholder_pixel_error",
                text: $tempPixelError,
                onCommit: validatePixelError
              )
              .onChange(of: tempPixelError) { validatePixelError() }
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .keyboardType(.decimalPad)
              .frame(width: 100)
              .onAppear {
                tempPixelError = String(storedAppModel.screenSpaceError)
              }
            }
            if let error = pixelErrorMsg {
              Text(error)
                .foregroundColor(.red)
                .font(.caption)
            }

            HStack {
              Text("settings_label_initial_bricks")
              Spacer()
              TextField(
                "settings_placeholder_initial_bricks",
                text: $tempInitialBricks,
                onCommit: validateInitialBricks
              )
              .onChange(of: tempInitialBricks) { validateInitialBricks() }
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .keyboardType(.numberPad)
              .frame(width: 100)
              .onAppear {
                tempInitialBricks = String(storedAppModel.initialBricks)
              }
            }
            if let error = bricksErrorMsg {
              Text(error)
                .foregroundColor(.red)
                .font(.caption)
            }

            HStack {
              Text("settings_label_hash_size")
              Spacer()
              TextField(
                "settings_placeholder_hash_size",
                text: $tempHashSize,
                onCommit: validateMinHashSize
              )
              .onChange(of: tempHashSize) { validateMinHashSize() }
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .keyboardType(.numberPad)
              .frame(width: 100)
              .onAppear {
                tempHashSize = String(storedAppModel.minHashTableSize)
              }
            }
            if let error = hashErrorMsg {
              Text(error)
                .foregroundColor(.red)
                .font(.caption)
            }

            HStack {
              Text("settings_label_max_probing_attempts")
              Spacer()
              TextField(
                "settings_placeholder_max_probing_attempts",
                text: $tempMaxProbingAttempts,
                onCommit: validateMaxProbingAttempts
              )
              .onChange(of: tempMaxProbingAttempts) { validateMaxProbingAttempts() }
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .keyboardType(.numberPad)
              .frame(width: 100)
              .onAppear {
                tempMaxProbingAttempts = String(storedAppModel.maxProbingAttempts)
              }
            }
            if let error = probingErrorMsg {
              Text(error)
                .foregroundColor(.red)
                .font(.caption)
            }

            HStack {
              Text("settings_label_atlas_size")
              Spacer()
              TextField(
                "settings_placeholder_atlas_size",
                text: $tempAtlasSize,
                onCommit: validateAtlasSize
              )
              .onChange(of: tempAtlasSize) { validateAtlasSize() }
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .keyboardType(.numberPad)
              .frame(width: 100)
              .onAppear { tempAtlasSize = String(storedAppModel.atlasSizeMB) }
            }
            if let error = atlasErrorMsg {
              Text(error)
                .foregroundColor(.red)
                .font(.caption)
            }

            Toggle(
              "settings_toggle_request_low_res_lod",
              isOn: $storedAppModel.requestLowResLOD
            )
            Toggle(
              "settings_toggle_stop_on_miss",
              isOn: $storedAppModel.stopOnMiss
            )
            Toggle(
              "settings_toggle_show_profiling",
              isOn: $storedAppModel.showProfiling
            )

            VStack {
              Text("settings_label_oversampling_mode_section_title")

              Picker(
                "settings_picker_oversampling_mode",
                selection: $storedAppModel.oversamplingMode
              ) {
                Text("settings_oversampling_mode_static")
                  .tag(OversamplingMode.staticMode.rawValue)
                Text("settings_oversampling_mode_dynamic")
                  .tag(OversamplingMode.dynamicMode.rawValue)
              }
              .pickerStyle(.segmented)

              HStack {
                Text(
                  NSLocalizedString(
                    storedAppModel.oversamplingMode
                    == OversamplingMode.dynamicMode.rawValue
                    ? "settings_label_base_oversampling"
                    : "settings_label_oversampling",
                    comment: "Label for oversampling value depending on mode"
                  )
                )
                Spacer()
                TextField(
                  "settings_placeholder_oversampling",
                  text: $tempOversampling,
                  onCommit: validateOversampling
                )
                .onChange(of: tempOversampling) { validateOversampling() }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.decimalPad)
                .frame(width: 100)
                .onAppear {
                  tempOversampling = String(storedAppModel.oversampling)
                }
              }
              if let error = oversamplingErrorMsg {
                Text(error)
                  .foregroundColor(.red)
                  .font(.caption)
              }

              if storedAppModel.oversamplingMode
                  == OversamplingMode.dynamicMode.rawValue
              {
                HStack {
                  Text("settings_label_drop_fps")
                  Spacer()
                  TextField(
                    "settings_label_drop_fps",
                    value: $storedAppModel.dropFPS,
                    formatter: NumberFormatter()
                  )
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .keyboardType(.numberPad)
                  .frame(width: 100)
                }

                HStack {
                  Text("settings_label_recovery_fps")
                  Spacer()
                  TextField(
                    "settings_label_recovery_fps",
                    value: $storedAppModel.recoveryFPS,
                    formatter: NumberFormatter()
                  )
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .keyboardType(.numberPad)
                  .frame(width: 100)
                }

                if storedAppModel.dropFPS >= storedAppModel.recoveryFPS
                    || storedAppModel.dropFPS <= 0
                    || storedAppModel.recoveryFPS <= 0
                {
                  Text("settings_error_drop_recovery_fps")
                    .foregroundColor(.red)
                    .font(.caption)
                }
              }

            }
          }
        }
        .tabItem { Label("settings_tab_advanced", systemImage: "gearshape.fill") }
      }

      Spacer()

      Button {
        runtimeAppModel.currentState = .start
      } label: {
        Label("settings_button_back_to_main_menu", systemImage: "chevron.backward")
      }
      .background(RoundedRectangle(cornerRadius: 30).fill(Color.blue))
      .padding(.horizontal)
    }
    .padding()
    .onDisappear {
      // Persist the edited server list back into StoredAppModel.servers
      syncServersToStoredModel()

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

  // MARK: - Remote server helpers

  private func addServer() {
    servers.append(ServerConfig(address: "", port: ""))
  }

  private func deleteServer(id: UUID) {
    if let index = servers.firstIndex(where: { $0.id == id }) {
      servers.remove(at: index)
    }
  }

  /// Convert UI `ServerConfig` list into `[StoredServer]` and store it.
  private func syncServersToStoredModel() {
    let converted: [StoredServer] = servers.compactMap { cfg in
      guard let portInt = Int(cfg.port) else { return nil }
      return StoredServer(address: cfg.address, port: portInt, password: cfg.password)
    }
    storedAppModel.servers = converted
  }

  private func validateAllServers() async {
    if isValidatingServers { return }
    await MainActor.run { isValidatingServers = true }
    defer {
      Task { @MainActor in
        isValidatingServers = false
      }
    }

    for index in servers.indices {
      await validateServer(at: index)
    }

    // After validation, persist the current list to StoredAppModel
    await MainActor.run {
      syncServersToStoredModel()
    }
  }

  private func validateServer(at index: Int) async {
    guard servers.indices.contains(index) else { return }

    await MainActor.run {
      servers[index].status = .validating
    }

    let server = await MainActor.run { servers[index] }

    // Basic validation of port
    guard let portValue = UInt16(server.port),
          (1...UInt16.max).contains(portValue) else {
      await MainActor.run {
        servers[index].status = .invalid(
          NSLocalizedString(
            "settings_error_port",
            comment: "Invalid port error message"
          )
        )
      }
      return
    }

    // Basic hostname check
    let trimmedAddress = server.address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedAddress.isEmpty else {
      await MainActor.run {
        servers[index].status = .invalid(NSLocalizedString(
          "settings_error_address_must_not_be_empty",
          comment: "Address must not be empty"
        ))
      }
      return
    }

    let ok: Bool
    do {
      ok = try await validateConnection(address: trimmedAddress, port: portValue, password: server.password)
    } catch {
      await MainActor.run {
        servers[index].status = .invalid(error.localizedDescription)
      }
      return
    }

    await MainActor.run {
      servers[index].status = ok ? .valid : .invalid(
        NSLocalizedString(
          "settings_error_connection_failed",
          comment: "Connection failed"
        )
      )
    }
  }

  private func validateConnection(address: String, port: UInt16, password: String) async throws -> Bool {
    if port == 0 || address.isEmpty {
      return false
    }
    do {
      let manager = BORGVRRemoteDataManager(
        host: address,
        port: port,
        authSecret: password,
        logger: nil,
        notifier: nil
      )
      try manager.connect(timeout: storedAppModel.timeout)
      return true
    } catch {
      return false
    }
  }

  // MARK: - Other validation functions (unchanged)

  private func validateTimeout() {
    if let value = Double(tempTimeout), value > 0 {
      storedAppModel.timeout = Double(value)
      timeoutError = nil
    } else {
      timeoutError = NSLocalizedString(
        "settings_error_timeout",
        comment: "Invalid timeout error message"
      )
    }
  }

  private func validatePixelError() {
    tempPixelError = tempPixelError.replacingOccurrences(of: ",", with: ".")
    if let value = Double(tempPixelError), value > 0 {
      storedAppModel.screenSpaceError = value
      pixelErrorMsg = nil
    } else {
      pixelErrorMsg = NSLocalizedString(
        "settings_error_pixel_error",
        comment: "Invalid pixel error message"
      )
    }
  }

  private func validateInitialBricks() {
    if let value = Int(tempInitialBricks), value >= 0 {
      storedAppModel.initialBricks = value
      bricksErrorMsg = nil
    } else {
      bricksErrorMsg = NSLocalizedString(
        "settings_error_initial_bricks",
        comment: "Invalid initial bricks error message"
      )
    }
  }

  private func validateMinHashSize() {
    if let value = Int(tempHashSize), value >= 1 {
      storedAppModel.minHashTableSize = value
      hashErrorMsg = nil
    } else {
      hashErrorMsg = NSLocalizedString(
        "settings_error_hash_size",
        comment: "Invalid hash size error message"
      )
    }
  }

  private func validateMaxProbingAttempts() {
    if let value = Int(tempMaxProbingAttempts), value >= 1 {
      storedAppModel.maxProbingAttempts = value
      probingErrorMsg = nil
    } else {
      probingErrorMsg = NSLocalizedString(
        "settings_error_max_probing_attempts",
        comment: "Invalid max probing attempts error message"
      )
    }
  }

  private func validateAtlasSize() {
    if let value = Int(tempAtlasSize), value >= 1 {
      storedAppModel.atlasSizeMB = value
      atlasErrorMsg = nil
    } else {
      atlasErrorMsg = NSLocalizedString(
        "settings_error_atlas_size",
        comment: "Invalid atlas size error message"
      )
    }
  }

  private func validateOversampling() {
    tempOversampling = tempOversampling.replacingOccurrences(of: ",", with: ".")
    if let value = Double(tempOversampling), value > 0 {
      storedAppModel.oversampling = value
      oversamplingErrorMsg = nil
    } else {
      oversamplingErrorMsg = NSLocalizedString(
        "settings_error_oversampling",
        comment: "Invalid oversampling error message"
      )
    }
  }

  private func validateBrickSize() {
    if let size = Int(tempBrickSize),
       size >= 1 + storedAppModel.brickOverlap * 2 {
      storedAppModel.brickSize = size
      brickSizeErrorMsg = nil
    } else {
      brickSizeErrorMsg = NSLocalizedString(
        "settings_error_brick_size",
        comment: "Invalid brick size error message"
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
        "settings_error_brick_overlap",
        comment: "Invalid brick overlap error message"
      )
    }
  }
}

// MARK: - Server row view

private struct ServerRowView: View {
  @Binding var server: ServerConfig
  var onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("settings_label_hostname")
        Spacer()
        TextField(
          "settings_placeholder_hostname",
          text: $server.address
        )
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .autocapitalization(.none)
        .disableAutocorrection(true)
        .frame(width: 200)

        Text("settings_label_port_number")
        TextField(
          "settings_placeholder_port",
          text: $server.port
        )
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .keyboardType(.numberPad)
        .frame(width: 80)

        SecureField("Passwort (optional)", text: $server.password)
          .textFieldStyle(RoundedBorderTextFieldStyle())
          .frame(width: 180)

        statusIndicator

        Button(role: .destructive, action: onDelete) {
          Image(systemName: "trash")
        }
      }

      if case let .invalid(error) = server.status {
        Text(error)
          .foregroundColor(.red)
          .font(.caption)
      }
    }
  }

  @ViewBuilder
  private var statusIndicator: some View {
    switch server.status {
      case .unknown:
        EmptyView()
      case .validating:
        ProgressView()
          .frame(width: 18, height: 18)
      case .valid:
        Circle()
          .fill(Color.green)
          .frame(width: 12, height: 12)
      case .invalid:
        Circle()
          .fill(Color.red)
          .frame(width: 12, height: 12)
    }
  }
}

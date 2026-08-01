import SwiftUI
import RealityKit
import AudioToolbox

// MARK: - FilePickerDialog

extension NumberFormatter {
  static var positiveInt: NumberFormatter {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimum = 0
    formatter.maximumFractionDigits = 0
    return formatter
  }
}

/**
 A SwiftUI view that lists `.trafo` files in the app’s Documents directory for loading a transformation

 Presents a list of filenames; tapping one attempts to load it into the rendering parameters.
 */
struct TrafoFilePickerDialog: View {
  /// The rendering parameters containing the transformation
  var sharedAppModel: SharedAppModel
  /// Binding controlling presentation.
  @Binding var isPresented: Bool
  /// URLs of available `.trafo` files.
  @State private var availableFiles: [URL] = []
  /// Error encountered during load.
  @State private var loadError: Error? = nil
  /// Whether to show load error alert.
  @State private var showLoadError = false

  var body: some View {
    NavigationView {
      List(availableFiles, id: \.self) { fileURL in
        Button(action: {
          do {
            try sharedAppModel.loadTransform(from: fileURL)
            isPresented = false
          } catch {
            loadError     = error
            showLoadError = true
          }
        }) {
          Text(fileURL.lastPathComponent)
        }
      }
      .navigationTitle("trafo_picker_title")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("trafo_picker_cancel_button") { isPresented = false }
        }
      }
    }
    .onAppear { refreshAvailableFiles() }
    .alert(
      "trafo_picker_load_failed_title",
      isPresented: $showLoadError,
      presenting: loadError
    ) { _ in
      Button("trafo_picker_ok_button", role: .cancel) { showLoadError = false }
    } message: { error in
      Text(error.localizedDescription)
    }
  }

  /**
   Scans the Documents directory for `.trafo` files and updates `availableFiles`.
   */
  func refreshAvailableFiles() {
    let fileManager = FileManager.default
    if let documentsURL = fileManager.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first {
      availableFiles =
      (try? fileManager.contentsOfDirectory(
        at: documentsURL,
        includingPropertiesForKeys: nil
      )
        .filter { $0.pathExtension == "trafo" }) ?? []
    } else {
      availableFiles = []
    }
  }
}

struct ProfileView: View {
  /// The shared application model containing performance data.
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel
  @EnvironmentObject var storedAppModel: StoredAppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  /// Whether the Save As dialog is presented.
  @State private var showSaveDialog = false
  /// The filename entered in the Save As dialog (without extension).
  @State private var saveFilename = ""
  /// An error encountered during save operations.
  @State private var saveError: Error? = nil
  /// Whether to show an alert for a save error.
  @State private var showSaveError = false
  /// Whether the file picker sheet for loading transformations is presented.
  @State private var showLoadFilePicker = false

  @State private var preRotationCountdown: Int? = nil
  @State private var preRotationTimer: Timer?

  @State private var workingSetCountdown: Int? = nil
  @State private var workingSetTimer: Timer?

  @State private var startupCountdown: Int = 5
  @State private var measureCountdown: Int = 10

  var body: some View {
    VStack(spacing: 20) {
      Text("profile_advanced_settings_title")
        .font(.title)
        .bold()
        .padding()

      GroupBox(label: Label("profile_group_additional_windows", systemImage: "macwindow")) {
        HStack {
          Button(action: openPerformanceGraphView) {
            Text("profile_button_performance_graph")
              .font(.headline)
              .padding(.horizontal, 20)
              .padding(.vertical, 10)
          }

          Button(action: openLoggerView) {
            Text("profile_button_show_log")
              .font(.headline)
              .padding(.horizontal, 20)
              .padding(.vertical, 10)
          }
        }
        .padding()
      }
      .padding()

      GroupBox(label: Label("profile_group_rendermodes", systemImage: "eye")) {
        HStack {
          Toggle(
            "profile_toggle_show_bricks",
            isOn: Binding(
              get: { sharedAppModel.brickVis },
              set: { sharedAppModel.brickVis = $0 }
            )
          )
          .padding()
          .fixedSize()

          Spacer()
        }
      }
      .padding()

      GroupBox(label: Label("profile_group_countdown", systemImage: "clock")) {
        HStack {
          HStack {
            Text("profile_label_startup")
            TextField(
              "",
              value: $startupCountdown,
              formatter: NumberFormatter.positiveInt
            )
            .frame(width: 60)
            .textFieldStyle(.roundedBorder)
          }

          HStack {
            Text("profile_label_measurement")
            TextField(
              "",
              value: $measureCountdown,
              formatter: NumberFormatter.positiveInt
            )
            .frame(width: 60)
            .textFieldStyle(.roundedBorder)
          }
        }
      }
      .padding()

      GroupBox(label: Label("profile_group_performance_profiling", systemImage: "gauge")) {
        HStack {
          Toggle(
            "profile_toggle_log_performance",
            isOn: Binding(
              get: { runtimeAppModel.logPerformance },
              set: { runtimeAppModel.logPerformance = $0 }
            )
          )
          .padding()
          .fixedSize()

          Spacer()

          Button(action: captureRotation) {
            Text("profile_button_capture_rotation")
              .font(.headline)
              .padding()
          }
          .disabled(preRotationCountdown != nil)

        }
        .padding()
        .onDisappear {
          preRotationTimer?.invalidate()
        }
      }
      .padding()

      GroupBox(label: Label("profile_group_memory_profiling", systemImage: "memorychip")) {

        HStack {
          Button("profile_button_clear_atlas") {
            sharedAppModel.purgeAtlas = true
          }
          .buttonStyle(.borderedProminent)
          .padding()

          Button("profile_button_measure_working_set") {
            countDownWorkingSetSize()
          }
          .buttonStyle(.borderedProminent)
          .padding()
          .disabled(workingSetCountdown != nil)
        }
        .onDisappear {
          workingSetTimer?.invalidate()
        }
        Spacer()
      }
      .padding()
      .onAppear() {
        openLoggerView()
      }
    }

    GroupBox(label: Label("profile_group_transform", systemImage: "arrow.triangle.2.circlepath")) {

      HStack {
        Button("profile_button_save") {
          saveFilename = ""
          showSaveDialog = true
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .sheet(isPresented: $showSaveDialog) {
          SaveAsDialog(
            isPresented: $showSaveDialog,
            filename: $saveFilename
          ) { name in
            let url = FileManager.default
              .urls(for: .documentDirectory, in: .userDomainMask).first!
              .appendingPathComponent(name)
              .appendingPathExtension("trafo")
            do {
              try sharedAppModel.modelTransform.save(to: url)
            } catch {
              saveError       = error
              showSaveError   = true
            }
          }
        }
        .alert(
          "profile_save_failed_title",
          isPresented: $showSaveError,
          presenting: saveError
        ) { _ in
          Button("profile_alert_ok_button", role: .cancel) {}
        } message: { error in
          Text(error.localizedDescription)
        }

        Button("profile_button_load") {
          showLoadFilePicker = true
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .sheet(isPresented: $showLoadFilePicker) {
          TrafoFilePickerDialog(
            sharedAppModel: sharedAppModel,
            isPresented: $showLoadFilePicker
          )
        }

        Spacer()
        // Auto-load/save toggle
        Text("profile_toggle_load_save_automatically")
        Toggle("", isOn: $storedAppModel.autoloadTransform)
          .labelsHidden()
      }
    }
    .padding()
  }

  private func openLoggerView() {
    if !self.runtimeAppModel.isViewOpen("LoggerView") {
      openWindow(id: "LoggerView")
    }
  }

  private func openPerformanceGraphView() {
    if !self.runtimeAppModel.isViewOpen("PerformanceGraphView") {
      openWindow(id: "PerformanceGraphView")
    }
  }

  private func countDownWorkingSetSize() {
    workingSetCountdown = startupCountdown
    workingSetTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
      guard let current = workingSetCountdown else { return }

      if current > 1 {
        AudioServicesPlaySystemSound(1104)
        workingSetCountdown = current - 1
      } else {
        AudioServicesPlaySystemSound(1322)
        workingSetCountdown = nil
        workingSetTimer?.invalidate()
        sharedAppModel.purgeAtlas = true
        measureWorkingSetSize()
      }
    }
  }

  private func measureWorkingSetSize() {
    workingSetCountdown = measureCountdown
    workingSetTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
      guard let current = workingSetCountdown else { return }

      if current > 1 {
        AudioServicesPlaySystemSound(1104)
        workingSetCountdown = current - 1
      } else {
        AudioServicesPlaySystemSound(1322)
        workingSetCountdown = nil
        workingSetTimer?.invalidate()
        sharedAppModel.purgeAtlas = true
      }
    }
  }

  private func captureRotation() {
    preRotationCountdown = startupCountdown
    preRotationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
      guard let current = preRotationCountdown else { return }

      if current > 1 {
        AudioServicesPlaySystemSound(1104)
        preRotationCountdown = current - 1
      } else {
        AudioServicesPlaySystemSound(1322)
        preRotationCountdown = nil
        preRotationTimer?.invalidate()
        DispatchQueue.main.async {
          runtimeAppModel.startRotationCapture = true
        }
      }
    }
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

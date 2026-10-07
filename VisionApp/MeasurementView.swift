import SwiftUI
import UniformTypeIdentifiers

struct MeasurementView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel
  @EnvironmentObject private var storedAppModel: StoredAppModel

  @State private var showDeleteAllConfirmation = false
  @State private var showLoadFilePicker = false
  @State private var pendingMeasurementExport: PendingSystemFileExport?
  @State private var pendingLoadedMeasurements: [VolumeMeasurement] = []
  @State private var showLoadMergeChoice = false
  @State private var showDatasetMismatchWarning = false
  @State private var measurementFileError: Error?
  @State private var showMeasurementFileError = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("measurement_window_title")
        .font(.title)
        .bold()
        .frame(maxWidth: .infinity, alignment: .center)

      Picker("measurement_kind_picker", selection: measurementKindBinding) {
        Label("measurement_kind_length", systemImage: "ruler").tag(VolumeMeasurementKind.length)
        Label("measurement_kind_area", systemImage: "triangle").tag(VolumeMeasurementKind.area)
        Label("measurement_kind_volume", systemImage: "cube").tag(VolumeMeasurementKind.volume)
      }
      .pickerStyle(.segmented)

      Toggle("Snap to Volume", isOn: projectMeasurementsOntoVolumeBinding)

      HStack {
        Button {
          _ = sharedAppModel.createVolumeMeasurement()
          runtimeAppModel.interactionMode = .measurement
        } label: {
          Label("measurement_new_button", systemImage: "plus")
        }

        Spacer()

        if let selectedMeasurement {
          Text(measurementValueText(selectedMeasurement))
            .font(.title2)
            .bold()
            .monospacedDigit()
        }
      }

      HStack {
        Button {
          showLoadFilePicker = true
        } label: {
          Label("measurement_load_button", systemImage: "folder")
        }

        Button {
          prepareMeasurementExport()
        } label: {
          Label("measurement_save_button", systemImage: "square.and.arrow.down")
        }
        .disabled(
          sharedAppModel.volumeMeasurementsSnapshot().isEmpty || currentDatasetID == nil
        )
      }

      if sharedAppModel.volumeMeasurements.isEmpty {
        ContentUnavailableView(
          "measurement_empty_title",
          systemImage: "ruler",
          description: Text("measurement_empty_description")
        )
      } else {
        List(selection: measurementSelectionBinding) {
          ForEach(sharedAppModel.volumeMeasurements) { measurement in
            HStack {
              Image(systemName: systemImage(for: measurement.kind))
                .foregroundStyle(.tint)
              VStack(alignment: .leading, spacing: 3) {
                Text(measurement.name)
                Text(measurementSummary(measurement))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .tag(measurement.id)
          }
        }
        .frame(minHeight: 180)
      }

      if let selectedMeasurement {
        Divider()

        TextField(
          "measurement_name_field",
          text: measurementNameBinding(id: selectedMeasurement.id)
        )
        .textFieldStyle(.roundedBorder)

        ScrollView(.horizontal) {
          HStack {
            ForEach(selectedMeasurement.points) { point in
              Button {
                sharedAppModel.selectedVolumeMeasurementPointID = point.id
                runtimeAppModel.interactionMode = .measurement
              } label: {
                Label(
                  pointLabel(point, in: selectedMeasurement),
                  systemImage: sharedAppModel.selectedVolumeMeasurementPointID == point.id
                    ? "smallcircle.filled.circle.fill" : "smallcircle.filled.circle"
                )
              }
              .buttonStyle(.bordered)
              .tint(sharedAppModel.selectedVolumeMeasurementPointID == point.id ? .accentColor : nil)
            }
          }
        }

      }

      HStack {
        if selectedMeasurement != nil {
          Button(role: .destructive) {
            _ = sharedAppModel.removeSelectedVolumeMeasurementPoint()
          } label: {
            Label("measurement_delete_point_button", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
          }
          .disabled(sharedAppModel.selectedVolumeMeasurementPointID == nil)

          Button(role: .destructive) {
            _ = sharedAppModel.removeSelectedVolumeMeasurement()
          } label: {
            Label("measurement_delete_button", systemImage: "trash")
          }
        }

        Spacer()

        Button(role: .destructive) {
          showDeleteAllConfirmation = true
        } label: {
          Label("measurement_delete_all_button", systemImage: "trash.slash")
        }
        .disabled(sharedAppModel.volumeMeasurementsSnapshot().isEmpty)
      }
      .padding(.bottom, 18)
    }
    .padding()
    .alert("measurement_delete_all_confirmation_title", isPresented: $showDeleteAllConfirmation) {
      Button("measurement_delete_all_confirmation_delete", role: .destructive) {
        _ = sharedAppModel.removeAllVolumeMeasurements()
      }
      Button("marker_clear_all_confirmation_cancel", role: .cancel) {}
    } message: {
      Text("measurement_delete_all_confirmation_message")
    }
    .confirmationDialog(
      "measurement_dataset_mismatch_title",
      isPresented: $showDatasetMismatchWarning,
      titleVisibility: .visible
    ) {
      Button("measurement_dataset_mismatch_load") {
        continueLoadingMeasurements()
      }
      Button("marker_clear_all_confirmation_cancel", role: .cancel) {
        clearPendingLoad()
      }
    } message: {
      Text("measurement_dataset_mismatch_message")
    }
    .confirmationDialog(
      "measurement_load_merge_title",
      isPresented: $showLoadMergeChoice,
      titleVisibility: .visible
    ) {
      Button("measurement_load_replace_button", role: .destructive) {
        applyLoadedMeasurements(replacingExisting: true)
      }
      Button("measurement_load_add_button") {
        applyLoadedMeasurements(replacingExisting: false)
      }
      Button("marker_clear_all_confirmation_cancel", role: .cancel) {
        clearPendingLoad()
      }
    } message: {
      Text("measurement_load_merge_message")
    }
    .fileImporter(
      isPresented: $showLoadFilePicker,
      allowedContentTypes: [.borgVRMeasurement],
      allowsMultipleSelection: false
    ) { result in
      loadMeasurements(from: result)
    }
    .sheet(item: $pendingMeasurementExport) { export in
      SystemFileExportPicker(
        sourceURL: export.sourceURL,
        defaultDirectoryURL: DatasetStateStorage.measurementDirectoryURL(
          logger: runtimeAppModel.logger
        )
      ) { _ in
        export.removeTemporaryFiles()
        pendingMeasurementExport = nil
      }
    }
    .fileDialogDefaultDirectory(
      DatasetStateStorage.measurementDirectoryURL(logger: runtimeAppModel.logger)
    )
    .alert(
      "measurement_file_error_title",
      isPresented: $showMeasurementFileError,
      presenting: measurementFileError
    ) { _ in
      Button("tf_picker_ok_button", role: .cancel) {
        showMeasurementFileError = false
      }
    } message: { error in
      Text(error.localizedDescription)
    }
  }

  private var currentDatasetID: String? {
    runtimeAppModel.activeDataset?.uniqueId
  }

  private var currentPhysicalExtent: SIMD3<Float>? {
    runtimeAppModel.activeDatasetInfo?.physicalExtentMeters
  }

  private var selectedMeasurement: VolumeMeasurement? {
    guard let id = sharedAppModel.selectedVolumeMeasurementID else { return nil }
    return sharedAppModel.volumeMeasurementsSnapshot().first { $0.id == id }
  }

  private var measurementKindBinding: Binding<VolumeMeasurementKind> {
    Binding(
      get: { sharedAppModel.measurementKind },
      set: { kind in
        sharedAppModel.measurementKind = kind
        if selectedMeasurement?.kind != kind {
          sharedAppModel.selectedVolumeMeasurementID = sharedAppModel.volumeMeasurementsSnapshot()
            .last(where: { $0.kind == kind })?.id
          sharedAppModel.selectedVolumeMeasurementPointID = nil
        }
      }
    )
  }

  private var projectMeasurementsOntoVolumeBinding: Binding<Bool> {
    Binding(
      get: { storedAppModel.projectMeasurementsOntoVolume },
      set: { storedAppModel.projectMeasurementsOntoVolume = $0 }
    )
  }

  private var measurementSelectionBinding: Binding<UUID?> {
    Binding(
      get: { sharedAppModel.selectedVolumeMeasurementID },
      set: { id in
        sharedAppModel.selectedVolumeMeasurementID = id
        sharedAppModel.selectedVolumeMeasurementPointID = nil
        if let measurement = sharedAppModel.volumeMeasurementsSnapshot().first(where: {
          $0.id == id
        }) {
          sharedAppModel.measurementKind = measurement.kind
          runtimeAppModel.interactionMode = .measurement
        }
      }
    )
  }

  private func measurementValueText(
    _ measurement: VolumeMeasurement
  ) -> String {
    measurement.formattedValue()
      ?? String(localized: "measurement_value_incomplete")
  }

  private func measurementSummary(_ measurement: VolumeMeasurement) -> String {
    let pointCount = String(
      format: String(localized: "measurement_point_count_format"),
      measurement.points.count
    )
    guard let value = measurement.formattedValue() else {
      return pointCount
    }
    return "\(value) · \(pointCount)"
  }

  private func measurementNameBinding(id: UUID) -> Binding<String> {
    Binding(
      get: {
        sharedAppModel.volumeMeasurementsSnapshot().first { $0.id == id }?.name ?? ""
      },
      set: { name in
        sharedAppModel.renameVolumeMeasurement(id: id, to: name)
      }
    )
  }

  private func pointLabel(
    _ point: VolumeMeasurementPoint,
    in measurement: VolumeMeasurement
  ) -> String {
    guard let index = measurement.points.firstIndex(where: { $0.id == point.id }) else {
      return ""
    }
    return String(format: String(localized: "measurement_point_format"), index + 1)
  }

  private func systemImage(for kind: VolumeMeasurementKind) -> String {
    switch kind {
      case .length: "ruler"
      case .area: "triangle"
      case .volume: "cube"
    }
  }

  private func loadMeasurements(from result: Result<[URL], Error>) {
    do {
      guard let url = try result.get().first else { return }
      let hasSecurityScope = url.startAccessingSecurityScopedResource()
      defer {
        if hasSecurityScope {
          url.stopAccessingSecurityScopedResource()
        }
      }
      prepareLoadedMeasurements(
        try VolumeMeasurementDocument.decode(from: Data(contentsOf: url))
      )
    } catch {
      presentFileError(error)
    }
  }

  private func prepareLoadedMeasurements(
    _ contents: VolumeMeasurementDocumentContents
  ) {
    guard let physicalExtent = currentPhysicalExtent else {
      presentFileError(VolumeMeasurementDocumentError.missingDatasetGeometry)
      return
    }
    pendingLoadedMeasurements = contents.measurements.map { measurement in
      VolumeMeasurement(
        id: measurement.id,
        name: measurement.name,
        kind: measurement.kind,
        points: measurement.points,
        physicalExtent: physicalExtent
      )
    }
    if let currentDatasetID,
       contents.datasetID.caseInsensitiveCompare(currentDatasetID) != .orderedSame {
      showDatasetMismatchWarning = true
    } else {
      continueLoadingMeasurements()
    }
  }

  private func continueLoadingMeasurements() {
    if sharedAppModel.volumeMeasurementsSnapshot().isEmpty {
      applyLoadedMeasurements(replacingExisting: true)
    } else {
      showLoadMergeChoice = true
    }
  }

  private func applyLoadedMeasurements(replacingExisting: Bool) {
    let loaded = replacingExisting
      ? pendingLoadedMeasurements
      : measurementsWithUniqueIDs(pendingLoadedMeasurements)
    if replacingExisting {
      sharedAppModel.volumeMeasurements = loaded
      sharedAppModel.synchronizeMeasurements()
    } else {
      sharedAppModel.mutateVolumeMeasurements { $0.append(contentsOf: loaded) }
    }
    clearPendingLoad()
    sharedAppModel.clearVolumeMeasurementSelection()
  }

  private func measurementsWithUniqueIDs(
    _ measurements: [VolumeMeasurement]
  ) -> [VolumeMeasurement] {
    guard let physicalExtent = currentPhysicalExtent else { return [] }
    let existing = sharedAppModel.volumeMeasurementsSnapshot()
    var measurementIDs = Set(existing.map(\.id))
    var pointIDs = Set(existing.flatMap { $0.points.map(\.id) })

    return measurements.map { measurement in
      let measurementID = measurementIDs.insert(measurement.id).inserted
        ? measurement.id : UUID()
      measurementIDs.insert(measurementID)
      let points = measurement.points.map { point in
        let pointID = pointIDs.insert(point.id).inserted ? point.id : UUID()
        pointIDs.insert(pointID)
        return VolumeMeasurementPoint(id: pointID, position: point.position)
      }
      return VolumeMeasurement(
        id: measurementID,
        name: measurement.name,
        kind: measurement.kind,
        points: points,
        physicalExtent: physicalExtent
      )
    }
  }

  private func clearPendingLoad() {
    pendingLoadedMeasurements = []
  }

  private func presentFileError(_ error: Error) {
    measurementFileError = error
    showMeasurementFileError = true
  }

  private func prepareMeasurementExport() {
    do {
      let data = try VolumeMeasurementDocument.encode(
        datasetID: currentDatasetID,
        measurements: sharedAppModel.volumeMeasurementsSnapshot()
      )
      pendingMeasurementExport = try PendingSystemFileExport(
        data: data,
        defaultFilename: BorgVRMeasurementFormat.defaultFilename,
        temporaryDirectoryName: "BorgVRMeasurementExports"
      )
    } catch {
      presentFileError(error)
    }
  }
}

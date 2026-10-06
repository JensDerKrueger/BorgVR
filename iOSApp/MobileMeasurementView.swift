import SwiftUI
import UniformTypeIdentifiers

struct MobileMeasurementView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @Environment(\.dismiss) private var dismiss

  @State private var importsMeasurements = false
  @State private var exportsMeasurements = false
  @State private var pendingMeasurements: [VolumeMeasurement] = []
  @State private var asksHowToLoad = false
  @State private var warnsAboutDataset = false
  @State private var confirmsDeleteAll = false
  @State private var fileError: Error?

  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        Picker("measurement_kind_picker", selection: $appModel.measurementKind) {
          Label("measurement_kind_length", systemImage: "ruler").tag(VolumeMeasurementKind.length)
          Label("measurement_kind_area", systemImage: "triangle").tag(VolumeMeasurementKind.area)
          Label("measurement_kind_volume", systemImage: "cube").tag(VolumeMeasurementKind.volume)
        }
        .pickerStyle(.segmented)

        Toggle("Project onto Volume", isOn: $appModel.projectMeasurementsOntoVolume)

        HStack {
          Button {
            _ = appModel.createVolumeMeasurement()
            appModel.interactionMode = .measurement
            synchronize()
          } label: {
            Label("measurement_new_button", systemImage: "plus")
          }
          Spacer()
          if let selectedMeasurement {
            Text(selectedMeasurement.formattedValue() ?? String(localized: "measurement_value_incomplete"))
              .font(.headline.monospacedDigit())
          }
        }

        List {
          ForEach(appModel.volumeMeasurements) { measurement in
            Button {
              select(measurement)
            } label: {
              HStack {
                Image(systemName: imageName(for: measurement.kind))
                VStack(alignment: .leading) {
                  Text(measurement.name)
                  Text(summary(for: measurement))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if appModel.selectedVolumeMeasurementID == measurement.id {
                  Image(systemName: "checkmark")
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .overlay {
          if appModel.volumeMeasurements.isEmpty {
            ContentUnavailableView(
              "measurement_empty_title",
              systemImage: "ruler",
              description: Text("measurement_empty_description")
            )
          }
        }

        if let measurement = selectedMeasurement {
          TextField("measurement_name_field", text: nameBinding(for: measurement.id))
            .textFieldStyle(.roundedBorder)

          ScrollView(.horizontal) {
            HStack {
              ForEach(Array(measurement.points.enumerated()), id: \.element.id) { index, point in
                Button(String(format: String(localized: "measurement_point_format"), index + 1)) {
                  appModel.selectedVolumeMeasurementPointID = point.id
                  appModel.interactionMode = .measurement
                }
                .buttonStyle(.bordered)
                .tint(appModel.selectedVolumeMeasurementPointID == point.id ? .accentColor : nil)
              }
            }
          }

          HStack {
            Button(role: .destructive) {
              if appModel.removeSelectedVolumeMeasurementPoint() { synchronize() }
            } label: {
              Label("measurement_delete_point_button", systemImage: "minus.circle")
            }
            .disabled(appModel.selectedVolumeMeasurementPointID == nil)

            Button(role: .destructive) {
              if appModel.removeSelectedVolumeMeasurement() { synchronize() }
            } label: {
              Label("measurement_delete_button", systemImage: "trash")
            }
          }
        }

        HStack {
          Button { importsMeasurements = true } label: {
            Label("measurement_load_button", systemImage: "folder")
          }
          Button { exportsMeasurements = true } label: {
            Label("measurement_save_button", systemImage: "square.and.arrow.down")
          }
          .disabled(appModel.volumeMeasurements.isEmpty || datasetID == nil)
          Spacer()
          Button(role: .destructive) { confirmsDeleteAll = true } label: {
            Label("measurement_delete_all_button", systemImage: "trash.slash")
          }
          .disabled(appModel.volumeMeasurements.isEmpty)
        }
      }
      .padding()
      .navigationTitle("measurement_window_title")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", systemImage: "checkmark") { dismiss() }
        }
      }
    }
    .fileImporter(
      isPresented: $importsMeasurements,
      allowedContentTypes: [.borgVRMeasurement],
      allowsMultipleSelection: false,
      onCompletion: load
    )
    .fileExporter(
      isPresented: $exportsMeasurements,
      document: VolumeMeasurementDocument(
        datasetID: datasetID,
        measurements: appModel.volumeMeasurements
      ),
      contentType: .borgVRMeasurement,
      defaultFilename: BorgVRMeasurementFormat.defaultFilename
    ) { result in
      do {
        try VolumeMeasurementExportRecovery.finish(
          result,
          datasetID: datasetID,
          measurements: appModel.volumeMeasurements
        )
      } catch {
        fileError = error
      }
    }
    .fileDialogDefaultDirectory(
      DatasetStateStorage.measurementDirectoryURL(logger: appModel.logger)
    )
    .confirmationDialog("measurement_dataset_mismatch_title", isPresented: $warnsAboutDataset) {
      Button("measurement_dataset_mismatch_load") { continueLoading() }
      Button("Cancel", role: .cancel) { pendingMeasurements = [] }
    } message: {
      Text("measurement_dataset_mismatch_message")
    }
    .confirmationDialog("measurement_load_merge_title", isPresented: $asksHowToLoad) {
      Button("measurement_load_replace_button", role: .destructive) { applyPending(replacing: true) }
      Button("measurement_load_add_button") { applyPending(replacing: false) }
      Button("Cancel", role: .cancel) { pendingMeasurements = [] }
    } message: {
      Text("measurement_load_merge_message")
    }
    .alert("measurement_delete_all_confirmation_title", isPresented: $confirmsDeleteAll) {
      Button("measurement_delete_all_confirmation_delete", role: .destructive) {
        if appModel.removeAllVolumeMeasurements() { synchronize() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("measurement_delete_all_confirmation_message")
    }
    .alert("measurement_file_error_title", isPresented: Binding(
      get: { fileError != nil },
      set: { if !$0 { fileError = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(fileError?.localizedDescription ?? "")
    }
  }

  private var datasetID: String? { appModel.activeDataset?.uniqueId }
  private var extent: SIMD3<Float>? { appModel.activeDatasetMetadata?.physicalExtentMeters }
  private var selectedMeasurement: VolumeMeasurement? {
    guard let id = appModel.selectedVolumeMeasurementID else { return nil }
    return appModel.volumeMeasurements.first { $0.id == id }
  }

  private func select(_ measurement: VolumeMeasurement) {
    appModel.selectedVolumeMeasurementID = measurement.id
    appModel.selectedVolumeMeasurementPointID = nil
    appModel.measurementKind = measurement.kind
    appModel.interactionMode = .measurement
  }

  private func nameBinding(for id: UUID) -> Binding<String> {
    Binding(
      get: { appModel.volumeMeasurements.first(where: { $0.id == id })?.name ?? "" },
      set: {
        appModel.renameVolumeMeasurement(id: id, to: $0)
        synchronize()
      }
    )
  }

  private func imageName(for kind: VolumeMeasurementKind) -> String {
    switch kind { case .length: "ruler"; case .area: "triangle"; case .volume: "cube" }
  }

  private func summary(for measurement: VolumeMeasurement) -> String {
    let points = String(
      format: String(localized: "measurement_point_count_format"),
      measurement.points.count
    )
    return measurement.formattedValue().map { "\($0) · \(points)" } ?? points
  }

  private func load(_ result: Result<[URL], Error>) {
    do {
      guard let url = try result.get().first, let extent else { return }
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      let contents = try VolumeMeasurementDocument.decode(from: Data(contentsOf: url))
      pendingMeasurements = contents.measurements.map {
        VolumeMeasurement(
          id: $0.id,
          name: $0.name,
          kind: $0.kind,
          points: $0.points,
          physicalExtent: extent
        )
      }
      if let datasetID,
         contents.datasetID.caseInsensitiveCompare(datasetID) != .orderedSame {
        warnsAboutDataset = true
      } else {
        continueLoading()
      }
    } catch { fileError = error }
  }

  private func continueLoading() {
    if appModel.volumeMeasurements.isEmpty {
      applyPending(replacing: true)
    } else {
      asksHowToLoad = true
    }
  }

  private func applyPending(replacing: Bool) {
    if replacing {
      appModel.replaceVolumeMeasurements(pendingMeasurements)
    } else {
      appModel.volumeMeasurements.append(contentsOf: uniqueCopies(of: pendingMeasurements))
    }
    pendingMeasurements = []
    appModel.clearVolumeMeasurementSelection()
    synchronize()
  }

  private func uniqueCopies(of measurements: [VolumeMeasurement]) -> [VolumeMeasurement] {
    guard let extent else { return [] }
    var measurementIDs = Set(appModel.volumeMeasurements.map(\.id))
    var pointIDs = Set(appModel.volumeMeasurements.flatMap { $0.points.map(\.id) })
    return measurements.map { measurement in
      let id = measurementIDs.insert(measurement.id).inserted ? measurement.id : UUID()
      measurementIDs.insert(id)
      let points = measurement.points.map { point -> VolumeMeasurementPoint in
        let id = pointIDs.insert(point.id).inserted ? point.id : UUID()
        pointIDs.insert(id)
        return VolumeMeasurementPoint(id: id, position: point.position)
      }
      return VolumeMeasurement(
        id: id,
        name: measurement.name,
        kind: measurement.kind,
        points: points,
        physicalExtent: extent
      )
    }
  }

  private func synchronize() {
    sharePlay.synchronizeMeasurements()
  }
}

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let borgVRSettings = UTType(exportedAs: BorgVRSettingsStore.typeIdentifier, conformingTo: .json)
}

struct SettingsServerRecord: Codable {
  var id: UUID
  var address: String
  var port: Int
  var password: String?
  var shareViaSharePlay: Bool?
  var intervalSeconds: Int?

  static func decode(_ value: Any) throws -> [Self] {
    let records = try JSONDecoder().decode([Self].self, from: JSONSerialization.data(withJSONObject: value))
    guard records.count <= 1000, Set(records.map(\.id)).count == records.count,
      records.allSatisfy({ !$0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && $0.address.utf8.count <= 1024 && (1...65535).contains($0.port)
        && ($0.password?.utf8.count ?? 0) <= 65536 && (10...31_536_000).contains($0.intervalSeconds ?? 300) }) else {
      throw BorgVRSettingsArchiveError.invalidValue("servers")
    }
    return records
  }

  static func entry(key: String, read: @escaping () -> [Self], write: @escaping ([Self]) -> Void) -> BorgVRSettingsStore.Entry {
    .init(key: key, defaultValue: [Any](), read: { includeCredentials in
      let records = read().map { value in
        var value = value
        if !includeCredentials { value.password = nil }
        return value
      }
      // These records consist entirely of finite, JSON-compatible values.
      return (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(records))) ?? []
    }, write: { write(try decode($0)) }, validate: { _ = try decode($0) })
  }

  static func servers(read: @escaping () -> [StoredServer], write: @escaping ([StoredServer]) -> Void) -> BorgVRSettingsStore.Entry {
    entry(key: "servers", read: {
      read().map { .init(id: $0.id, address: $0.address, port: $0.port,
        password: $0.password, shareViaSharePlay: $0.shareViaSharePlay) }
    }, write: { records in
      let existing = read()
      write(records.map { record in
        let previous = existing.first { $0.id == record.id || ($0.address == record.address && $0.port == record.port) }
        return StoredServer(id: record.id, address: record.address, port: record.port,
          password: record.password ?? previous?.password ?? "",
          shareViaSharePlay: record.shareViaSharePlay ?? previous?.shareViaSharePlay ?? false)
      })
    })
  }
}

extension BorgVRSettingsStore.Entry {
  static func credentials(serverPassword: Binding<String>, includeMCP: Bool = true) -> [Self] {
    var entries: [Self] = [
      .init(key: "serverPassword", defaultValue: "", sensitive: true,
        read: { _ in serverPassword.wrappedValue }, write: {
          let password = $0 as! String
          if DatasetServerPasswordStore.save(password) != nil {
            throw BorgVRSettingsArchiveError.invalidValue("serverPassword")
          }
          serverPassword.wrappedValue = password
        }),
      .init(key: "webServerCertificatePassword", defaultValue: "", sensitive: true,
        read: { _ in WebServerCertificatePasswordStore.load() },
        write: { try WebServerCertificatePasswordStore.save($0 as! String) })
    ]
    if includeMCP {
      entries.append(.init(key: "mcpServerCertificatePassword", defaultValue: "", sensitive: true,
        read: { _ in MCPServerCertificatePasswordStore.load() },
        write: { try MCPServerCertificatePasswordStore.save($0 as! String) }))
    }
    return entries
  }
}

@MainActor
final class SettingsFileController: ObservableObject {
  struct PendingImport: Identifiable {
    let id = UUID()
    let store: BorgVRSettingsStore
    let plan: BorgVRSettingsStore.ImportPlan
  }
  @Published var pendingImport: PendingImport?
  @Published var message: String?

  @discardableResult
  func open(_ url: URL, store: BorgVRSettingsStore) -> Bool {
    guard url.isFileURL, url.pathExtension.lowercased() == BorgVRSettingsStore.fileExtension else { return false }
    do {
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      var result: Result<Data, Error>?
      var error: NSError?
      NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinatedURL in
        result = Result {
          let size = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size <= BorgVRSettingsStore.maximumFileSize else { throw BorgVRSettingsArchiveError.invalidFile }
          return try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
        }
      }
      if let error { throw error }
      guard let result else { throw BorgVRSettingsArchiveError.invalidFile }
      pendingImport = PendingImport(store: store, plan: try store.prepareImport(result.get()))
    } catch { message = error.localizedDescription }
    return true
  }

  func apply(_ request: PendingImport) {
    pendingImport = nil
    do {
      try request.store.apply(request.plan)
      message = String(format: String(localized: "Imported %lld settings; ignored %lld unsupported entries."),
        Int64(request.plan.count), Int64(request.plan.ignoredCount))
    } catch { message = error.localizedDescription }
  }
}

private struct SettingsImportDialogs: ViewModifier {
  @ObservedObject var controller: SettingsFileController
  func body(content: Content) -> some View {
    content
      .confirmationDialog("Import settings?", isPresented: Binding(
        get: { controller.pendingImport != nil },
        set: { if !$0 { controller.pendingImport = nil } }
      ), titleVisibility: .visible, presenting: controller.pendingImport) { request in
        Button("Import") { controller.apply(request) }
        Button("Cancel", role: .cancel) { controller.pendingImport = nil }
      } message: { _ in
        Text("Apply the settings in this file? Missing and unsupported settings stay unchanged. This can also change network services, remote-control access, and stored credentials.")
      }
      .alert("Settings", isPresented: Binding(
        get: { controller.message != nil }, set: { if !$0 { controller.message = nil } }
      )) { Button("OK", role: .cancel) { controller.message = nil } }
      message: { Text(controller.message ?? "") }
  }
}

extension View {
  func settingsImportDialogs(_ controller: SettingsFileController) -> some View {
    modifier(SettingsImportDialogs(controller: controller))
  }
}

struct SettingsFileControls: View {
  var store: () -> BorgVRSettingsStore
  @StateObject private var controller = SettingsFileController()
  @State private var showsImporter = false
  @State private var showsExportOptions = false
  @State private var includeCredentials = false
  @State private var exportData: Data?
  #if !os(macOS)
  @State private var pendingExport: PendingSystemFileExport?
  #endif

  var body: some View {
    HStack {
      Button { showsImporter = true } label: {
        Label("Import settings", systemImage: "square.and.arrow.down")
      }
      .help("Import settings")
      Button {
        includeCredentials = false
        showsExportOptions = true
      } label: {
        Label("Export settings", systemImage: "square.and.arrow.up")
      }
      .help("Export settings")
    }
    .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.borgVRSettings]) { result in
      switch result {
        case .success(let url): controller.open(url, store: store())
        case .failure(let error): controller.message = error.localizedDescription
      }
    }
    .sheet(isPresented: $showsExportOptions, onDismiss: export) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Export settings").font(.headline)
        Toggle("Include passwords, access tokens, and certificates", isOn: $includeCredentials)
        Text("Settings files are unencrypted JSON. Included credentials can be read by anyone with access to the file. Device-specific folder permissions and caches are not exported.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Cancel", role: .cancel) { showsExportOptions = false }
          Spacer()
          Button("Export") {
            do { exportData = try store().export(includeCredentials: includeCredentials) }
            catch { controller.message = error.localizedDescription }
            showsExportOptions = false
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(24)
      .frame(idealWidth: 480)
      .presentationDetents([.medium])
    }
    #if !os(macOS)
    .sheet(item: $pendingExport) { request in
      SystemFileExportPicker(sourceURL: request.sourceURL, defaultDirectoryURL: nil) { _ in
        request.removeTemporaryFiles()
        pendingExport = nil
      }
    }
    #endif
    .settingsImportDialogs(controller)
  }

  private func export() {
    guard let data = exportData else { return }
    exportData = nil
    do {
      #if os(macOS)
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.borgVRSettings]
      panel.nameFieldStringValue = "BorgVR.\(BorgVRSettingsStore.fileExtension)"
      panel.canCreateDirectories = true
      guard panel.runModal() == .OK, let url = panel.url else { return }
      try data.write(to: url, options: .atomic)
      #else
      pendingExport = try PendingSystemFileExport(data: data,
        defaultFilename: "BorgVR.\(BorgVRSettingsStore.fileExtension)",
        temporaryDirectoryName: "BorgVRSettingsExports")
      #endif
    } catch { controller.message = error.localizedDescription }
  }
}

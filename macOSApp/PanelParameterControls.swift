import SwiftUI
import UniformTypeIdentifiers

private struct PanelPresetDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.json]
  let data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
    self.data = data
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

private struct PanelParameterControls<Value: Codable>: ViewModifier {
  let kind: String
  let reset: PanelAction
  let snapshot: () -> Value
  let apply: (Value) throws -> Void
  @State private var imports = false
  @State private var exports = false
  @State private var document: PanelPresetDocument?
  @State private var error: Error?

  func body(content: Content) -> some View {
    content
      .panelActions(.standard(reset: reset,
        load: .button("load", icon: "folder", text: String(localized: "Load...")) { imports = true },
        save: .button("save", icon: "square.and.arrow.down", text: String(localized: "Save...")) { save() }))
      .fileImporter(isPresented: $imports, allowedContentTypes: [.json]) { result in
        do {
          let url = try result.get()
          let accessed = url.startAccessingSecurityScopedResource()
          defer { if accessed { url.stopAccessingSecurityScopedResource() } }
          try apply(PanelParameterStorage.load(Value.self, kind: kind, from: url))
        } catch { self.error = error }
      }
      .fileExporter(isPresented: $exports, document: document, contentType: .json,
        defaultFilename: "\(kind).json") { result in
          if case .failure(let error) = result { self.error = error }
        }
      .alert("Panel File Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("OK", role: .cancel) {}
      } message: { Text(error?.localizedDescription ?? "") }
  }

  private func save() {
    do {
      document = PanelPresetDocument(data: try PanelParameterStorage.encode(snapshot(), kind: kind))
      exports = true
    } catch { self.error = error }
  }
}

extension View {
  func panelParameters<Value: Codable>(kind: String, reset: PanelAction,
    snapshot: @escaping () -> Value, apply: @escaping (Value) throws -> Void) -> some View {
    modifier(PanelParameterControls(kind: kind, reset: reset, snapshot: snapshot, apply: apply))
  }
}

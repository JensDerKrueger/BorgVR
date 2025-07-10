import SwiftUI
import UniformTypeIdentifiers

struct TextFileDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.plainText] }

  var text: String

  init(text: String) {
    self.text = text
  }

  init(configuration: ReadConfiguration) throws {
    if let data = configuration.file.regularFileContents,
       let string = String(data: data, encoding: .utf8) {
      text = string
    } else {
      throw CocoaError(.fileReadCorruptFile)
    }
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    let data = text.data(using: .utf8)!
    return .init(regularFileWithContents: data)
  }
}

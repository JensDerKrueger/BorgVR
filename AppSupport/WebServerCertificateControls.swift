import SwiftUI
import UniformTypeIdentifiers

struct WebServerCertificateControls: View {
  @Binding var certificateData: Data

  @State private var isImporterPresented = false
  @State private var importStatus: String?
  @State private var passwordText = ""
  @State private var passwordStatus: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(certificateStatusText)
        .font(.caption)
        .foregroundStyle(.secondary)

      SecureField("PKCS#12 password", text: passwordBinding)
        .textFieldStyle(.roundedBorder)

      HStack {
        Button {
          isImporterPresented = true
        } label: {
          Label("Import PKCS#12", systemImage: "doc.badge.plus")
        }

        Button(role: .destructive) {
          certificateData = Data()
          passwordText = ""
          WebServerCertificatePasswordStore.delete()
          passwordStatus = nil
          importStatus = "Custom certificate removed."
        } label: {
          Label("Remove certificate", systemImage: "trash")
        }
        .disabled(certificateData.isEmpty)
      }

      if let importStatus {
        Text(importStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let passwordStatus {
        Text(passwordStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .onAppear {
      passwordText = WebServerCertificatePasswordStore.load()
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: Self.allowedContentTypes,
      allowsMultipleSelection: false,
      onCompletion: importCertificate
    )
  }

  private var certificateStatusText: String {
    if certificateData.isEmpty {
      return "No custom certificate: BorgVR creates a temporary self-signed certificate."
    }
    return "Custom PKCS#12 certificate loaded (\(certificateData.count) bytes)."
  }

  private var passwordBinding: Binding<String> {
    Binding(
      get: { passwordText },
      set: { newValue in
        passwordText = newValue
        do {
          try WebServerCertificatePasswordStore.save(newValue)
          passwordStatus = newValue.isEmpty ? nil : "Password saved in the Keychain."
        } catch {
          passwordStatus = "Password could not be saved: \(error.localizedDescription)"
        }
      }
    )
  }

  private func importCertificate(_ result: Result<[URL], Error>) {
    do {
      guard let url = try result.get().first else {
        return
      }

      let needsScopedAccess = url.startAccessingSecurityScopedResource()
      defer {
        if needsScopedAccess {
          url.stopAccessingSecurityScopedResource()
        }
      }

      certificateData = try Data(contentsOf: url)
      importStatus = "\(url.lastPathComponent) importiert."
      passwordText = WebServerCertificatePasswordStore.load()
    } catch {
      importStatus = "Certificate could not be imported: \(error.localizedDescription)"
    }
  }

  private static var allowedContentTypes: [UTType] {
    [
      UTType(filenameExtension: "p12"),
      UTType(filenameExtension: "pfx"),
      .data
    ].compactMap { $0 }
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.
 */

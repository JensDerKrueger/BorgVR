import SwiftUI

struct MCPSettingsControls: View {
  @Binding var enabled: Bool
  @Binding var port: Int
  @Binding var allowRemoteConnections: Bool
  @Binding var accessToken: String
  @Binding var certificateData: Data
  let statusText: String

  @State private var revealsAccessToken = false
  @State private var tokenWasCopied = false

  var body: some View {
    let endpointPort = min(max(port, 1), 65_535)
    Toggle("Enable MCP server", isOn: $enabled)
    if enabled {
      TextField("MCP server port", value: $port, format: .number.grouping(.never))
#if os(iOS) || os(visionOS)
        .keyboardType(.numberPad)
#endif
      Toggle("Allow connections from the network", isOn: $allowRemoteConnections)
      if allowRemoteConnections {
        HStack {
          Group {
            if revealsAccessToken {
              TextField("Access token", text: $accessToken)
            } else {
              SecureField("Access token", text: $accessToken)
            }
          }
          .textContentType(.password)

          Button {
            revealsAccessToken.toggle()
          } label: {
            Image(systemName: revealsAccessToken ? "eye.slash" : "eye")
          }
          .buttonStyle(.borderless)
          .help(revealsAccessToken ? "Hide access token" : "Show access token")

          Button {
            copyAccessToken()
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .disabled(trimmedAccessToken.isEmpty)
          .help("Copy access token")
        }
        Button {
          let generatedToken = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
          accessToken = generatedToken
          copyAccessToken(generatedToken)
        } label: {
          Label("Generate and copy access token", systemImage: "key.fill")
        }
        if tokenWasCopied {
          Label("Access token copied to the clipboard.", systemImage: "checkmark")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if trimmedAccessToken.isEmpty {
          Label(
            "An access token is required before remote MCP connections can be enabled.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.orange)
        }
        Text("Use this value as the Bearer token in the MCP client's Authorization header.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Text("Remote MCP connections use HTTPS. Unless a custom PKCS#12 identity is imported, BorgVR creates a temporary self-signed certificate.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        WebServerCertificateControls(
          certificateData: $certificateData,
          passwordStore: .mcpServer
        )
      } else {
        Text("The MCP endpoint is available only on this device.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      LabeledContent("Endpoint") {
        Text("\(allowRemoteConnections ? "https" : "http")://\(allowRemoteConnections ? "<device-address>" : "127.0.0.1"):\(endpointPort)/mcp")
          .textSelection(.enabled)
      }
      Text(statusText)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var trimmedAccessToken: String {
    accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func copyAccessToken() {
    guard !trimmedAccessToken.isEmpty else { return }
    copyAccessToken(trimmedAccessToken)
  }

  private func copyAccessToken(_ token: String) {
    WebGPUShareLink.copyToPasteboard(token)
    tokenWasCopied = true
  }
}

import SwiftUI

private let mcpPortNumberFormatter: NumberFormatter = {
  let formatter = NumberFormatter()
  formatter.numberStyle = .none
  formatter.usesGroupingSeparator = false
  formatter.allowsFloats = false
  formatter.minimum = 1
  formatter.maximum = 65535
  return formatter
}()

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
      TextField("MCP server port", value: clampedPortBinding, formatter: mcpPortNumberFormatter)
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
        VStack(alignment: .trailing, spacing: 6) {
          ForEach(endpointURLs(port: endpointPort), id: \.self) { endpointURL in
            HStack(spacing: 8) {
              Text(verbatim: endpointURL)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
              Button {
                WebGPUShareLink.copyToPasteboard(endpointURL)
              } label: {
                Image(systemName: "doc.on.doc")
              }
              .buttonStyle(.borderless)
              .help("Copy endpoint")
            }
          }
        }
      }
      Text(statusText)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var trimmedAccessToken: String {
    accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var clampedPortBinding: Binding<Int> {
    Binding(
      get: { port },
      set: { port = min(65535, max(1, $0)) }
    )
  }

  private func endpointURLs(port: Int) -> [String] {
    guard allowRemoteConnections else {
      return ["http://127.0.0.1:\(port)/mcp"]
    }
    return WebGPUShareLink.localNetworkHosts().map { "https://\($0):\(port)/mcp" }
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

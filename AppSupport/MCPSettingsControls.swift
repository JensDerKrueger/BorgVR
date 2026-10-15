import SwiftUI

struct MCPSettingsControls: View {
  @Binding var enabled: Bool
  @Binding var port: Int
  @Binding var allowRemoteConnections: Bool
  @Binding var accessToken: String
  let statusText: String

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
        SecureField("Access token", text: $accessToken)
          .textContentType(.password)
        Button {
          accessToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        } label: {
          Label("Generate access token", systemImage: "key.fill")
        }
        if accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Label(
            "An access token is required before remote MCP connections can be enabled.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.orange)
        }
        Text("The MCP server listens on all network interfaces and uses unencrypted HTTP. Depending on the network configuration, it may also be reachable from the internet.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        Text("The MCP endpoint is available only on this device.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      LabeledContent("Endpoint") {
        Text("http://\(allowRemoteConnections ? "<device-address>" : "127.0.0.1"):\(endpointPort)/mcp")
          .textSelection(.enabled)
      }
      Text(statusText)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }
}

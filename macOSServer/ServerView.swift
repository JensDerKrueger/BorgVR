import SwiftUI
import UniformTypeIdentifiers
import Foundation
import SystemConfiguration


struct ServerView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @EnvironmentObject var storedAppModel: StoredAppModel

  @State private var isRunningServer: Bool = false
  @State private var logText: String = ""
  @State private var IPText: String = ""
  @State private var statusText: String = L(
    "server_status_stopped",
    comment: "Initial server status text when the server is stopped"
  )
  @State private var statusColor: Color = .red
  @State private var isScanningDatasets = false

  /// Logger instance for GUI
  private var logger = GUILogger()

  /// timer to check if the IP adress has changed
  private let ipUpdateTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

  /// Server instance
  @State private var server: TCPServer?

  /// Dataset scanner for the directory
  @State private var datasetScanner: DatasetScanner?
  @State private var datasets: [DatasetInfo] = []
  @State private var datasetInfoText: String = L(
    "server_dataset_scanning_message",
    comment: "Status text while scanning for datasets"
  )
  @State private var showDirectoryPicker = false

  struct IPSelection: Identifiable { let id = UUID(); let ips: [String] }
  @State private var ipSelection: IPSelection? = nil


  var body: some View {
    ZStack {
      VStack(spacing: 20) {
        Text("server_title_app")
          .font(.largeTitle)
          .bold()
          .frame(minHeight: 40)

        Image("borgvr")
          .resizable()
          .scaledToFit()
          .frame(width: 200, height: 200)
          .clipShape(RoundedRectangle(cornerRadius: 20))
          .shadow(radius: 10)

        HStack(spacing: 10) {
          Text("server_label_ip_addresses")

          Text(IPText)
            .font(.system(.body, design: .monospaced))
            .bold()
            .foregroundColor(.blue)
            .textSelection(.enabled)

          Button {
            let ips = getMyIPAddresses().filter { $0 != "127.0.0.1" }
            guard !ips.isEmpty else { return }

            if ips.count == 1 {
              let toCopy = ips.first ?? IPText
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(toCopy, forType: .string)
            } else {
              ipSelection = IPSelection(ips: ips)
            }
          } label: {
            Label("server_button_copy", systemImage: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .help("server_help_copy_ip")
        }

        HStack {
          Text(
            String(
              format: L(
                "server_label_port_format",
                comment: "Label showing the server port, with placeholder for the number"
              ),
              storedAppModel.port
            )
          )
        }

        HStack {
          Text("server_label_data_directory")
          TextField(
            "server_placeholder_path",
            text: $storedAppModel.dataDirectory,
            onCommit: scanDatasets
          )
          .textFieldStyle(RoundedBorderTextFieldStyle())
          .disabled(isRunningServer)
          .accentColor(.blue)
          Button("server_button_select") {
            showDirectoryPicker = true
          }
          .disabled(isRunningServer)
        }

        Text(datasetInfoText)
          .font(.footnote)
          .foregroundColor(.gray)

        TextEditor(text: $logText)
          .border(Color.gray, width: 1)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 200)

        Text(statusText)
          .font(.largeTitle)
          .bold()
          .frame(minHeight: 40)
          .foregroundColor(statusColor)

        Spacer()

        HStack {
          Button {
            isRunningServer.toggle()

            if isRunningServer {
              startServer()
            } else {
              stopServer()
            }
          } label: {
            if isRunningServer {
              Label("server_button_stop_server", systemImage: "stop.circle")
            } else {
              Label("server_button_start_server", systemImage: "play.circle")
            }
          }

          Button {
            logText = ""
          } label: {
            Label("server_button_clear_log", systemImage: "trash")
          }

          Button {
            runtimeAppModel.currentState = .start
          } label: {
            Label("server_button_back_to_main_menu", systemImage: "chevron.backward.circle")
          }
          .disabled(isRunningServer)
        }

        HStack(spacing: 5) {
          Text("© 2024–2026")
          Link(
            "server_footer_cgvis_link",
            destination: URL(string: "https://www.cgvis.de")!
          )
        }
        .font(.footnote)
        .foregroundColor(.gray)
        .frame(minHeight: 20)
      }
      .padding()

      if isScanningDatasets {
        ZStack {
          Color.black.opacity(0.7)
            .ignoresSafeArea()
            .transition(.opacity)
            .zIndex(1)
            .allowsHitTesting(true)

          VStack(spacing: 16) {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: .blue))
              .scaleEffect(1.5)
            Text("server_dataset_scanning_title")
              .font(.headline)
              .foregroundColor(.primary)
              .transition(.opacity)
          }
          .padding(40)
          .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
              .fill(.ultraThinMaterial)
          )
          .shadow(radius: 10)
          .transition(.scale)
          .zIndex(2)
        }
        .animation(.easeInOut, value: isScanningDatasets)
      }
    }
    .onAppear {
      logger.setLogBinding($logText)
      fillIPAdressText()
      scanDatasets()
    }
    .onReceive(ipUpdateTimer) { _ in
      fillIPAdressText()
    }
    .fileImporter(
      isPresented: $showDirectoryPicker,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
        case .success(let urls):
          if let selectedURL = urls.first {
            storedAppModel.dataDirectory = selectedURL.path
            scanDatasets()
          }
        case .failure(let error):
          logger.error(
            String(
              format: L(
                "server_error_selecting_directory",
                comment: "Error message when selecting a directory fails"
              ),
              error.localizedDescription
            )
          )
      }
    }
    .sheet(item: $ipSelection) { selection in
      VStack(alignment: .leading, spacing: 12) {
        Text("server_ip_sheet_title")
          .font(.headline)
        Text("server_ip_sheet_description")
          .font(.subheadline)
          .foregroundColor(.secondary)

        ForEach(Array(selection.ips.enumerated()), id: \.offset) { _, ip in
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
            ipSelection = nil
          } label: {
            HStack {
              Image(systemName: "doc.on.doc")
              Text(ip)
                .font(.system(.body, design: .monospaced))
              Spacer()
            }
          }
        }

        HStack {
          Spacer()
          Button(role: .cancel) {
            ipSelection = nil
          } label: {
            Label("server_button_cancel", systemImage: "xmark.circle")
          }
        }
      }
      .padding(20)
      .frame(minWidth: 420)
    }
  }

  private func scanDatasets() {
    isScanningDatasets = true
    Task {
      datasetScanner = DatasetScanner(
        directory: storedAppModel.dataDirectory,
        logger: logger
      )
      datasetScanner?.loadDatasets()
      datasets = datasetScanner?.getDatasets() ?? []
      datasetInfoText = String(
        format: L(
          "server_dataset_found_count",
          comment: "Label showing the number of found datasets"
        ),
        datasets.count
      )
      isScanningDatasets = false

      if storedAppModel.autoStartServer {
        isRunningServer = true
        startServer()
      }
    }
  }

  private func fillIPAdressText() {
    IPText = getMyIPAddresses()
      .filter { $0 != "127.0.0.1" }
      .joined(separator: ", ")
  }

  func getMyIPAddresses() -> [String] {
    var addresses = [String]()
    var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil

    if getifaddrs(&ifaddr) == 0 {
      var ptr = ifaddr
      while ptr != nil {
        defer { ptr = ptr?.pointee.ifa_next }

        guard let interface = ptr?.pointee,
              let addr = interface.ifa_addr else { continue }

        let addrFamily = addr.pointee.sa_family

        if addrFamily == UInt8(AF_INET) {
          var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
          if getnameinfo(
            addr,
            socklen_t(addr.pointee.sa_len),
            &hostname,
            socklen_t(hostname.count),
            nil,
            0,
            NI_NUMERICHOST
          ) == 0 {
            let address = String(cString: hostname)
            addresses.append(address)
          }
        }
      }
      freeifaddrs(ifaddr)
    }
    return addresses
  }

  private func stopServer() {
    server?.stop()
    server = nil
    statusText = L(
      "server_status_stopped",
      comment: "Server status when the server is stopped"
    )
    statusColor = .red
  }

  private func startServer() {
    logText = ""
    server = TCPServer(
      port: UInt16(storedAppModel.port),
      maxBricksPerGetRequest: storedAppModel.maxBricksPerGetRequest,
      logger: logger,
      datasets: datasets
    )
    server?.start()
    statusText = L(
      "server_status_running",
      comment: "Server status when the server is running"
    )
    statusColor = .green
  }

}

/// Localized string helper
private func L(_ key: String, comment: String = "") -> String {
  NSLocalizedString(key, comment: comment)
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

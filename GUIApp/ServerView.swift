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
  @State private var statusText: String = "Server status: Stopped"
  @State private var statusColor : Color = .red
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
  @State private var datasetInfoText: String = "Scanning for datasets..."
  @State private var showDirectoryPicker = false

  struct IPSelection: Identifiable { let id = UUID(); let ips: [String] }
  @State private var ipSelection: IPSelection? = nil


  var body: some View {
    ZStack {
      VStack(spacing: 20) {
        Text("BorgVR Dataset Companion Application")
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
          Text("IP Addresses of this System:")

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
            Label("Copy", systemImage: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .help("Copy IP addresses")
        }

        HStack {
          Text("Port: \(String(storedAppModel.port))")
        }

        HStack {
          Text("Data directory:")
          TextField("Path", text: $storedAppModel.dataDirectory, onCommit: scanDatasets)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .disabled(isRunningServer)
            .accentColor(.blue)
          Button("Select") {
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
              Label("Stop Server", systemImage: "stop.circle")
            } else {
              Label("Start Dataset Server", systemImage: "play.circle")
            }
          }
          Button {
            logText = ""
          } label: {
            Label("Clear Log", systemImage: "trash")
          }

          Button {
            runtimeAppModel.currentState = .start
          } label: {
            Label("Back to main menu", systemImage: "chevron.backward.circle")
          }
          .disabled(isRunningServer)
        }

        HStack(spacing: 5) {
          Text("© 2024-2025")
          Link("CGVIS Duisburg, Germany", destination: URL(string: "https://www.cgvis.de")!)
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
            Text("Scanning for datasets")
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
    .fileImporter(isPresented: $showDirectoryPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
      switch result {
        case .success(let urls):
          if let selectedURL = urls.first {
            storedAppModel.dataDirectory = selectedURL.path
            scanDatasets()
          }
        case .failure(let error):
          logger.error("Error selecting directory: \(error.localizedDescription)")
      }
    }
    .sheet(item: $ipSelection) { selection in


      VStack(alignment: .leading, spacing: 12) {
        Text("Select IP to Copy")
          .font(.headline)
        Text("Multiple IP addresses were found on this system. Choose one to copy.")
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
            Label("Cancel", systemImage: "xmark.circle")
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
      datasetScanner = DatasetScanner(directory: storedAppModel.dataDirectory, logger: logger)
      datasetScanner?.loadDatasets()
      datasets = datasetScanner?.getDatasets() ?? []
      datasetInfoText = "Found datasets: \(datasets.count)"
      isScanningDatasets = false

      if storedAppModel.autoStartServer {
        isRunningServer = true
        startServer()
      }
    }
  }

  private func fillIPAdressText() {
    IPText = getMyIPAddresses().filter{$0 != "127.0.0.1"}.joined(separator: ", ")
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
          if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                         &hostname, socklen_t(hostname.count),
                         nil, 0, NI_NUMERICHOST) == 0 {
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
    statusText = "Server status: Stopped"
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
    statusText = "Server status: Running"
    statusColor = .green
  }

}


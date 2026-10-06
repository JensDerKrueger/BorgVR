import Dispatch
import Foundation

enum TerminalServerInfo {
  static let version = "2.7"
  static let defaultMaximumBricksPerRequest = 64
  static let build: String = {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable),
          let date = attributes[.modificationDate] as? Date else {
      return "unknown"
    }
    return ISO8601DateFormatter().string(from: date)
  }()

  static let banner = #"""
   ____                   __     ______
  | __ )  ___  _ __ __ _ \ \   / /  _ \
  |  _ \ / _ \| '__/ _` | \ \ / /| |_) |
  | |_) | (_) | | | (_| |  \ V / |  _ <
  |____/ \___/|_|  \__, |   \_/  |_| \_\
                   |___/
  """#
}

struct ServerConfiguration {
  var dataDirectory = FileManager.default.homeDirectoryForCurrentUser.path
  var port = UInt16(BorgVRSharedDefaults.datasetServerPort)
  var maxBricksPerGetRequest = TerminalServerInfo.defaultMaximumBricksPerRequest
  var password = ""
  var scanIntervalSeconds = 10
  var webPort: UInt16?
  var useWebServerTLS = true
  var webServerCertificatePath: String?
  var webServerCertificatePassword = ""
  var logFilePath: String?
  var syncServers: [ServerSyncEndpoint] = []

  func serverConfiguration(certificateData: Data) -> BorgVRServerConfiguration {
    BorgVRServerConfiguration(
      dataDirectory: dataDirectory,
      port: Int(port),
      maxBricksPerGetRequest: maxBricksPerGetRequest,
      authSecret: password,
      startDatasetServer: true,
      enableWebServer: webPort != nil,
      webPort: Int(webPort ?? 8080),
      useWebServerTLS: useWebServerTLS,
      webServerCertificateData: certificateData,
      webServerCertificatePassword: webServerCertificatePassword
    )
  }
}

let executableName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let usage = """
Usage:
  \(executableName) [options]

Options:
  --directory, -d <path>          Directory containing .data, .tf1d, .marker, and .mesh files.
                                  Defaults to the home directory.
  --port, -p <port>               Native dataset-server port.
                                  Defaults to \(BorgVRSharedDefaults.datasetServerPort).
  --max-bricks, -m <count>        Maximum bricks per GETBRICKS request.
                                  Defaults to \(TerminalServerInfo.defaultMaximumBricksPerRequest).
  --password <secret>             Optional password for native and WebGPU clients.
  --scan-interval <seconds>       Refresh the file catalog periodically.
                                  Defaults to 10; use 0 to disable rescanning.
  --web-port <port>               Enable the WebGPU server on this port.
                                  HTTPS with a temporary certificate is the default.
  --web-http                      Use HTTP instead of HTTPS. HTTP only listens on localhost.
  --web-certificate <path>        PKCS#12 certificate (.p12 or .pfx) for HTTPS.
  --web-certificate-password <p>  Password for the PKCS#12 certificate.
  --log-file <path>               Also append log messages to this file.
  --sync-server <host> <port> <interval> [password]
                                  Synchronize server content at intervals of at least
                                  10 seconds. Repeat for fallback sources.
  --version, -v                   Show the version.
  --help, -h                      Show this help.

Examples:
  \(executableName) --directory /data/BorgVR --port 12345
  \(executableName) -d /data/BorgVR -p 12345 -m \(TerminalServerInfo.defaultMaximumBricksPerRequest) --web-port 8080 --log-file server.log
  \(executableName) -d /data/BorgVR --sync-server 192.168.1.10 12345 300 secret
"""

func fail(_ message: String) -> Never {
  fputs("\(message)\n\n\(usage)\n", stderr)
  exit(2)
}

func parseArguments(_ args: [String]) -> ServerConfiguration {
  var config = ServerConfiguration()
  var index = 1

  func requireValue(after option: String) -> String {
    guard index + 1 < args.count else {
      fail("Missing value for \(option).")
    }
    index += 1
    return args[index]
  }

  while index < args.count {
    let argument = args[index]
    switch argument {
      case "--directory", "-d":
        config.dataDirectory = requireValue(after: argument)

      case "--port", "-p":
        let value = requireValue(after: argument)
        guard let port = UInt16(value), port > 0 else {
          fail("Invalid port: \(value)")
        }
        config.port = port

      case "--max-bricks", "-m":
        let value = requireValue(after: argument)
        guard let maxBricks = Int(value), maxBricks > 0 else {
          fail("Invalid max-bricks value: \(value)")
        }
        config.maxBricksPerGetRequest = maxBricks

      case "--password":
        config.password = requireValue(after: argument)

      case "--scan-interval":
        let value = requireValue(after: argument)
        guard let interval = Int(value), interval >= 0 else {
          fail("Invalid scan interval: \(value)")
        }
        config.scanIntervalSeconds = interval

      case "--web-port":
        let value = requireValue(after: argument)
        guard let port = UInt16(value), port > 0 else {
          fail("Invalid WebGPU port: \(value)")
        }
        config.webPort = port

      case "--web-http":
        config.useWebServerTLS = false

      case "--web-certificate":
        config.webServerCertificatePath = requireValue(after: argument)

      case "--web-certificate-password":
        config.webServerCertificatePassword = requireValue(after: argument)

      case "--log-file":
        let path = requireValue(after: argument).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
          fail("Log file path must not be empty.")
        }
        config.logFilePath = NSString(string: path).expandingTildeInPath

      case "--sync-server":
        let address = requireValue(after: argument)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
          fail("Invalid sync server address.")
        }

        let portValue = requireValue(after: argument)
        guard let port = Int(portValue), (1...65535).contains(port) else {
          fail("Invalid sync server port: \(portValue)")
        }

        let intervalValue = requireValue(after: argument)
        guard let interval = Int(intervalValue), interval >= 10 else {
          fail("Invalid sync server interval: \(intervalValue)")
        }

        var password = ""
        if index + 1 < args.count, !args[index + 1].hasPrefix("-") {
          index += 1
          password = args[index]
        }
        config.syncServers.append(
          ServerSyncEndpoint(
            address: address,
            port: port,
            password: password,
            intervalSeconds: interval
          )
        )

      case "--version", "-v":
        print(TerminalServerInfo.version)
        exit(0)

      case "--help", "-h":
        print(usage)
        exit(0)

      default:
        fail("Unknown argument: \(argument)")
    }

    index += 1
  }

  if config.webServerCertificatePath != nil && config.webPort == nil {
    fail("--web-certificate requires --web-port.")
  }
  if !config.webServerCertificatePassword.isEmpty && config.webServerCertificatePath == nil {
    fail("--web-certificate-password requires --web-certificate.")
  }
  if !config.useWebServerTLS && config.webServerCertificatePath != nil {
    fail("--web-certificate cannot be combined with --web-http.")
  }

  return config
}

func loadCertificate(from path: String?) -> Data {
  guard let path else { return Data() }
  do {
    return try Data(contentsOf: URL(fileURLWithPath: path))
  } catch {
    fail("Could not read WebGPU certificate at \(path): \(error.localizedDescription)")
  }
}

func logLevelDescription(_ level: LogLevel) -> String {
  switch level {
    case .dev, .progress: "developer/debug (l0)"
    case .info: "info (l1)"
    case .warning: "warning (l2)"
    case .error: "error (l3)"
  }
}

func printStartupBanner(_ config: ServerConfiguration, logLevel: LogLevel = .info) {
  let cyan = "\u{001B}[36m"
  let reset = "\u{001B}[0m"
  print("\(cyan)\n\(TerminalServerInfo.banner)\n\(reset)")
  print(" BorgVR Dataset Server")
  print(" ------------------------------------------------------------")
  print(" Version           : \(TerminalServerInfo.version)")
  print(" Build             : \(TerminalServerInfo.build)")
  print(" Dataset directory : \(config.dataDirectory)")
  print(" Dataset port      : \(config.port)")
  print(" Max brick batch   : \(config.maxBricksPerGetRequest)")
  if config.scanIntervalSeconds > 0 {
    print(" Scan interval     : \(config.scanIntervalSeconds) s")
  } else {
    print(" Scan interval     : disabled")
  }
  print(" Password          : \(config.password.isEmpty ? "disabled" : "enabled")")
  print(" Log level         : \(logLevelDescription(logLevel))")
  print(" Log file          : \(config.logFilePath ?? "disabled")")
  if let webPort = config.webPort {
    let scheme = config.useWebServerTLS ? "https" : "http"
    let effectivePort = webPort == config.port
      ? (config.port == UInt16.max ? 1 : config.port + 1)
      : webPort
    print(" WebGPU frontend   : \(scheme)://localhost:\(effectivePort)/")
  } else {
    print(" WebGPU frontend   : disabled")
  }
  if config.syncServers.isEmpty {
    print(" Sync servers      : disabled")
  } else {
    print(" Sync servers      : \(config.syncServers.count)")
    for endpoint in config.syncServers {
      let password = endpoint.password.isEmpty ? "" : " (password)"
      print("   - \(endpoint.address):\(endpoint.port) every \(endpoint.intervalSeconds) s\(password)")
    }
  }
  print(" ------------------------------------------------------------\n")
  fflush(stdout)
}

func datasetDisplayName(_ dataset: DatasetInfo) -> String {
  let description = dataset.datasetDescription.trimmingCharacters(in: .whitespacesAndNewlines)
  if !description.isEmpty { return description }
  return URL(fileURLWithPath: dataset.filename).deletingPathExtension().lastPathComponent
}

func formatPhysicalExtent(_ value: Double) -> String {
  String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
}

func printDatasets(_ datasets: [DatasetInfo]) {
  guard !datasets.isEmpty else {
    print("No datasets are currently available.")
    fflush(stdout)
    return
  }

  print("Available datasets (\(datasets.count)):")
  for (index, dataset) in datasets.enumerated() {
    let size = dataset.size.count == 3 ? dataset.size : [0, 0, 0]
    let spacing = dataset.voxelSpacing.count == 3 ? dataset.voxelSpacing : [0, 0, 0]
    let extent = zip(size, spacing).map { Double($0.0) * Double($0.1) }
    print("  \(index + 1). \(datasetDisplayName(dataset))")
    print("     ID      : \(dataset.id)")
    print("     Voxels  : \(size[0]) x \(size[1]) x \(size[2])")
    print(
      "     Size    : \(formatPhysicalExtent(extent[0])) x " +
      "\(formatPhysicalExtent(extent[1])) x \(formatPhysicalExtent(extent[2])) m"
    )
  }
  fflush(stdout)
}

func printConsoleHelp() {
  print("""
  Commands:
    l  List currently available datasets.
    l0 Log developer/debug messages and above.
    l1 Log informational messages and above.
    l2 Log warnings and errors.
    l3 Log errors only.
    i  Show the startup and server configuration information.
    r  Refresh the server catalog now.
    h  Show this command list.
    q  Stop the server and quit.
  """)
  fflush(stdout)
}

final class TerminalLogger: LoggerBase {
  private let destinations: [LoggerBase]
  private let lock = NSLock()
  private var minimumLevel: LogLevel = .info

  init(destinations: [LoggerBase]) {
    self.destinations = destinations
    destinations.forEach { $0.setMinimumLogLevel(.dev) }
  }

  func setMinimumLogLevel(_ level: LogLevel) {
    lock.lock()
    minimumLevel = level
    lock.unlock()
  }

  var currentLevel: LogLevel {
    lock.lock()
    defer { lock.unlock() }
    return minimumLevel
  }

  private func emit(level: LogLevel, _ action: (LoggerBase) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    guard level >= minimumLevel else { return }
    destinations.forEach(action)
  }

  func dev(_ message: String) { emit(level: .dev) { $0.dev(message) } }
  func info(_ message: String) { emit(level: .info) { $0.info(message) } }
  func warning(_ message: String) { emit(level: .warning) { $0.warning(message) } }
  func error(_ message: String) { emit(level: .error) { $0.error(message) } }
  func progress(_ message: String, _ progress: Double) {
    emit(level: .dev) { $0.progress(message, progress) }
  }
}

func prepareLogFile(at path: String) {
  let url = URL(fileURLWithPath: path)
  let parent = url.deletingLastPathComponent()
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
        isDirectory.boolValue else {
    fail("Log file directory does not exist: \(parent.path)")
  }
  if !FileManager.default.fileExists(atPath: url.path) {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      fail("Could not create log file at \(path).")
    }
  }
  do {
    let handle = try FileHandle(forWritingTo: url)
    try handle.close()
  } catch {
    fail("Could not open log file at \(path): \(error.localizedDescription)")
  }
}

let config = parseArguments(CommandLine.arguments)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: config.dataDirectory, isDirectory: &isDirectory),
      isDirectory.boolValue
else {
  fail("Dataset directory does not exist: \(config.dataDirectory)")
}

let certificateData = loadCertificate(from: config.webServerCertificatePath)
let serverConfiguration = config.serverConfiguration(certificateData: certificateData)
var logDestinations: [LoggerBase] = [PrintfLogger(useColors: true, etaFormat: .mmss)]
if let logFilePath = config.logFilePath {
  prepareLogFile(at: logFilePath)
  logDestinations.append(
    FileLogger(
      logFilePath: logFilePath,
      maxFileSize: 10 * 1024 * 1024,
      flushImmediately: true,
      enableCompression: false
    )
  )
}
let logger = TerminalLogger(destinations: logDestinations)
let host = BorgVRServerHost(logger: logger)

printStartupBanner(config, logLevel: logger.currentLevel)
logger.info("Scanning server catalog in \(config.dataDirectory)")
let state = host.start(configuration: serverConfiguration)

guard state.isRunning, state.serverError == nil else {
  logger.error(state.serverError ?? "Dataset server did not start.")
  host.stop()
  exit(1)
}
if config.webPort != nil, !state.isWebServerRunning {
  logger.error(state.webServerError ?? "WebGPU server did not start.")
  host.stop()
  exit(1)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let runtimeQueue = DispatchQueue(label: "TerminalServerApp.RuntimeQueue")
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: runtimeQueue)
let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: runtimeQueue)
var catalogTimer: DispatchSourceTimer?
let syncManager: ServerSyncManager? = config.syncServers.isEmpty ? nil : ServerSyncManager(
  logger: logger,
  dataDirectory: config.dataDirectory,
  endpoints: config.syncServers,
  onLocalCatalogChanged: {
    runtimeQueue.async {
      if host.refreshCatalog(configuration: serverConfiguration) {
        logger.info("Published synchronized server catalog.")
      }
    }
  },
  onStatusChanged: { _ in }
)

func stopAndExit() {
  logger.info("Stopping server...")
  catalogTimer?.cancel()
  catalogTimer = nil
  syncManager?.stop()
  host.stop()
  exit(0)
}

interruptSource.setEventHandler(handler: stopAndExit)
terminateSource.setEventHandler(handler: stopAndExit)
interruptSource.resume()
terminateSource.resume()

if config.scanIntervalSeconds > 0 {
  let timer = DispatchSource.makeTimerSource(queue: runtimeQueue)
  let interval = DispatchTimeInterval.seconds(config.scanIntervalSeconds)
  timer.schedule(deadline: .now() + interval, repeating: interval)
  timer.setEventHandler {
    _ = host.refreshCatalog(configuration: serverConfiguration)
  }
  timer.resume()
  catalogTimer = timer
}

syncManager?.start()

printConsoleHelp()
while let line = readLine() {
  let command = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  switch command {
    case "q":
      stopAndExit()
    case "l":
      let datasets = runtimeQueue.sync { host.state.datasets }
      printDatasets(datasets)
    case "l0":
      logger.setMinimumLogLevel(.dev)
      print("Log level set to developer/debug (l0).")
    case "l1":
      logger.setMinimumLogLevel(.info)
      print("Log level set to info (l1).")
    case "l2":
      logger.setMinimumLogLevel(.warning)
      print("Log level set to warning (l2).")
    case "l3":
      logger.setMinimumLogLevel(.error)
      print("Log level set to error (l3).")
    case "i":
      printStartupBanner(config, logLevel: logger.currentLevel)
    case "r":
      runtimeQueue.sync {
        _ = host.refreshCatalog(configuration: serverConfiguration)
      }
      logger.info("Server catalog refreshed.")
    case "h", "?":
      printConsoleHelp()
    case "":
      break
    default:
      logger.warning("Unknown command: \(command). Type 'h' for help.")
  }
}

logger.info("Standard input closed. Press Ctrl-C to stop \(executableName).")
dispatchMain()

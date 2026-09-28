import Dispatch
import Foundation

enum TerminalServerInfo {
  static let version = "2.5"

  static let banner = #"""
   ____                   __     ______
  | __ )  ___  _ __ __ _ \ \   / /  _ \
  |  _ \ / _ \| '__/ _` | \ \ / /| |_) |
  | |_) | (_) | | | (_| |  \ V / |  _ <
  |____/ \___/|_|  \__, |   \_/  |_| \_\
                   |___/
               Dataset Server \#(version)
  """#
}

struct ServerConfiguration {
  var dataDirectory = FileManager.default.homeDirectoryForCurrentUser.path
  var port = UInt16(BorgVRSharedDefaults.datasetServerPort)
  var maxBricksPerGetRequest = BorgVRSharedDefaults.maximumBricksPerRequest
  var password = ""
  var scanIntervalSeconds = 10
  var webPort: UInt16?
  var useWebServerTLS = true
  var webServerCertificatePath: String?
  var webServerCertificatePassword = ""
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
  --directory, -d <path>          Directory containing .data, .tf1d, and .marker files.
                                  Defaults to the home directory.
  --port, -p <port>               Native dataset-server port.
                                  Defaults to \(BorgVRSharedDefaults.datasetServerPort).
  --max-bricks, -m <count>        Maximum bricks per GETBRICKS request.
                                  Defaults to \(BorgVRSharedDefaults.maximumBricksPerRequest).
  --password <secret>             Optional password for native and WebGPU clients.
  --scan-interval <seconds>       Refresh the file catalog periodically.
                                  Defaults to 10; use 0 to disable rescanning.
  --web-port <port>               Enable the WebGPU server on this port.
                                  HTTPS with a temporary certificate is the default.
  --web-http                      Use HTTP instead of HTTPS. HTTP only listens on localhost.
  --web-certificate <path>        PKCS#12 certificate (.p12 or .pfx) for HTTPS.
  --web-certificate-password <p>  Password for the PKCS#12 certificate.
  --sync-server <host> <port> <interval> [password]
                                  Synchronize datasets, transfer functions, and marker
                                  files from a BorgVR server. The interval is specified
                                  in seconds and must be at least 10. Repeat this option
                                  to configure fallback sources.
  --version, -v                   Show the version.
  --help, -h                      Show this help.
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

print(TerminalServerInfo.banner)

let config = parseArguments(CommandLine.arguments)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: config.dataDirectory, isDirectory: &isDirectory),
      isDirectory.boolValue
else {
  fail("Dataset directory does not exist: \(config.dataDirectory)")
}

let certificateData = loadCertificate(from: config.webServerCertificatePath)
let serverConfiguration = config.serverConfiguration(certificateData: certificateData)
let logger = PrintfLogger(useColors: true, etaFormat: .mmss)
let host = BorgVRServerHost(logger: logger)

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

logger.info("Dataset server: port \(state.port), max brick batch \(config.maxBricksPerGetRequest).")
logger.info("Password protection: \(config.password.isEmpty ? "disabled" : "enabled").")
if state.isWebServerRunning {
  let scheme = state.webServerUsesTLS ? "https" : "http"
  logger.info("WebGPU frontend: \(scheme)://localhost:\(state.webPort)/")
}
if config.scanIntervalSeconds > 0 {
  logger.info("Catalog refresh interval: \(config.scanIntervalSeconds) seconds.")
} else {
  logger.info("Periodic catalog refresh is disabled.")
}
if config.syncServers.isEmpty {
  logger.info("Server-to-server synchronization: disabled.")
} else {
  logger.info("Server-to-server synchronization: \(config.syncServers.count) source(s).")
  for endpoint in config.syncServers {
    logger.info(
      "  \(endpoint.address):\(endpoint.port), every \(endpoint.intervalSeconds) seconds, " +
      "password \(endpoint.password.isEmpty ? "not configured" : "configured")."
    )
  }
}
logger.info("Press Ctrl-C to stop \(executableName).")

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

dispatchMain()

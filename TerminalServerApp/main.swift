import Dispatch
import Foundation

struct ServerConfiguration {
  var dataDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
  var port: UInt16 = 12345
  var maxBricksPerGetRequest: Int = 20
}

let usage = """
Usage:
  TerminalServerApp [--directory <path>] [--port <port>] [--max-bricks <count>]

Options:
  --directory, -d   Directory containing .data datasets. Defaults to the home directory.
  --port, -p        TCP port to listen on. Defaults to 12345.
  --max-bricks, -m  Maximum bricks per GETBRICKS request. Defaults to 20.
  --help, -h        Show this help.
"""

func parseArguments(_ args: [String]) -> ServerConfiguration {
  var config = ServerConfiguration()
  var index = 1

  func requireValue(after option: String) -> String {
    guard index + 1 < args.count else {
      fputs("Missing value for \(option).\n\n\(usage)\n", stderr)
      exit(2)
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
          fputs("Invalid port: \(value)\n\n\(usage)\n", stderr)
          exit(2)
        }
        config.port = port

      case "--max-bricks", "-m":
        let value = requireValue(after: argument)
        guard let maxBricks = Int(value), maxBricks > 0 else {
          fputs("Invalid max-bricks value: \(value)\n\n\(usage)\n", stderr)
          exit(2)
        }
        config.maxBricksPerGetRequest = maxBricks

      case "--help", "-h":
        print(usage)
        exit(0)

      default:
        fputs("Unknown argument: \(argument)\n\n\(usage)\n", stderr)
        exit(2)
    }

    index += 1
  }

  return config
}

let config = parseArguments(CommandLine.arguments)
let logger = PrintfLogger(useColors: true, etaFormat: .mmss)

logger.info("Scanning datasets in \(config.dataDirectory)")
let scanner = DatasetScanner(directory: config.dataDirectory, logger: logger)
scanner.loadDatasets()
let datasets = scanner.getDatasets()
logger.info("Found \(datasets.count) datasets.")

let server = TCPServer(
  port: config.port,
  maxBricksPerGetRequest: config.maxBricksPerGetRequest,
  logger: logger,
  datasets: datasets
)
server.start()

guard server.isRunning else {
  logger.error("Server did not start.")
  exit(1)
}

logger.info("Press Ctrl-C to stop TerminalServerApp.")

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let signalQueue = DispatchQueue(label: "TerminalServerApp.SignalQueue")
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)

func stopAndExit() {
  logger.info("Stopping server...")
  server.stop()
  exit(0)
}

interruptSource.setEventHandler(handler: stopAndExit)
terminateSource.setEventHandler(handler: stopAndExit)
interruptSource.resume()
terminateSource.resume()

dispatchMain()

#if os(macOS)
import Foundation
import Darwin

/// Serial worker shared by the GUI and command-line servers. Never copies the source volume.
final class BorgVRAutoImporter: @unchecked Sendable {
  static let defaultInterval: TimeInterval = 10
  static let allowedIntervals: ClosedRange<TimeInterval> = 0.1...86400

  enum ImportError: Error, LocalizedError {
    case overlappingDirectories, invalidDirectory, unsafeSource, sourceChanged

    var errorDescription: String? {
      switch self {
        case .overlappingDirectories: "The output directory must be outside the auto-import directory."
        case .invalidDirectory: "Auto-import requires an existing input directory and a check interval between 0.1 and 86400 seconds."
        case .unsafeSource: "Auto-import sources must be regular files inside the input directory, without symbolic links."
        case .sourceChanged: "Auto-import source changed; waiting for another stable check."
      }
    }
  }

  private struct Stamp: Equatable {
    let size: UInt64
    let modified: Date
    let identity: UInt64
    let linkCount: UInt64
    let kind: FileAttributeType
  }
  private typealias Snapshot = [String: Stamp]

  private let input: URL
  private let output: URL
  private let interval: TimeInterval
  private let mode: BorgVRAutoImportMode
  private let settings: BorgVRVolumeConversionSettings
  private let toolIdentification: String
  private let logger: LoggerBase?
  private let onImported: @Sendable (URL) -> Void
  private let queue = DispatchQueue(label: "BorgVR.AutoImporter", qos: .utility)
  private let cancellation = BorgVRVolumeConversionCancellationToken()
  // The following state is confined to queue (or a synchronous test before start()).
  private var timer: DispatchSourceTimer?
  private var previous: Snapshot?
  private var failed: Set<String> = []
  private var previousManifest: Stamp?
  private var manifestGeneration: Stamp?
  private var rejectedManifest: Stamp?
  private var completedManifestSources: Set<String> = []

  init(input: URL, output: URL, interval: TimeInterval = defaultInterval,
       mode: BorgVRAutoImportMode = .automatic,
       settings: BorgVRVolumeConversionSettings, logger: LoggerBase? = nil,
       toolIdentification: String = BORGVRToolIdentification.current,
       onImported: @escaping @Sendable (URL) -> Void = { _ in }) throws {
    self.input = input.standardizedFileURL.resolvingSymlinksInPath()
    self.output = output.standardizedFileURL.resolvingSymlinksInPath()
    self.interval = interval
    self.mode = mode
    self.settings = settings
    self.toolIdentification = toolIdentification
    self.logger = logger
    self.onImported = onImported
    guard interval.isFinite, Self.allowedIntervals.contains(interval),
          try self.input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw ImportError.invalidDirectory
    }
    guard self.output != self.input, !Self.contains(self.output.path, in: self.input.path) else {
      throw ImportError.overlappingDirectories
    }
    try settings.validate()
    try FileManager.default.createDirectory(at: self.output, withIntermediateDirectories: true)
  }

  func start() {
    queue.async { [self] in
      guard timer == nil, !cancellation.isCancelled else { return }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: interval)
      timer.setEventHandler { [weak self] in
        guard let self, !self.cancellation.isCancelled else { return }
        do { try self.checkForImports() }
        catch is CancellationError {}
        catch {
          self.previous = nil
          self.logger?.warning("Auto-import check failed: \(error.localizedDescription)")
        }
      }
      self.timer = timer
      timer.resume()
      logger?.info("Auto-import watching \(input.path) every \(interval) seconds.")
    }
  }

  func stop() {
    cancellation.cancel()
    queue.async { [self] in timer?.cancel(); timer = nil }
  }

  deinit { timer?.cancel() }

  /// One poll, kept synchronous so stability/cleanup can be regression-tested without timers.
  func checkForImports() throws {
    try cancellation.checkCancellation()
    if mode == .guided { try checkManifest(); return }
    let snapshot = try takeSnapshot()
    guard previous == snapshot else {
      previous = snapshot
      failed.removeAll()
      return
    }
    let candidates = snapshot.keys.filter { !$0.contains("/") }.sorted { lhs, rhs in
      // Headers precede their payloads, which may themselves have a supported extension.
      let headers = ["dat", "nhdr", "nrrd"]
      let l = headers.contains(URL(fileURLWithPath: lhs).pathExtension.lowercased())
      let r = headers.contains(URL(fileURLWithPath: rhs).pathExtension.lowercased())
      return l == r ? lhs < rhs : l
    }
    _ = try process(candidates.map { BorgVRAutoImportManifest.Entry(source: $0) }, snapshot: snapshot)
  }

  private func checkManifest() throws {
    let manifest = input.appendingPathComponent(BorgVRAutoImportManifest.filename)
    guard FileManager.default.fileExists(atPath: manifest.path) ||
      (try? FileManager.default.attributesOfItem(atPath: manifest.path)) != nil else {
      previousManifest = nil
      manifestGeneration = nil
      rejectedManifest = nil
      completedManifestSources.removeAll()
      return
    }
    let control = try stamp(manifest)
    if control == rejectedManifest { try finishManifest(control); return }
    if manifestGeneration != control {
      manifestGeneration = control
      completedManifestSources.removeAll()
    }
    guard previousManifest == control else { previousManifest = control; return }
    let entries: [BorgVRAutoImportManifest.Entry]
    let snapshot: Snapshot
    do {
      guard control.kind == .typeRegular, control.linkCount == 1,
            control.size <= BorgVRAutoImportManifest.maximumByteCount else {
        throw ImportError.unsafeSource
      }
      let descriptor = open(manifest.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
      guard descriptor >= 0 else { throw ImportError.unsafeSource }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: BorgVRAutoImportManifest.maximumByteCount + 1) ?? Data()
      guard try stamp(manifest) == control else { throw ImportError.sourceChanged }
      let names = Set(try FileManager.default.contentsOfDirectory(atPath: input.path))
      entries = try BorgVRAutoImportManifest.decode(data, inputNames: names.union(completedManifestSources))
      snapshot = try takeSnapshot()
      // Reject an unsafe instruction before processing any entry in its batch.
      for entry in entries where !completedManifestSources.contains(entry.source) {
        try validateSources([input.appendingPathComponent(entry.source)], snapshot: snapshot)
      }
    } catch ImportError.sourceChanged { previousManifest = nil; return }
    catch {
      try appendAudit("REJECTED", source: BorgVRAutoImportManifest.filename, detail: error.localizedDescription)
      logger?.warning("Guided import rejected import.json: \(error.localizedDescription)")
      rejectedManifest = control
      try finishManifest(control)
      return
    }
    do {
      _ = try process(entries.filter { !completedManifestSources.contains($0.source) },
                      snapshot: snapshot, manifest: control)
      if previousManifest == control { try finishManifest(control) }
    } catch is CancellationError { throw CancellationError() }
    catch ImportError.sourceChanged { previousManifest = nil }
    catch {
      try appendAudit("FAILED", source: BorgVRAutoImportManifest.filename, detail: error.localizedDescription)
      try finishManifest(control)
    }
  }

  private func finishManifest(_ control: Stamp) throws {
    let url = input.appendingPathComponent(BorgVRAutoImportManifest.filename)
    guard try stamp(url) == control else { previousManifest = nil; return }
    try appendAudit("FINISHED", source: BorgVRAutoImportManifest.filename, detail: "Request processed; see entry results.")
    try removeSnapshotPaths([BorgVRAutoImportManifest.filename],
      snapshot: [BorgVRAutoImportManifest.filename: control])
    previousManifest = nil
    manifestGeneration = nil
    rejectedManifest = nil
    completedManifestSources.removeAll()
  }

  private func process(_ entries: [BorgVRAutoImportManifest.Entry], snapshot initial: Snapshot,
                       manifest: Stamp? = nil) throws -> Bool {
    var snapshot = initial
    for entry in entries where manifest != nil || !failed.contains(entry.source) {
      let name = entry.source
      try cancellation.checkCancellation()
      guard snapshot[name] != nil else { continue }
      let source = input.appendingPathComponent(name)
      let staging = output.appendingPathComponent(".auto-import-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: staging) }
      var sources = [source]
      var destinationPublished = false
      var publicationAttempted = false
      do {
        try validateSources([source], snapshot: snapshot)
        let stagedFile = staging.appendingPathComponent("volume.data")
        sources = try BorgVRAutomaticVolumeConversion.convert(source: source,
          destination: stagedFile, settings: settings, logger: logger, cancellationToken: cancellation,
          description: entry.description, physicalSizeMeters: entry.physicalSize,
          provenance: entry.provenance, toolIdentification: toolIdentification,
          validateSources: {
            try self.validateSources($0, snapshot: snapshot)
            sources = $0
          })
        try cancellation.checkCancellation()
        try ensureUnchanged(snapshot, sources: [source] + sources, manifest: manifest)
        publicationAttempted = true
        let destination = try publish(stagedFile, source: source, filename: entry.destination)
        destinationPublished = true
        try appendAudit("SUCCESS", source: name, detail: destination.path)
        logger?.info("Auto-import completed: \(destination.lastPathComponent).")
        onImported(destination)
        let roots = snapshot[name]?.kind == .typeDirectory ? [name] : try sources.map(relativePath)
        try removeSnapshotPaths(roots, snapshot: snapshot)
        if manifest != nil { completedManifestSources.insert(name) }
        snapshot = try snapshotAfterCleanup(snapshot, roots: roots, manifest: manifest)
      } catch is CancellationError {
        try appendAudit("FAILED", source: name, detail: "Import cancelled; remaining sources retained.")
        throw CancellationError()
      }
      catch ImportError.sourceChanged {
        previous = nil; previousManifest = nil
        try appendAudit("FAILED", source: name, detail: ImportError.sourceChanged.localizedDescription)
        logger?.info(ImportError.sourceChanged.localizedDescription)
        return false
      } catch {
        // I/O failures must not destroy the only copy when the output could not be written.
        if destinationPublished || publicationAttempted || isWriteFailure(error) {
          failed.insert(name)
          try appendAudit("FAILED", source: name, detail: "Source retained: \(error.localizedDescription)")
          logger?.warning("Auto-import retained \(name): \(error.localizedDescription)")
          return false
        }
        try ensureUnchanged(snapshot, sources: [source] + sources, manifest: manifest)
        try appendAudit("FAILED", source: name, detail: error.localizedDescription)
        logger?.warning("Auto-import could not read \(name); removing source.")
        let roots = snapshot[name]?.kind == .typeDirectory ? [name]
          : ((try? sources.map(relativePath)) ?? [name])
        try removeSnapshotPaths(roots, snapshot: snapshot)
        if manifest != nil { completedManifestSources.insert(name) }
        snapshot = try snapshotAfterCleanup(snapshot, roots: roots, manifest: manifest)
      }
    }
    return true
  }

  private func ensureUnchanged(_ snapshot: Snapshot, sources: [URL], manifest: Stamp?) throws {
    let current = try takeSnapshot()
    if let manifest {
      guard try stamp(input.appendingPathComponent(BorgVRAutoImportManifest.filename)) == manifest else {
        throw ImportError.sourceChanged
      }
      // Guided mode is gated by import.json, not by unrelated arrivals in the inbox.
      let roots = try sources.map(relativePath)
      for root in roots {
        let expected = snapshot.filter { $0.key == root || Self.contains($0.key, in: root) }
        let actual = current.filter { $0.key == root || Self.contains($0.key, in: root) }
        guard expected == actual else { throw ImportError.sourceChanged }
      }
    } else if current != snapshot { throw ImportError.sourceChanged }
  }

  private func snapshotAfterCleanup(_ before: Snapshot, roots: [String], manifest: Stamp?) throws -> Snapshot {
    let after = try takeSnapshot()
    if manifest == nil {
      for (path, value) in after {
        guard let old = before[path], value == old ||
          (value.kind == .typeDirectory && old.kind == .typeDirectory && value.identity == old.identity &&
           roots.contains(where: { Self.contains($0, in: path) })) else {
          previous = nil
          throw ImportError.sourceChanged
        }
      }
      previous = after
    }
    return after
  }

  private func isWriteFailure(_ error: Error) -> Bool {
    let value = error as NSError
    return (value.domain == NSCocoaErrorDomain && (512...671).contains(value.code)) ||
      (value.domain == NSPOSIXErrorDomain && [ENOSPC, EDQUOT, EROFS, EFBIG, EIO, EACCES, EPERM].contains(Int32(value.code)))
  }

  private static func contains(_ path: String, in directory: String) -> Bool {
    path.hasPrefix(directory == "/" ? "/" : directory + "/")
  }

  private func relativePath(_ url: URL) throws -> String {
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    guard Self.contains(resolved.path, in: input.path) else { throw ImportError.unsafeSource }
    var ancestor = url.standardizedFileURL
    while ancestor.resolvingSymlinksInPath().path != input.path {
      guard try ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
        throw ImportError.unsafeSource
      }
      let parent = ancestor.deletingLastPathComponent()
      guard parent.path != ancestor.path else { throw ImportError.unsafeSource }
      ancestor = parent
    }
    return String(resolved.path.dropFirst(input.path.count + (input.path == "/" ? 0 : 1)))
  }

  private func stamp(_ url: URL) throws -> Stamp {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return Stamp(size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
      modified: attributes[.modificationDate] as? Date ?? .distantPast,
      identity: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
      linkCount: (attributes[.referenceCount] as? NSNumber)?.uint64Value ?? 1,
      kind: attributes[.type] as? FileAttributeType ?? .typeUnknown)
  }

  private func takeSnapshot() throws -> Snapshot {
    var snapshot: Snapshot = [:]
    func visit(_ directory: URL, prefix: String = "") throws {
      guard directory.resolvingSymlinksInPath().path == directory.path else { throw ImportError.unsafeSource }
      for entryURL in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        let name = entryURL.lastPathComponent
        if prefix.isEmpty, name.lowercased() == "log.txt" ||
          (mode == .guided && name.lowercased() == BorgVRAutoImportManifest.filename) { continue }
        // FileManager may return /private/var URLs for a /var input; build relative paths explicitly.
        let url = directory.appendingPathComponent(name)
        let path = prefix + name
        let entry = try stamp(url)
        snapshot[path] = entry
        if entry.kind == .typeDirectory { try visit(url, prefix: path + "/") }
      }
    }
    try visit(input)
    return snapshot
  }

  private func validateSources(_ sources: [URL], snapshot: Snapshot) throws {
    for source in sources {
      let path = try relativePath(source)
      guard let entry = snapshot[path], entry.kind == .typeRegular || entry.kind == .typeDirectory else {
        throw ImportError.unsafeSource
      }
      guard entry.kind != .typeRegular || entry.linkCount == 1 else { throw ImportError.unsafeSource }
      guard !snapshot.contains(where: { Self.contains($0.key, in: path) &&
        (($0.value.kind != .typeRegular && $0.value.kind != .typeDirectory) ||
         ($0.value.kind == .typeRegular && $0.value.linkCount != 1)) }) else {
        throw ImportError.unsafeSource
      }
    }
  }

  private func publish(_ staged: URL, source: URL, filename: String?) throws -> URL {
    let name = filename ?? source.deletingPathExtension().lastPathComponent + ".data"
    let fullName = URL(fileURLWithPath: name).pathExtension.isEmpty ? name + ".data" : name
    let base = URL(fileURLWithPath: fullName).deletingPathExtension().lastPathComponent
    var destination = output.appendingPathComponent(fullName)
    var suffix = 2
    while true {
      // Atomic, no-replace publication on the output filesystem, without copying volume bytes.
      if renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
      let code = errno
      guard code == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
      destination = output.appendingPathComponent("\(base)-\(suffix).data")
      suffix += 1
    }
  }

  private func removeSnapshotPaths(_ roots: [String], snapshot: Snapshot) throws {
    let paths = snapshot.keys.filter { path in roots.contains {
      path == $0 || Self.contains(path, in: $0)
    }}
    for path in paths where snapshot[path]?.kind != .typeDirectory {
      try cancellation.checkCancellation()
      let url = input.appendingPathComponent(path)
      guard try stamp(url) == snapshot[path],
            url.deletingLastPathComponent().resolvingSymlinksInPath().path == url.deletingLastPathComponent().path else {
        throw ImportError.sourceChanged
      }
      try FileManager.default.removeItem(at: url)
    }
    // Never recursively remove a directory: a producer might have added a new file meanwhile.
    var directories = Set(paths.filter { snapshot[$0]?.kind == .typeDirectory })
    for path in paths {
      var parent = input.appendingPathComponent(path).deletingLastPathComponent()
      while parent != input, Self.contains(parent.path, in: input.path) {
        let relative = try relativePath(parent)
        if snapshot[relative]?.kind == .typeDirectory { directories.insert(relative) }
        parent.deleteLastPathComponent()
      }
    }
    for path in directories.sorted(by: { $0.count > $1.count }) {
      let url = input.appendingPathComponent(path)
      guard url.resolvingSymlinksInPath() == url else { throw ImportError.sourceChanged }
      if rmdir(url.path) != 0 && errno != ENOTEMPTY && errno != ENOENT {
        logger?.warning("Auto-import could not remove empty directory \(url.lastPathComponent).")
      }
    }
  }

  private func appendAudit(_ result: String, source: String, detail: String) throws {
    let url = input.appendingPathComponent("log.txt")
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw ImportError.unsafeSource
    }
    let text = "\(ISO8601DateFormatter().string(from: Date())) [\(result)] \(source): \(detail)"
      .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") + "\n"
    try Data(text.utf8).withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        offset += count
      }
    }
  }
}
#endif

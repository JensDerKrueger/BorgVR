import Foundation
import CryptoKit
import Compression

private struct VolumeEditProposal: Codable, Sendable {
  let stateID: UUID
  let id: UUID
  let mode: BorgVRVolumeBrushMode
  let samples: [BorgVRVolumeBrushSample]
}

private struct VolumeEditSnapshotHeader: Codable, Sendable {
  let id: UUID
  let stateID: UUID
  let revision: UInt64
  let bytes: Int
  let decodedBytes: Int
  let chunks: Int
  let digest: Data
}

private enum VolumeEditPacket: Codable, Sendable {
  case request
  case snapshot(VolumeEditSnapshotHeader)
  case chunk(UUID, Int, Data)
  case receipt(UUID, Int)
  case proposal(VolumeEditProposal)
  case commit(UUID, BorgVRVolumeBrushBatch)
  case rejected(UUID, UUID)
  case cursors(UUID, [BorgVRVolumeBrushCursor])
  case status(UUID, UInt64)
}

private struct VolumeEditReceiptKey: Hashable { let transfer: UUID; let index: Int }
private enum VolumeEditTransferError: LocalizedError {
  case receiptTimeout
  var errorDescription: String? { "Timed out waiting for an edit-state receipt." }
}

/// Shared by all three apps. Only the transport/participant lookup is platform-specific.
@MainActor
final class BorgVRVolumeEditCollaboration {
  typealias Sender = @MainActor (Data, UUID?) async throws -> Void
  private let model: VolumeBrushModel
  private let send: Sender
  private let log: (String) -> Void
  private let info: (String) -> Void
  private var participants: Set<UUID> = []
  private var outgoing: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
  private var receipts: [VolumeEditReceiptKey: (participant: UUID, continuation: CheckedContinuation<Bool, Error>, timeout: Task<Void, Never>)] = [:]
  private var localID: UUID?
  private var hostID: UUID?
  private var datasetID: String?
  private var epoch: UUID?
  private var revision: UInt64 = 0
  private var generation = UUID()
  private var preparing: Task<Void, Error>?
  private var cursorTask: Task<Void, Never>?
  private var processing: Task<Void, Never>?
  private var proposals: [(UUID, VolumeEditProposal)] = []
  private var commits: [UInt64: BorgVRVolumeBrushBatch] = [:]
  private var pending: [UUID: (proposal: VolumeEditProposal, completion: @Sendable (Error?) -> Void)] = [:]
  private var pendingOrder: [UUID] = []
  private var incoming: (header: VolumeEditSnapshotHeader, chunks: [Int: Data], received: Int)?
  private var latestTransferID: UUID?
  private var decodingTransferID: UUID?
  private var latestSnapshotHeader: VolumeEditSnapshotHeader?
  private var pendingSnapshot: BorgVRVolumeEditSnapshot?
  private var installing = false
  private var requested = false
  private var lastRequest = Date.distantPast
  private var lastTransferActivity = Date.distantPast
  private let chunkSize = 16 * 1024
  private let maximumSnapshotBytes = 256 * 1024 * 1024
  private var isHost: Bool { localID != nil && localID == hostID }

  init(model: VolumeBrushModel, send: @escaping Sender, log: @escaping (String) -> Void,
       info: ((String) -> Void)? = nil) {
    self.model = model; self.send = send; self.log = log
    self.info = info ?? log
    model.didBecomeReady = { [weak self] in self?.datasetReady() }
  }

  func configure(localID: UUID, hostID: UUID?, datasetID: String?, participants: Set<UUID> = []) {
    let changedDataset = self.datasetID != datasetID
    let changedHost = self.hostID != hostID
    if changedDataset || changedHost {
      invalidatePending()
      epoch = nil; revision = 0; commits.removeAll(); incoming = nil; pendingSnapshot = nil; latestSnapshotHeader = nil
      requested = false
    }
    self.localID = localID; self.hostID = hostID; self.datasetID = datasetID
    self.participants = participants
    for (participant, transfer) in outgoing where !participants.contains(participant) {
      transfer.task.cancel()
    }
    model.isSharePlayHost = isHost
    model.setSharePlayActive(true)
    if changedDataset || (changedHost && hostID != nil) { model.beginSharedStateSynchronization() }
    model.context.setEditHandler { [weak self] mode, samples, token, completion in
      Task { @MainActor in
        guard let self else { completion(CancellationError()); return }
        await self.submit(mode: mode, samples: samples, cancellationToken: token, completion: completion)
      }
    }
    model.sharedDiscard = { [weak self] in
      guard let self else { throw CancellationError() }
      let snapshot = try await self.model.stateSnapshot()
      let extent = SIMD3<Double>(snapshot.mask.size) * snapshot.mask.spacing
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        Task { @MainActor in
          await self.submit(mode: .restore, samples: [.init(center: extent * 0.5, radius: max(extent.x, extent.y, extent.z) * 2)]) { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          }
        }
      }
    }
    if cursorTask == nil { startCursors() }
    if changedHost { requested = false }
    datasetReady()
  }

  func stop() {
    invalidatePending()
    cursorTask?.cancel(); cursorTask = nil
    epoch = nil; datasetID = nil; localID = nil; hostID = nil
    incoming = nil; pendingSnapshot = nil; commits.removeAll()
    model.didBecomeReady = nil
    model.setSharePlayActive(false)
  }

  private func invalidatePending() {
    generation = UUID()
    installing = false
    decodingTransferID = nil
    for transfer in outgoing.values { transfer.task.cancel() }
    outgoing.removeAll()
    for key in Array(receipts.keys) { finishReceipt(key, result: .failure(CancellationError())) }
    preparing?.cancel(); preparing = nil
    processing?.cancel(); processing = nil
    proposals.removeAll()
    let callbacks = pending.values.map(\.completion)
    pending.removeAll()
    pendingOrder.removeAll()
    model.cancelSharedPredictions()
    for callback in callbacks { callback(CancellationError()) }
    model.context.clearRemoteCursors()
  }

  private func datasetReady() {
    guard model.volumeEditingState().datasetID == datasetID, hostID != nil, !installing, !model.isOpeningState else { return }
    if let snapshot = pendingSnapshot { install(snapshot); return }
    if isHost, epoch != nil, model.isWaitingForSharedState {
      invalidatePending()
      epoch = nil; revision = 0; commits.removeAll()
    }
    if isHost, epoch == nil, preparing == nil {
      Task { [weak self] in
        do { try await self?.ensureHostState(); await self?.sendSnapshot() }
        catch { self?.log("Edit state initialization failed: \(error.localizedDescription)") }
      }
    } else if !isHost, (epoch == nil || model.isWaitingForSharedState), !requested {
      requested = true
      info("Requesting the shared edit state for the loaded dataset.")
      Task { [weak self] in await self?.transmit(.request, to: self?.hostID) }
    }
  }

  private func ensureHostState() async throws {
    guard isHost else { throw CancellationError() }
    if let preparing { try await preparing.value; return }
    guard epoch == nil else { return }
    let generation = self.generation
    let task = Task { [weak self] in
      guard let self else { throw CancellationError() }
      let original = try await model.stateSnapshot()
      guard self.generation == generation, original.datasetID == datasetID else { throw CancellationError() }
      let snapshot = BorgVRVolumeEditSnapshot(datasetID: original.datasetID, stateID: UUID(), revision: 0, mask: original.mask)
      installing = true
      defer { if self.generation == generation { installing = false } }
      try await model.installSessionSnapshot(snapshot, preserveAppearance: true)
      guard self.generation == generation else { throw CancellationError() }
      epoch = snapshot.stateID; revision = 0
    }
    preparing = task
    do { try await task.value; preparing = nil } catch { preparing = nil; throw error }
  }

  func sendSnapshot(to participant: UUID? = nil) async {
    guard isHost else { return }
    let targets = participant.map { [$0] } ?? participants.filter { $0 != localID }.sorted { $0.uuidString < $1.uuidString }
    for target in targets {
      if let transfer = outgoing[target] { await transfer.task.value; continue }
      let id = UUID()
      let task = Task<Void, Never> { [weak self] in
        guard let self else { return }
        await self.sendSnapshotTransfer(to: target)
      }
      outgoing[target] = (id, task)
      await task.value
      if outgoing[target]?.id == id { outgoing[target] = nil }
    }
  }

  private func sendSnapshotTransfer(to participant: UUID) async {
    do {
      try await ensureHostState()
      let generation = self.generation
      let snapshot = try await model.stateSnapshot()
      let maximumBytes = maximumSnapshotBytes
      let prepared = try await Task.detached(priority: .utility) {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumBytes else { throw BorgVRVolumeEditError.invalidBufferSize }
        var compressed = [UInt8](repeating: 0, count: data.count)
        let count = compressed.withUnsafeMutableBufferPointer { output in
          data.withUnsafeBytes { input in
            compression_encode_buffer(output.baseAddress!, output.count,
              input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZ4)
          }
        }
        return (count > 0 && count < data.count ? Data(compressed.prefix(count)) : data, data.count, Data(SHA256.hash(data: data)))
      }.value
      guard self.generation == generation else { throw CancellationError() }
      let data = prepared.0
      guard prepared.1 <= maximumSnapshotBytes else { throw BorgVRVolumeEditError.invalidBufferSize }
      let header = VolumeEditSnapshotHeader(id: UUID(), stateID: snapshot.stateID, revision: snapshot.revision,
        bytes: data.count, decodedBytes: prepared.1, chunks: (data.count + chunkSize - 1) / chunkSize, digest: prepared.2)
      info("Sending edit state revision \(snapshot.revision): \(data.count)/\(prepared.1) bytes, \(header.chunks) chunk(s).")
      if try await sendConfirmed(.snapshot(header), key: .init(transfer: header.id, index: -1), to: participant) { return }
      for index in 0..<header.chunks {
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        let start = index * chunkSize
        _ = try await sendConfirmed(.chunk(header.id, index, data.subdata(in: start..<min(data.count, start + chunkSize))),
          key: .init(transfer: header.id, index: index), to: participant)
      }
      info("Edit-state transfer acknowledged, revision \(snapshot.revision).")
    } catch is CancellationError {}
    catch { log("Could not send edit snapshot: \(error.localizedDescription)") }
  }

  private func sendConfirmed(_ packet: VolumeEditPacket, key: VolumeEditReceiptKey, to participant: UUID) async throws -> Bool {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(15)) } catch { return }
          self?.finishReceipt(key, result: .failure(VolumeEditTransferError.receiptTimeout))
        }
        receipts[key] = (participant, continuation, timeout)
        Task { [weak self] in
          guard let self else { return }
          do { try await send(encode(packet), participant) }
          catch { finishReceipt(key, result: .failure(error)) }
        }
      }
    } onCancel: { Task { @MainActor [weak self] in self?.finishReceipt(key, result: .failure(CancellationError())) } }
  }

  private func finishReceipt(_ key: VolumeEditReceiptKey, result: Result<Bool, Error>) {
    guard let receipt = receipts.removeValue(forKey: key) else { return }
    receipt.timeout.cancel()
    receipt.continuation.resume(with: result)
  }

  func receive(_ data: Data, from participant: UUID) {
    do {
      guard data.count <= 64 * 1024 else { throw BorgVRVolumeEditError.invalidBufferSize }
      let packet = try PropertyListDecoder().decode(VolumeEditPacket.self, from: data)
      switch packet {
        case .request:
          if isHost { Task { [weak self] in await self?.sendSnapshot(to: participant) } }
        case .snapshot(let header):
          guard participant == hostID, !isHost, header.bytes > 0, header.bytes <= maximumSnapshotBytes,
            header.decodedBytes >= header.bytes, header.decodedBytes <= maximumSnapshotBytes,
            header.chunks == (header.bytes + chunkSize - 1) / chunkSize,
            header.digest.count == 32, header.revision < UInt64.max else { return }
          if epoch == header.stateID, header.revision <= revision, pending.isEmpty,
            !model.isWaitingForSharedState {
            Task { await transmit(.receipt(header.id, -2), to: participant) }
            return
          }
          if let latestSnapshotHeader, latestSnapshotHeader.stateID == header.stateID,
             latestSnapshotHeader.revision > header.revision ||
               (decodingTransferID != nil && latestSnapshotHeader.revision == header.revision) {
            Task { await transmit(.receipt(header.id, -2), to: participant) }
            return
          }
          incoming = (header, [:], 0)
          decodingTransferID = nil
          lastTransferActivity = Date()
          latestTransferID = header.id
          latestSnapshotHeader = header
          info("Receiving edit state revision \(header.revision): \(header.bytes) bytes, \(header.chunks) chunk(s).")
          Task { await transmit(.receipt(header.id, -1), to: participant) }
        case .chunk(let id, let index, let bytes):
          guard participant == hostID, var transfer = incoming, transfer.header.id == id,
            index >= 0, index < transfer.header.chunks, !bytes.isEmpty, bytes.count <= chunkSize,
            transfer.chunks[index] == nil, transfer.received + bytes.count <= transfer.header.bytes else { return }
          transfer.chunks[index] = bytes; transfer.received += bytes.count
          lastTransferActivity = Date()
          incoming = transfer
          Task { await transmit(.receipt(id, index), to: participant) }
          if transfer.chunks.count == transfer.header.chunks {
            incoming = nil
            decodingTransferID = transfer.header.id
            let generation = self.generation
            let datasetID = self.datasetID
            Task { [weak self] in
              do {
                let snapshot = try await Task.detached(priority: .utility) {
                  var joined = Data(); joined.reserveCapacity(transfer.header.bytes)
                  for i in 0..<transfer.header.chunks { joined.append(transfer.chunks[i]!) }
                  guard joined.count == transfer.header.bytes else { throw BorgVRVolumeEditError.corruptJournal }
                  if transfer.header.decodedBytes != joined.count {
                    var output = [UInt8](repeating: 0, count: transfer.header.decodedBytes)
                    let count = output.withUnsafeMutableBufferPointer { destination in
                      joined.withUnsafeBytes { input in
                        compression_decode_buffer(destination.baseAddress!, destination.count,
                          input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZ4)
                      }
                    }
                    guard count == output.count else { throw BorgVRVolumeEditError.corruptJournal }
                    joined = Data(output)
                  }
                  guard Data(SHA256.hash(data: joined)) == transfer.header.digest else {
                    throw BorgVRVolumeEditError.corruptJournal
                  }
                  let snapshot = try PropertyListDecoder().decode(BorgVRVolumeEditSnapshot.self, from: joined)
                  guard snapshot.stateID == transfer.header.stateID, snapshot.revision == transfer.header.revision,
                    snapshot.datasetID == datasetID else { throw BorgVRVolumeEditError.incompatibleDataset }
                  return snapshot
                }.value
                guard let self, self.generation == generation, self.latestTransferID == transfer.header.id else { return }
                self.decodingTransferID = nil
                self.pendingSnapshot = snapshot
                self.info("Edit-state checksum and dataset validated, revision \(snapshot.revision).")
                self.datasetReady()
              } catch {
                guard let self, self.generation == generation else { return }
                if self.decodingTransferID == transfer.header.id { self.decodingTransferID = nil }
                self.model.reportError(error)
                self.log("Invalid edit snapshot: \(error.localizedDescription)")
              }
            }
          }
        case .receipt(let id, let index):
          let key = VolumeEditReceiptKey(transfer: id, index: index == -2 ? -1 : index)
          guard isHost, receipts[key]?.participant == participant else { return }
          finishReceipt(key, result: .success(index == -2))
        case .proposal(let proposal):
          guard isHost, proposal.stateID == epoch, !proposal.samples.isEmpty, proposal.samples.count <= 128 else { return }
          for sample in proposal.samples { try sample.validate() }
          guard proposals.count < 4096 else { throw BorgVRVolumeEditError.invalidBufferSize }
          proposals.append((participant, proposal)); process()
        case .commit(let stateID, let batch):
          guard participant == hostID, !isHost, batch.revision > revision, batch.revision < UInt64.max else { return }
          if let epoch, epoch != stateID { self.epoch = nil; commits.removeAll(); requested = false; datasetReady(); return }
          guard !batch.samples.isEmpty, batch.samples.count <= 128 else { throw BorgVRVolumeEditError.invalidBrush }
          for sample in batch.samples { try sample.validate() }
          guard commits.count < 4096 || commits[batch.revision] != nil else {
            commits.removeAll(); requested = true
            Task { [weak self] in await self?.transmit(.request, to: self?.hostID) }
            return
          }
          commits[batch.revision] = batch
          process()
        case .cursors(let stateID, let cursors):
          guard stateID == epoch, cursors.count <= 8 else { return }
          guard cursors.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite &&
            $0.radius.isFinite && $0.radius > 0 && $0.radius <= 1 }) else { return }
          model.context.setRemoteCursors(cursors, from: participant)
        case .rejected(let stateID, let operationID):
          guard participant == hostID, !isHost, stateID == epoch else { return }
          completePending(operationID, error: BorgVRVolumeEditError.invalidRevision)
          model.cancelSharedPredictions()
          for id in pendingOrder {
            guard let item = pending[id] else { continue }
            model.predictSharedBrush(id: id, mode: item.proposal.mode, samples: item.proposal.samples)
          }
        case .status(let stateID, let hostRevision):
          guard !isHost, participant == hostID, !installing, decodingTransferID == nil, pendingSnapshot == nil,
            epoch != stateID || revision < hostRevision || model.isWaitingForSharedState else { return }
          if incoming != nil, Date().timeIntervalSince(lastTransferActivity) < 10 { return }
          guard Date().timeIntervalSince(lastRequest) >= 1 else { return }
          incoming = nil; lastRequest = Date(); requested = true
          info("Requesting edit-state recovery; local revision \(revision), host revision \(hostRevision).")
          Task { [weak self] in await self?.transmit(.request, to: self?.hostID) }
      }
    } catch { log("Rejected edit synchronization message: \(error.localizedDescription)") }
  }

  private func install(_ snapshot: BorgVRVolumeEditSnapshot) {
    guard !installing else { return }
    installing = true
    let generation = self.generation
    Task { [weak self] in
      guard let self else { return }
      do {
        await processing?.value
        guard self.generation == generation else { return }
        if epoch == snapshot.stateID, revision > snapshot.revision {
          pendingSnapshot = nil; installing = false; return
        }
        info("Installing shared edit state revision \(snapshot.revision).")
        try await model.installSessionSnapshot(snapshot)
        guard self.generation == generation else { return }
        epoch = snapshot.stateID; revision = snapshot.revision
        if pendingSnapshot?.stateID == snapshot.stateID, (pendingSnapshot?.revision ?? 0) <= snapshot.revision { pendingSnapshot = nil }
        requested = false
        commits = commits.filter { $0.key > self.revision }
        for id in snapshot.operationIDs {
          completePending(id, error: nil)
        }
        installing = false
        info("Shared edit state ready, revision \(revision).")
        for id in pendingOrder {
          guard let item = pending[id] else { continue }
          model.predictSharedBrush(id: id, mode: item.proposal.mode, samples: item.proposal.samples)
          await transmit(.proposal(item.proposal), to: hostID)
        }
        if pendingSnapshot != nil { datasetReady() }
        process()
      } catch {
        guard self.generation == generation else { return }
        installing = false
        if pendingSnapshot?.stateID == snapshot.stateID,
           pendingSnapshot?.revision == snapshot.revision { pendingSnapshot = nil }
        requested = false
        model.reportError(error)
        log("Could not install shared edit state: \(error.localizedDescription)")
      }
    }
  }

  private func submit(mode: BorgVRVolumeBrushMode, samples: [BorgVRVolumeBrushSample],
                      cancellationToken: BorgVRVolumeConversionCancellationToken? = nil,
                      completion: @escaping @Sendable (Error?) -> Void) async {
    do {
      try cancellationToken?.checkCancellation()
      if isHost { try await ensureHostState() }
      guard let epoch, let localID, !installing else { throw BorgVRVolumeEditingCommandError.busy }
      guard pending.count < 4096 else { throw BorgVRVolumeEditingCommandError.busy }
      for start in stride(from: 0, to: samples.count, by: 128) {
        try cancellationToken?.checkCancellation()
        let proposal = VolumeEditProposal(stateID: epoch, id: UUID(), mode: mode,
          samples: Array(samples[start..<min(samples.count, start + 128)]))
        model.predictSharedBrush(id: proposal.id, mode: mode, samples: proposal.samples)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          pending[proposal.id] = (proposal, { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          })
          pendingOrder.append(proposal.id)
          if isHost { proposals.append((localID, proposal)); process() }
          else {
            Task { [weak self] in
              guard let self else { return }
              do { try await send(encode(.proposal(proposal)), hostID) }
              catch { completePending(proposal.id, error: error); model.cancelSharedPredictions() }
            }
          }
        }
      }
      completion(nil)
    } catch { completion(error) }
  }

  private func process() {
    guard processing == nil, !installing, epoch != nil else { return }
    let generation = self.generation
    processing = Task { [weak self] in
      guard let self else { return }
      defer { if self.generation == generation { processing = nil } }
      do {
        while self.generation == generation, !Task.isCancelled, !installing {
          if isHost {
            guard !proposals.isEmpty, let epoch else { break }
            let (participant, proposal) = proposals.removeFirst()
            do {
              let snapshot = try await model.stateSnapshot()
              if snapshot.operationIDs.contains(proposal.id) {
                if participant == localID { completePending(proposal.id, error: nil) }
                else { await sendSnapshot(to: participant) }
                continue
              }
              guard snapshot.revision < UInt64.max - 1 else { throw BorgVRVolumeEditError.invalidRevision }
              let batch = BorgVRVolumeBrushBatch(id: proposal.id, revision: snapshot.revision + 1, mode: proposal.mode, samples: proposal.samples)
              try await model.applyConfirmed(batch)
              guard self.generation == generation else { break }
              revision = batch.revision
              // A committed operation stays committed even if its announcement fails.
              do { try await send(encode(.commit(epoch, batch)), nil) }
              catch { log("Edit committed locally; peers need a snapshot: \(error.localizedDescription)") }
              completePending(proposal.id, error: nil)
            } catch {
              guard self.generation == generation else { break }
              log("Could not apply proposed volume edit: \(error.localizedDescription)")
              completePending(proposal.id, error: error)
              model.cancelSharedPredictions()
              if participant != localID { await transmit(.rejected(epoch, proposal.id), to: participant) }
            }
          } else {
            guard let batch = commits.removeValue(forKey: revision + 1) else {
              if !commits.isEmpty, !requested { requested = true; await transmit(.request, to: hostID) }
              break
            }
            try await model.applyConfirmed(batch)
            guard self.generation == generation else { break }
            revision = batch.revision
            completePending(batch.id, error: nil)
          }
        }
      } catch {
        log("Edit synchronization requires recovery: \(error.localizedDescription)")
        requested = true
        if !isHost { await transmit(.request, to: hostID) }
      }
    }
  }

  private func startCursors() {
    cursorTask = Task { [weak self] in
      var previous: [BorgVRVolumeBrushCursor] = []
      var lastSent = ContinuousClock.now
      var lastStatus = ContinuousClock.now
      while !Task.isCancelled {
        guard let self else { return }
        if let epoch, hostID != nil {
          if isHost, lastStatus.duration(to: .now) > .seconds(1) {
            await transmit(.status(epoch, revision), to: nil)
            lastStatus = .now
          }
          let current = model.context.cursors()
          if current != previous || (!current.isEmpty && lastSent.duration(to: .now) > .milliseconds(200)) {
            await transmit(.cursors(epoch, current), to: nil)
            previous = current; lastSent = .now
          }
        }
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      }
    }
  }

  private func encode(_ packet: VolumeEditPacket) throws -> Data {
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    return try encoder.encode(packet)
  }
  private func completePending(_ id: UUID, error: Error?) {
    pendingOrder.removeAll { $0 == id }
    pending.removeValue(forKey: id)?.completion(error)
  }
  private func transmit(_ packet: VolumeEditPacket, to participant: UUID?) async {
    do { try await send(encode(packet), participant) }
    catch { log("Edit synchronization transport failed: \(error.localizedDescription)") }
  }
}

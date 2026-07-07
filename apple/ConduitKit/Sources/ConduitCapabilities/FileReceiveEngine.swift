import Foundation
import CryptoKit
import ConduitProtocol
import ConduitSession
import ConduitTransport

/// Receiver half of the file capability: offer/accept UX hooks, ordered chunk
/// writing, incremental hashing, resume metadata that survives relaunches,
/// and final SHA-256 verification before the file lands in the destination.
public actor FileReceiveEngine {
    static let ackEvery: UInt64 = 16

    /// Sidecar persisted next to a partial download so an interrupted transfer
    /// can resume: keyed by content (sha256), not offer id, so a fresh offer of
    /// the same file resumes even after both apps restarted.
    struct PartialMeta: Codable {
        var sha256: String
        var size: UInt64
        var chunkSize: UInt32
        var receivedChunks: UInt64
        var accepted: Bool
        var name: String
    }

    struct IncomingTransfer {
        let offer: FileOfferBody
        let fromDeviceID: String
        var link: PeerLink
        var handle: FileHandle?
        var hasher = SHA256()
        var receivedChunks: UInt64 = 0
        var bulkToken: String?
        var bulkReadTask: Task<Void, Never>?
        var accepted = false
        var lane = "control"
        var lastEmitAt = Date()
        var lastEmitBytes: UInt64 = 0
    }

    private var transfers: [String: IncomingTransfer] = [:]
    /// ChunkFrame carries a UUID; offers carry a string. Map between them.
    private var uuidToFileID: [UUID: String] = [:]
    private let receiveDirectory: URL
    private let partialsDirectory: URL
    private let emit: @Sendable (ConduitEvent) -> Void

    public init(receiveDirectory: URL, partialsDirectory: URL, emit: @escaping @Sendable (ConduitEvent) -> Void) {
        self.receiveDirectory = receiveDirectory
        self.partialsDirectory = partialsDirectory
        self.emit = emit
    }

    // MARK: Offers

    public func handleOffer(_ offer: FileOfferBody, from link: PeerLink) async {
        guard let uuid = UUID(uuidString: offer.fileID) else {
            try? await link.send(.fileReject(FileRejectBody(fileID: offer.fileID, reason: "malformed file id")))
            return
        }
        // Replace any stale entry for the same content (re-offer after a blip).
        if let staleID = transfers.first(where: { $0.value.offer.sha256 == offer.sha256 && $0.value.fromDeviceID == link.peer.deviceID })?.key {
            cleanup(fileID: staleID, deletePartial: false)
        }
        transfers[offer.fileID] = IncomingTransfer(offer: offer, fromDeviceID: link.peer.deviceID, link: link)
        uuidToFileID[uuid] = offer.fileID

        // Auto-resume: if this exact content was accepted before and a partial
        // exists, the user already consented — don't prompt again.
        if let meta = loadMeta(sha256: offer.sha256),
           meta.accepted, meta.size == offer.size, meta.chunkSize == offer.chunkSize {
            await accept(fileID: offer.fileID)
        } else {
            emit(.incomingFileOffer(fromDeviceID: link.peer.deviceID, offer: offer))
        }
    }

    public func accept(fileID: String) async {
        guard var transfer = transfers[fileID], !transfer.accepted else { return }
        let offer = transfer.offer
        do {
            try FileManager.default.createDirectory(at: partialsDirectory, withIntermediateDirectories: true)
            let partialURL = partialURL(sha256: offer.sha256)

            var resumeFrom: UInt64 = 0
            if let meta = loadMeta(sha256: offer.sha256),
               meta.size == offer.size, meta.chunkSize == offer.chunkSize,
               FileManager.default.fileExists(atPath: partialURL.path) {
                resumeFrom = meta.receivedChunks
            }

            if !FileManager.default.fileExists(atPath: partialURL.path) {
                FileManager.default.createFile(atPath: partialURL.path, contents: nil)
                resumeFrom = 0
            }

            let handle = try FileHandle(forWritingTo: partialURL)
            let validBytes = resumeFrom * UInt64(offer.chunkSize)
            try handle.truncate(atOffset: validBytes)
            try handle.seek(toOffset: validBytes)

            // Rebuild the incremental hash over what we already have.
            var hasher = SHA256()
            if validBytes > 0 {
                let readHandle = try FileHandle(forReadingFrom: partialURL)
                defer { try? readHandle.close() }
                var remaining = validBytes
                while remaining > 0,
                      let data = try readHandle.read(upToCount: Int(min(remaining, 4 * 1024 * 1024))),
                      !data.isEmpty {
                    hasher.update(data: data)
                    remaining -= UInt64(data.count)
                }
            }

            let token = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).hexString
            transfer.handle = handle
            transfer.hasher = hasher
            transfer.receivedChunks = resumeFrom
            transfer.bulkToken = token
            transfer.accepted = true
            transfers[fileID] = transfer
            saveMeta(PartialMeta(
                sha256: offer.sha256, size: offer.size, chunkSize: offer.chunkSize,
                receivedChunks: resumeFrom, accepted: true, name: offer.name
            ))
            try await transfer.link.send(.fileAccept(FileAcceptBody(
                fileID: fileID, resumeFromChunk: resumeFrom, bulkToken: token
            )))
        } catch {
            cleanup(fileID: fileID, deletePartial: false)
            emit(.transferFailed(fileID: fileID, reason: "accept failed: \(error)"))
        }
    }

    public func reject(fileID: String, reason: String = "declined") async {
        guard let transfer = transfers[fileID] else { return }
        try? await transfer.link.send(.fileReject(FileRejectBody(fileID: fileID, reason: reason)))
        cleanup(fileID: fileID, deletePartial: false)
    }

    // MARK: Bulk lane

    /// Binds an inbound bulk connection to an accepted transfer, then drains
    /// its chunk frames. Returns false (caller closes) on a bad token.
    public func attachBulk(_ framed: FramedConnection, fileID: String, token: String) -> Bool {
        guard var transfer = transfers[fileID], transfer.accepted,
              let expected = transfer.bulkToken, expected == token else {
            return false
        }
        transfer.lane = "bulk"
        let task = Task {
            do {
                while let frame = try await framed.nextFrame() {
                    if case .fileChunk(let chunk) = frame {
                        await self.handleChunk(chunk)
                    }
                }
            } catch {
                // Bulk lane died; sender will re-offer or fall back.
            }
            framed.closeUnderlying()
        }
        transfer.bulkReadTask = task
        transfers[fileID] = transfer
        return true
    }

    // MARK: Chunks

    public func handleChunk(_ chunk: ChunkFrame) async {
        guard let fileID = uuidToFileID[chunk.fileID],
              var transfer = transfers[fileID],
              transfer.accepted,
              let handle = transfer.handle
        else { return }
        let offer = transfer.offer

        if chunk.seq < transfer.receivedChunks {
            return // duplicate after resume; already have it
        }
        guard chunk.seq == transfer.receivedChunks else {
            await fail(fileID: fileID, reason: "out-of-order chunk \(chunk.seq), expected \(transfer.receivedChunks)")
            return
        }

        do {
            try handle.write(contentsOf: chunk.data)
        } catch {
            await fail(fileID: fileID, reason: "write failed: \(error)")
            return
        }
        transfer.hasher.update(data: chunk.data)
        transfer.receivedChunks += 1
        transfers[fileID] = transfer

        let isFinal = chunk.isLast || transfer.receivedChunks == offer.chunkCount
        if transfer.receivedChunks % Self.ackEvery == 0 || isFinal {
            saveMeta(PartialMeta(
                sha256: offer.sha256, size: offer.size, chunkSize: offer.chunkSize,
                receivedChunks: transfer.receivedChunks, accepted: true, name: offer.name
            ))
            if !isFinal {
                try? await transfer.link.send(.fileAck(FileAckBody(
                    fileID: fileID, status: .progress, ackedThrough: transfer.receivedChunks
                )))
            }
        }
        maybeEmitProgress(fileID: fileID)

        if isFinal {
            await finalize(fileID: fileID)
        }
    }

    private func finalize(fileID: String) async {
        guard var transfer = transfers[fileID] else { return }
        let offer = transfer.offer
        try? transfer.handle?.close()
        transfer.handle = nil
        transfers[fileID] = transfer

        let digest = Data(transfer.hasher.finalize()).hexString
        guard digest == offer.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: partialURL(sha256: offer.sha256))
            deleteMeta(sha256: offer.sha256)
            try? await transfer.link.send(.fileAck(FileAckBody(
                fileID: fileID, status: .hashMismatch, ackedThrough: transfer.receivedChunks,
                message: "sha256 mismatch"
            )))
            cleanup(fileID: fileID, deletePartial: false)
            emit(.transferFailed(fileID: fileID, reason: "hash mismatch"))
            return
        }

        do {
            try FileManager.default.createDirectory(at: receiveDirectory, withIntermediateDirectories: true)
            let destination = uniqueDestination(for: offer.name)
            try FileManager.default.moveItem(at: partialURL(sha256: offer.sha256), to: destination)
            deleteMeta(sha256: offer.sha256)
            try? await transfer.link.send(.fileAck(FileAckBody(
                fileID: fileID, status: .complete, ackedThrough: transfer.receivedChunks
            )))
            cleanup(fileID: fileID, deletePartial: false)
            emit(.transferCompleted(fileID: fileID, savedTo: destination))
        } catch {
            try? await transfer.link.send(.fileAck(FileAckBody(
                fileID: fileID, status: .error, ackedThrough: transfer.receivedChunks,
                message: "\(error)"
            )))
            cleanup(fileID: fileID, deletePartial: false)
            emit(.transferFailed(fileID: fileID, reason: "finalize failed: \(error)"))
        }
    }

    private func fail(fileID: String, reason: String) async {
        guard let transfer = transfers[fileID] else { return }
        try? await transfer.link.send(.fileAck(FileAckBody(
            fileID: fileID, status: .error, ackedThrough: transfer.receivedChunks, message: reason
        )))
        cleanup(fileID: fileID, deletePartial: false)
        emit(.transferFailed(fileID: fileID, reason: reason))
    }

    private func cleanup(fileID: String, deletePartial: Bool) {
        guard let transfer = transfers.removeValue(forKey: fileID) else { return }
        try? transfer.handle?.close()
        transfer.bulkReadTask?.cancel()
        if let uuid = UUID(uuidString: fileID) {
            uuidToFileID.removeValue(forKey: uuid)
        }
        if deletePartial {
            try? FileManager.default.removeItem(at: partialURL(sha256: transfer.offer.sha256))
            deleteMeta(sha256: transfer.offer.sha256)
        }
    }

    private func maybeEmitProgress(fileID: String) {
        guard var transfer = transfers[fileID] else { return }
        let offer = transfer.offer
        let bytes = min(transfer.receivedChunks * UInt64(offer.chunkSize), offer.size)
        let now = Date()
        let elapsed = now.timeIntervalSince(transfer.lastEmitAt)
        let isFinal = transfer.receivedChunks == offer.chunkCount
        guard isFinal || elapsed >= 0.25 else { return }
        let rate = elapsed > 0 ? Double(bytes - transfer.lastEmitBytes) / elapsed : 0
        transfer.lastEmitAt = now
        transfer.lastEmitBytes = bytes
        transfers[fileID] = transfer
        emit(.transferUpdated(TransferSnapshot(
            fileID: fileID,
            peerDeviceID: transfer.fromDeviceID,
            name: offer.name,
            direction: .receive,
            totalBytes: offer.size,
            transferredBytes: bytes,
            bytesPerSecond: rate,
            lane: transfer.lane
        )))
    }

    // MARK: Partial-file bookkeeping

    private func partialURL(sha256: String) -> URL {
        partialsDirectory.appendingPathComponent("\(sha256).part")
    }

    private func metaURL(sha256: String) -> URL {
        partialsDirectory.appendingPathComponent("\(sha256).json")
    }

    private func loadMeta(sha256: String) -> PartialMeta? {
        guard let data = try? Data(contentsOf: metaURL(sha256: sha256)) else { return nil }
        return try? JSONDecoder().decode(PartialMeta.self, from: data)
    }

    private func saveMeta(_ meta: PartialMeta) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL(sha256: meta.sha256), options: [.atomic])
    }

    private func deleteMeta(sha256: String) {
        try? FileManager.default.removeItem(at: metaURL(sha256: sha256))
    }

    private func uniqueDestination(for name: String) -> URL {
        let base = receiveDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        for index in 2...9999 {
            let candidate = receiveDirectory.appendingPathComponent(
                ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            )
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return receiveDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
    }
}

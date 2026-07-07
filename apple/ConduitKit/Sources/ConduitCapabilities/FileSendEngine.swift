import Foundation
import CryptoKit
import UniformTypeIdentifiers
import ConduitProtocol
import ConduitSession
import ConduitTransport

/// Sender half of the file capability (spec §9 Phase 1 step 7): chunked
/// transfer with hash verification and resume-from-last-acked-chunk.
/// Chunks prefer a dedicated bulk connection so control messages never sit
/// behind file data (head-of-line pitfall, spec §9 Phase 1).
public actor FileSendEngine {
    /// In-flight chunk budget before the pump waits for acks (16 MiB at 512 KiB).
    static let windowChunks: UInt64 = 32
    static let ackEmitEvery: UInt64 = 16

    struct OutgoingTransfer {
        let offer: FileOfferBody
        let url: URL
        let peerDeviceID: String
        var link: PeerLink
        var bulk: FramedConnection?
        var ackedThrough: UInt64 = 0
        var nextToSend: UInt64 = 0
        var windowWaiter: CheckedContinuation<Void, Never>?
        var pumpTask: Task<Void, Never>?
        var lane = "control"
        var lastEmitAt = Date()
        var lastEmitBytes: UInt64 = 0
        /// True when the transfer died on a connection error and can be
        /// re-offered automatically once the session comes back.
        var awaitingRetry = false
    }

    private var transfers: [String: OutgoingTransfer] = [:]
    private let emit: @Sendable (ConduitEvent) -> Void
    /// Opens a pinned TLS connection to the peer's listener for the bulk lane.
    private let bulkOpener: @Sendable (PinnedPeer, UInt16) async throws -> FramedConnection

    public init(
        emit: @escaping @Sendable (ConduitEvent) -> Void,
        bulkOpener: @escaping @Sendable (PinnedPeer, UInt16) async throws -> FramedConnection
    ) {
        self.emit = emit
        self.bulkOpener = bulkOpener
    }

    // MARK: Offer

    /// Hashes the file, sends FILE_OFFER, and waits for the receiver's decision
    /// (which arrives via handleMessage).
    @discardableResult
    public func offerFile(url: URL, to link: PeerLink) async throws -> String {
        let (sha256, size) = try Self.sha256AndSize(of: url)
        let chunkSize = ProtocolConstants.defaultChunkSize
        let chunkCount = size == 0 ? 1 : (size + UInt64(chunkSize) - 1) / UInt64(chunkSize)
        let offer = FileOfferBody(
            fileID: UUID().uuidString,
            name: url.lastPathComponent,
            size: size,
            mime: Self.mimeType(for: url),
            sha256: sha256,
            chunkSize: chunkSize,
            chunkCount: chunkCount
        )
        transfers[offer.fileID] = OutgoingTransfer(
            offer: offer, url: url, peerDeviceID: link.peer.deviceID, link: link
        )
        try await link.send(.fileOffer(offer))
        emit(.transferUpdated(snapshot(for: offer.fileID)!))
        return offer.fileID
    }

    /// Re-offers transfers that died with the connection (called on reconnect).
    public func retryPending(peerDeviceID: String, over link: PeerLink) async {
        for (fileID, transfer) in transfers where transfer.peerDeviceID == peerDeviceID && transfer.awaitingRetry {
            transfers[fileID]?.awaitingRetry = false
            transfers[fileID]?.link = link
            try? await link.send(.fileOffer(transfer.offer))
        }
    }

    // MARK: Inbound control messages

    public func handleMessage(_ message: Message) async {
        switch message {
        case .fileAccept(let body):
            startPump(fileID: body.fileID, resumeFrom: body.resumeFromChunk, bulkToken: body.bulkToken)
        case .fileReject(let body):
            removeTransfer(body.fileID)
            emit(.transferFailed(fileID: body.fileID, reason: "declined: \(body.reason)"))
        case .fileAck(let body):
            await handleAck(body)
        default:
            break
        }
    }

    private func handleAck(_ ack: FileAckBody) async {
        guard var transfer = transfers[ack.fileID] else { return }
        switch ack.status {
        case .progress:
            transfer.ackedThrough = max(transfer.ackedThrough, ack.ackedThrough)
            let waiter = transfer.windowWaiter
            transfer.windowWaiter = nil
            transfers[ack.fileID] = transfer
            waiter?.resume()
        case .complete:
            removeTransfer(ack.fileID)
            emit(.transferCompleted(fileID: ack.fileID, savedTo: nil))
        case .hashMismatch, .error:
            removeTransfer(ack.fileID)
            emit(.transferFailed(fileID: ack.fileID, reason: ack.message ?? ack.status.rawValue))
        }
    }

    /// Removes a transfer, releasing anything that could otherwise leak:
    /// a parked window waiter, the pump task, the bulk connection.
    private func removeTransfer(_ fileID: String) {
        guard var transfer = transfers.removeValue(forKey: fileID) else { return }
        let waiter = transfer.windowWaiter
        transfer.windowWaiter = nil
        waiter?.resume()
        transfer.pumpTask?.cancel()
        transfer.bulk?.closeUnderlying()
    }

    // MARK: Pump

    private func startPump(fileID: String, resumeFrom: UInt64, bulkToken: String) {
        guard transfers[fileID] != nil else { return }
        // A re-accept after a connection blip supersedes any previous pump.
        transfers[fileID]?.pumpTask?.cancel()
        transfers[fileID]?.windowWaiter?.resume()
        transfers[fileID]?.windowWaiter = nil
        transfers[fileID]?.bulk?.closeUnderlying()
        transfers[fileID]?.bulk = nil
        transfers[fileID]?.lane = "control"
        transfers[fileID]?.ackedThrough = resumeFrom
        transfers[fileID]?.nextToSend = resumeFrom
        let task = Task { await self.pump(fileID: fileID, resumeFrom: resumeFrom, bulkToken: bulkToken) }
        transfers[fileID]?.pumpTask = task
    }

    private func pump(fileID: String, resumeFrom: UInt64, bulkToken: String) async {
        guard let transfer = transfers[fileID] else { return }
        let offer = transfer.offer
        let link = transfer.link

        // Try to open the bulk lane (candidate-chain reverse dial); fall back to
        // the control connection.
        var bulk: FramedConnection?
        if let port = await link.remoteHello?.listenPort {
            bulk = try? await bulkOpener(link.peer, port)
        }
        if let bulk {
            do {
                await bulk.adoptSessionID(UUID().uuidString)
                try await bulk.send(.bulkAttach(BulkAttachBody(fileID: fileID, bulkToken: bulkToken)))
                transfers[fileID]?.bulk = bulk
                transfers[fileID]?.lane = "bulk"
            } catch {
                bulk.closeUnderlying()
                transfers[fileID]?.bulk = nil
            }
        }

        guard let uuid = UUID(uuidString: offer.fileID) else {
            emit(.transferFailed(fileID: fileID, reason: "bad file id"))
            return
        }

        do {
            let handle = try FileHandle(forReadingFrom: transfer.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: resumeFrom * UInt64(offer.chunkSize))

            var seq = resumeFrom
            while seq < offer.chunkCount {
                try Task.checkCancellation()
                // Window: never more than windowChunks unacked.
                while let current = transfers[fileID], current.nextToSend - current.ackedThrough >= Self.windowChunks {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if transfers[fileID] != nil {
                            transfers[fileID]?.windowWaiter = cont
                        } else {
                            cont.resume()
                        }
                    }
                    try Task.checkCancellation()
                }

                let data = try handle.read(upToCount: Int(offer.chunkSize)) ?? Data()
                let isLast = seq == offer.chunkCount - 1
                let chunk = ChunkFrame(fileID: uuid, seq: seq, isLast: isLast, data: data)
                if let bulkLane = transfers[fileID]?.bulk {
                    try await bulkLane.sendChunk(chunk)
                } else {
                    try await link.sendChunk(chunk)
                }
                seq += 1
                transfers[fileID]?.nextToSend = seq
                maybeEmitProgress(fileID: fileID, sentChunks: seq)
            }
            // Completion is signaled by the receiver's FILE_ACK complete.
        } catch is CancellationError {
            // superseded or finished; nothing to do
        } catch {
            transfers[fileID]?.awaitingRetry = true
            transfers[fileID]?.bulk?.closeUnderlying()
            transfers[fileID]?.bulk = nil
            transfers[fileID]?.pumpTask = nil
            emit(.nodeLog("transfer \(offer.name) interrupted (\(error)); will resume when the session returns"))
        }
    }

    private func maybeEmitProgress(fileID: String, sentChunks: UInt64) {
        guard var transfer = transfers[fileID] else { return }
        let bytes = min(sentChunks * UInt64(transfer.offer.chunkSize), transfer.offer.size)
        let now = Date()
        let elapsed = now.timeIntervalSince(transfer.lastEmitAt)
        guard sentChunks == transfer.offer.chunkCount || elapsed >= 0.25 else { return }
        let rate = elapsed > 0 ? Double(bytes - transfer.lastEmitBytes) / elapsed : 0
        transfer.lastEmitAt = now
        transfer.lastEmitBytes = bytes
        transfers[fileID] = transfer
        emit(.transferUpdated(TransferSnapshot(
            fileID: fileID,
            peerDeviceID: transfer.peerDeviceID,
            name: transfer.offer.name,
            direction: .send,
            totalBytes: transfer.offer.size,
            transferredBytes: bytes,
            bytesPerSecond: rate,
            lane: transfer.lane
        )))
    }

    private func snapshot(for fileID: String) -> TransferSnapshot? {
        guard let transfer = transfers[fileID] else { return nil }
        return TransferSnapshot(
            fileID: fileID,
            peerDeviceID: transfer.peerDeviceID,
            name: transfer.offer.name,
            direction: .send,
            totalBytes: transfer.offer.size,
            transferredBytes: min(transfer.ackedThrough * UInt64(transfer.offer.chunkSize), transfer.offer.size),
            bytesPerSecond: 0,
            lane: transfer.lane
        )
    }

    // MARK: Helpers

    public static func sha256AndSize(of url: URL) throws -> (String, UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: UInt64 = 0
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
            size += UInt64(data.count)
        }
        return (Data(hasher.finalize()).hexString, size)
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

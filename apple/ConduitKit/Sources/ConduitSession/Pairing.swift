import Foundation
import CryptoKit
import ConduitProtocol
import ConduitTransport

/// Deterministic derivation of the out-of-band verification code and word pair
/// (spec §9 Phase 1 step 4). Both devices compute this from the two Ed25519
/// public keys; a middle-man substituting keys produces mismatched codes.
public enum PairingMath {
    static let context = Data("conduit-pairing-v1".utf8)

    public static func material(pubA: Data, pubB: Data) -> Data {
        let (low, high) = pubA.lexicographicallyPrecedes(pubB) ? (pubA, pubB) : (pubB, pubA)
        return Data(SHA256.hash(data: context + low + high))
    }

    /// Six-digit confirmation code, zero-padded.
    public static func verificationCode(pubA: Data, pubB: Data) -> String {
        let bytes = [UInt8](material(pubA: pubA, pubB: pubB))
        let value = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return String(format: "%06d", value % 1_000_000)
    }

    /// Word-pair fingerprint from bytes 4 and 5 of the material.
    public static func verificationWords(pubA: Data, pubB: Data) -> (String, String) {
        let bytes = [UInt8](material(pubA: pubA, pubB: pubB))
        return (PairingWordlist.words[Int(bytes[4])], PairingWordlist.words[Int(bytes[5])])
    }
}

public enum PairingError: Error, Equatable {
    case invalidBindingSignature
    case identityMismatch
    case tlsKeySubstitution
    case peerRejected(String)
    case unexpectedMessage(String)
    case connectionLost
    case timeout
}

public enum PairingOutcome: Sendable {
    case paired(PinnedPeer)
    case rejectedLocally
    case failed(String)
}

/// What the UI must show during the ceremony.
public struct PairingPromptInfo: Sendable, Equatable {
    public let flowID: UUID
    public let code: String
    public let wordA: String
    public let wordB: String
    public let remoteName: String
    public let remoteDeviceClassRaw: String
}

/// Runs the LAN pairing ceremony over an already-established (accept-any) TLS
/// connection. Trust on first use; user confirms the code on both screens.
public enum PairingFlow {
    /// Builds this device's PAIR_REQUEST/PAIR_RESPONSE body.
    public static func makeLocalBody(bundle: IdentityBundle) throws -> PairBody {
        let identity = try bundle.deviceIdentity()
        let signature = try identity.signTLSBinding(tlsPublicKeyHash: bundle.tlsMaterial.publicKeyHash)
        return PairBody(
            identity: identity.deviceID,
            name: bundle.name,
            deviceClass: bundle.deviceClass,
            pubkey: identity.publicKeyRaw,
            tlsPubkeySHA256: bundle.tlsMaterial.publicKeyHash.hexString,
            bindingSig: signature
        )
    }

    /// Validates a remote pair body against the TLS key the connection actually
    /// presented. Returns the failure, or nil if the body checks out.
    public static func validate(remote: PairBody, connectionTLSKeyHash: Data?) -> PairingError? {
        guard DeviceIdentity.deviceID(publicKeyRaw: remote.pubkey) == remote.identity else {
            return .identityMismatch
        }
        guard let claimedTLSHash = Data(hexString: remote.tlsPubkeySHA256),
              DeviceIdentity.verifyTLSBinding(
                signature: remote.bindingSig,
                tlsPublicKeyHash: claimedTLSHash,
                publicKeyRaw: remote.pubkey
              )
        else {
            return .invalidBindingSignature
        }
        // The key the TLS handshake presented must be the key the signed body claims.
        guard let presented = connectionTLSKeyHash, presented == claimedTLSHash else {
            return .tlsKeySubstitution
        }
        return nil
    }

    public static func pinnedPeer(from remote: PairBody) -> PinnedPeer {
        PinnedPeer(
            deviceID: remote.identity,
            name: remote.name,
            deviceClassRaw: remote.deviceClass.rawValue,
            ed25519PublicKey: remote.pubkey,
            tlsPubkeySHA256: Data(hexString: remote.tlsPubkeySHA256) ?? Data(),
            pairedAt: Date()
        )
    }

    /// Initiator role: we connected to the peer and open the ceremony.
    /// `confirm` shows the code/words to the user and returns their decision.
    public static func initiate(
        framed: FramedConnection,
        localBody: PairBody,
        confirm: @Sendable (PairingPromptInfo) async -> Bool
    ) async -> PairingOutcome {
        do {
            await framed.adoptSessionID(UUID().uuidString.lowercased())
            try await framed.send(.pairRequest(localBody))
            let remote = try await expectPairMessage(framed, wantResponse: true)
            return await completeCeremony(framed: framed, localBody: localBody, remote: remote, confirm: confirm)
        } catch {
            framed.closeUnderlying()
            return .failed("\(error)")
        }
    }

    /// Responder role: the listener routed us a PAIR_REQUEST it already decoded.
    public static func respond(
        framed: FramedConnection,
        request: PairBody,
        requestMeta: EnvelopeMeta,
        localBody: PairBody,
        confirm: @Sendable (PairingPromptInfo) async -> Bool
    ) async -> PairingOutcome {
        do {
            await framed.adoptSessionID(requestMeta.sessionID)
            try await framed.send(.pairResponse(localBody))
            return await completeCeremony(framed: framed, localBody: localBody, remote: request, confirm: confirm)
        } catch {
            framed.closeUnderlying()
            return .failed("\(error)")
        }
    }

    private static func completeCeremony(
        framed: FramedConnection,
        localBody: PairBody,
        remote: PairBody,
        confirm: @Sendable (PairingPromptInfo) async -> Bool
    ) async -> PairingOutcome {
        do {
            if let problem = PairingFlow.validate(remote: remote, connectionTLSKeyHash: framed.peerTLSKeyHash) {
                try? await framed.send(.pairReject(PairRejectBody(reason: "validation failed: \(problem)")))
                framed.closeUnderlying()
                return .failed("\(problem)")
            }
            let words = PairingMath.verificationWords(pubA: localBody.pubkey, pubB: remote.pubkey)
            let prompt = PairingPromptInfo(
                flowID: UUID(),
                code: PairingMath.verificationCode(pubA: localBody.pubkey, pubB: remote.pubkey),
                wordA: words.0,
                wordB: words.1,
                remoteName: remote.name,
                remoteDeviceClassRaw: remote.deviceClass.rawValue
            )
            guard await confirm(prompt) else {
                try? await framed.send(.pairReject(PairRejectBody(reason: "declined")))
                framed.closeUnderlying()
                return .rejectedLocally
            }
            try await framed.send(.pairConfirm)
            try await expectPairConfirm(framed)
            return .paired(PairingFlow.pinnedPeer(from: remote))
        } catch let error as PairingError {
            framed.closeUnderlying()
            if case .peerRejected(let reason) = error {
                return .failed("peer declined: \(reason)")
            }
            return .failed("\(error)")
        } catch {
            framed.closeUnderlying()
            return .failed("\(error)")
        }
    }

    /// How long either side will wait for the next step of the ceremony.
    ///
    /// There was no timeout anywhere in this file until 2026-08-17, while
    /// `PairingError.timeout` sat in the enum unused for exactly this: a peer
    /// that opened TLS, sent PAIR_REQUEST and then went silent left the
    /// responder awaiting a frame forever, holding the connection and — on the
    /// apps — a pairing sheet the user could only escape by force-quitting. The
    /// human still has to read six digits off two screens, so this is generous.
    static let stepTimeout: Duration = .seconds(60)

    /// nextFrame with a deadline. Cancelling a blocked read is not guaranteed to
    /// interrupt it, so callers close the underlying connection on the way out
    /// (both `initiate` and `respond` do) — that is what actually frees it.
    private static func nextFrame(_ framed: FramedConnection) async throws -> Frame? {
        try await withThrowingTaskGroup(of: Frame?.self) { group in
            group.addTask { try await framed.nextFrame() }
            group.addTask {
                try await Task.sleep(for: stepTimeout)
                throw PairingError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw PairingError.timeout
            }
            return first
        }
    }

    private static func expectPairMessage(_ framed: FramedConnection, wantResponse: Bool) async throws -> PairBody {
        while true {
            guard let frame = try await nextFrame(framed) else {
                throw PairingError.connectionLost
            }
            guard case .control(let payload) = frame else { continue }
            let (_, message) = try MessageCodec.decode(payload)
            switch message {
            case .pairResponse(let body) where wantResponse:
                return body
            case .pairReject(let body):
                throw PairingError.peerRejected(body.reason)
            case .unknown:
                continue
            default:
                throw PairingError.unexpectedMessage(message.typeString)
            }
        }
    }

    private static func expectPairConfirm(_ framed: FramedConnection) async throws {
        while true {
            guard let frame = try await nextFrame(framed) else {
                throw PairingError.connectionLost
            }
            guard case .control(let payload) = frame else { continue }
            let (_, message) = try MessageCodec.decode(payload)
            switch message {
            case .pairConfirm:
                return
            case .pairReject(let body):
                throw PairingError.peerRejected(body.reason)
            case .unknown:
                continue
            default:
                throw PairingError.unexpectedMessage(message.typeString)
            }
        }
    }
}

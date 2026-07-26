import Foundation
import Testing
import ConduitProtocol
import ConduitTransport
import ConduitTestSupport
@testable import ConduitSession

/// A connection whose control write blocks until the test releases it, so the
/// order bytes actually reach the wire is decided by the code under test rather
/// than by how loaded the machine is.
///
/// Models the control-lane fallback, where one connection carries 2.5 Mbps of
/// video *and* the input events, and a write in progress is what a later frame
/// would otherwise be handed to the transport ahead of.
private final class GatedConnection: ByteStreamConnection, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, Error>
    let peerTLSKeyHash: Data? = nil
    let backendKind: TransportBackendKind = .lan
    let remoteDescription = "gated"
    var remoteHost: String? { nil }

    /// Set once a control write is in flight. A flag polled with `Task.yield()`
    /// rather than a semaphore: `DispatchSemaphore.wait()` is unavailable from
    /// an async context, and blocking a cooperative thread there is precisely
    /// how you deadlock a test.
    let controlWriteInFlight = Locked(false)
    private let controlRelease = DispatchSemaphore(value: 0)
    private let order = Locked<[FrameKind]>([])
    private let wire = DispatchQueue(label: "test.gated.wire")

    init() { (incoming, _) = AsyncThrowingStream.makeStream(of: Data.self) }

    func send(_ data: Data) async throws {
        let kind = FrameKind(rawValue: data.first ?? 0) ?? .control
        let order = self.order
        let inFlight = controlWriteInFlight
        let release = controlRelease
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wire.async {
                // Screen writes complete immediately, so if the gate were absent
                // a frame would overtake the blocked control write — which is
                // exactly what the ordering assertion detects.
                if kind == .control {
                    inFlight.set(true)
                    release.wait()
                }
                order.withValue { $0.append(kind) }
                continuation.resume()
            }
        }
    }

    func releaseControl() { controlRelease.signal() }
    func close() {}
    func writeOrder() -> [FrameKind] { order.get() }
}

@Suite struct SendPriorityTests {
    /// RC-10, the ordering half: while a control frame is outstanding on a link
    /// that also carries video, no *further* video frame is handed to the
    /// transport ahead of it.
    ///
    /// What this does and does not claim: a frame already inside the transport
    /// cannot be preempted, so an input event still waits out at most one frame
    /// (~10 KB at the fallback bitrate). What it can no longer do is wait out a
    /// queue of them. Getting input off this connection entirely is the
    /// datagram lane's job — which is why `InputControllerEngine` now retries
    /// that dial instead of giving up after one attempt.
    ///
    /// Deliberately free of wall-clock waits. An earlier version slept for a
    /// fixed 20 ms to "get mid-frame" and passed alone while failing under
    /// full-suite load — measuring the scheduler, not the gate.
    @Test(.timeLimit(.minutes(1))) func videoYieldsToInputAlreadyWaiting() async throws {
        let raw = GatedConnection()
        let framed = FramedConnection(raw)

        let input = Task { try? await framed.send(.inputEvent(.click(.left, action: .tap))) }
        while !raw.controlWriteInFlight.get() { await Task.yield() }   // input is in the transport

        let video = Task {
            try? await framed.sendScreenFrame(ScreenFrame(
                sessionID: 1, seq: 0, isKeyframe: true, ptsMillis: 0,
                data: Data(repeating: 0xAB, count: 512)
            ))
        }
        // Wait on the condition itself — the gate incrementing its counter —
        // rather than on a duration. Releasing promptly afterwards keeps the
        // window far inside `screenGateMaxWait`.
        while await framed.screenFramesYielded == 0 { await Task.yield() }
        raw.releaseControl()
        await input.value
        await video.value

        #expect(raw.writeOrder() == [.control, .screenFrame],
                "the video frame overtook an input event that was already waiting")
    }

    /// The gate must never strand video: if a control send never returns — a
    /// black-holed socket, a failure this codebase has already been bitten by —
    /// screen frames go out anyway after `screenGateMaxWait` rather than hanging
    /// behind it forever.
    @Test(.timeLimit(.minutes(1))) func videoIsNotHeldHostageByAWedgedControlSend() async throws {
        final class WedgedConnection: ByteStreamConnection, @unchecked Sendable {
            let incoming: AsyncThrowingStream<Data, Error>
            let peerTLSKeyHash: Data? = nil
            let backendKind: TransportBackendKind = .lan
            let remoteDescription = "wedged"
            var remoteHost: String? { nil }
            let screensSent = Locked(0)
            init() { (incoming, _) = AsyncThrowingStream.makeStream(of: Data.self) }
            func send(_ data: Data) async throws {
                if FrameKind(rawValue: data.first ?? 0) == .screenFrame {
                    screensSent.withValue { $0 += 1 }
                    return
                }
                try await Task.sleep(for: .seconds(60))
            }
            func close() {}
        }

        let raw = WedgedConnection()
        let framed = FramedConnection(raw)
        let stuck = Task { try? await framed.send(.ping(PingBody(nonce: "abc", t: 0))) }
        try await Task.sleep(for: .milliseconds(20))

        let start = ContinuousClock.now
        try await framed.sendScreenFrame(ScreenFrame(
            sessionID: 1, seq: 0, isKeyframe: true, ptsMillis: 0, data: Data([0x01])
        ))
        let elapsed = ContinuousClock.now - start
        stuck.cancel()

        #expect(raw.screensSent.get() == 1, "the frame must go out despite the wedged control send")
        // Deliberately loose. The property under test is liveness — released
        // rather than hung — and the wedged send blocks for 60 s, so anything
        // finishing here proves the valve fired. A tight wall-clock bound would
        // instead be measuring how contended the cooperative thread pool is
        // while the rest of the suite runs, which is not a property of this
        // code: at 250 ms nominal it was observed taking 4.4 s under full-suite
        // load and passing in 0.29 s alone. The configured bound is asserted
        // separately, below, where it is exact.
        #expect(elapsed < .seconds(20), "waited \(elapsed); the safety valve must release the frame")
    }

    /// The valve's *configured* bound, checked exactly — the half the liveness
    /// test above deliberately can't pin down. A regression that quietly raised
    /// this to seconds would make the degraded lane stutter without failing
    /// anything else.
    @Test func theSafetyValveIsShortEnoughToBeInvisible() {
        #expect(FramedConnection.screenGateMaxWait <= .milliseconds(500))
    }
}

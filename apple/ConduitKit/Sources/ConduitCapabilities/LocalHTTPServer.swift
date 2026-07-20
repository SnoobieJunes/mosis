import Foundation
import Network
import ConduitTransport

/// A minimal HTTP/1.1 server serving the HLS playlist + fMP4 segments for the
/// convenience senders. Plaintext HTTP on the LAN is fine here — this carries a
/// screen the user is already casting to a nearby TV, not Conduit's pinned
/// device traffic (which stays on the TLS path). Scoped to the LAN, one stream.
final class LocalHTTPServer: @unchecked Sendable {
    private weak var publisher: HLSPublisher?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "org.mosis.hls.http")

    init(publisher: HLSPublisher) {
        self.publisher = publisher
    }

    /// Starts listening; returns the bound port, or nil on failure.
    func start(port requestedPort: UInt16) -> UInt16? {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let nwPort = requestedPort == 0 ? nil : NWEndpoint.Port(rawValue: requestedPort)
        guard let listener = try? NWListener(using: params, on: nwPort ?? .any) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }

        let ready = DispatchSemaphore(value: 0)
        let boundPort = Locked<UInt16?>(nil)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                boundPort.set(listener.port?.rawValue)
                ready.signal()
            } else if case .failed = state {
                ready.signal()
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        return boundPort.get()
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                conn.cancel(); return
            }
            let path = Self.requestPath(request)
            self.respond(to: path, on: conn)
        }
    }

    private func respond(to path: String, on conn: NWConnection) {
        guard let publisher else { conn.cancel(); return }
        let (body, contentType): (Data?, String)
        switch path {
        case "/stream.m3u8":
            (body, contentType) = (Data(publisher.playlist().utf8), "application/vnd.apple.mpegurl")
        case "/init.mp4":
            (body, contentType) = (publisher.initSegment(), "video/mp4")
        default:
            if path.hasPrefix("/seg"), path.hasSuffix(".m4s"),
               let index = Int(path.dropFirst(4).dropLast(4)) {
                (body, contentType) = (publisher.mediaSegment(index: index), "video/mp4")
            } else {
                (body, contentType) = (nil, "text/plain")
            }
        }

        let response: Data
        if let body {
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: \(contentType)\r\n"
            header += "Content-Length: \(body.count)\r\n"
            header += "Access-Control-Allow-Origin: *\r\n"
            header += "Cache-Control: no-cache\r\n\r\n"
            response = Data(header.utf8) + body
        } else {
            let header = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
            response = Data(header.utf8)
        }
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func requestPath(_ request: String) -> String {
        // "GET /stream.m3u8 HTTP/1.1" → "/stream.m3u8"
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : "/"
    }
}

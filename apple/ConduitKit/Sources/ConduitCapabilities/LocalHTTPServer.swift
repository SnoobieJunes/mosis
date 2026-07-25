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
        case "/", "/index.html", "/watch":
            (body, contentType) = (Data(Self.watchPage.utf8), "text/html; charset=utf-8")
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

    /// The zero-install viewer: any browser on the LAN — a laptop, a tablet, a
    /// smart TV — opens this URL and watches, with nothing to install and no
    /// pairing. It is the 2013 APPture demo ("put in the web address and it
    /// streams") that `plans/06-appture-2013-gap-analysis.md` calls the single
    /// highest-leverage gap, and it is the only cast target that works when the
    /// TV is not an Apple TV or a Chromecast.
    ///
    /// Deliberately dependency-free: Safari, iOS, iPadOS, tvOS and most
    /// smart-TV browsers play HLS from a plain `<video>` element. Chrome and
    /// Firefox on the desktop do not, and rather than vendor a megabyte of
    /// hls.js the page says so plainly and offers the raw stream URL for VLC.
    private static let watchPage = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>MOSIS — shared screen</title>
    <style>
      :root { color-scheme: dark; }
      * { box-sizing: border-box; }
      html, body { margin: 0; height: 100%; background: #000; color: #f2f2f7;
        font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
      body { display: flex; flex-direction: column; }
      video { flex: 1 1 auto; width: 100%; min-height: 0; background: #000; }
      .bar { flex: 0 0 auto; display: flex; gap: 12px; align-items: center;
        padding: 10px 16px; background: #1c1c1e; border-top: 1px solid #2c2c2e; }
      .dot { width: 9px; height: 9px; border-radius: 50%; background: #30d158; flex: 0 0 auto; }
      .name { font-weight: 600; }
      .hint { color: #98989d; font-size: 13px; }
      #fallback { display: none; padding: 24px; max-width: 44rem; margin: auto; text-align: center; }
      #fallback code { background: #1c1c1e; padding: 3px 7px; border-radius: 5px;
        font-size: 13px; user-select: all; word-break: break-all; }
      button { font: inherit; color: inherit; background: #2c2c2e; border: 0;
        border-radius: 8px; padding: 8px 14px; cursor: pointer; }
    </style>
    </head>
    <body>
    <video id="v" controls autoplay playsinline muted></video>
    <div id="fallback">
      <h2>This browser can't play the stream</h2>
      <p>Safari, an iPhone, an iPad, an Apple TV, and most smart-TV browsers play it directly.
         Chrome and Firefox on a desktop don't support HLS without a plugin.</p>
      <p>Open this page in Safari, or paste this into VLC:</p>
      <p><code id="u"></code></p>
    </div>
    <div class="bar">
      <span class="dot"></span>
      <span class="name">MOSIS</span>
      <span class="hint">Live screen over your local network &middot; a few seconds behind</span>
      <span style="flex:1"></span>
      <button onclick="document.getElementById('v').requestFullscreen&&document.getElementById('v').requestFullscreen()">Full screen</button>
    </div>
    <script>
      var v = document.getElementById('v');
      var src = new URL('stream.m3u8', location.href).href;
      document.getElementById('u').textContent = src;
      if (v.canPlayType('application/vnd.apple.mpegurl')) {
        v.src = src;
        // The stream is a live window of segments; if the player falls behind
        // or the source restarts, reload rather than sit on a stalled buffer.
        v.addEventListener('error', function () { setTimeout(function () { v.src = src; }, 1500); });
        v.addEventListener('ended', function () { setTimeout(function () { v.src = src; }, 1500); });
      } else {
        v.style.display = 'none';
        document.getElementById('fallback').style.display = 'block';
      }
    </script>
    </body>
    </html>
    """
}

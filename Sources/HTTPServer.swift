import Foundation
import Network
import CryptoKit

/// Minimal HTTP + WebSocket server on a single port. Returns `index.html` for
/// GET /, upgrades GET /ws to a WebSocket. Serves one viewer at a time.
final class HTTPServer {
    var onViewerConnected: ((WebSocketConnection) -> Void)?
    var onViewerDisconnected: ((WebSocketConnection) -> Void)?

    private let port: UInt16
    private let queue = DispatchQueue(label: "com.simulatorstream.httpserver")
    private var listener: NWListener?
    private var indexHTML: Data?

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        indexHTML = loadIndexHTML()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: print("[HTTP] Listening on http://localhost:\(self.port)")
            case .failed(let err): print("[HTTP] Listener failed: \(err)")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak conn] state in
            if case .failed = state { conn?.cancel() }
        }
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    /// Read until we have a full HTTP request header block (`\r\n\r\n`).
    /// Bounded at 16 KB to fend off malformed clients.
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if error != nil {
                conn.cancel()
                return
            }
            guard let data = data, !data.isEmpty else {
                conn.cancel()
                return
            }
            var buf = buffer
            buf.append(data)
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerEnd = range.upperBound
                let headers = buf.prefix(upTo: headerEnd)
                self.dispatch(conn, headers: Data(headers))
                return
            }
            if buf.count > 16_384 {
                self.respond(conn, status: 431, body: "Request Header Fields Too Large")
                return
            }
            self.readRequest(conn, buffer: buf)
        }
    }

    private func dispatch(_ conn: NWConnection, headers raw: Data) {
        guard let text = String(data: raw, encoding: .utf8) else {
            conn.cancel()
            return
        }
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = parts[0]
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }

        let isWS = (headers["upgrade"]?.lowercased() == "websocket")
            && (headers["connection"]?.lowercased().contains("upgrade") == true)

        if isWS && path.hasPrefix("/ws") {
            guard let key = headers["sec-websocket-key"] else {
                respond(conn, status: 400, body: "Missing Sec-WebSocket-Key")
                return
            }
            upgradeToWebSocket(conn, key: key)
            return
        }

        if method == "GET" && (path == "/" || path == "/index.html") {
            serveIndex(conn)
            return
        }

        respond(conn, status: 404, body: "Not Found")
    }

    // MARK: - WebSocket upgrade

    private func upgradeToWebSocket(_ conn: NWConnection, key: String) {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let hash = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        let accept = Data(hash).base64EncodedString()

        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """

        conn.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] err in
            guard let self = self else { return }
            if let err = err {
                print("[HTTP] handshake send failed: \(err)")
                conn.cancel()
                return
            }
            let ws = WebSocketConnection(connection: conn)
            ws.onClose = { [weak self, weak ws] in
                if let ws = ws { self?.onViewerDisconnected?(ws) }
            }
            self.onViewerConnected?(ws)
            ws.start()
        })
    }

    // MARK: - Static HTML

    private func serveIndex(_ conn: NWConnection) {
        guard let body = indexHTML else {
            respond(conn, status: 500, body: "index.html not loaded")
            return
        }
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Cache-Control: no-cache\r
        Connection: close\r
        \r

        """
        var payload = Data(header.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func respond(_ conn: NWConnection, status: Int, body: String) {
        let reason = HTTPServer.reasonPhrase(status)
        let bodyData = Data(body.utf8)
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """
        var payload = Data(header.utf8)
        payload.append(bodyData)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default:  return "Status"
        }
    }

    /// Locates index.html relative to the binary or working directory.
    private func loadIndexHTML() -> Data? {
        let candidates = [
            "browser/index.html",
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("../../../browser/index.html")
                .standardized.path
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path),
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                print("[HTTP] Loaded index.html from \(path) (\(data.count) bytes)")
                return data
            }
        }
        print("[HTTP] Could not find browser/index.html. Tried: \(candidates)")
        return nil
    }
}

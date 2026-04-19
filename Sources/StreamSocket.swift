import Foundation

/// WebSocket client that carries both the H.264 binary frames (streamer→viewer)
/// and JSON control messages in both directions. Replaces SignalingClient.
final class StreamSocket: NSObject {
    var onViewerJoined: (() -> Void)?
    var onViewerLeft: (() -> Void)?
    var onRequestKeyframe: (() -> Void)?
    var onTouchEvent: ((TouchEvent) -> Void)?
    var onCommand: ((String) -> Void)?

    private let url: URL
    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var sentFrameCount = 0

    init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: .default)
        super.init()
    }

    func connect() {
        print("[Socket] Connecting to \(url.absoluteString)")
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveMessage()
        sendJSON(["type": "register", "role": "streamer"])
    }

    // MARK: - Send

    func sendJSON(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { error in
            if let error = error { print("[Socket] sendJSON error: \(error)") }
        }
    }

    /// Binary frame layout: `[0: key flag][1..8: pts µs big-endian][9..: Annex-B H.264]`.
    /// Keyframes include inline SPS+PPS so a fresh decoder can latch on.
    func sendBinaryFrame(isKey: Bool, ptsMicros: Int64, annexB: Data) {
        var payload = Data(count: 9)
        payload[0] = isKey ? 0x01 : 0x00
        let pts = UInt64(bitPattern: ptsMicros).bigEndian
        withUnsafeBytes(of: pts) { raw in
            for i in 0..<8 { payload[1 + i] = raw[i] }
        }
        payload.append(annexB)
        sentFrameCount += 1
        if sentFrameCount <= 3 || sentFrameCount % 300 == 0 {
            print("[Socket] send frame #\(sentFrameCount) key=\(isKey) bytes=\(payload.count)")
        }
        webSocketTask?.send(.data(payload)) { error in
            if let error = error { print("[Socket] sendBinaryFrame error: \(error)") }
        }
    }

    // MARK: - Receive

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self?.receiveMessage()
            case .failure(let error):
                print("[Socket] receive error: \(error)")
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            print("[Socket] drop non-JSON (\(text.count) chars)")
            return
        }

        switch type {
        case "viewer-joined":
            onViewerJoined?()
        case "viewer-left":
            onViewerLeft?()
        case "request-keyframe":
            onRequestKeyframe?()
        case "down", "move", "up":
            guard let x = json["x"] as? Double, let y = json["y"] as? Double else { return }
            onTouchEvent?(TouchEvent(type: type, x: x, y: y))
        case "home":
            onCommand?("home")
        default:
            print("[Socket] Unknown message type: \(type)")
        }
    }
}

struct TouchEvent: Codable {
    let type: String   // "down", "move", "up"
    let x: Double      // normalized 0..1
    let y: Double      // normalized 0..1
}

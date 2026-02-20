import Foundation

final class SignalingClient: NSObject {
    private var webSocketTask: URLSessionWebSocketTask?
    private let url: URL
    private let session: URLSession

    var onOffer: ((String) -> Void)?
    var onIceCandidate: ((String, Int32, String?) -> Void)?
    var onConnected: (() -> Void)?

    init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: .default)
        super.init()
    }

    func connect() {
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveMessage()

        let registerMsg = #"{"type":"register","role":"streamer"}"#
        send(text: registerMsg)
        print("[Signaling] Connected to \(url)")
        onConnected?()
    }

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
                print("[Signaling] Receive error: \(error)")
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "offer":
            if let sdp = json["sdp"] as? String {
                print("[Signaling] Received offer")
                onOffer?(sdp)
            }
        case "ice-candidate":
            if let candidate = json["candidate"] as? String,
               !candidate.isEmpty,
               let sdpMLineIndex = json["sdpMLineIndex"] as? Int32 {
                let sdpMid = json["sdpMid"] as? String
                onIceCandidate?(candidate, sdpMLineIndex, sdpMid)
            }
        default:
            print("[Signaling] Unknown message type: \(type)")
        }
    }

    func sendAnswer(_ sdp: String) {
        let json: [String: Any] = ["type": "answer", "sdp": sdp]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        send(text: text)
        print("[Signaling] Sent answer")
    }

    func sendIceCandidate(_ candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        var json: [String: Any] = [
            "type": "ice-candidate",
            "candidate": candidate,
            "sdpMLineIndex": sdpMLineIndex
        ]
        if let mid = sdpMid {
            json["sdpMid"] = mid
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        send(text: text)
    }

    private func send(text: String) {
        webSocketTask?.send(.string(text)) { error in
            if let error = error {
                print("[Signaling] Send error: \(error)")
            }
        }
    }
}

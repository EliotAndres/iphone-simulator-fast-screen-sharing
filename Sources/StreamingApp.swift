import Foundation

final class StreamingApp {
    private let captureManager = CaptureManager()
    private let streamManager = StreamManager()
    private let touchInjector = TouchInjector()
    private let httpServer: HTTPServer

    /// Single-viewer policy: if a second viewer connects, we close the first.
    private var activeViewer: WebSocketConnection?

    init() {
        let port = ProcessInfo.processInfo.environment["PORT"].flatMap { UInt16($0) } ?? 3738
        httpServer = HTTPServer(port: port)
        print("[App] Port: \(port) (override with PORT env var)")
    }

    func start() {
        wireStreamHandlers()
        wireHTTPHandlers()

        do {
            try httpServer.start()
        } catch {
            print("[App] Failed to start HTTP server: \(error)")
            return
        }

        Task {
            do {
                try await captureManager.start()
                touchInjector.setVideoIsCropped(captureManager.deviceScreenRect != nil)
                captureManager.onFrame = { [weak self] pixelBuffer, timestamp in
                    self?.streamManager.pushFrame(pixelBuffer, timestamp: timestamp)
                }
                touchInjector.resolveSimulator()
            } catch {
                print("[App] Failed to start capture: \(error)")
                print("[App] Hint: Grant Screen Recording permission to Terminal in System Settings → Privacy & Security → Screen Recording")
            }
        }
    }

    // MARK: - Stream → WebSocket

    private func wireStreamHandlers() {
        streamManager.onSendJSON = { [weak self] json in
            guard let viewer = self?.activeViewer else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: json),
                  let text = String(data: data, encoding: .utf8) else { return }
            viewer.sendText(text)
        }
        streamManager.onSendBinaryFrame = { [weak self] isKey, ptsMicros, annexB in
            guard let viewer = self?.activeViewer else { return }
            // [1 byte key flag][8 bytes pts µs BE][Annex-B]
            var payload = Data(count: 9)
            payload[0] = isKey ? 0x01 : 0x00
            let pts = UInt64(bitPattern: ptsMicros).bigEndian
            withUnsafeBytes(of: pts) { raw in
                for i in 0..<8 { payload[1 + i] = raw[i] }
            }
            payload.append(annexB)
            viewer.sendBinary(payload)
        }
    }

    // MARK: - WebSocket → Stream

    private func wireHTTPHandlers() {
        httpServer.onViewerConnected = { [weak self] ws in
            guard let self = self else { return }
            if let old = self.activeViewer {
                print("[App] Replacing old viewer")
                old.close()
            }
            self.activeViewer = ws

            ws.onText = { [weak self] text in
                self?.handleJSON(text)
            }
            ws.onBinary = { data in
                print("[App] Unexpected binary from viewer (\(data.count) bytes)")
            }

            print("[App] Viewer connected")
            self.streamManager.viewerJoined()
            // If the first resolve ran before SpringBoard had a layout, retry when someone actually uses the UI.
            self.touchInjector.resolveSimulator()
            // Push one frame immediately so a static simulator screen doesn't
            // leave the viewer waiting for SCStream to deliver on content change.
            self.captureManager.pushCurrentFrame()
        }

        httpServer.onViewerDisconnected = { [weak self] ws in
            guard let self = self else { return }
            if self.activeViewer === ws {
                print("[App] Viewer disconnected")
                self.activeViewer = nil
                self.streamManager.viewerLeft()
            }
        }
    }

    private func handleJSON(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "request-keyframe":
            streamManager.requestKeyframe()
        case "pause":
            streamManager.pause()
        case "resume":
            streamManager.resume()
        case "down", "move", "up":
            guard let x = json["x"] as? Double, let y = json["y"] as? Double else { return }
            touchInjector.handleTouch(TouchEvent(type: type, x: x, y: y))
        case "home":
            touchInjector.pressHome()
        case "config":
            handleConfig(json)
        default:
            print("[App] Unknown message type: \(type)")
        }
    }

    /// Live quality sliders from the viewer. All fields optional.
    /// fps (1–60), bitrate (bps), maxHeight (output pixels; 0 = uncapped).
    /// fps + maxHeight are bundled into a single `SCStream.updateConfiguration`
    /// call because concurrent reconfigs can leave SCStream not delivering (VM).
    private func handleConfig(_ json: [String: Any]) {
        if let bps = (json["bitrate"] as? NSNumber)?.intValue {
            streamManager.setBitrate(max(100_000, min(20_000_000, bps)))
        }
        var fpsClamped: Int? = nil
        if let fps = (json["fps"] as? NSNumber)?.intValue {
            let c = max(1, min(60, fps))
            fpsClamped = c
            streamManager.setFPS(c)
        }
        var maxHeightClamped: Int? = nil
        if let maxHeight = (json["maxHeight"] as? NSNumber)?.intValue {
            maxHeightClamped = max(0, min(4000, maxHeight))
        }
        if fpsClamped != nil || maxHeightClamped != nil {
            Task { await captureManager.updateConfig(fps: fpsClamped, maxHeight: maxHeightClamped) }
        }
    }
}

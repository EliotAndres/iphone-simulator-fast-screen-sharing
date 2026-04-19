import Foundation

final class StreamingApp {
    private let captureManager = CaptureManager()
    private let streamManager = StreamManager()
    private let socket: StreamSocket
    private let touchInjector = TouchInjector()

    init() {
        let defaultURL = URL(string: "ws://localhost:3000/ws")!
        let url = ProcessInfo.processInfo.environment["SIMULATOR_SIGNALING_URL"]
            .flatMap { URL(string: $0) } ?? defaultURL
        socket = StreamSocket(url: url)
        print("[App] Streaming WebSocket URL: \(url.absoluteString) (override with SIMULATOR_SIGNALING_URL)")
    }

    func start() {
        wireHandlers()
        socket.connect()

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

    private func wireHandlers() {
        streamManager.onSendJSON = { [weak self] json in
            self?.socket.sendJSON(json)
        }
        streamManager.onSendBinaryFrame = { [weak self] isKey, pts, data in
            self?.socket.sendBinaryFrame(isKey: isKey, ptsMicros: pts, annexB: data)
        }

        socket.onViewerJoined = { [weak self] in
            self?.streamManager.viewerJoined()
            // Pump fresh frames in case the simulator content is static — SCStream
            // only delivers on change, so without this a new viewer could hang.
            self?.captureManager.startIdleFramePump()
        }
        socket.onViewerLeft = { [weak self] in
            self?.streamManager.viewerLeft()
        }
        socket.onRequestKeyframe = { [weak self] in
            self?.streamManager.requestKeyframe()
        }
        socket.onTouchEvent = { [weak self] event in
            self?.touchInjector.handleTouch(event)
        }
        socket.onCommand = { [weak self] command in
            switch command {
            case "home":
                self?.touchInjector.pressHome()
            default:
                print("[App] Unknown command: \(command)")
            }
        }
    }
}

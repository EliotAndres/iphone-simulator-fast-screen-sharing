import Foundation
import WebRTC

final class StreamingApp {
    private let captureManager = CaptureManager()
    private let webRTCManager = WebRTCManager()
    private let signalingClient: SignalingClient
    private let touchInjector = TouchInjector()

    init() {
        signalingClient = SignalingClient(url: URL(string: "ws://localhost:3000/ws")!)
    }

    func start() {
        setupSignalingHandlers()
        signalingClient.connect()

        Task {
            do {
                try await captureManager.start()
                captureManager.onFrame = { [weak self] pixelBuffer, timestamp in
                    self?.webRTCManager.pushFrame(pixelBuffer, timestamp: timestamp)
                }
            } catch {
                print("[App] Failed to start capture: \(error)")
                print("[App] Hint: Grant Screen Recording permission to Terminal in System Settings → Privacy & Security → Screen Recording")
            }
        }
    }

    private func setupSignalingHandlers() {
        signalingClient.onOffer = { [weak self] sdp in
            guard let self = self else { return }
            Task {
                do {
                    print("[App] Handling offer, creating answer...")
                    let answerSdp = try await self.webRTCManager.handleOffer(sdp)
                    self.signalingClient.sendAnswer(answerSdp)
                    print("[App] Answer sent")
                } catch {
                    print("[App] Failed to handle offer: \(error)")
                }
            }
        }

        signalingClient.onIceCandidate = { [weak self] candidate, sdpMLineIndex, sdpMid in
            let iceCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
            self?.webRTCManager.addIceCandidate(iceCandidate)
        }

        webRTCManager.onIceCandidate = { [weak self] candidate in
            self?.signalingClient.sendIceCandidate(
                candidate.sdp,
                sdpMLineIndex: candidate.sdpMLineIndex,
                sdpMid: candidate.sdpMid
            )
        }

        webRTCManager.onTouchEvent = { [weak self] event in
            self?.touchInjector.handleTouch(event)
        }

        webRTCManager.onConnectionStateChange = { [weak self] state in
            print("[App] WebRTC connection state changed: \(state.rawValue)")
            if state == .connected {
                self?.captureManager.sendLastFrame()
                self?.touchInjector.resolveSimulator()
            }
        }
    }
}

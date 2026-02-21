import Foundation
import WebRTC

final class WebRTCManager: NSObject {
    var onIceCandidate: ((RTCIceCandidate) -> Void)?
    var onConnectionStateChange: ((RTCPeerConnectionState) -> Void)?
    var onTouchEvent: ((TouchEvent) -> Void)?

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private let videoSource: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private var dataChannel: RTCDataChannel?

    private var frameCount = 0
    private var adaptedToSize = false
    private var statsTimer: Timer?
    private var lastBytesSent: UInt64 = 0
    private var lastStatsTime: CFTimeInterval = 0

    override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        videoSource = factory.videoSource()
        capturer = RTCVideoCapturer(delegate: videoSource)
        super.init()
    }

    func pushFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        frameCount += 1

        if !adaptedToSize {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            videoSource.adaptOutputFormat(toWidth: Int32(w), height: Int32(h), fps: 30)
            print("[WebRTC] Adapted output format to \(w)x\(h)")
            adaptedToSize = true
        }

        if frameCount % 90 == 0 {
            print("[WebRTC] Pushed \(frameCount) frames, pc=\(peerConnection?.connectionState.rawValue ?? -1)")
        }

        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timestamp) * Double(NSEC_PER_SEC))
        let frame = RTCVideoFrame(buffer: rtcPixelBuffer, rotation: ._0, timeStampNs: timeStampNs)
        videoSource.capturer(capturer, didCapture: frame)
    }

    func handleOffer(_ sdpString: String) async throws -> String {
        // Close previous peer connection before creating a new one
        if let old = peerConnection {
            print("[WebRTC] Closing previous peer connection")
            old.close()
            peerConnection = nil
        }

        let config = makeConfiguration()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw WebRTCError.peerConnectionFailed
        }
        self.peerConnection = pc

        let videoTrack = makeVideoTrack()
        let sender = pc.add(videoTrack, streamIds: ["stream0"])
        configureHighBitrate(sender: sender)

        let offerSdp = RTCSessionDescription(type: .offer, sdp: sdpString)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(offerSdp) { error in
                if let error = error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        let answerSdp: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            let answerConstraints = RTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveVideo": "false"],
                optionalConstraints: nil
            )
            pc.answer(for: answerConstraints) { sdp, error in
                if let error = error { continuation.resume(throwing: error) }
                else if let sdp = sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: WebRTCError.noAnswer) }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(answerSdp) { error in
                if let error = error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        // Send answer immediately; ICE candidates are trickled via onIceCandidate
        print("[WebRTC] Answer ready, sending immediately (trickle ICE)")
        return answerSdp.sdp
    }

    func addIceCandidate(_ candidate: RTCIceCandidate) {
        peerConnection?.add(candidate) { error in
            if let error = error {
                print("[WebRTC] Failed to add ICE candidate: \(error)")
            }
        }
    }

    private func makeConfiguration() -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        return config
    }

    private func makeVideoTrack() -> RTCVideoTrack {
        let track = factory.videoTrack(with: videoSource, trackId: "video0")
        return track
    }

    private func startStatsPolling() {
        statsTimer?.invalidate()
        lastBytesSent = 0
        lastStatsTime = CACurrentMediaTime()

        statsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.pollStats()
        }
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func pollStats() {
        guard let pc = peerConnection else { return }
        pc.statistics { [weak self] report in
            guard let self else { return }
            var totalBytes: UInt64 = 0
            for (_, stats) in report.statistics {
                if stats.type == "outbound-rtp",
                   let bytes = stats.values["bytesSent"] as? UInt64 {
                    totalBytes += bytes
                }
            }
            let now = CACurrentMediaTime()
            let elapsed = now - self.lastStatsTime
            if elapsed > 0 && self.lastBytesSent > 0 {
                let deltaBytes = totalBytes - self.lastBytesSent
                let mbps = Double(deltaBytes) / elapsed / 1_000_000
                print(String(format: "[WebRTC] Bandwidth: %.2f MB/s (%.1f Mbps)", mbps, mbps * 8))
            }
            self.lastBytesSent = totalBytes
            self.lastStatsTime = now
        }
    }

    private func configureHighBitrate(sender: RTCRtpSender?) {
        guard let sender = sender else { return }
        let params = sender.parameters
        for encoding in params.encodings {
            encoding.maxBitrateBps = NSNumber(value: 8_000_000)
            encoding.minBitrateBps = NSNumber(value: 2_000_000)
        }
        sender.parameters = params
    }
}

enum WebRTCError: Error {
    case peerConnectionFailed
    case noAnswer
}

extension WebRTCManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("[WebRTC] Signaling state: \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("[WebRTC] ICE connection state: \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("[WebRTC] ICE gathering state: \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("[WebRTC] Data channel opened: \(dataChannel.label)")
        self.dataChannel = dataChannel
        dataChannel.delegate = self
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        print("[WebRTC] Peer connection state: \(newState.rawValue)")
        if newState == .connected {
            DispatchQueue.main.async { self.startStatsPolling() }
        } else if newState == .disconnected || newState == .failed || newState == .closed {
            DispatchQueue.main.async { self.stopStatsPolling() }
        }
        onConnectionStateChange?(newState)
    }
}

// MARK: - Data channel (touch events from browser)

struct TouchEvent: Codable {
    let type: String   // "down", "move", "up"
    let x: Double      // normalized 0..1
    let y: Double      // normalized 0..1
}

extension WebRTCManager: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("[WebRTC] Data channel state: \(dataChannel.readyState.rawValue)")
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let raw = String(data: buffer.data, encoding: .utf8) ?? "<binary>"
        print("[WebRTC] Data channel message: \(raw)")
        guard let event = try? JSONDecoder().decode(TouchEvent.self, from: buffer.data) else {
            print("[WebRTC] Failed to decode touch event from: \(raw)")
            return
        }
        print("[WebRTC] Touch event: \(event.type) (\(event.x), \(event.y))")
        onTouchEvent?(event)
    }
}

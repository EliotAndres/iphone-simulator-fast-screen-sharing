import Foundation
import CoreMedia
import CoreVideo

struct TouchEvent: Codable {
    let type: String   // "down", "move", "up"
    let x: Double      // normalized 0..1
    let y: Double      // normalized 0..1
}

/// Owns the H.264 encoder and the socket-facing side of the video pipeline.
/// Replaces the previous libwebrtc-based WebRTCManager.
final class StreamManager {
    /// Called whenever we want to push a JSON control message (e.g. video-init)
    /// to the viewer. Wired to StreamSocket.sendJSON.
    var onSendJSON: (([String: Any]) -> Void)?
    /// Called for every encoded binary frame. Wired to StreamSocket.sendBinaryFrame.
    var onSendBinaryFrame: ((_ isKey: Bool, _ ptsMicros: Int64, _ annexB: Data) -> Void)?

    private let encoder = H264Encoder()

    /// Codec/dimensions announced by the encoder once SPS is parsed. Cached so
    /// we can re-announce to a new viewer without waiting for the next reconfig.
    private var lastCodec: String?
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0

    /// Only send to the socket while a viewer is attached. We still run the
    /// encoder so the first frame after connect is immediate, but drop bytes
    /// until a viewer is there.
    private var viewerAttached = false
    /// Viewer is still connected but its tab is backgrounded. Encoder keeps
    /// running (simpler than tearing it down) but we don't waste bandwidth.
    private var viewerPaused = false

    /// Skip re-encoding the exact same pixel buffer — SCStream only delivers on
    /// content change, so duplicate pointers come from our own idle re-pushes.
    /// Reset by viewerJoined / requestKeyframe so the next push always goes
    /// through (and yields a keyframe).
    private var lastEncodedBufferPtr: UnsafeMutableRawPointer?
    private var forceNextEncode = true

    private var frameCount = 0

    init() {
        encoder.onConfig = { [weak self] codec, width, height in
            guard let self = self else { return }
            self.lastCodec = codec
            self.lastWidth = width
            self.lastHeight = height
            print("[Stream] Announce codec=\(codec) size=\(width)x\(height)")
            self.sendVideoInit()
        }
        encoder.onFrame = { [weak self] isKey, data, pts in
            guard let self = self, self.viewerAttached, !self.viewerPaused else { return }
            self.frameCount += 1
            if self.frameCount % 90 == 0 {
                print("[Stream] Sent \(self.frameCount) frames, lastKey=\(isKey) bytes=\(data.count)")
            }
            self.onSendBinaryFrame?(isKey, pts, data)
        }
    }

    func pushFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        let ptr = Unmanaged.passUnretained(pixelBuffer).toOpaque()
        if ptr == lastEncodedBufferPtr && !forceNextEncode {
            return
        }
        lastEncodedBufferPtr = ptr
        forceNextEncode = false
        encoder.encode(pixelBuffer, pts: timestamp)
    }

    /// Called when a viewer registers (or re-registers). Re-announces config
    /// and forces the next encoded frame to be a keyframe.
    func viewerJoined() {
        print("[Stream] Viewer joined → request keyframe")
        viewerAttached = true
        forceNextEncode = true
        sendVideoInit()
        encoder.requestKeyframe()
    }

    func viewerLeft() {
        print("[Stream] Viewer left")
        viewerAttached = false
        viewerPaused = false
    }

    /// Browser tab went to background. Keep the WS open but stop sending frames.
    func pause() {
        print("[Stream] Viewer paused")
        viewerPaused = true
    }

    /// Browser tab returned. The viewer dropped its decoder, so we re-announce
    /// the codec config and force the next encoded frame to be a keyframe.
    func resume() {
        print("[Stream] Viewer resumed → fresh video-init + keyframe")
        viewerPaused = false
        forceNextEncode = true
        sendVideoInit()
        encoder.requestKeyframe()
    }

    /// Browser-initiated (tab became visible, decoder reset, etc.).
    func requestKeyframe() {
        print("[Stream] Keyframe requested by viewer")
        forceNextEncode = true
        encoder.requestKeyframe()
    }

    private func sendVideoInit() {
        guard let codec = lastCodec, lastWidth > 0, lastHeight > 0 else { return }
        onSendJSON?([
            "type": "video-init",
            "codec": codec,
            "width": lastWidth,
            "height": lastHeight
        ])
    }
}

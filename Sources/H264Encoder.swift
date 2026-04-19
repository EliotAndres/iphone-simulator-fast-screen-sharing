import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Low-latency H.264 encoder backed by VideoToolbox.
/// Emits Annex-B NAL units; on keyframes SPS+PPS are prepended inline so the
/// browser-side `VideoDecoder` can consume frames without a separate `description`.
final class H264Encoder {
    /// Called for every encoded frame with Annex-B bytes.
    var onFrame: ((_ isKeyframe: Bool, _ data: Data, _ ptsMicros: Int64) -> Void)?
    /// Called once per (re)configuration with codec string + dimensions.
    /// Used to emit `video-init` to the viewer before the first binary frame.
    var onConfig: ((_ codec: String, _ width: Int, _ height: Int) -> Void)?

    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var forceNextKeyframe = false
    private var announcedCodec = false
    private let bitrate: Int
    private let fps: Int

    init(bitrate: Int = 6_000_000, fps: Int = 60) {
        self.bitrate = bitrate
        self.fps = fps
    }

    deinit { invalidate() }

    /// Ask the next `encode()` to emit a keyframe (SPS+PPS+IDR). Used on viewer
    /// (re)connect, tab foregrounding, or any time the decoder state is lost.
    func requestKeyframe() {
        forceNextKeyframe = true
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if session == nil || w != width || h != height {
            configure(width: w, height: h)
        }
        guard let session = session else { return }

        var frameProps: CFDictionary? = nil
        if forceNextKeyframe {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceNextKeyframe = false
        }

        var infoFlags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if status != noErr {
            print("[Encoder] VTCompressionSessionEncodeFrame failed status=\(status)")
        }
    }

    func invalidate() {
        if let s = session {
            VTCompressionSessionInvalidate(s)
            session = nil
        }
    }

    // MARK: - Private

    private func configure(width: Int32, height: Int32) {
        invalidate()
        self.width = width
        self.height = height
        self.announcedCodec = false
        self.forceNextKeyframe = true

        var sess: VTCompressionSession?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // EnableLowLatencyRateControl flips the Apple Silicon hardware encoder into
        // its videoconferencing mode — drops internal buffering by ~1 frame.
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: H264Encoder.outputCallback,
            refcon: selfPtr,
            compressionSessionOut: &sess
        )
        guard status == noErr, let sess = sess else {
            print("[Encoder] VTCompressionSessionCreate failed status=\(status)")
            return
        }

        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2.0))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        // Never hold frames for reorder / lookahead.
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        // Break large frames (esp. keyframes) into MTU-sized slices so the decoder
        // can start on partial data instead of waiting for a full packet reassembly.
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxH264SliceBytes, value: NSNumber(value: 1200))
        VTCompressionSessionPrepareToEncodeFrames(sess)
        self.session = sess
        print("[Encoder] VTCompressionSession \(width)x\(height) @ \(fps)fps, bitrate=\(bitrate)")
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard let refcon = refcon else { return }
        let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        guard status == noErr, let sampleBuffer = sampleBuffer else {
            print("[Encoder] Output callback status=\(status)")
            return
        }
        encoder.handleEncoded(sampleBuffer)
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        let isKey = Self.isKeyframe(sampleBuffer)
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let getStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard getStatus == kCMBlockBufferNoErr, let dataPointer = dataPointer else { return }

        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var annexB = Data()

        if isKey, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // Announce codec (from SPS) + dimensions once per configuration.
            if !announcedCodec {
                if let codec = Self.codecString(from: fmt) {
                    onConfig?(codec, Int(width), Int(height))
                    announcedCodec = true
                }
            }
            // Prepend SPS and PPS before each IDR so a fresh decoder can latch on.
            let paramSets = Self.parameterSets(fmt)
            for ps in paramSets {
                annexB.append(contentsOf: startCode)
                annexB.append(ps)
            }
        }

        // Walk AVCC length-prefixed NAL units, rewrite with Annex-B start codes.
        let base = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= totalLength {
            let nalLen =
                (Int(base[offset]) << 24) |
                (Int(base[offset + 1]) << 16) |
                (Int(base[offset + 2]) << 8) |
                Int(base[offset + 3])
            offset += 4
            guard nalLen > 0, offset + nalLen <= totalLength else { break }
            annexB.append(contentsOf: startCode)
            annexB.append(UnsafeBufferPointer(start: base.advanced(by: offset), count: nalLen))
            offset += nalLen
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsMicros = Int64(CMTimeGetSeconds(pts) * 1_000_000)
        onFrame?(isKey, annexB, ptsMicros)
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    private static func parameterSets(_ fmt: CMFormatDescription) -> [Data] {
        var count: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            let s = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if s == noErr, let ptr = ptr {
                sets.append(Data(bytes: ptr, count: size))
            }
        }
        return sets
    }

    /// Build an `avc1.XXYYZZ` codec string from the SPS (first param set).
    /// SPS byte layout after the 1-byte NAL header: [profile_idc][constraint_flags][level_idc].
    private static func codecString(from fmt: CMFormatDescription) -> String? {
        let sets = parameterSets(fmt)
        guard let sps = sets.first, sps.count >= 4 else { return nil }
        let profile = sps[1]
        let constraint = sps[2]
        let level = sps[3]
        return String(format: "avc1.%02X%02X%02X", profile, constraint, level)
    }
}

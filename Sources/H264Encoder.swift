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
    private var outputErrorCount = 0
    /// After repeated encode callback failures (typical in macOS VMs: HW session creates but never emits frames).
    private var softwareEncoderForced = false
    /// Set from VT output callback; session teardown must run on the `encode` thread to avoid racing `VTCompressionSessionEncodeFrame` (kVTInvalidSessionErr).
    private var fallbackRebuildNeeded = false
    private var bitrate: Int
    private var fps: Int

    /// Prefer software H.264 from the first frame (set env SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER=1 in VMs).
    private static var preferSoftwareEncoderFromStart: Bool {
        let v = ProcessInfo.processInfo.environment["SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER"] ?? ""
        return v == "1" || v.lowercased() == "true" || v.lowercased() == "yes"
    }

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

    /// Live-update bitrate on the running session; also stored for future sessions.
    func setBitrate(_ bps: Int) {
        bitrate = bps
        guard let session = session else { return }
        let s = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bps) as CFNumber)
        if s != noErr {
            print("[Encoder] setBitrate(\(bps)) failed status=\(s) (\(Self.vtStatusLabel(s)))")
        } else {
            print("[Encoder] bitrate → \(bps) bps")
        }
    }

    /// Live-update expected framerate hint; also stored for future sessions.
    func setExpectedFrameRate(_ fps: Int) {
        self.fps = fps
        guard let session = session else { return }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps) as CFNumber)
        print("[Encoder] expected fps → \(fps)")
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if w != width || h != height {
            // Preserve softwareEncoderForced across dim changes — if HW never delivered
            // at one size, it won't suddenly start at another (VM case).
            fallbackRebuildNeeded = false
        }
        if fallbackRebuildNeeded {
            fallbackRebuildNeeded = false
            print("[Encoder] Rebuilding compression session for software encoder (serialize with capture thread)")
            invalidate()
            outputErrorCount = 0
        }
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
            print("[Encoder] VTCompressionSessionEncodeFrame failed status=\(status) (\(Self.vtStatusLabel(status))) infoFlags=\(infoFlags)")
            if status == kVTInvalidSessionErr {
                invalidate()
            }
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
        self.outputErrorCount = 0

        Self.logVideoEncoderList(width: width, height: height)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let lowLatencySpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ]
        let softwarePreferSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanFalse as Any
        ]

        var sess: VTCompressionSession?
        if Self.preferSoftwareEncoderFromStart || softwareEncoderForced {
            let why = softwareEncoderForced ? "runtime SW fallback" : "SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER"
            sess = Self.createSession(width: width, height: height, spec: softwarePreferSpec as CFDictionary, refcon: selfPtr, label: "prefer-SW (\(why))")
            if sess == nil {
                sess = Self.createSession(width: width, height: height, spec: nil, refcon: selfPtr, label: "default after prefer-SW fail")
            }
        } else {
            // Bare metal: low-latency HW first; VM often creates a session then never emits (-12908/-12915) — outputCallback forces softwareEncoderForced.
            sess = Self.createSession(width: width, height: height, spec: lowLatencySpec as CFDictionary, refcon: selfPtr, label: "low-latency HW")
            if sess == nil {
                sess = Self.createSession(width: width, height: height, spec: nil, refcon: selfPtr, label: "default (create fallback)")
            }
        }
        guard let sess = sess else { return }

        func setProp(_ key: CFString, _ value: CFTypeRef, _ label: String) {
            let s = VTSessionSetProperty(sess, key: key, value: value)
            if s != noErr {
                print("[Encoder] VTSessionSetProperty failed \(label) status=\(s) (\(Self.vtStatusLabel(s)))")
            }
        }

        setProp(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime")
        setProp(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel, "ProfileLevel")
        setProp(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering")
        setProp(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate) as CFNumber, "AverageBitRate")
        setProp(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 2) as CFNumber, "MaxKeyFrameInterval")
        setProp(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2.0) as CFNumber, "MaxKeyFrameIntervalDuration")
        setProp(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps) as CFNumber, "ExpectedFrameRate")
        setProp(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0) as CFNumber, "MaxFrameDelayCount")
        setProp(kVTCompressionPropertyKey_MaxH264SliceBytes, NSNumber(value: 1200) as CFNumber, "MaxH264SliceBytes")

        let prep = VTCompressionSessionPrepareToEncodeFrames(sess)
        if prep != noErr {
            print("[Encoder] VTCompressionSessionPrepareToEncodeFrames status=\(prep) (\(Self.vtStatusLabel(prep)))")
        }

        // Use withUnsafeMutablePointer so valueOut is typed as CFTypeRef?, not bridged via a raw Optional<AnyObject> warning.
        var hwProp: CFTypeRef?
        let hwSt = withUnsafeMutablePointer(to: &hwProp) { valueOut in
            VTSessionCopyProperty(
                sess,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault,
                valueOut: valueOut
            )
        }
        if hwSt == noErr, let v = hwProp {
            print("[Encoder] UsingHardwareAcceleratedVideoEncoder (after prepare)=\(v)")
        } else {
            print("[Encoder] UsingHardwareAcceleratedVideoEncoder query status=\(hwSt) (\(Self.vtStatusLabel(hwSt))) value=\(String(describing: hwProp))")
        }

        self.session = sess
        print("[Encoder] VTCompressionSession ready \(width)x\(height) @ \(fps)fps, bitrate=\(bitrate)")
    }

    private static func createSession(
        width: Int32,
        height: Int32,
        spec: CFDictionary?,
        refcon: UnsafeMutableRawPointer,
        label: String
    ) -> VTCompressionSession? {
        var sess: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: H264Encoder.outputCallback,
            refcon: refcon,
            compressionSessionOut: &sess
        )
        if status != noErr || sess == nil {
            print("[Encoder] VTCompressionSessionCreate(\(label)) failed status=\(status) (\(vtStatusLabel(status))) \(width)x\(height)")
            return nil
        }
        print("[Encoder] VTCompressionSessionCreate(\(label)) ok \(width)x\(height)")
        return sess
    }

    private static func logVideoEncoderList(width: Int32, height: Int32) {
        let opts: [CFString: Any] = [
            kVTVideoEncoderList_CodecType: NSNumber(value: kCMVideoCodecType_H264)
        ]
        var list: CFArray?
        let s = VTCopyVideoEncoderList(opts as CFDictionary, &list)
        if s != noErr {
            print("[Encoder] VTCopyVideoEncoderList failed status=\(s) (\(Self.vtStatusLabel(s)))")
            return
        }
        guard let arr = list as? [NSDictionary] else {
            print("[Encoder] VTCopyVideoEncoderList: empty or unexpected format")
            return
        }
        print("[Encoder] VTCopyVideoEncoderList: \(arr.count) encoder(s) for H.264 (want \(width)x\(height))")
        for (i, enc) in arr.prefix(8).enumerated() {
            let id = enc[kVTVideoEncoderList_EncoderID] ?? "?"
            let name = enc[kVTVideoEncoderList_EncoderName] ?? "?"
            let hw = enc[kVTVideoEncoderList_IsHardwareAccelerated] ?? "?"
            print("[Encoder]   [\(i)] id=\(id) name=\(name) hw=\(hw)")
        }
        if arr.count > 8 {
            print("[Encoder]   ... \(arr.count - 8) more")
        }
    }

    private static func vtStatusLabel(_ status: OSStatus) -> String {
        switch status {
        case noErr: return "noErr"
        case kVTCouldNotFindVideoEncoderErr: return "kVTCouldNotFindVideoEncoderErr"
        case kVTVideoEncoderNotAvailableNowErr: return "kVTVideoEncoderNotAvailableNowErr"
        case kVTVideoEncoderMalfunctionErr: return "kVTVideoEncoderMalfunctionErr"
        case kVTInvalidSessionErr: return "kVTInvalidSessionErr"
        case kVTParameterErr: return "kVTParameterErr"
        case kVTPropertyNotSupportedErr: return "kVTPropertyNotSupportedErr"
        default: return "OSStatus(\(status))"
        }
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, infoFlags, sampleBuffer in
        guard let refcon = refcon else { return }
        let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        guard status == noErr, let sampleBuffer = sampleBuffer else {
            encoder.outputErrorCount += 1
            let n = encoder.outputErrorCount
            let label = H264Encoder.vtStatusLabel(status)
            let hasBuf = sampleBuffer != nil
            if n <= 5 || n % 120 == 0 {
                print("[Encoder] Output callback status=\(status) (\(label)) infoFlags=\(infoFlags) sampleBuffer=\(hasBuf) (count=\(n))")
            }
            // HW session on Apple VM often creates OK but never delivers frames; switch to software encoder.
            if !encoder.softwareEncoderForced, !H264Encoder.preferSoftwareEncoderFromStart,
               (status == kVTCouldNotFindVideoEncoderErr || status == kVTVideoEncoderNotAvailableNowErr),
               n >= 3 {
                encoder.softwareEncoderForced = true
                encoder.fallbackRebuildNeeded = true
                print("[Encoder] Switching to software H.264 encoder after \(n) failed output callbacks (rebuild on next encode)")
            }
            return
        }
        encoder.outputErrorCount = 0
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

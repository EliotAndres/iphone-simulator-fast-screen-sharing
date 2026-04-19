import Foundation
import CoreVideo
import CoreImage
import CoreMedia

enum CaptureDebug {
    /// Log dimensions, pixel format, and timestamp (cheap sanity check that SCStream is producing frames).
    static func logPixelBuffer(_ pixelBuffer: CVPixelBuffer, label: String, pts: CMTime) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let fmtStr = fourCC(fmt)
        let sec = CMTimeGetSeconds(pts)
        let ptsStr = sec.isFinite ? String(format: "%.4f", sec) : "invalid"
        print("[Capture] DEBUG \(label): \(w)×\(h) px format=\(fmtStr) (\(fmt)) pts=\(ptsStr)s")
    }

    /// Writes one JPEG (first frame is enough to confirm capture + crop). Requires sRGB-capable buffer path.
    static func saveJPEG(from pixelBuffer: CVPixelBuffer, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CaptureDebugError.noColorSpace
        }
        let options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.88,
        ]
        try context.writeJPEGRepresentation(of: ciImage, to: url, colorSpace: colorSpace, options: options)
    }

    private static func fourCC(_ t: OSType) -> String {
        let chars: [UInt8] = [
            UInt8((t >> 24) & 0xff),
            UInt8((t >> 16) & 0xff),
            UInt8((t >> 8) & 0xff),
            UInt8(t & 0xff),
        ]
        let str = chars.map { (byte: UInt8) -> Character in
            let c = Character(UnicodeScalar(byte))
            return (byte >= 32 && byte < 127) ? c : "?"
        }
        return String(str)
    }
}

enum CaptureDebugError: Error {
    case noColorSpace
}

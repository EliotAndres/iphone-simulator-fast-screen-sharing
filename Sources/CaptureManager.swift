import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

final class CaptureManager: NSObject {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var stream: SCStream?
    private let streamQueue = DispatchQueue(label: "com.simulatorstream.capture")
    private var lastPixelBuffer: CVPixelBuffer?

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("[Capture] Failed to get shareable content. Make sure Screen Recording permission is granted.")
            print("[Capture] Error: \(error)")
            throw error
        }

        let (filter, windowSize) = try makeFilter(from: content)
        let config = makeConfiguration(windowSize: windowSize)

        let captureStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamQueue)
        try await captureStream.startCapture()
        self.stream = captureStream
        print("[Capture] Capture started successfully")
    }

    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
    }

    /// Push the last captured frame once, so a newly connected client gets an
    /// image even if the screen is static.
    func sendLastFrame() {
        streamQueue.async { [weak self] in
            guard let self, let buf = self.lastPixelBuffer else { return }
            self.onFrame?(buf, CMTime(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000))
        }
    }

    private func makeFilter(from content: SCShareableContent) throws -> (SCContentFilter, CGSize?) {
        // Try to find the Simulator window first
        if let window = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator"
        }) {
            print("[Capture] Found Simulator window: \(window.title ?? "untitled") (\(window.frame.width)x\(window.frame.height))")
            let size = CGSize(width: window.frame.width, height: window.frame.height)
            return (SCContentFilter(desktopIndependentWindow: window), size)
        }

        // Fall back to application-level filter
        if let app = content.applications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }), let display = content.displays.first {
            print("[Capture] Found Simulator app, capturing all its windows")
            return (SCContentFilter(display: display, including: [app], exceptingWindows: []), nil)
        }

        // Last resort: capture entire display
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        print("[Capture] Warning: Simulator not found, capturing entire display")
        return (SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), nil)
    }

    private func makeConfiguration(windowSize: CGSize?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        if let size = windowSize {
            let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
            config.width = Int(size.width * scaleFactor)
            config.height = Int(size.height * scaleFactor)
            print("[Capture] Output size: \(config.width)x\(config.height) (scale \(scaleFactor))")
        }

        return config
    }
}

enum CaptureError: Error {
    case noDisplay
}

extension CaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        let timestamp = sampleBuffer.presentationTimeStamp

        if let pixelBuffer = sampleBuffer.imageBuffer {
            lastPixelBuffer = pixelBuffer
            onFrame?(pixelBuffer, timestamp)
        }
    }
}

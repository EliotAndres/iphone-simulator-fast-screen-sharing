import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

final class CaptureManager: NSObject {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var stream: SCStream?
    private let streamQueue = DispatchQueue(label: "com.simulatorstream.capture")

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("[Capture] Failed to get shareable content. Make sure Screen Recording permission is granted.")
            print("[Capture] Error: \(error)")
            throw error
        }

        let filter = try makeFilter(from: content)
        let config = makeConfiguration()

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

    private func makeFilter(from content: SCShareableContent) throws -> SCContentFilter {
        // Try to find the Simulator window first
        if let window = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator"
        }) {
            print("[Capture] Found Simulator window: \(window.title ?? "untitled")")
            return SCContentFilter(desktopIndependentWindow: window)
        }

        // Fall back to application-level filter
        if let app = content.applications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }), let display = content.displays.first {
            print("[Capture] Found Simulator app, capturing all its windows")
            return SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }

        // Last resort: capture entire display
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        print("[Capture] Warning: Simulator not found, capturing entire display")
        return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        return config
    }
}

enum CaptureError: Error {
    case noDisplay
}

extension CaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }
        let timestamp = sampleBuffer.presentationTimeStamp
        onFrame?(pixelBuffer, timestamp)
    }
}

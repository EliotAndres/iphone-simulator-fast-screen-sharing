import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

final class CaptureManager: NSObject {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var streamConfig: SCStreamConfiguration?
    private let streamQueue = DispatchQueue(label: "com.simulatorstream.capture")
    private var lastPixelBuffer: CVPixelBuffer?
    private var idleTimer: DispatchSourceTimer?
    private var hasReceivedRealFrame = false

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("[Capture] Failed to get shareable content. Make sure Screen Recording permission is granted.")
            print("[Capture] Error: \(error)")
            throw error
        }

        let (contentFilter, windowSize) = try makeFilter(from: content)
        let config = makeConfiguration(windowSize: windowSize)
        self.filter = contentFilter
        self.streamConfig = config

        let captureStream = SCStream(filter: contentFilter, configuration: config, delegate: nil)
        try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamQueue)
        try await captureStream.startCapture()
        self.stream = captureStream
        print("[Capture] Capture started successfully")
    }

    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
    }

    /// Repeatedly push a frame (screenshot or cached) every 500ms until
    /// SCStream delivers a real frame. Ensures the newly connected WebRTC
    /// client receives video even when the simulator screen is static.
    func startIdleFramePump() {
        stopIdleFramePump()
        hasReceivedRealFrame = false

        let timer = DispatchSource.makeTimerSource(queue: streamQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, !self.hasReceivedRealFrame else {
                self?.stopIdleFramePump()
                return
            }
            self.pushOneFrame()
        }
        timer.resume()
        idleTimer = timer
    }

    private func stopIdleFramePump() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func pushOneFrame() {
        if let buf = lastPixelBuffer {
            let ts = CMTime(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)
            onFrame?(buf, ts)
            return
        }

        guard let filter, let config = streamConfig else { return }
        Task {
            do {
                let image = try await SCScreenshotManager.captureSampleBuffer(
                    contentFilter: filter,
                    configuration: config
                )
                guard let pixelBuffer = image.imageBuffer else { return }
                self.lastPixelBuffer = pixelBuffer
                let ts = CMTime(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)
                self.onFrame?(pixelBuffer, ts)
                print("[Capture] Sent screenshot as initial frame")
            } catch {
                print("[Capture] Failed to capture screenshot: \(error)")
            }
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
            if !hasReceivedRealFrame {
                hasReceivedRealFrame = true
                stopIdleFramePump()
            }
            onFrame?(pixelBuffer, timestamp)
        }
    }
}

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

final class CaptureManager: NSObject {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var streamConfig: SCStreamConfiguration?
    private let streamQueue = DispatchQueue(label: "com.simulatorstream.capture")
    private var lastPixelBuffer: CVPixelBuffer?
    private var idleTimer: DispatchSourceTimer?
    private var hasReceivedRealFrame = false

    private(set) var deviceScreenRect: CGRect?

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
        if let window = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator"
        }) {
            print("[Capture] Found Simulator window: \(window.title ?? "untitled") (\(window.frame.width)x\(window.frame.height))")
            let size = CGSize(width: window.frame.width, height: window.frame.height)
            return (SCContentFilter(desktopIndependentWindow: window), size)
        }

        if let app = content.applications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }), let display = content.displays.first {
            print("[Capture] Found Simulator app, capturing all its windows")
            return (SCContentFilter(display: display, including: [app], exceptingWindows: []), nil)
        }

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

            if let contentRect = detectSimulatorContentRect() {
                self.deviceScreenRect = contentRect
                config.sourceRect = contentRect
                config.width = Int(contentRect.width * scaleFactor)
                config.height = Int(contentRect.height * scaleFactor)
                print("[Capture] Cropping to content area: \(contentRect) → \(config.width)x\(config.height)")
            } else {
                config.width = Int(size.width * scaleFactor)
                config.height = Int(size.height * scaleFactor)
                print("[Capture] Output size: \(config.width)x\(config.height) (scale \(scaleFactor))")
            }
        }

        return config
    }

    /// Uses macOS Accessibility to find the device screen content area inside
    /// the Simulator window. Returns a rect in window-local points suitable
    /// for SCStreamConfiguration.sourceRect, or nil on failure.
    private func detectSimulatorContentRect() -> CGRect? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }) else {
            print("[Capture] Simulator app not found for content rect detection")
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard let windows = windowsRef as? [AXUIElement] else { return nil }

        for win in windows {
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef)
            guard (subroleRef as? String) == "AXStandardWindow" else { continue }

            // Get window origin in screen coords
            var winPos = CGPoint.zero
            var posRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
            if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &winPos) }

            var winSize = CGSize.zero
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
            if let sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &winSize) }

            // Find the AXGroup child -- this is the device screen content area
            var childrenRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXChildrenAttribute as CFString, &childrenRef)
            guard let children = childrenRef as? [AXUIElement] else { continue }

            for child in children {
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
                guard (roleRef as? String) == "AXGroup" else { continue }

                var childPos = CGPoint.zero
                var cPosRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &cPosRef)
                if let cPosRef { AXValueGetValue(cPosRef as! AXValue, .cgPoint, &childPos) }

                var childSize = CGSize.zero
                var cSizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &cSizeRef)
                if let cSizeRef { AXValueGetValue(cSizeRef as! AXValue, .cgSize, &childSize) }

                guard childSize.width > 0, childSize.height > 0 else { continue }

                let offsetX = childPos.x - winPos.x
                let offsetY = childPos.y - winPos.y
                let rect = CGRect(x: offsetX, y: offsetY, width: childSize.width, height: childSize.height)
                print("[Capture] AX content rect in window: \(rect)  (window \(winSize.width)x\(winSize.height))")
                return rect
            }
        }

        print("[Capture] Could not find content group via Accessibility")
        return nil
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

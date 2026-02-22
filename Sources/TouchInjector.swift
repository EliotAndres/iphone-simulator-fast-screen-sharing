import Foundation
import AppKit

final class TouchInjector {
    private let queue = DispatchQueue(label: "com.simulatorstream.touch", qos: .userInteractive)
    private var bridgeProcess: Process?
    private var bridgeStdin: FileHandle?
    private var screenWidth: Double = 0
    private var screenHeight: Double = 0
    private var simulatorUDID: String?

    /// When false, the captured video is the full simulator window (top bar included)
    /// and touch coordinates must be adjusted. When true, the video is already cropped
    /// to the device screen and direct mapping is correct.
    private var videoIsCropped: Bool = true

    /// Top bar height in macOS window points (from Accessibility API).
    private var topBarOffsetMacOS: Double = 0
    /// Total simulator window height in macOS points.
    private var windowHeightMacOS: Double = 0
    /// Device content area height in macOS points.
    private var contentHeightMacOS: Double = 0

    private var touchDownPoint: CGPoint?
    private var lastMovePoint: CGPoint?

    private static let tapThreshold: Double = 10

    init() {
        resolveSimulator()
    }

    func pressHome() {
        queue.async { [weak self] in
            guard let self, let udid = self.simulatorUDID else {
                print("[Touch] pressHome: simulator not resolved yet")
                return
            }
            _ = self.shell("xcrun", "simctl", "io", udid, "button", "home")
            print("[Touch] Home button pressed")
        }
    }

    func setVideoIsCropped(_ isCropped: Bool) {
        queue.async { self.videoIsCropped = isCropped }
        print("[Touch] Video is \(isCropped ? "cropped to device screen (direct mapping)" : "full window — applying top bar correction")")
    }

    func handleTouch(_ event: TouchEvent) {
        guard screenWidth > 0, screenHeight > 0 else { return }

        let deviceX: Double
        let deviceY: Double

        if !videoIsCropped && windowHeightMacOS > 0 && contentHeightMacOS > 0 && topBarOffsetMacOS > 0 {
            // Video frame is the full simulator window (top bar included).
            // Map through the content rect to get device logical coordinates.
            let scaleY = screenHeight / contentHeightMacOS
            deviceX = event.x * screenWidth
            deviceY = max(0, (event.y * windowHeightMacOS - topBarOffsetMacOS) * scaleY)
        } else {
            deviceX = event.x * screenWidth
            deviceY = event.y * screenHeight
        }

        let point = CGPoint(x: deviceX, y: deviceY)

        switch event.type {
        case "down":
            touchDownPoint = point
            lastMovePoint = nil
        case "move":
            lastMovePoint = point
        case "up":
            guard let start = touchDownPoint else { return }
            let end = lastMovePoint ?? point
            let distance = hypot(end.x - start.x, end.y - start.y)

            if distance < Self.tapThreshold {
                sendBridge(["type": "tap", "x": start.x, "y": start.y])
            } else {
                sendBridge([
                    "type": "swipe",
                    "x1": start.x, "y1": start.y,
                    "x2": end.x, "y2": end.y,
                    "duration": 0.3
                ])
            }
            touchDownPoint = nil
            lastMovePoint = nil
        default:
            break
        }
    }

    func resolveSimulator() {
        queue.async { [weak self] in
            guard let self else { return }

            print("[Touch] Resolving simulator...")
            guard let udid = self.findBootedUDID() else {
                print("[Touch] No booted simulator found")
                return
            }
            self.simulatorUDID = udid
            print("[Touch] Using simulator UDID: \(udid)")

            if let size = self.queryScreenSize(udid: udid) {
                self.screenWidth = size.width
                self.screenHeight = size.height
                print("[Touch] Screen size: \(size.width)x\(size.height) points")
            } else {
                print("[Touch] Failed to query screen size")
                return
            }

            if let metrics = self.detectWindowMetrics() {
                self.topBarOffsetMacOS = metrics.topBarOffset
                self.windowHeightMacOS = metrics.windowHeight
                self.contentHeightMacOS = metrics.contentHeight
                print("[Touch] Top bar offset: \(metrics.topBarOffset) pts, window: \(metrics.windowHeight) pts, content: \(metrics.contentHeight) pts")
            } else {
                print("[Touch] Could not detect window metrics via Accessibility, using direct mapping")
            }

            let socketPath = "/tmp/idb/\(udid)_companion.sock"
            guard FileManager.default.fileExists(atPath: socketPath) else {
                print("[Touch] Companion socket not found at \(socketPath)")
                return
            }

            self.startBridge(socketPath: socketPath)
        }
    }

    // MARK: - Bridge process

    private func startBridge(socketPath: String) {
        let scriptPath = self.bridgeScriptPath()
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            print("[Touch] Bridge script not found at \(scriptPath)")
            return
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/opt/python@3.13/bin/python3.13")
        process.arguments = [scriptPath]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["IDB_COMPANION_SOCKET": socketPath]
        ) { _, new in new }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            print("[Touch] Failed to start bridge: \(error)")
            return
        }

        self.bridgeProcess = process
        self.bridgeStdin = stdinPipe.fileHandleForWriting

        // Read the "ready" line
        let outHandle = stdoutPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while let line = self.readLine(from: outHandle) {
                print("[Touch] Bridge: \(line)")
            }
            print("[Touch] Bridge process exited")
        }

        print("[Touch] Bridge started (pid \(process.processIdentifier))")
    }

    private func sendBridge(_ dict: [String: Any]) {
        guard let stdin = bridgeStdin,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              var json = String(data: data, encoding: .utf8) else {
            return
        }
        json += "\n"
        queue.async {
            stdin.write(json.data(using: .utf8)!)
        }
    }

    private func readLine(from handle: FileHandle) -> String? {
        var buffer = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty { return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8) }
            if byte.first == UInt8(ascii: "\n") {
                return String(data: buffer, encoding: .utf8)
            }
            buffer.append(byte)
        }
    }

    private func bridgeScriptPath() -> String {
        // Locate scripts/touch_bridge.py relative to the built binary or the source tree
        let fm = FileManager.default
        // When running from the source tree with `swift run`
        let candidates = [
            // Relative to working directory
            "scripts/touch_bridge.py",
            // Relative to executable
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("../../../scripts/touch_bridge.py")
                .standardized.path
        ]
        for path in candidates {
            if fm.fileExists(atPath: path) { return path }
        }
        return candidates[0]
    }

    // MARK: - Simulator discovery (one-time, via CLI)

    private func findBootedUDID() -> String? {
        let output = shell("xcrun", "simctl", "list", "devices", "booted", "-j")
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = json["devices"] as? [String: [[String: Any]]] else {
            return nil
        }
        for (_, devices) in devicesByRuntime {
            for device in devices {
                if let state = device["state"] as? String, state == "Booted",
                   let udid = device["udid"] as? String {
                    return udid
                }
            }
        }
        return nil
    }

    private func queryScreenSize(udid: String) -> CGSize? {
        let output = shell("idb", "ui", "describe-all", "--udid", udid, "--json")
        guard let data = output.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first,
              let frame = first["frame"] as? [String: Any] else {
            return nil
        }
        let width = (frame["width"] as? Double) ?? Double(frame["width"] as? Int ?? 0)
        let height = (frame["height"] as? Double) ?? Double(frame["height"] as? Int ?? 0)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Uses macOS Accessibility to find the simulator top bar height and total window height.
    /// Returns values in macOS window points (same coordinate space as SCStream sourceRect).
    private func detectWindowMetrics() -> (topBarOffset: Double, windowHeight: Double, contentHeight: Double)? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }) else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard let windows = windowsRef as? [AXUIElement] else { return nil }

        for win in windows {
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef)
            guard (subroleRef as? String) == "AXStandardWindow" else { continue }

            var winPos = CGPoint.zero
            var posRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
            if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &winPos) }

            var winSize = CGSize.zero
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
            if let sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &winSize) }
            guard winSize.height > 0 else { continue }

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
                guard childSize.height > 0 else { continue }

                let topBarOffset = Double(childPos.y - winPos.y)
                return (topBarOffset: topBarOffset, windowHeight: Double(winSize.height), contentHeight: Double(childSize.height))
            }
        }
        return nil
    }

    private func shell(_ command: String, _ args: String...) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

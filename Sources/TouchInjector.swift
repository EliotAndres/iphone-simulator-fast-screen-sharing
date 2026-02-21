import Foundation

final class TouchInjector {
    private let queue = DispatchQueue(label: "com.simulatorstream.touch", qos: .userInteractive)
    private var simulatorUDID: String?
    private var screenWidth: Double = 0
    private var screenHeight: Double = 0

    private var touchDownPoint: CGPoint?
    private var lastMovePoint: CGPoint?

    private static let tapThreshold: Double = 10

    init() {
        resolveSimulator()
    }

    func handleTouch(_ event: TouchEvent) {
        print("[Touch] Received: \(event.type) (\(event.x), \(event.y))")
        guard let udid = simulatorUDID, screenWidth > 0, screenHeight > 0 else {
            print("[Touch] Simulator not resolved (udid=\(simulatorUDID ?? "nil"), screen=\(screenWidth)x\(screenHeight))")
            return
        }

        let point = CGPoint(x: event.x * screenWidth, y: event.y * screenHeight)
        print("[Touch] Mapped to point: (\(point.x), \(point.y)) in \(screenWidth)x\(screenHeight)")

        switch event.type {
        case "down":
            touchDownPoint = point
            lastMovePoint = nil
            print("[Touch] Down at (\(point.x), \(point.y))")
        case "move":
            lastMovePoint = point
        case "up":
            guard let start = touchDownPoint else {
                print("[Touch] Up without matching down, ignoring")
                return
            }
            let end = lastMovePoint ?? point
            let distance = hypot(end.x - start.x, end.y - start.y)
            print("[Touch] Up: start=(\(start.x),\(start.y)) end=(\(end.x),\(end.y)) distance=\(distance)")

            if distance < Self.tapThreshold {
                let args = ["ui", "tap", "\(Int(start.x))", "\(Int(start.y))", "--udid", udid]
                print("[Touch] Running: idb \(args.joined(separator: " "))")
                queue.async {
                    let result = self.runIDB(args)
                    print("[Touch] idb tap result: '\(result)'")
                }
            } else {
                let args = ["ui", "swipe", "\(Int(start.x))", "\(Int(start.y))", "\(Int(end.x))", "\(Int(end.y))", "--udid", udid]
                print("[Touch] Running: idb \(args.joined(separator: " "))")
                queue.async {
                    let result = self.runIDB(args)
                    print("[Touch] idb swipe result: '\(result)'")
                }
            }
            touchDownPoint = nil
            lastMovePoint = nil
        default:
            print("[Touch] Unknown event type: \(event.type)")
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
                print("[Touch] Failed to query screen size for \(udid)")
            }
        }
    }

    private func findBootedUDID() -> String? {
        let output = shell("xcrun", "simctl", "list", "devices", "booted", "-j")
        print("[Touch] simctl output length: \(output.count) chars")
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = json["devices"] as? [String: [[String: Any]]] else {
            print("[Touch] Failed to parse simctl JSON")
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
        print("[Touch] idb describe-all output length: \(output.count) chars")
        guard let data = output.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first,
              let frame = first["frame"] as? [String: Any] else {
            print("[Touch] Failed to parse idb describe-all JSON")
            return nil
        }

        let width = (frame["width"] as? Double) ?? Double(frame["width"] as? Int ?? 0)
        let height = (frame["height"] as? Double) ?? Double(frame["height"] as? Int ?? 0)
        print("[Touch] Parsed screen size: \(width)x\(height)")

        guard width > 0, height > 0 else {
            print("[Touch] Invalid screen size: \(width)x\(height)")
            return nil
        }
        return CGSize(width: width, height: height)
    }

    @discardableResult
    private func runIDB(_ args: [String]) -> String {
        return shell("idb", args)
    }

    private func shell(_ command: String, _ args: String...) -> String {
        return shell(command, args)
    }

    private func shell(_ command: String, _ args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[Touch] Failed to run \(command) \(args.joined(separator: " ")): \(error)")
            return ""
        }

        let exitCode = process.terminationStatus
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if exitCode != 0 {
            print("[Touch] \(command) \(args.joined(separator: " ")) exited with \(exitCode): \(output)")
        }
        return output
    }
}

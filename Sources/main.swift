import Foundation
import AppKit

// Disable stdout buffering so print() shows immediately in background
setbuf(stdout, nil)

// Disable simulator device bezels for a cleaner capture
do {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = ["write", "com.apple.iphonesimulator", "ShowDeviceBezels", "-bool", "false"]
    try p.run()
    p.waitUntilExit()
} catch {
    print("[App] Warning: could not disable simulator bezels: \(error)")
}

// Initialize the AppKit/CoreGraphics subsystem required by ScreenCaptureKit
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)

let app = StreamingApp()
app.start()
RunLoop.main.run()

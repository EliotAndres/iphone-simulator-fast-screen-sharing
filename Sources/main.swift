import Foundation
import AppKit

// Disable stdout buffering so print() shows immediately in background
setbuf(stdout, nil)

// Initialize the AppKit/CoreGraphics subsystem required by ScreenCaptureKit
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)

let app = StreamingApp()
app.start()
RunLoop.main.run()

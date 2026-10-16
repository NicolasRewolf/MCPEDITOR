// Runner-only UI smoke check. Local interactive checks use the computer-use tool.
import AppKit
import CoreGraphics
import Foundation

guard ProcessInfo.processInfo.environment["CI"] == "true", CommandLine.arguments.count == 2 else {
    fputs("This launch probe is restricted to an isolated CI runner.\n", stderr)
    exit(2)
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.activates = false
var launched: NSRunningApplication?
var completed = false
var launchError: Error?
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
    // AppKit documents a concurrent completion queue. All state observed by the
    // main RunLoop is published on that same queue instead of racing the probe.
    DispatchQueue.main.async {
        launched = app
        launchError = error
        completed = true
    }
}
let deadline = Date().addingTimeInterval(25)
var visibleWindow = false
while Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    if completed, launched == nil { break }
    guard let app = launched, !app.isTerminated,
          app.bundleURL?.standardizedFileURL == appURL else { continue }
    let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                        kCGNullWindowID) as? [[String: Any]] ?? []
    visibleWindow = rows.contains { row in
        guard row[kCGWindowOwnerPID as String] as? Int == Int(app.processIdentifier),
              let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
        return width >= 500 && height >= 300
    }
    if visibleWindow { break }
}
// The handle returned for this exact URL is the only process ever terminated.
if let app = launched, app.bundleURL?.standardizedFileURL == appURL {
    print("PROCESS_OBSERVED: PID \(app.processIdentifier), \(appURL.path)")
    app.terminate()
    for _ in 0..<20 where !app.isTerminated {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if !app.isTerminated { app.forceTerminate() }
}
if visibleWindow {
    print("WINDOW_OBSERVED: current extracted archive; this does not validate a kit on MPC.")
    exit(0)
}
fputs("WINDOW_NOT_CONFIRMED: \(String(describing: launchError))\n", stderr)
exit(1)

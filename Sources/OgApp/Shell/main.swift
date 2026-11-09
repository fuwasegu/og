import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    if ProcessInfo.processInfo.environment["OG_DEBUG_SCRIPT"] == nil { app.activate(ignoringOtherApps: true) }
    withExtendedLifetime(delegate) { app.run() }
}

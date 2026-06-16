import AppKit

// Run as accessory (no Dock icon, no menu bar menu takeover)
NSApplication.shared.setActivationPolicy(.accessory)

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()

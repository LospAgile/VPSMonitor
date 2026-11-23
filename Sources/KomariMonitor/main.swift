import AppKit
import Foundation

if let status = LoginItemCommand.runIfRequested() { exit(status) }

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()

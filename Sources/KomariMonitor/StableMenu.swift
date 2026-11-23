import AppKit
import SwiftUI

@MainActor enum DashboardMenuTracking {
    private static var depth = 0
    private static var endedAt = -Double.infinity
    static var isTracking: Bool { depth > 0 }
    static func begin() { depth += 1 }
    static func end() { depth = max(0, depth - 1); endedAt = ProcessInfo.processInfo.systemUptime }
    // Menu selection can reach an event monitor after NSMenu has returned.
    static func containsClick(at timestamp: TimeInterval) -> Bool { isTracking || timestamp <= endedAt + 0.15 }
}

struct StableMenuEntry {
    var title: String
    var symbol: String? = nil
    var checked = false
    var enabled = true
    var action: () -> Void = {}
    static var separator: Self { Self(title: "") }
}

/// Keep the tracking NSMenu independent of SwiftUI's live telemetry updates.
struct StableMenu: NSViewRepresentable {
    var title: String
    var symbol: String
    var help: String = ""
    var entries: () -> [StableMenuEntry]

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        guard !context.coordinator.tracking else { return }
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help.isEmpty ? title : help)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = help
        button.setAccessibilityLabel(help.isEmpty ? title : help)
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var parent: StableMenu
        private(set) var tracking = false
        private var activeEntries: [StableMenuEntry] = []
        init(_ parent: StableMenu) { self.parent = parent }

        @objc func openMenu(_ sender: NSButton) {
            guard !tracking else { return }
            activeEntries = parent.entries()
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            for (index, entry) in activeEntries.enumerated() {
                if entry.title.isEmpty { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: entry.title, action: #selector(selectEntry(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.state = entry.checked ? .on : .off
                item.isEnabled = entry.enabled
                if let symbol = entry.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                menu.addItem(item)
            }
            tracking = true
            DashboardMenuTracking.begin()
            defer {
                DashboardMenuTracking.end()
                tracking = false
                activeEntries.removeAll()
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 3), in: sender)
        }
        @objc private func selectEntry(_ item: NSMenuItem) {
            guard activeEntries.indices.contains(item.tag), activeEntries[item.tag].enabled else { return }
            activeEntries[item.tag].action()
        }
    }
}

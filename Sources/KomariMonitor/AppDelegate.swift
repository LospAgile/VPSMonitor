import AppKit
import QuartzCore
import SwiftUI
import OSLog
import Network

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private enum PopoverFade {
        static let fadeInDuration: TimeInterval = 0.07
        static let fadeOutDuration: TimeInterval = 0.20
    }

    private var statusItem: NSStatusItem!
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var nodeObservationTask: Task<Void, Never>?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var isClosingPopover = false
    private var store: KomariStore?
    private let networkTools = NetworkToolsStore()
    private var resizeOrigin: NSSize?
    private var resizeWindowOrigin: NSRect?
    private var menuTrackingDepth = 0
    private var menuObservers: [NSObjectProtocol] = []
    private let windowLog = Logger(subsystem: "local.komari.monitor", category: "Popover")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        DashboardPreferences.prepare(defaults, legacyValues: Bundle.main.bundleIdentifier == "local.komari.monitor.preview"
                                     ? defaults.persistentDomain(forName: "local.komari.monitor") : nil)
        configureStatusItem()
        configurePopover()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store?.refresh() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.store?.refresh() }
        }
        monitor.start(queue: DispatchQueue(label: "VPSMonitor.connectivity"))
        pathMonitor = monitor

        do {
            startMonitor(config: try Config.load())
            if CommandLine.arguments.contains("--show") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.togglePopover() }
            }
        } catch {
            showConfigError(error)
            showSettingsWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopOutsideClickMonitoring()
        nodeObservationTask?.cancel()
        store?.stop()
        networkTools.shutdown()
        pathMonitor?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return false
    }

    @objc private func statusClicked() {
        togglePopover()
    }

    private func startMonitor(config: Config) {
        nodeObservationTask?.cancel()
        store?.stop()
        let store = KomariStore(config: config)
        self.store = store
        configurePopover()

        nodeObservationTask = Task { @MainActor in
            while !Task.isCancelled {
                self.updateStatusTitle()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        store.start()
        updateStatusTitle()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = ServerIcon.image
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(statusClicked)
        }
        updateStatusTitle()
    }

    private func configurePopover() {
        popover?.performClose(nil)
        stopOutsideClickMonitoring()
        popover = NSPopover()
        popover.delegate = self
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentSize = savedPopoverSize()
    }

    private func makePopoverContent() -> NSViewController {
        if let store {
            return NSHostingController(
                rootView: MonitorDashboard(
                    store: store,
                    tools: networkTools,
                    onOpenSettings: { [weak self] in self?.showSettingsWindow() },
                    onResize: { [weak self] delta, edge, finished in self?.resizePopover(delta: delta, edge: edge, finished: finished) },
                    onResetSize: { [weak self] in
                        DispatchQueue.main.async { self?.resetPopoverSize() }
                    },
                    onAppearanceChange: { [weak self] in self?.updatePopoverAppearance() }
                )
            )
        } else {
            return NSHostingController(
                rootView: MissingConfigView(
                    onOpenSettings: { [weak self] in self?.showSettingsWindow() },
                    onQuit: { NSApplication.shared.terminate(nil) }
                )
            )
        }
    }

    private func updateStatusTitle() {
        let count = NodeCount(nodes: store?.nodes ?? [], catalogUpdatedAt: store?.catalogUpdatedAt)
        guard let button = statusItem.button else { return }
        let title = " " + count.title
        if button.title != title { button.title = title }
        let description = count.catalogIsFresh
            ? "\(AppIdentity.displayName) · 在线 \(count.online)，离线 \(count.offline)，未知 \(count.unknown)，共 \(count.total) 台"
            : "\(AppIdentity.displayName) · 等待 Komari 更新，当前状态未知"
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    private func clampedPopoverSize(_ size: NSSize) -> NSSize {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let bounds = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let maxWidth = max(440, bounds.width - 40)
        let maxHeight = max(460, bounds.height - 40)
        return NSSize(width: min(maxWidth, max(440, size.width)), height: min(maxHeight, max(460, size.height)))
    }

    private func savedPopoverSize() -> NSSize {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: "monitor.lite.popover.width")
        let height = defaults.double(forKey: "monitor.lite.popover.height")
        let fallback = defaultPopoverSize()
        return clampedPopoverSize(NSSize(width: width > 0 ? width : fallback.width, height: height > 0 ? height : fallback.height))
    }

    private func defaultPopoverSize() -> NSSize {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        return clampedPopoverSize(NSSize(width: 680, height: min(720, (screen?.visibleFrame.height ?? 900) * 0.8)))
    }

    private func resetPopoverSize() {
        guard popover.isShown else { return }
        resizeOrigin = nil
        resizeWindowOrigin = nil
        let size = defaultPopoverSize()
        resizePopover(delta: CGSize(width: size.width - popover.contentSize.width, height: size.height - popover.contentSize.height),
                      edge: .bottomRight, finished: true)
    }

    private func resizePopover(delta: CGSize, edge: PopoverResizeEdge, finished: Bool) {
        guard let window = popover.contentViewController?.view.window else { return }
        if resizeOrigin == nil {
            resizeOrigin = popover.contentSize
            resizeWindowOrigin = window.frame
        }
        guard let origin = resizeOrigin else { return }
        let widthDelta = edge == .bottom ? 0 : delta.width * (edge.isLeft ? -1 : 1)
        let heightDelta = edge.changesHeight ? delta.height : 0
        let size = clampedPopoverSize(NSSize(width: origin.width + widthDelta, height: origin.height + heightDelta))
        if popover.contentSize != size {
            popover.contentViewController?.preferredContentSize = size
            popover.contentSize = size
        }
        if let originalFrame = resizeWindowOrigin, size != origin || finished {
            // NSPopover otherwise re-centers around its menu-bar anchor on every
            // change. Keep the opposite edge fixed while the pointer is held.
            var frame = originalFrame
            frame.size.width += size.width - origin.width
            frame.size.height += size.height - origin.height
            frame.origin.x = edge.isLeft ? originalFrame.maxX - frame.width : originalFrame.minX
            frame.origin.y = originalFrame.maxY - frame.height
            if let screen = window.screen ?? statusItem.button?.window?.screen {
                let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
                frame.origin.x = min(max(visible.minX, frame.origin.x), visible.maxX - frame.width)
                frame.origin.y = max(visible.minY, frame.origin.y)
            }
            if window.frame != frame {
                // Let AppKit coalesce drawing with the current display cycle.
                window.setFrame(frame, display: false, animate: false)
            }
        }
        if finished {
            UserDefaults.standard.set(size.width, forKey: "monitor.lite.popover.width")
            UserDefaults.standard.set(size.height, forKey: "monitor.lite.popover.height")
            resizeOrigin = nil
            resizeWindowOrigin = nil
            windowLog.info("Popover resized to \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public)")
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopoverLightly()
        } else {
            showPopoverLightly(relativeTo: button.bounds, of: button)
        }
    }

    private func updatePopoverAppearance() {
        let mode = DashboardAppearance(rawValue: UserDefaults.standard.string(forKey: DashboardPreferences.appearanceKey) ?? "") ?? .system
        let appearance = mode.appKitAppearance
        popover.appearance = appearance
        popover.contentViewController?.view.appearance = appearance
        popover.contentViewController?.view.window?.appearance = appearance
    }

    private func showPopoverLightly(relativeTo rect: NSRect, of button: NSView) {
        isClosingPopover = false
        NSApp.activate(ignoringOtherApps: true)
        if popover.contentViewController == nil {
            let size = savedPopoverSize()
            let controller = makePopoverContent()
            controller.view.frame = NSRect(origin: .zero, size: size)
            controller.preferredContentSize = size
            popover.contentViewController = controller
            popover.contentSize = size
        }
        guard let contentController = popover.contentViewController else { return }
        updatePopoverAppearance()
        contentController.view.alphaValue = 0
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        windowLog.info("Popover shown \(self.popover.isShown, privacy: .public), size \(Int(self.popover.contentSize.width), privacy: .public)x\(Int(self.popover.contentSize.height), privacy: .public)")

        guard let window = contentController.view.window else {
            contentController.view.alphaValue = 1
            startOutsideClickMonitoring()
            return
        }

        updatePopoverAppearance()
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.alphaValue = 0
        window.makeFirstResponder(contentController.view)
        window.makeKey()
        contentController.view.alphaValue = 1
        startOutsideClickMonitoring()

        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : PopoverFade.fadeInDuration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak contentController, weak window] in
            guard let self, self.popover.isShown, !self.isClosingPopover,
                  self.popover.contentViewController === contentController else { return }
            window?.alphaValue = 1
        }
    }

    private func closePopoverLightly(reason: String = #function) {
        guard popover.isShown, !isClosingPopover else { return }
        windowLog.info("Closing popover: \(reason, privacy: .public)")
        isClosingPopover = true

        guard let window = popover.contentViewController?.view.window else {
            popover.performClose(nil)
            return
        }

        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : PopoverFade.fadeOutDuration
        let controller = popover.contentViewController
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        }
        // Occluded windows can defer animation completion indefinitely. Closing
        // and releasing the live dashboard must not depend on that callback.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak controller] in
            guard let self, self.isClosingPopover,
                  self.popover.contentViewController === controller else { return }
            self.popover.performClose(nil)
        }
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        menuObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTrackingDepth += 1 }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTrackingDepth = max(0, (self?.menuTrackingDepth ?? 0) - 1) }
            }
        ]

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let timestamp = event.timestamp
            Task { @MainActor in
                guard self?.menuTrackingDepth == 0, !DashboardMenuTracking.containsClick(at: timestamp) else { return }
                self?.closePopoverLightly(reason: "global outside click")
            }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if self.menuTrackingDepth > 0 || DashboardMenuTracking.containsClick(at: event.timestamp) { return event }
            if self.isStatusButtonClick(event) {
                return event
            }
            guard let popoverWindow = self.popover.contentViewController?.view.window else {
                self.closePopoverLightly(reason: "local click without popover window")
                return event
            }
            if let window = event.window, window === NSApp.modalWindow || window.sheetParent === popoverWindow { return event }
            if event.window !== popoverWindow {
                self.closePopoverLightly(reason: "local click in another window")
            }
            return event
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, event.keyCode == 53 else { return event }
            if self.menuTrackingDepth > 0 || DashboardMenuTracking.isTracking { return event }
            if let window = event.window, window === NSApp.modalWindow || window.sheetParent === self.popover.contentViewController?.view.window { return event }
            self.closePopoverLightly(reason: "Escape")
            return nil
        }
    }

    private func stopOutsideClickMonitoring() {
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers.removeAll()
        menuTrackingDepth = 0
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func isStatusButtonClick(_ event: NSEvent) -> Bool {
        guard let button = statusItem.button, event.window === button.window else { return false }
        let location = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(location)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        windowLog.info("Popover closed; releasing hidden view")
        isClosingPopover = false
        resizeOrigin = nil
        resizeWindowOrigin = nil
        popover.contentViewController?.view.window?.alphaValue = 1
        popover.contentViewController?.view.alphaValue = 1
        // Closed dashboards should not keep rebuilding charts for every live report.
        popover.contentViewController = nil
        networkTools.stopAllHealthPolling()
        stopOutsideClickMonitoring()
    }

    private func showConfigError(_ error: Error) {
        if let button = statusItem.button {
            button.toolTip = "无法读取 Komari 配置：\(error.localizedDescription)"
        }
    }

    private func showSettingsWindow() {
        popover?.performClose(nil)
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let config = (try? Config.load()) ?? .empty
        let rootView = SettingsView(
            config: config,
            onSave: { [weak self] next in
                self?.settingsWindow?.close()
                self?.settingsWindow = nil
                self?.startMonitor(config: next)
            },
            onCancel: { [weak self] in
                self?.settingsWindow?.close()
                self?.settingsWindow = nil
            }
        )
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = "\(AppIdentity.displayName) 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}

import AppKit
import SwiftUI

struct DashboardSnapshot: Equatable {
    var nodes: [NodeViewModel] = []
    var connected = false
    var isRefreshing = false
    var lastError: String?
    var exchangeRates: ExchangeRateSnapshot?
    var exchangeRateError: String?
    var catalogUpdatedAt: Date?
    var catalogError: String?
    var statusError: String?
    var pingError: String?
    var pingUpdatedAt: Date?
    var sampledAt: Date = Date()
    var historyPlots: [String: [Int: PingHistoryGeometry]] = [:]
    var historyUpdatedAt: Date?
    var historyError: String?
    var historyLoading = false
    var totals = DashboardTotals(nodes: [], catalogUpdatedAt: nil, now: .distantPast)
    var count: NodeCount { NodeCount(nodes: nodes, catalogUpdatedAt: catalogUpdatedAt, now: sampledAt) }
    var countTitle: String { count.title }
    var catalogIsFresh: Bool { count.catalogIsFresh }
    var onlineCount: Int { count.online }
    var unknownCount: Int { count.unknown }
    var emptyPingText: String {
        pingError != nil ? "三网暂不可用" : pingUpdatedAt == nil ? "正在读取三网…" : "未绑定三网"
    }

    var assetSummary: AssetSummary {
        AssetAccounting.summary(nodes: nodes.map(\.node), rates: exchangeRates?.rates, now: sampledAt)
    }
}

/// Incoming telemetry continues while presentation is held during interaction.
@MainActor
final class DashboardPresentation: ObservableObject {
    @Published private(set) var snapshot = DashboardSnapshot()
    @Published private(set) var isRefreshing = false
    private let store: KomariStore
    private let defaults: UserDefaults
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var lastPublished = Date.distantPast
    private var requestedRefresh = false
    private var isResizing = false

    init(store: KomariStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    isolated deinit {
        timer?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        guard timer == nil else { return }
        store.refreshIfNeeded()
        capture(force: true)
        observers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let identifier = ObjectIdentifier(menu)
                MainActor.assumeIsolated { _ = self?.trackingMenus.insert(identifier) }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let identifier = ObjectIdentifier(menu)
                MainActor.assumeIsolated { _ = self?.trackingMenus.remove(identifier) }
            }
        ]
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.capture()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        trackingMenus.removeAll()
        isResizing = false
        requestedRefresh = false
    }

    func setResizing(_ resizing: Bool) {
        guard isResizing != resizing else { return }
        isResizing = resizing
        if !resizing { capture(force: true) }
    }

    func refresh() {
        requestedRefresh = true
        store.refresh()
        capture(force: true)
    }

    func capture(force: Bool = false, now: Date = Date()) {
        // Button activity must not get stuck if the user pauses during a request.
        let refreshing = store.isRefreshing || (requestedRefresh && store.history.isLoading)
        if isRefreshing != refreshing { isRefreshing = refreshing }
        guard !isResizing, trackingMenus.isEmpty, !DashboardMenuTracking.isTracking else { return }
        let firstData = snapshot.nodes.isEmpty && !store.nodes.isEmpty
        let initialData = snapshot.catalogUpdatedAt == nil && store.catalogUpdatedAt != nil
        let initialTelemetry = (snapshot.pingUpdatedAt == nil && store.pingUpdatedAt != nil)
            || (snapshot.historyUpdatedAt == nil && store.history.updatedAt != nil)
        let manualCompleted = requestedRefresh && !refreshing
        let initialCapture = lastPublished == .distantPast
        guard !defaults.bool(forKey: DashboardPreferences.pausedKey) || initialCapture || initialData || requestedRefresh else { return }
        let intervalElapsed = now.timeIntervalSince(lastPublished) >= DashboardPreferences.refreshInterval(in: defaults)
        guard force || initialData || firstData || initialTelemetry || manualCompleted || intervalElapsed else { return }
        // Preserve the row under the pointer while this panel is open. New metadata
        // still appears immediately; reopening adopts the latest Komari ordering.
        let previousOrder = Dictionary(uniqueKeysWithValues: snapshot.nodes.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = store.nodes.enumerated().sorted {
            (previousOrder[$0.element.id] ?? (previousOrder.count + $0.offset))
            < (previousOrder[$1.element.id] ?? (previousOrder.count + $1.offset))
        }.map(\.element)
        let next = DashboardSnapshot(nodes: ordered, connected: store.connected,
                                     isRefreshing: store.isRefreshing, lastError: store.lastError,
                                     exchangeRates: store.exchangeRateSnapshot,
                                     exchangeRateError: store.exchangeRateError,
                                     catalogUpdatedAt: store.catalogUpdatedAt, catalogError: store.catalogError,
                                     statusError: store.statusError, pingError: store.pingError,
                                     pingUpdatedAt: store.pingUpdatedAt, sampledAt: now,
                                     historyPlots: store.history.plots,
                                     historyUpdatedAt: store.history.updatedAt,
                                     historyError: store.history.error, historyLoading: store.history.isLoading,
                                     totals: DashboardTotals(nodes: ordered, catalogUpdatedAt: store.catalogUpdatedAt, now: now))
        if next != snapshot { snapshot = next }
        lastPublished = now
        if manualCompleted { requestedRefresh = false }
    }
}

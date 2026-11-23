import Foundation
import Testing
@testable import KomariMonitor

@Suite @MainActor struct DashboardPresentationTests {
    @Test func resizingHoldsOnlyPresentationAndPublishesLatestCatalogOnRelease() async throws {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        let store = KomariStore(config: fixture.config, catalogInterval: 0.1, exchangeRatesEnabled: false)
        store.start()
        defer { store.stop() }
        try #require(await eventually { store.nodes.count == 2 })
        let presentation = DashboardPresentation(store: store, defaults: defaults)
        presentation.capture(force: true)
        let before = presentation.snapshot
        presentation.setResizing(true)
        try await fixture.update(["catalog_result": []])
        try #require(await eventually { store.nodes.isEmpty })
        presentation.capture(force: true)
        #expect(presentation.snapshot == before)
        presentation.setResizing(false)
        #expect(presentation.snapshot.nodes.isEmpty && presentation.snapshot.countTitle == "0/0")
        presentation.setResizing(true)
        presentation.stop()
        let later = Date().addingTimeInterval(181)
        presentation.capture(force: true, now: later)
        #expect(presentation.snapshot.sampledAt == later) // Closing cannot leave updates held.
    }

    @Test func selectedIntervalControlsPublicationAndCanBeShortened() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = KomariStore(config: .empty, exchangeRatesEnabled: false)
        let presentation = DashboardPresentation(store: store, defaults: defaults)
        let now = Date()
        for interval in DashboardPreferences.refreshIntervals {
            defaults.set(interval, forKey: DashboardPreferences.refreshKey)
            presentation.capture(force: true, now: now)
            presentation.capture(now: now.addingTimeInterval(interval - 0.1))
            #expect(presentation.snapshot.sampledAt == now)
            presentation.capture(now: now.addingTimeInterval(interval))
            #expect(presentation.snapshot.sampledAt == now.addingTimeInterval(interval))
        }
        defaults.set(30, forKey: DashboardPreferences.refreshKey)
        presentation.capture(force: true, now: now)
        defaults.set(2, forKey: DashboardPreferences.refreshKey)
        presentation.capture(now: now.addingTimeInterval(3))
        #expect(presentation.snapshot.sampledAt == now.addingTimeInterval(3))
    }

    @Test func pauseKeepsCollectingAndSurvivesResizeUntilResumed() async throws {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        let store = KomariStore(config: fixture.config, catalogInterval: 0.1, exchangeRatesEnabled: false)
        store.start()
        defer { store.stop() }
        try #require(await eventually { store.nodes.count == 2 })
        let presentation = DashboardPresentation(store: store, defaults: defaults)
        presentation.capture(force: true)
        let before = presentation.snapshot
        defaults.set(true, forKey: DashboardPreferences.pausedKey)
        presentation.setResizing(true)
        try await fixture.update(["catalog_result": []])
        try #require(await eventually { store.nodes.isEmpty && !store.isRefreshing })
        presentation.setResizing(false)
        presentation.capture(force: true, now: Date().addingTimeInterval(60))
        #expect(presentation.snapshot == before)
        #expect(!presentation.isRefreshing)
        defaults.set(false, forKey: DashboardPreferences.pausedKey)
        presentation.capture(force: true)
        #expect(presentation.snapshot.countTitle == "0/0")
    }

    @Test func pausedReopenGetsInitialDataAndManualRefreshUpdatesOnce() async throws {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: DashboardPreferences.pausedKey)
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        let store = KomariStore(config: fixture.config, catalogInterval: 3_600, exchangeRatesEnabled: false)
        let presentation = DashboardPresentation(store: store, defaults: defaults)
        presentation.capture(force: true)
        store.start()
        defer { store.stop() }
        try #require(await eventually { store.nodes.count == 2 && !store.isRefreshing })
        presentation.capture()
        #expect(presentation.snapshot.nodes.count == 2)
        try await fixture.update(["catalog_result": []])
        presentation.refresh()
        #expect(presentation.isRefreshing)
        try #require(await eventually { store.nodes.isEmpty && !store.isRefreshing })
        presentation.capture()
        #expect(!presentation.isRefreshing && presentation.snapshot.countTitle == "0/0")
        #expect(defaults.bool(forKey: DashboardPreferences.pausedKey))
        let frozenEmpty = presentation.snapshot
        try await fixture.update(["catalog_result": [["uuid": "added", "name": "new node"]]])
        store.refresh()
        try #require(await eventually { store.nodes.count == 1 && !store.isRefreshing })
        presentation.capture(force: true, now: Date().addingTimeInterval(60))
        #expect(presentation.snapshot == frozenEmpty) // A valid empty catalog is still paused.
    }

    @Test func importsOnlyDisplayPreferencesWithoutOverwritingCandidateChoices() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let legacy: [String: Any] = [DashboardPreferences.appearanceKey: "dark",
                                   DashboardPreferences.refreshKey: 30.0,
                                   DashboardPreferences.pausedKey: true, "unrelated": "do not copy"]
        DashboardPreferences.prepare(defaults, legacyValues: legacy)
        #expect(defaults.string(forKey: DashboardPreferences.appearanceKey) == "dark")
        #expect(DashboardPreferences.refreshInterval(in: defaults) == 30)
        #expect(defaults.bool(forKey: DashboardPreferences.pausedKey))
        #expect(defaults.object(forKey: "unrelated") == nil)
        defaults.set("light", forKey: DashboardPreferences.appearanceKey)
        defaults.set(10, forKey: DashboardPreferences.refreshKey)
        defaults.set(false, forKey: DashboardPreferences.pausedKey)
        DashboardPreferences.prepare(defaults, legacyValues: legacy)
        #expect(defaults.string(forKey: DashboardPreferences.appearanceKey) == "light")
        #expect(DashboardPreferences.refreshInterval(in: defaults) == 10)
        #expect(!defaults.bool(forKey: DashboardPreferences.pausedKey))
    }

    @Test func pausedManualRefreshWaitsForLateHistory() async throws {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: DashboardPreferences.pausedKey)
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        try await fixture.update(["theme_settings": ["homepagePingBindings": ["1": ["visible", "hidden"]]]])
        let store = KomariStore(config: fixture.config, catalogInterval: 3_600, exchangeRatesEnabled: false)
        store.start()
        defer { store.stop() }
        try #require(await eventually { store.nodes.count == 2 && !store.isRefreshing })
        store.history.setVisible(true)
        try #require(await eventually { store.history.updatedAt != nil && !store.history.isLoading })
        let presentation = DashboardPresentation(store: store, defaults: defaults)
        presentation.capture(force: true)
        let before = presentation.snapshot.historyUpdatedAt
        try await fixture.update(["history_delay": 0.8])
        presentation.refresh()
        try #require(await eventually { !store.isRefreshing && store.history.isLoading })
        presentation.capture()
        #expect(presentation.isRefreshing)
        #expect(presentation.snapshot.historyUpdatedAt == before)
        try #require(await eventually { !store.history.isLoading && store.history.updatedAt != before })
        presentation.capture()
        #expect(!presentation.isRefreshing)
        #expect(presentation.snapshot.historyUpdatedAt == store.history.updatedAt)
        #expect(defaults.bool(forKey: DashboardPreferences.pausedKey))
    }

    @Test func firstCardHistoryAppearsWithoutWaitingForLongRefreshInterval() async throws {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(30, forKey: DashboardPreferences.refreshKey)
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        try await fixture.update(["theme_settings": ["homepagePingBindings": ["1": ["visible", "hidden"]]]])
        let store = KomariStore(config: fixture.config, catalogInterval: 3_600, exchangeRatesEnabled: false)
        store.start()
        defer { store.stop() }
        try #require(await eventually { store.pingUpdatedAt != nil && !store.isRefreshing })
        let presentation = DashboardPresentation(store: store, defaults: defaults)
        let now = Date()
        presentation.capture(force: true, now: now)
        #expect(presentation.snapshot.historyUpdatedAt == nil)
        store.history.setVisible(true)
        try #require(await eventually { store.history.updatedAt != nil && !store.history.isLoading })
        presentation.capture(now: now.addingTimeInterval(1))
        #expect(presentation.snapshot.historyUpdatedAt == store.history.updatedAt)
        #expect(!presentation.snapshot.historyPlots.isEmpty)
    }

    @Test func pausedInitialEmptyCatalogDoesNotWaitForRefreshInterval() async throws {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: DashboardPreferences.pausedKey)
        defaults.set(30, forKey: DashboardPreferences.refreshKey)
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        try await fixture.update(["catalog_result": []])
        let store = KomariStore(config: fixture.config, exchangeRatesEnabled: false)
        let presentation = DashboardPresentation(store: store, defaults: defaults)
        let now = Date()
        presentation.capture(force: true, now: now)
        store.start()
        defer { store.stop() }
        try #require(await eventually { store.catalogUpdatedAt != nil && !store.isRefreshing })
        presentation.capture(now: now.addingTimeInterval(1))
        #expect(presentation.snapshot.countTitle == "0/0")
    }

    @Test func invalidStoredDisplayPreferencesFallBackToSupportedChoices() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("invalid", forKey: DashboardPreferences.appearanceKey)
        defaults.set(-1, forKey: DashboardPreferences.refreshKey)
        DashboardPreferences.prepare(defaults)
        #expect(defaults.string(forKey: DashboardPreferences.appearanceKey) == "system")
        #expect(DashboardPreferences.refreshInterval(in: defaults) == 5)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let domain = "VPSMonitor.presentation-tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: domain)!, domain)
    }

    private func eventually(_ predicate: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}

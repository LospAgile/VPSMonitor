import Testing
@testable import KomariMonitor
import Foundation

@Suite struct AssetAccountingTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private func node(price: Double = 100, currency: String = "CNY", cycle: Int = 365, days: Double? = 365) -> NodeInfo {
        NodeInfo(id: "test", name: "test", region: "", os: "", arch: "", virtualization: "", cpuCores: 1,
                 trafficLimit: 0, expiresAt: days.map { now.addingTimeInterval($0 * 86_400) },
                 price: price, billingCycleDays: cycle, currency: currency)
    }

    @Test func testCurrencyAliasesAndUnknownCurrencies() {
        for alias in ["$", "US$", "$USD", " 美 元 ", "＄"] { #expect((AssetAccounting.currency(alias)) == ("USD")) }
        for alias in ["", "RMB", "¥", "人民币"] { #expect((AssetAccounting.currency(alias)) == ("CNY")) }
        #expect((AssetAccounting.currency("JP¥")) == ("JPY"))
        #expect((AssetAccounting.currency("AUD")) == ("AUD"))
        #expect((AssetAccounting.currency("XYZ")) == ("XYZ"))
        #expect((AssetAccounting.currency("unknown")) == (""))
    }

    @Test func testConversionRejectsMissingOrInvalidRates() {
        let usd = node(currency: "$")
        #expect((AssetAccounting.cnyPrice(usd, rates: ["USD": 1, "CNY": 7])) == (700))
        #expect((AssetAccounting.cnyPrice(node(currency: "EUR"), rates: ["EUR": 0.8, "CNY": 7])) == (875))
        #expect(AssetAccounting.cnyPrice(usd, rates: ["USD": 1]) == nil)
        #expect(AssetAccounting.cnyPrice(usd, rates: ["USD": 0, "CNY": 7]) == nil)
        #expect(AssetAccounting.cnyPrice(usd, rates: ["USD": 1, "CNY": .nan]) == nil)
        #expect(AssetAccounting.cnyPrice(node(price: .infinity), rates: [:]) == nil)
        #expect((AssetAccounting.cnyPrice(node(), rates: [:])) == (100))
    }

    @Test func testRemainingValueMatchesPrepaidAndExpiryConventions() {
        #expect(abs((AssetAccounting.remaining(node(days: 182.5), cny: 100, now: now)) - (50)) <= 0.0001)
        #expect(abs((AssetAccounting.remaining(node(days: 730), cny: 100, now: now)) - (200)) <= 0.0001)
        #expect((AssetAccounting.remaining(node(days: -1), cny: 100, now: now)) == (0))
        #expect((AssetAccounting.remaining(node(days: nil), cny: 100, now: now)) == (100))
        #expect((AssetAccounting.remaining(node(cycle: -1, days: 10), cny: 100, now: now)) == (100))
        #expect((AssetAccounting.remaining(node(days: 36_501), cny: 100, now: now)) == (100))
        #expect((AssetAccounting.remaining(node(cycle: 0, days: 365), cny: 100, now: now)) == (100))
    }

    @Test func testCyclesAndAnnualCostMatchTheme() {
        #expect((AssetAccounting.billingCycleDays("月付")) == (30))
        #expect((AssetAccounting.billingCycleDays("quarterly")) == (90))
        #expect((AssetAccounting.billingCycleDays("half-year")) == (180))
        #expect((AssetAccounting.billingCycleDays("lifetime")) == (-1))
        #expect((AssetAccounting.billingCycleDays(0)) == (365))
        #expect((AssetAccounting.billingCycleDays(nil)) == (365))
        #expect((AssetAccounting.annual(node(cycle: 360), cny: 100)) == (100))
        #expect((AssetAccounting.annual(node(cycle: 730), cny: 100)) == (50))
        #expect((AssetAccounting.annual(node(cycle: 90), cny: 100)) == (400))
        #expect((AssetAccounting.annual(node(cycle: 30), cny: 100)) == (1200))
        #expect((AssetAccounting.annual(node(cycle: -1), cny: 100)) == (0))
    }

    @Test func testPartialAndUnpricedSummariesDoNotInventValues() {
        let partial = AssetAccounting.summary(nodes: [node(), node(currency: "$"), node(price: 0)], rates: nil, now: now)
        #expect((partial.remainingCNY) == (100))
        #expect((partial.countedNodes) == (1))
        #expect((partial.missingRateNodes) == (1))
        #expect((partial.freeOrUnpricedNodes) == (1))
        #expect(AssetAccounting.summary(nodes: [node(currency: "XYZ")], rates: nil, now: now).remainingCNY == nil)
        #expect((AssetAccounting.summary(nodes: [node(price: 0)], rates: nil, now: now).remainingCNY) == (0))
    }

    @Test func testRateResponseAndCacheFreshness() throws {
        let data = Data(#"[{"quote":"CNY","rate":7,"date":"2026-09-09"},{"quote":"EUR","rate":0.9,"date":"2026-09-09"}]"#.utf8)
        let snapshot = try ExchangeRateSnapshot.parse(data, now: now)
        #expect((snapshot.rates["USD"]) == (1))
        #expect((snapshot.rates["CNY"]) == (7))
        #expect(!snapshot.isStale(at: now.addingTimeInterval(3_599)))
        #expect(snapshot.isStale(at: now.addingTimeInterval(3_600)))
        #expect(snapshot.isStale(at: now.addingTimeInterval(-1)))
        #expect((try? ExchangeRateSnapshot.parse(Data("[]".utf8))) == nil)
        let invalid = Data(#"[{"quote":"CNY","rate":0,"date":"2026-09-09"}]"#.utf8)
        #expect((try? ExchangeRateSnapshot.parse(invalid)) == nil)
    }

    @Test func testParsesServerBillingFields() {
        let parsed = parseNodeInfo(["uuid": "paid", "name": "Paid node", "price": 12.50, "currency": "$", "billing_cycle": 365, "traffic_limit_type": "max", "expired_at": "2030-01-01T00:00:00Z"])
        #expect((parsed?.price) == (12.50))
        #expect((parsed?.currency) == ("$"))
        #expect((parsed?.billingCycleDays) == (365))
        #expect((parsed?.trafficLimitType) == ("max"))
        #expect(parsed?.expiresAt != nil)
    }
}

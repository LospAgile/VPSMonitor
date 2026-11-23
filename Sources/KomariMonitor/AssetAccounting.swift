import Foundation

struct ExchangeRateSnapshot: Equatable, Codable, Sendable {
    var rates: [String: Double]
    var asOf: String?
    var fetchedAt: Date

    var isValid: Bool {
        rates["USD"] == 1 && rates["CNY"].map { $0.isFinite && $0 > 0 } == true
    }

    var isStale: Bool { isStale(at: Date()) }

    func isStale(at now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age < 0 || age >= 3_600
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        struct Rate: Decodable { let quote: String; let rate: Double; let date: String }
        let rows = try JSONDecoder().decode([Rate].self, from: data)
        var rates = ["USD": 1.0]
        for row in rows where row.rate.isFinite && row.rate > 0 {
            rates[row.quote.uppercased()] = row.rate
        }
        let snapshot = Self(rates: rates, asOf: rows.map(\.date).min(), fetchedAt: now)
        guard snapshot.isValid else { throw URLError(.cannotParseResponse) }
        return snapshot
    }
}

struct AssetSummary: Equatable, Sendable {
    var remainingCNY: Double?
    var annualCNY: Double?
    var countedNodes: Int
    var freeOrUnpricedNodes: Int
    var missingRateNodes: Int
}

enum AssetAccounting {
    // Keep the deployed LuminaPlus cost summary's currency and billing conventions.
    private static let aliases: [String: String] = {
        let groups: [String: [String]] = [
            "USD": ["$", "US$", "$US", "USD$", "$USD", "美元", "美金"],
            "EUR": ["€", "欧元"], "CNY": ["¥", "￥", "RMB", "CN¥", "人民币", "元"],
            "HKD": ["HK$", "港币", "港元"], "TWD": ["NT$", "台币", "新台币"],
            "JPY": ["JP¥", "日元", "円"], "GBP": ["£", "英镑"],
            "SGD": ["S$", "新币", "新加坡元"], "AUD": ["A$", "AU$", "澳元"],
            "CAD": ["C$", "CA$", "加元"]
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { code, names in
            (names + [code]).map { ($0, code) }
        })
    }()

    static func currency(_ value: String) -> String {
        let text = value.uppercased().filter { !$0.isWhitespace }.replacingOccurrences(of: "＄", with: "$")
        if text.isEmpty { return "CNY" }
        if let code = aliases[text] { return code }
        return text.range(of: "^[A-Z]{3}$", options: .regularExpression) == nil ? "" : text
    }

    static func billingCycleDays(_ raw: Any?) -> Int {
        let text = raw.map { String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        if let days = Double(text), days.isFinite, days < Double(Int.max), (days == -1 || days >= 1) {
            return Int(days)
        }
        switch text {
        case "monthly", "month", "mo", "月", "每月", "月付": return 30
        case "quarterly", "quarter", "季", "季度", "每季", "季付": return 90
        case "semiannual", "semiannually", "semi-annual", "semi-annually", "halfyear", "half-year", "半年", "半年付": return 180
        case "lifetime", "once", "one-time", "永久", "一次性", "买断": return -1
        default: return 365
        }
    }

    static func cnyPrice(_ node: NodeInfo, rates: [String: Double]) -> Double? {
        guard node.price.isFinite, node.price > 0 else { return nil }
        let code = currency(node.currency)
        if code == "CNY" { return node.price }
        guard let source = rates[code], let cny = rates["CNY"],
              source.isFinite, source > 0, cny.isFinite, cny > 0 else { return nil }
        let converted = node.price / source * cny
        return converted.isFinite ? converted : nil
    }

    static func remaining(_ node: NodeInfo, cny: Double, now: Date = Date()) -> Double {
        guard let expiry = node.expiresAt else { return cny }
        let seconds = expiry.timeIntervalSince(now)
        guard seconds > 0 else { return 0 }
        if seconds / (86_400 * 365) > 100 { return cny }
        let days = billingCycleDays(node.billingCycleDays)
        guard days > 0 else { return cny }
        // Prepaid multiple cycles can legitimately exceed a single cycle's price.
        return cny * seconds / (Double(days) * 86_400)
    }

    static func annual(_ node: NodeInfo, cny: Double) -> Double {
        let days = billingCycleDays(node.billingCycleDays)
        guard days > 0 else { return 0 }
        let months: Double
        if days == 365 || days == 360 { months = 12 }
        else if days % 365 == 0 { months = Double(days) / 365 * 12 }
        else { months = Double(days) / 30 }
        return cny / months * 12
    }

    static func summary(nodes: [NodeInfo], rates: [String: Double]?, now: Date = Date()) -> AssetSummary {
        var remainingTotal = 0.0, annualTotal = 0.0
        var counted = 0, unpriced = 0, missing = 0
        for node in nodes {
            guard node.price.isFinite, node.price > 0 else { unpriced += 1; continue }
            guard let price = cnyPrice(node, rates: rates ?? [:]) else { missing += 1; continue }
            counted += 1
            remainingTotal += remaining(node, cny: price, now: now)
            annualTotal += annual(node, cny: price)
        }
        let unavailable = counted == 0 && missing > 0
        return AssetSummary(
            remainingCNY: unavailable ? nil : remainingTotal,
            annualCNY: unavailable ? nil : annualTotal,
            countedNodes: counted, freeOrUnpricedNodes: unpriced, missingRateNodes: missing
        )
    }
}

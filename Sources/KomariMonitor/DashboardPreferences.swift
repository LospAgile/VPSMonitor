import AppKit

enum DashboardAppearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum DashboardPreferences {
    static let appearanceKey = "monitor.dashboard.appearance"
    static let refreshKey = "monitor.dashboard.refreshSeconds"
    static let pausedKey = "monitor.dashboard.paused"
    static let refreshIntervals: [TimeInterval] = [2, 5, 10, 30]

    static func refreshInterval(in defaults: UserDefaults) -> TimeInterval {
        let interval = defaults.double(forKey: refreshKey)
        return refreshIntervals.contains(interval) ? interval : 5
    }

    static func prepare(_ defaults: UserDefaults, legacyValues: [String: Any]? = nil) {
        // A separate preview can inherit these display preferences once without
        // copying credentials or writing back into the daily application's domain.
        for key in [appearanceKey, refreshKey, pausedKey] where defaults.object(forKey: key) == nil {
            if let value = legacyValues?[key] { defaults.set(value, forKey: key) }
        }
        let appearance = DashboardAppearance(rawValue: defaults.string(forKey: appearanceKey) ?? "") ?? .system
        defaults.set(appearance.rawValue, forKey: appearanceKey)
        defaults.set(refreshInterval(in: defaults), forKey: refreshKey)
        defaults.set(defaults.bool(forKey: pausedKey), forKey: pausedKey)
    }
}

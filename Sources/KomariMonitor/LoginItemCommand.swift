import Foundation
import ServiceManagement

enum LoginItemCommand {
    // Run inside the signed app bundle so ServiceManagement uses its real identity.
    static func runIfRequested() -> Int32? {
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.first == "--login-item" else { return nil }
        guard arguments.count == 2, let action = arguments.last,
              ["status", "enable", "disable"].contains(action),
              Bundle.main.bundleURL.pathExtension == "app" else {
            print("Usage: VPSMonitor --login-item status|enable|disable (inside an app bundle)")
            return 64
        }

        let service = SMAppService.mainApp
        let before = service.status
        var result: [String: Any] = [
            "action": action,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "bundlePath": Bundle.main.bundleURL.path,
            "before": name(before)
        ]
        var exitCode: Int32 = 0
        do {
            if action == "enable", before != .enabled { try service.register() }
            if action == "disable", before != .notRegistered { try service.unregister() }
            let after = service.status
            if action == "enable", after != .enabled { exitCode = 1 }
            if action == "disable", after != .notRegistered { exitCode = 1 }
        } catch {
            let error = error as NSError
            result["errorDomain"] = error.domain
            result["errorCode"] = error.code
            result["error"] = error.localizedDescription
            exitCode = 1
        }
        result["status"] = name(service.status)
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let output = String(data: data, encoding: .utf8) { print(output) }
        return exitCode
    }

    private static func name(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }
}

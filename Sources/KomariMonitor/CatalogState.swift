import Foundation

enum KomariAPIError: LocalizedError {
    case http(Int), rpc(Int), invalidResponse
    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): return "Komari 拒绝访问，请检查连接凭据或访问规则。"
        case .http(let code): return "Komari 请求失败（HTTP \(code)）。"
        case .rpc(let code): return "Komari 接口返回错误（\(code)）。"
        case .invalidResponse: return "Komari 返回的数据不完整，已保留上次结果。"
        }
    }
}

func validateHTTP(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else { throw KomariAPIError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else { throw KomariAPIError.http(http.statusCode) }
}

// A malformed entry must reject the full snapshot, never masquerade as a deletion.
func parseCatalog(_ value: Any) throws -> [NodeInfo] {
    let records: [[String: Any]]
    if let list = value as? [Any] {
        guard let typed = list as? [[String: Any]] else { throw KomariAPIError.invalidResponse }
        records = typed
    } else if let map = value as? [String: Any] {
        if let wrapped = map["nodes"] { return try parseCatalog(wrapped) }
        records = try map.map { key, value in
            guard var record = value as? [String: Any], !key.isEmpty,
                  record["uuid"] == nil || record["uuid"] as? String == key else { throw KomariAPIError.invalidResponse }
            record["uuid"] = key
            return record
        }
    } else { throw KomariAPIError.invalidResponse }
    var ids = Set<String>()
    return try records.map { record in
        guard let id = record["uuid"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record["name"] is String, let node = parseNodeInfo(record), ids.insert(id).inserted else {
            throw KomariAPIError.invalidResponse
        }
        return node
    }
}

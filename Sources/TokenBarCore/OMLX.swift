import Foundation
import Security

/// A TokenBar override for an authenticated local oMLX instance.
public enum OMLXCredentials {
    private static let service = "local.tokenbar.omlx"

    private static func query(port: Int) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: String(port)]
    }

    public static func key(port: Int) -> String? {
        var query = query(port: port)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty key removes the override, allowing the server's own configuration.
    public static func save(_ key: String, port: Int) throws {
        let query = query(port: port)
        let status: OSStatus
        if key.isEmpty {
            status = SecItemDelete(query as CFDictionary)
        } else {
            let attributes = [kSecValueData as String: Data(key.utf8)]
            let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updated == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            } else {
                status = updated
            }
        }
        guard status == errSecSuccess || (key.isEmpty && status == errSecItemNotFound) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

struct OMLXConfiguration {
    let port: Int
    let apiKey: String?

    init(args: [String], environment: [String: String], settings: Data?) {
        let root = settings.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let server = root?["server"] as? [String: Any]
        let auth = root?["auth"] as? [String: Any]
        let configuredPort = (server?["port"] as? NSNumber)?.intValue
        let candidate = LocalServerParsing.option("--port", in: args).flatMap(Int.init)
            ?? environment["OMLX_PORT"].flatMap(Int.init) ?? configuredPort ?? 8000
        port = (1...65535).contains(candidate) ? candidate : 8000
        apiKey = [LocalServerParsing.option("--api-key", in: args), environment["OMLX_API_KEY"], auth?["api_key"] as? String]
            .compactMap { $0 }.first { !$0.isEmpty }
    }

    static func load(args: [String], environment: [String: String]) -> OMLXConfiguration {
        let bootstrap = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/oMLX/base-path")
        let savedBase = (try? String(contentsOf: bootstrap, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = LocalServerParsing.option("--base-path", in: args) ?? environment["OMLX_BASE_PATH"]
            ?? savedBase.flatMap { $0.isEmpty ? nil : $0 } ?? "~/.omlx"
        let url = URL(fileURLWithPath: (base as NSString).expandingTildeInPath).appendingPathComponent("settings.json")
        return OMLXConfiguration(args: args, environment: environment, settings: try? Data(contentsOf: url))
    }
}

extension LocalServerParsing {
    static func omlx(_ data: Data, into server: inout LocalServer) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = root["active_models"] as? [String: Any] else {
            server.status = .notAnswering
            return
        }
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }
            return n.doubleValue
        }
        func bytes(_ value: Any?) -> UInt64? {
            guard let n = number(value), n < Double(UInt64.max) else { return nil }
            return UInt64(n)
        }
        func count(_ value: Any?) -> Int? {
            guard let n = number(value), n < Double(Int.max) else { return nil }
            return Int(n)
        }
        server.memoryUsed = bytes(active["model_memory_used"])
        server.memoryLimit = bytes(active["model_memory_max"])
        server.limitSource = server.memoryLimit == nil ? nil : .server
        server.decodeTokensPerSecond = number(root["avg_generation_tps"])
        server.prefillTokensPerSecond = number(root["avg_prefill_tps"])
        server.inputTokens = count(root["total_prompt_tokens"])
        server.outputTokens = count(root["total_completion_tokens"])
        server.requestsCompleted = count(root["total_requests"])
        server.queued = count(active["total_waiting_requests"])
        let models = active["models"] as? [[String: Any]] ?? []
        let names = models.compactMap { $0["id"] as? String }
        server.model = names.isEmpty ? nil : names.joined(separator: ", ")
    }
}

import Foundation

/// Pure response parsers. Field names come from live responses captured on 2026-10-14
/// (Claude, Codex, Copilot) and from Token Monitor's fixtures (Antigravity).
public enum Parsers {

    // MARK: Claude: GET api.anthropic.com/api/oauth/usage

    public static func claude(_ data: Data, plan: String?, now: Date = Date()) throws -> LimitsReading {
        let root = try jsonObject(data)
        let named: [(key: String, label: String, kind: WindowKind)] = [
            ("five_hour", "5-hour", .session),
            ("seven_day", "Weekly", .weekly),
            ("seven_day_opus", "Weekly Opus", .weekly),
            ("seven_day_sonnet", "Weekly Sonnet", .weekly),
        ]
        let windows = named.compactMap { entry -> LimitWindow? in
            guard let w = root[entry.key] as? [String: Any] else { return nil }
            return LimitWindow(
                label: entry.label,
                kind: entry.kind,
                usedPercent: number(w["utilization"]),
                resetsAt: isoDate(w["resets_at"])
            )
        }
        return LimitsReading(plan: plan, windows: windows, observedAt: now)
    }

    // MARK: Codex: last `token_count` event in ~/.codex/sessions/**/*.jsonl

    /// Returns the `rate_limits` of the last event in `text` that carries a window, or nil.
    /// A partial first line (from reading only the file's tail) fails to parse and is skipped.
    /// Once the limit is hit, Codex appends a `limit_id: "premium"` event with null windows,
    /// which would otherwise hide the real reading.
    public static func codexLastRateLimits(_ text: Substring) -> [String: Any]? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let payload = obj["payload"] as? [String: Any],
                let limits = payload["rate_limits"] as? [String: Any],
                limits["primary"] is [String: Any] || limits["secondary"] is [String: Any]
            else { continue }
            return limits
        }
        return nil
    }

    public static func codex(_ limits: [String: Any], observedAt: Date, now: Date = Date()) -> LimitsReading {
        let windows = ["primary", "secondary"].compactMap { key -> LimitWindow? in
            guard let w = limits[key] as? [String: Any] else { return nil }
            let minutes = number(w["window_minutes"])
            let resetsAt = number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            // The event is a snapshot from the last turn. A window whose reset time has
            // passed since then is empty now, not still at the old percentage.
            let elapsed = resetsAt.map { $0 <= now } ?? false
            return LimitWindow(
                label: codexLabel(minutes: minutes),
                kind: minutes == 300 ? .session : (minutes == 10080 ? .weekly : .other),
                usedPercent: elapsed ? 0 : number(w["used_percent"]),
                resetsAt: elapsed ? nil : resetsAt
            )
        }
        return LimitsReading(plan: limits["plan_type"] as? String, windows: windows, observedAt: observedAt)
    }

    static func codexLabel(minutes: Double?) -> String {
        switch minutes {
        case 300: "5-hour"
        case 10080: "Weekly"
        case let m? where m >= 60: "\(Int(m / 60))-hour"
        case let m?: "\(Int(m))-minute"
        case nil: "Window"
        }
    }

    // MARK: Copilot: GET api.github.com/copilot_internal/user

    public static func copilot(_ data: Data, now: Date = Date()) throws -> LimitsReading {
        let root = try jsonObject(data)
        let snapshots = root["quota_snapshots"] as? [String: Any] ?? [:]
        let resetsAt = dayDate(root["quota_reset_date"])
        let named: [(key: String, label: String)] = [
            ("premium_interactions", "Premium requests"),
            ("chat", "Chat"),
            ("completions", "Completions"),
        ]
        let windows = named.compactMap { entry -> LimitWindow? in
            guard let s = snapshots[entry.key] as? [String: Any],
                  (s["unlimited"] as? Bool) != true,
                  let remaining = number(s["percent_remaining"])
            else { return nil }
            return LimitWindow(label: entry.label, kind: .monthly, usedPercent: 100 - remaining, resetsAt: resetsAt)
        }
        return LimitsReading(plan: root["copilot_plan"] as? String, windows: windows, observedAt: now)
    }

    // MARK: Antigravity: IDE language server RetrieveUserQuotaSummary or `agy -p /quota --output-format json`

    public static func antigravity(_ data: Data, now: Date = Date()) throws -> LimitsReading {
        let root = try jsonObject(data)
        let cliData = (root["command"] as? [String: Any])?["data"] as? [String: Any]
        let summary = cliData ?? ((root["response"] ?? root["summary"]) as? [String: Any] ?? root)
        var windows: [LimitWindow] = []
        for group in summary["groups"] as? [[String: Any]] ?? [] {
            let rawGroupName = (group["displayName"] ?? group["name"]) as? String
            let groupName = antigravityGroupName(rawGroupName)
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let kind = antigravityBucketKind(bucket) else { continue }
                let remaining = (bucket["disabled"] as? Bool) == true ? nil : antigravityRemaining(bucket)
                windows.append(LimitWindow(
                    label: "\(groupName) \(kind == .session ? "5-hour" : "weekly")",
                    kind: kind,
                    usedPercent: remaining.map { (1 - $0) * 100 },
                    resetsAt: isoDate(bucket["resetTime"] ?? bucket["reset_time"])
                ))
            }
        }
        return LimitsReading(plan: nil, windows: windows, observedAt: now)
    }

    static func antigravityGroupName(_ name: String?) -> String {
        let lower = (name ?? "").lowercased()
        if lower.contains("argon") { return "Gemini Argon" }
        if lower.contains("gemini") { return "Gemini" }
        if lower.contains("claude") || lower.contains("gpt") { return "Claude/GPT" }
        return name?.isEmpty == false ? name! : "Quota"
    }

    static func antigravityBucketKind(_ bucket: [String: Any]) -> WindowKind? {
        let aliases: Set<String> = ["session", "5h", "5-hour", "five hour", "five-hour", "five-hour limit", "five hour limit"]
        for key in ["window", "bucketId", "id", "displayName", "name"] {
            guard let raw = bucket[key] as? String else { continue }
            let value = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-")
            if value == "weekly" || value.hasSuffix("-weekly") || value == "weekly limit" { return .weekly }
            if aliases.contains(value) || aliases.contains(where: { value.hasSuffix("-\($0)") }) { return .session }
        }
        return nil
    }

    static func antigravityRemaining(_ bucket: [String: Any]) -> Double? {
        if let direct = number(bucket["remainingFraction"] ?? bucket["remaining_fraction"]) { return direct }
        guard let remaining = bucket["remaining"] as? [String: Any] else { return nil }
        if let fraction = number(remaining["remainingFraction"] ?? remaining["remaining_fraction"]) { return fraction }
        if remaining["case"] as? String == "remainingFraction" { return number(remaining["value"]) }
        return nil
    }

    // MARK: Helpers

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.failed("Unexpected response shape")
        }
        return obj
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber where !(n === kCFBooleanTrue || n === kCFBooleanFalse): n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// ISO 8601 with or without fractional seconds of any precision
    /// (Claude sends microseconds, which ISO8601DateFormatter rejects).
    static func isoDate(_ value: Any?) -> Date? {
        guard var text = value as? String, !text.isEmpty else { return nil }
        if let range = text.range(of: #"\.\d+"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return try? Date(text, strategy: .iso8601)
    }

    /// `YYYY-MM-DD` (start of that day in UTC) or full ISO 8601.
    static func dayDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if text.count == 10 { return isoDate(text + "T00:00:00Z") }
        return isoDate(text)
    }
}

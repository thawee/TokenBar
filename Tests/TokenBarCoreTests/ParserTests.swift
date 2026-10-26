import Foundation
import Testing
@testable import TokenBarCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func claudeReadsNamedWindowsAndMicrosecondDates() throws {
    let reading = try Parsers.claude(fixture("claude-usage.json"), plan: "max")
    #expect(reading.plan == "max")
    #expect(reading.windows.map(\.label) == ["5-hour", "Weekly", "Weekly Sonnet"])
    #expect(reading.windows[0].usedPercent == 11)
    #expect(reading.windows[0].kind == .session)
    let reset = try #require(reading.windows[0].resetsAt)
    #expect(reset == Date(timeIntervalSince1970: 1_791_975_599))
    #expect(reading.windows[2].resetsAt == nil)
}

@Test func codexUsesLastNonNullRateLimits() throws {
    let text = String(decoding: try fixture("codex-session.jsonl"), as: UTF8.self)
    let limits = try #require(Parsers.codexLastRateLimits(text[...]))
    let before = Date(timeIntervalSince1970: 1_791_950_000)
    let reading = Parsers.codex(limits, observedAt: before, now: before)
    #expect(reading.windows.map(\.label) == ["5-hour", "Weekly"])
    #expect(reading.windows.map(\.usedPercent) == [65, 26])
    #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_791_959_517))
}

@Test func codexWindowPastItsResetShowsEmpty() throws {
    let text = String(decoding: try fixture("codex-session.jsonl"), as: UTF8.self)
    let limits = try #require(Parsers.codexLastRateLimits(text[...]))
    let afterSession = Date(timeIntervalSince1970: 1_791_960_000)
    let reading = Parsers.codex(limits, observedAt: afterSession, now: afterSession)
    #expect(reading.windows[0].usedPercent == 0)
    #expect(reading.windows[0].resetsAt == nil)
    #expect(reading.windows[1].usedPercent == 26)
}

@Test func codexWithoutRateLimitsReturnsNil() {
    #expect(Parsers.codexLastRateLimits(#"{"type":"event_msg","payload":{"rate_limits":null}}"#[...]) == nil)
}

@Test func codexSkipsTrailingEventWithoutWindows() throws {
    // Shape Codex writes after the usage limit is hit (seen 2026-10-26).
    let text = #"""
    {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":100.0,"window_minutes":300,"resets_at":1792990959},"secondary":{"used_percent":47.0,"window_minutes":10080,"resets_at":1793513602}}}}
    {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"plan_type":null}}}
    """#
    let limits = try #require(Parsers.codexLastRateLimits(text[...]))
    let reading = Parsers.codex(limits, observedAt: Date(timeIntervalSince1970: 1_792_980_000), now: Date(timeIntervalSince1970: 1_792_980_000))
    #expect(reading.windows.map(\.usedPercent) == [100, 47])
}

@Test func copilotSkipsUnlimitedAndConvertsRemaining() throws {
    let reading = try Parsers.copilot(fixture("copilot-user.json"))
    #expect(reading.plan == "business")
    #expect(reading.windows.map(\.label) == ["Premium requests"])
    #expect(reading.windows[0].usedPercent == 15)
    #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_793_491_200))
}

@Test func antigravityMapsBucketsAndDisabledToUnknown() throws {
    let reading = try Parsers.antigravity(fixture("antigravity-summary.json"))
    #expect(reading.windows.map(\.label) == ["Claude/GPT weekly", "Claude/GPT 5-hour", "Gemini weekly", "Gemini 5-hour"])
    let used = reading.windows.map { $0.usedPercent.map { ($0 * 10).rounded() / 10 } }
    #expect(used == [36, 27, nil, 9])
    #expect(reading.windows[1].kind == .session)
}

@Test func antigravityFlagParsing() {
    let command = "/x/extensions/antigravity/bin/language_server --csrf_token abc123 --other=1"
    #expect(AntigravityProvider.flag("--csrf_token", in: command) == "abc123")
    #expect(AntigravityProvider.flag("--other", in: command) == "1")
    #expect(AntigravityProvider.flag("--missing", in: command) == nil)
}

@Test func antigravityParsesCLIQuotaOutput() throws {
    let cliJSON = Data(#"""
    {
      "status": "SUCCESS",
      "command": {
        "name": "usage",
        "data": {
          "groups": [
            {
              "name": "Gemini Models",
              "buckets": [
                {"id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.98, "reset_time": "2026-10-23T01:45:33Z"},
                {"id": "gemini-5h", "window": "5h", "remaining_fraction": 0.96, "reset_time": "2026-10-16T06:45:33Z"}
              ]
            },
            {
              "name": "Claude and GPT models",
              "buckets": [
                {"id": "3p-weekly", "window": "weekly", "remaining_fraction": 1.0, "reset_time": "2026-10-23T02:14:27Z"},
                {"id": "3p-5h", "window": "5h", "remaining_fraction": 1.0, "reset_time": "2026-10-16T07:14:27Z"}
              ]
            },
            {
              "name": "Gemini 4 Argon",
              "buckets": [
                {"id": "gemini-argon-wtu-weekly", "window": "weekly", "remaining_fraction": 0.75, "reset_time": "2026-10-23T01:33:15Z"}
              ]
            }
          ]
        }
      }
    }
    """#.utf8)
    let reading = try Parsers.antigravity(cliJSON)
    #expect(reading.windows.map(\.label) == [
        "Gemini weekly", "Gemini 5-hour", "Claude/GPT weekly", "Claude/GPT 5-hour", "Gemini Argon weekly",
    ])
    let used = reading.windows.map { $0.usedPercent.map { Int($0.rounded()) } }
    #expect(used == [2, 4, 0, 0, 25])
    #expect(reading.headlineWindow?.label == "Gemini 5-hour")
}

@Test func percentIsClamped() {
    #expect(LimitWindow(label: "x", kind: .other, usedPercent: 140, resetsAt: nil).usedPercent == 100)
}


import Foundation

public protocol LimitsProvider: Sendable {
    var id: ProviderID { get }
    /// Seconds between fetches. Local sources are cheap; network ones are throttled.
    var minInterval: TimeInterval { get }
    func fetch() async throws -> LimitsReading
}

private let home = FileManager.default.homeDirectoryForCurrentUser

// MARK: Claude Code

/// Reads the OAuth token Claude Code keeps in the Keychain. Never refreshes it:
/// refreshing would rotate the token out from under Claude Code and force a re-login.
public struct ClaudeProvider: LimitsProvider {
    public let id = ProviderID.claude
    public let minInterval: TimeInterval = 300
    public init() {}

    public func fetch() async throws -> LimitsReading {
        let oauth = try readCredentials()
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ProviderError.notConfigured("Not signed in to Claude Code")
        }
        if let expiresMs = Parsers.number(oauth["expiresAt"]), expiresMs / 1000 < Date().timeIntervalSince1970 {
            throw ProviderError.unauthorized("Token expired. Run Claude Code once to refresh it.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let data = try await HTTP.send(request)
        return try Parsers.claude(data, plan: oauth["subscriptionType"] as? String)
    }

    private func readCredentials() throws -> [String: Any] {
        // /usr/bin/security is already trusted by the item's ACL; a native SecItem read
        // from this ad-hoc signed app would prompt again after every rebuild.
        if let text = try? Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
           let oauth = Self.oauth(from: Data(text.utf8)) {
            return oauth
        }
        let file = home.appending(path: ".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let oauth = Self.oauth(from: data) {
            return oauth
        }
        throw ProviderError.notConfigured("Claude Code credentials not found")
    }

    private static func oauth(from data: Data) -> [String: Any]? {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return root?["claudeAiOauth"] as? [String: Any]
    }
}

// MARK: Codex

/// Codex writes its rate limits into every `token_count` event of the session log,
/// so this needs no network and no credentials.
public struct CodexProvider: LimitsProvider {
    public let id = ProviderID.codex
    public let minInterval: TimeInterval = 30
    public init() {}

    /// Only the tail is read; the latest event is always near the end.
    static let tailBytes = 512 * 1024

    public func fetch() async throws -> LimitsReading {
        let root = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(filePath: $0) }
            ?? home.appending(path: ".codex")
        let sessions = root.appending(path: "sessions")
        guard FileManager.default.fileExists(atPath: sessions.path) else {
            throw ProviderError.notConfigured("No Codex sessions found")
        }
        for file in recentSessionFiles(in: sessions) {
            guard let text = try? Self.readTail(of: file.url),
                  let limits = Parsers.codexLastRateLimits(text[...])
            else { continue }
            return Parsers.codex(limits, observedAt: file.modified)
        }
        throw ProviderError.notConfigured("No rate limit data in recent Codex sessions")
    }

    /// Newest first, from the `YYYY/MM/DD` folders of the last 8 days only: older data
    /// says nothing about a weekly window, and walking the whole history would grow forever.
    /// Codex names folders by local Gregorian date regardless of the system calendar.
    private func recentSessionFiles(in dir: URL, now: Date = Date()) -> [(url: URL, modified: Date)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        var files: [(URL, Date)] = []
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = dir.appending(path: String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".jsonl") {
                let url = folder.appending(path: name)
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate
                else { continue }
                files.append((url, modified))
            }
        }
        return files.sorted { $0.1 > $1.1 }
    }

    static func readTail(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    }
}

// MARK: GitHub Copilot

/// Uses the token the Copilot editor plugins store in ~/.config/github-copilot.
public struct CopilotProvider: LimitsProvider {
    public let id = ProviderID.copilot
    public let minInterval: TimeInterval = 300
    public init() {}

    public func fetch() async throws -> LimitsReading {
        guard let token = Self.readToken() else {
            throw ProviderError.notConfigured("Copilot not signed in")
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        let data = try await HTTP.send(request)
        return try Parsers.copilot(data)
    }

    static func readToken() -> String? {
        let dir = home.appending(path: ".config/github-copilot")
        for name in ["apps.json", "hosts.json"] {
            guard let data = try? Data(contentsOf: dir.appending(path: name)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
            else { continue }
            // Keys look like "github.com" or "github.com:<app id>".
            for (key, entry) in root where key.hasPrefix("github.com") {
                if let token = entry["oauth_token"] as? String, !token.isEmpty { return token }
            }
        }
        return nil
    }
}

// MARK: Antigravity

/// Asks the Antigravity IDE's local language server, which needs no Google sign-in.
/// The server's CSRF token is on its command line and its port comes from lsof.
public struct AntigravityProvider: LimitsProvider {
    public let id = ProviderID.antigravity
    public let minInterval: TimeInterval = 120
    public init() {}

    static let method = "exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    static let appPaths = ["/Applications/Antigravity.app", home.appending(path: "Applications/Antigravity.app").path]

    public func fetch() async throws -> LimitsReading {
        guard let server = try Self.findServer() else {
            if !Self.appPaths.contains(where: FileManager.default.fileExists(atPath:)) {
                throw ProviderError.notConfigured("Antigravity not installed")
            }
            throw ProviderError.notRunning("Open Antigravity to see its limits")
        }
        let ports = try Self.listeningPorts(pid: server.pid)
        var lastError: Error = ProviderError.failed("Language server did not answer")
        for port in ports {
            for scheme in ["https", "http"] {
                var request = URLRequest(url: URL(string: "\(scheme)://127.0.0.1:\(port)/\(Self.method)")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 3
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
                request.setValue(server.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
                request.httpBody = Data(#"{"forceRefresh":true}"#.utf8)
                do {
                    let data = try await HTTP.send(request, session: HTTP.loopback)
                    return try Parsers.antigravity(data)
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError
    }

    static func findServer() throws -> (pid: Int32, csrfToken: String)? {
        let output = try Shell.run("/bin/ps", ["-axww", "-o", "pid=,command="])
        for line in output.split(separator: "\n") where line.contains("/extensions/antigravity/bin/language_server") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]),
                  let token = flag("--csrf_token", in: String(parts[1]))
            else { continue }
            return (pid, token)
        }
        return nil
    }

    static func flag(_ name: String, in command: String) -> String? {
        let tokens = command.split(separator: " ").map(String.init)
        for (i, token) in tokens.enumerated() {
            if token == name, i + 1 < tokens.count { return tokens[i + 1] }
            if token.hasPrefix(name + "=") { return String(token.dropFirst(name.count + 1)) }
        }
        return nil
    }

    static func listeningPorts(pid: Int32) throws -> [Int] {
        let output = try Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)])
        let regex = /:(\d+) \(LISTEN\)/
        let ports = output.split(separator: "\n").compactMap { line in
            line.firstMatch(of: regex).flatMap { Int($0.1) }
        }
        guard !ports.isEmpty else { throw ProviderError.failed("Language server has no listening port") }
        return Array(Set(ports)).sorted()
    }
}

// MARK: Shared plumbing

enum Shell {
    /// Runs a tool and returns stdout. Kills it after `timeout` so a stuck `lsof` or a
    /// Keychain prompt left unanswered cannot stall the refresh loop.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let watchdog = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        let name = URL(filePath: path).lastPathComponent
        if process.terminationReason == .uncaughtSignal {
            throw ProviderError.failed("\(name) timed out")
        }
        guard process.terminationStatus == 0 else {
            throw ProviderError.failed("\(name) exited \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HTTP {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Accepts the self-signed certificate of a local server, and only for 127.0.0.1.
    static let loopback: URLSession = URLSession(
        configuration: .ephemeral, delegate: LoopbackTrust(), delegateQueue: nil
    )

    static func send(_ request: URLRequest, session: URLSession = shared) async throws -> Data {
        var request = request
        request.setValue("TokenBar/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401, 403: throw ProviderError.unauthorized("Sign-in rejected (HTTP \(status))")
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.failed("HTTP \(status)")
        }
    }
}

final class LoopbackTrust: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

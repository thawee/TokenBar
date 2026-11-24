import Foundation

/// The last reading per tool, kept on disk so the dock shows numbers at launch instead
/// of waiting on the network. Stale until the first refresh replaces them.
public struct ReadingCache: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: ReadingCache {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ReadingCache(url: support.appending(path: "TokenBar/readings.json"))
    }

    /// Empty when the file is missing or unreadable (an older or newer format).
    public func load() -> [ProviderID: LimitsReading] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: LimitsReading].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, reading in
            ProviderID(rawValue: key).map { ($0, reading) }
        })
    }

    public func save(_ readings: [ProviderID: LimitsReading]) {
        let stored = Dictionary(uniqueKeysWithValues: readings.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

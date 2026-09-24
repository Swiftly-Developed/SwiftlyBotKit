import Foundation

/// Failed sign-in throttling, in memory.
///
/// Per process rather than shared, which is the known weakness: with several
/// app instances an attacker gets the allowance once per instance. Acceptable
/// for a single-owner page whose password should be a long random value, and
/// cheaper than a shared store with its own table and migration.
actor LoginAttemptLimiter {
    let maximumFailures: Int
    let window: TimeInterval

    private var failures: [String: [Date]] = [:]

    init(limit: BotKitConfiguration.LoginLimit = .default) {
        self.maximumFailures = limit.maximumFailures
        self.window = limit.window
    }

    func isBlocked(_ key: String, now: Date = Date()) -> Bool {
        prune(key, now: now)
        return (failures[key]?.count ?? 0) >= maximumFailures
    }

    func recordFailure(_ key: String, now: Date = Date()) {
        prune(key, now: now)
        failures[key, default: []].append(now)
    }

    func reset(_ key: String) {
        failures[key] = nil
    }

    private func prune(_ key: String, now: Date) {
        failures[key] = failures[key]?.filter { now.timeIntervalSince($0) < window }
        if failures[key]?.isEmpty == true { failures[key] = nil }
    }
}

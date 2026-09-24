import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Failed sign-in throttling, in memory.
///
/// Two limits, both over the same sliding window:
///
/// - **Per client**, keyed by the client's address (IPv6 by its /64, since
///   one subscriber owns at least that many addresses).
/// - **Process-wide**, a ceiling on failures from every client together. The
///   per-client key is only as honest as the client-IP strategy: behind a
///   misconfigured proxy, or with the app reachable directly, a client can
///   rotate `X-Forwarded-For` and get a fresh allowance per guess. The global
///   ceiling bounds the total number of guesses regardless. When it trips,
///   every sign-in is refused until the window passes, the owner's included.
///   That lockout is deliberate: it is the price of a hard bound.
///
/// An attempt is reserved (counted as a failure) *before* the password is
/// compared, in the same actor call as the check, so a concurrent burst cannot
/// have several requests pass the check before any failure is recorded. A
/// successful sign-in then releases its reservation.
///
/// Per process rather than shared, which is the known weakness: with several
/// app instances an attacker gets the allowance once per instance. Acceptable
/// for a single-owner page whose password should be a long random value, and
/// cheaper than a shared store with its own table and migration.
actor LoginAttemptLimiter {

    /// The process-wide ceiling used by default: fifty failures per window,
    /// or the per-client limit if that is higher.
    static let defaultGlobalMaximumFailures = BotKitConfiguration.LoginLimit.default.globalMaximumFailures

    /// The most client keys held at once. The global ceiling already bounds
    /// how many keys a window can create through `reserve`; this is a second
    /// bound for direct `recordFailure` callers.
    static let defaultMaximumTrackedKeys = 10_000

    /// The outcome of ``reserve(_:now:)``.
    enum Reservation: Equatable {
        /// The attempt may be evaluated. It is already counted as a failure;
        /// call ``succeeded(_:reservation:)`` if the credentials match.
        case allowed(Date)
        /// This client has used its allowance for the window.
        case blocked
        /// Every client together has hit the process-wide ceiling.
        case globallyBlocked
    }

    let maximumFailures: Int
    let globalMaximumFailures: Int
    let window: TimeInterval
    let maximumTrackedKeys: Int

    private var failures: [String: [Date]] = [:]
    /// Every failure across all keys, oldest first.
    private var globalFailures: [Date] = []
    private var lastSweep: Date = .distantPast
    private var globalTripReported = false

    init(
        limit: BotKitConfiguration.LoginLimit = .default,
        globalMaximumFailures: Int? = nil,
        maximumTrackedKeys: Int = LoginAttemptLimiter.defaultMaximumTrackedKeys
    ) {
        // Nonsensical limits are clamped rather than obeyed: a limit below 1
        // would refuse the owner's first attempt forever, and a window that
        // is not positive (or not finite) would silently disable throttling.
        let perClient = max(1, limit.maximumFailures)
        self.maximumFailures = perClient
        self.window = limit.window.isFinite && limit.window >= 1
            ? limit.window
            : (limit.window.isFinite ? 1 : BotKitConfiguration.LoginLimit.default.window)
        // `globalMaximumFailures` overrides the configured ceiling (tests).
        self.globalMaximumFailures = max(
            globalMaximumFailures ?? limit.globalMaximumFailures,
            perClient
        )
        self.maximumTrackedKeys = max(1, maximumTrackedKeys)
    }

    // MARK: Atomic check and record

    /// Checks both limits and, when neither is reached, counts the attempt as
    /// a failure, all in one actor turn.
    func reserve(_ key: String, now: Date = Date()) -> Reservation {
        sweepIfDue(now: now)
        prune(key, now: now)
        pruneGlobal(now: now)
        if (failures[key]?.count ?? 0) >= maximumFailures { return .blocked }
        if globalFailures.count >= globalMaximumFailures { return .globallyBlocked }
        append(key, at: now)
        return .allowed(now)
    }

    /// Releases a reservation after a successful sign-in and clears the
    /// client's failures.
    func succeeded(_ key: String, reservation: Date) {
        failures[key] = nil
        if let index = globalFailures.lastIndex(of: reservation) {
            globalFailures.remove(at: index)
        }
    }

    /// `true` exactly once per trip of the global ceiling, so the caller can
    /// log it loudly without logging every refused request.
    func shouldReportGlobalTrip(now: Date = Date()) -> Bool {
        pruneGlobal(now: now)
        guard globalFailures.count >= globalMaximumFailures else {
            globalTripReported = false
            return false
        }
        defer { globalTripReported = true }
        return !globalTripReported
    }

    // MARK: Separate calls (tests and diagnostics)

    func isBlocked(_ key: String, now: Date = Date()) -> Bool {
        sweepIfDue(now: now)
        prune(key, now: now)
        return (failures[key]?.count ?? 0) >= maximumFailures
    }

    func recordFailure(_ key: String, now: Date = Date()) {
        sweepIfDue(now: now)
        prune(key, now: now)
        pruneGlobal(now: now)
        append(key, at: now)
    }

    func reset(_ key: String) {
        failures[key] = nil
    }

    // MARK: Bookkeeping

    private func append(_ key: String, at now: Date) {
        if failures[key] == nil, failures.count >= maximumTrackedKeys {
            sweep(now: now)
            if failures.count >= maximumTrackedKeys { evictOldest() }
        }
        failures[key, default: []].append(now)
        globalFailures.append(now)
    }

    private func prune(_ key: String, now: Date) {
        failures[key] = failures[key]?.filter { now.timeIntervalSince($0) < window }
        if failures[key]?.isEmpty == true { failures[key] = nil }
    }

    private func pruneGlobal(now: Date) {
        let firstLive = globalFailures.firstIndex { now.timeIntervalSince($0) < window } ?? globalFailures.endIndex
        if firstLive > 0 { globalFailures.removeFirst(firstLive) }
    }

    /// A full sweep at most once per tenth of a window, so the dictionary is
    /// bounded by the live window without an O(n) pass on every request.
    private func sweepIfDue(now: Date) {
        guard now.timeIntervalSince(lastSweep) >= max(window / 10, 1) || now < lastSweep else { return }
        sweep(now: now)
    }

    private func sweep(now: Date) {
        lastSweep = now
        for key in Array(failures.keys) { prune(key, now: now) }
    }

    private func evictOldest() {
        guard let oldest = failures.min(by: { ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast) })
        else { return }
        failures[oldest.key] = nil
    }

    // MARK: Keys

    /// The bucket a client address is throttled under: an IPv4 address as is,
    /// an IPv6 address by its /64 (an IPv4-mapped IPv6 address as its IPv4
    /// address), anything unparseable as the raw string.
    static func bucket(for address: String) -> String {
        var candidate = address.trimmingCharacters(in: .whitespaces)
        if candidate.hasPrefix("["), let close = candidate.firstIndex(of: "]") {
            candidate = String(candidate[candidate.index(after: candidate.startIndex)..<close])
        }
        if let zone = candidate.firstIndex(of: "%") {
            candidate = String(candidate[..<zone])
        }
        guard candidate.contains(":") else { return candidate }

        var storage = in6_addr()
        let parsed = candidate.withCString { inet_pton(AF_INET6, $0, &storage) }
        guard parsed == 1 else { return candidate }
        let bytes = withUnsafeBytes(of: &storage) { Array($0) }
        guard bytes.count == 16 else { return candidate }

        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return bytes[12..<16].map(String.init).joined(separator: ".")
        }
        let prefix = bytes[0..<8].map { String(format: "%02x", $0) }.joined()
        return "v6/64:\(prefix)"
    }
}

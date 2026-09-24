import Foundation

extension BotKitTimeZone {

    /// The case for an IANA identifier.
    ///
    /// A canonical name gives its named case, and a legacy or
    /// backward-compatible name gives the canonical case it now means:
    /// `Asia/Calcutta` is ``asiaKolkata``, `US/Eastern` is ``americaNewYork``,
    /// `Etc/UTC` is ``utc``. Any other name Foundation knows becomes
    /// ``custom(_:)``. `nil` when Foundation does not know the identifier at all.
    public init?(identifier: String) {
        if let named = Self.byIdentifier[identifier] {
            self = named
        } else if let canonical = Self.legacyIdentifiers[identifier] {
            self = canonical
        } else if let timeZone = TimeZone(identifier: identifier) {
            self = .custom(timeZone)
        } else {
            return nil
        }
    }

    /// Whether this platform's tz database has the zone.
    ///
    /// `false` for a zone newer than the host's tzdata, for example
    /// `America/Coyhaique` (tzdata 2025b) under the Foundation that ships with
    /// Swift 6.0 and 6.1 on Linux. Such a zone is drawn in UTC, see
    /// ``foundationTimeZone``.
    public var isAvailable: Bool {
        if case .custom = self { return true }
        return TimeZone(identifier: identifier) != nil
    }

    /// The Foundation time zone every bucket is computed in.
    ///
    /// When this platform's tz database lacks the zone (``isAvailable`` is
    /// `false`), this is UTC. The fallback is visible, not silent: the
    /// dashboard names the zone it actually used under the chart, and
    /// PostgreSQL is not involved, so there is no second zone that could
    /// disagree with it.
    public var foundationTimeZone: TimeZone {
        if case .custom(let timeZone) = self { return timeZone }
        return TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 0)!
    }

    /// Two values are equal when they mean the same zone:
    /// `.custom(TimeZone(identifier: "Asia/Tokyo")!)` equals ``asiaTokyo``, and
    /// a `.custom` zone under a legacy name equals its canonical case.
    public static func == (lhs: BotKitTimeZone, rhs: BotKitTimeZone) -> Bool {
        lhs.canonicalIdentifier == rhs.canonicalIdentifier
    }

    /// Hashes the canonical identifier, consistent with ``==(_:_:)``.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalIdentifier)
    }

    /// The named case's identifier for a `.custom` zone that has one,
    /// otherwise ``identifier``.
    private var canonicalIdentifier: String {
        guard case .custom(let timeZone) = self else { return identifier }
        let name = timeZone.identifier
        if let named = Self.byIdentifier[name] ?? Self.legacyIdentifiers[name] {
            return named.identifier
        }
        return name
    }

    private static let byIdentifier: [String: BotKitTimeZone] = Dictionary(
        uniqueKeysWithValues: allNamed.map { ($0.identifier, $0) }
    )
}

import Foundation

extension BotKitTimeZone {

    /// The named case for an IANA identifier, or ``custom(_:)`` when the
    /// identifier is valid but not in the list. `nil` when Foundation does not
    /// know the identifier at all.
    public init?(identifier: String) {
        if let named = Self.byIdentifier[identifier] {
            self = named
        } else if let timeZone = TimeZone(identifier: identifier) {
            self = .custom(timeZone)
        } else {
            return nil
        }
    }

    /// The Foundation time zone. Falls back to UTC if this platform's tz
    /// database lacks the zone, so Swift and PostgreSQL still agree on
    /// ``identifier`` of the zone actually used.
    public var foundationTimeZone: TimeZone {
        if case .custom(let timeZone) = self { return timeZone }
        return TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 0)!
    }

    private static let byIdentifier: [String: BotKitTimeZone] = Dictionary(
        uniqueKeysWithValues: allNamed.map { ($0.identifier, $0) }
    )
}

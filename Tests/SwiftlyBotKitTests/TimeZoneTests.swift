import XCTest
import FluentKit
@testable import SwiftlyBotKit

final class TimeZoneTests: XCTestCase {

    func testNamedCasesMapToTheirIANAIdentifiers() {
        XCTAssertEqual(BotKitTimeZone.utc.identifier, "UTC")
        XCTAssertEqual(BotKitTimeZone.americaNewYork.identifier, "America/New_York")
        XCTAssertEqual(BotKitTimeZone.europeBrussels.identifier, "Europe/Brussels")
        XCTAssertEqual(BotKitTimeZone.americaPortAuPrince.identifier, "America/Port-au-Prince")
        XCTAssertEqual(BotKitTimeZone.americaArgentinaBuenosAires.identifier, "America/Argentina/Buenos_Aires")
    }

    /// The list is the canonical IANA one: no legacy spellings, and the
    /// current names present.
    func testNamedCasesAreCanonical() {
        XCTAssertGreaterThan(BotKitTimeZone.allNamed.count, 400)
        XCTAssertEqual(Set(BotKitTimeZone.allNamed).count, BotKitTimeZone.allNamed.count)
        let identifiers = Set(BotKitTimeZone.allNamed.map(\.identifier))
        for legacy in ["Asia/Calcutta", "Europe/Kiev", "Asia/Katmandu", "Asia/Rangoon", "America/Godthab",
                       "Pacific/Truk", "Pacific/Ponape", "Pacific/Enderbury", "Antarctica/South_Pole",
                       "Asia/Choibalsan", "Europe/Uzhgorod", "Europe/Zaporozhye"] {
            XCTAssertFalse(identifiers.contains(legacy), legacy)
        }
        for canonical in ["Asia/Kolkata", "Europe/Kyiv", "Asia/Kathmandu", "Asia/Yangon", "America/Nuuk",
                          "Pacific/Chuuk", "Pacific/Pohnpei", "Pacific/Kanton", "Europe/Amsterdam"] {
            XCTAssertTrue(identifiers.contains(canonical), canonical)
        }
    }

    /// Nearly every case is known to this platform's Foundation. A zone newer
    /// than the host tzdata (on Linux, `America/Coyhaique` under Swift 6.0
    /// and 6.1) is reported by `isAvailable` and consistently drawn in UTC.
    func testNamedCasesAreKnownToFoundationOrFallBackToUTC() {
        var unavailable: [String] = []
        for zone in BotKitTimeZone.allNamed {
            if zone.isAvailable {
                let tz = zone.foundationTimeZone
                XCTAssertEqual(TimeZone(identifier: zone.identifier)?.secondsFromGMT(for: Date()),
                               tz.secondsFromGMT(for: Date()), zone.identifier)
            } else {
                unavailable.append(zone.identifier)
                XCTAssertNil(TimeZone(identifier: zone.identifier))
                XCTAssertEqual(zone.foundationTimeZone.secondsFromGMT(for: Date()), 0, zone.identifier)
                XCTAssertEqual(zone.foundationTimeZone.nextDaylightSavingTimeTransition(after: Date()), nil)
            }
        }
        if !unavailable.isEmpty {
            print("BotKitTimeZone cases this Foundation lacks, drawn in UTC: \(unavailable)")
        }
        XCTAssertLessThanOrEqual(unavailable.count, 10, "\(unavailable)")
        XCTAssertTrue(BotKitTimeZone.utc.isAvailable)
        XCTAssertEqual(BotKitTimeZone.utc.foundationTimeZone.secondsFromGMT(), 0)
    }

    func testInitFromIdentifier() {
        XCTAssertEqual(BotKitTimeZone(identifier: "Asia/Tokyo"), .asiaTokyo)
        XCTAssertEqual(BotKitTimeZone(identifier: "UTC"), .utc)
        XCTAssertEqual(BotKitTimeZone(identifier: "Etc/UTC"), .utc)
        XCTAssertNil(BotKitTimeZone(identifier: "Not/AZone"))
    }

    /// Legacy names resolve to the canonical case, never to `.custom`.
    func testLegacyIdentifiersMapToCanonicalCases() {
        XCTAssertEqual(BotKitTimeZone(identifier: "Asia/Calcutta"), .asiaKolkata)
        XCTAssertEqual(BotKitTimeZone(identifier: "Europe/Kiev"), .europeKyiv)
        XCTAssertEqual(BotKitTimeZone(identifier: "Pacific/Truk"), .pacificChuuk)
        XCTAssertEqual(BotKitTimeZone(identifier: "US/Eastern"), .americaNewYork)
        XCTAssertEqual(BotKitTimeZone(identifier: "Antarctica/South_Pole"), .antarcticaMcMurdo)
    }

    /// The deprecated aliases are the canonical case, so they compare equal.
    @available(*, deprecated)
    func testDeprecatedAliasesAreTheCanonicalCase() {
        XCTAssertEqual(BotKitTimeZone.asiaCalcutta, .asiaKolkata)
        XCTAssertEqual(BotKitTimeZone.europeKiev, .europeKyiv)
        XCTAssertEqual(BotKitTimeZone.asiaCalcutta.identifier, "Asia/Kolkata")
    }

    /// A fixed offset keeps its sign: nothing is ever handed to PostgreSQL by
    /// name, so the POSIX sign inversion cannot bite.
    func testFixedOffsetCustomZone() {
        let zone = BotKitTimeZone.custom(TimeZone(secondsFromGMT: 3_600)!)
        XCTAssertTrue(zone.isAvailable)
        XCTAssertEqual(zone.foundationTimeZone.secondsFromGMT(), 3_600)
        let now = Date(timeIntervalSince1970: 1_774_785_600) // 12:00 UTC
        XCTAssertEqual(BotDateRange.day.axisLabel(for: now, in: zone.foundationTimeZone), "13:00")
    }

    func testCustomZonePassesThrough() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let zone = BotKitTimeZone.custom(tokyo)
        XCTAssertEqual(zone.foundationTimeZone, tokyo)
        XCTAssertEqual(zone.identifier, "Asia/Tokyo")
    }

    /// Equality is by the zone meant, not by the case used to spell it.
    func testCustomEqualsTheNamedCaseForTheSameZone() {
        XCTAssertEqual(BotKitTimeZone.custom(TimeZone(identifier: "Asia/Tokyo")!), .asiaTokyo)
        XCTAssertEqual(Set([BotKitTimeZone.custom(TimeZone(identifier: "Asia/Tokyo")!), .asiaTokyo]).count, 1)
        XCTAssertEqual(BotKitTimeZone.custom(TimeZone(identifier: "Asia/Calcutta")!), .asiaKolkata)
        XCTAssertEqual(BotKitTimeZone.custom(TimeZone(identifier: "Asia/Calcutta")!).hashValue, BotKitTimeZone.asiaKolkata.hashValue)
        XCTAssertEqual(BotKitTimeZone.custom(TimeZone(secondsFromGMT: 0)!), .utc)
        XCTAssertEqual(BotKitTimeZone.custom(TimeZone(secondsFromGMT: 3_600)!), .custom(TimeZone(secondsFromGMT: 3_600)!))
        XCTAssertNotEqual(BotKitTimeZone.custom(TimeZone(secondsFromGMT: 3_600)!), .utc)
        XCTAssertNotEqual(BotKitTimeZone.europeParis, .europeBrussels)
    }

    func testDashboardTakesAnEnumCase() {
        var config = BotKitConfiguration()
        XCTAssertEqual(config.dashboard.timeZone, .utc)
        config.dashboard.timeZone = .americaNewYork
        XCTAssertEqual(config.dashboard.timeZone.foundationTimeZone.identifier, "America/New_York")
    }

    func testDatabaseDefaultsToTheAppsDefaultDatabase() {
        XCTAssertNil(BotKitConfiguration().database)
        XCTAssertEqual(BotKitConfiguration(database: DatabaseID(string: "analytics")).database, DatabaseID(string: "analytics"))
    }
}

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

    func testEveryNamedCaseIsAKnownFoundationZone() {
        XCTAssertGreaterThan(BotKitTimeZone.allNamed.count, 400)
        XCTAssertEqual(Set(BotKitTimeZone.allNamed).count, BotKitTimeZone.allNamed.count)
        for zone in BotKitTimeZone.allNamed {
            XCTAssertNotNil(TimeZone(identifier: zone.identifier), zone.identifier)
            // Foundation names UTC "GMT" on some platforms; both mean the same to PostgreSQL.
            guard zone != .utc else { continue }
            XCTAssertEqual(zone.foundationTimeZone.identifier, zone.identifier)
        }
        XCTAssertEqual(BotKitTimeZone.utc.foundationTimeZone.secondsFromGMT(), 0)
    }

    func testInitFromIdentifier() {
        XCTAssertEqual(BotKitTimeZone(identifier: "Asia/Tokyo"), .asiaTokyo)
        XCTAssertEqual(BotKitTimeZone(identifier: "UTC"), .utc)
        XCTAssertNil(BotKitTimeZone(identifier: "Not/AZone"))
    }

    func testCustomZonePassesThrough() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let zone = BotKitTimeZone.custom(tokyo)
        XCTAssertEqual(zone.foundationTimeZone, tokyo)
        XCTAssertEqual(zone.identifier, "Asia/Tokyo")
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

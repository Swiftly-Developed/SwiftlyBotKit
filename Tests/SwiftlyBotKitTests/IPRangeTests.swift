import XCTest
@testable import SwiftlyBotKit

final class IPRangeTests: XCTestCase {

    func testIPv4Matching() {
        let range = IPRange(cidr: "20.171.207.0/24")
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains("20.171.207.1"))
        XCTAssertTrue(range!.contains("20.171.207.255"))
        XCTAssertFalse(range!.contains("20.171.208.1"))
        XCTAssertFalse(range!.contains("20.171.206.255"))
    }

    /// A /28 exercises the partial-byte mask, which a byte-aligned test misses.
    func testPartialByteMask() {
        let range = IPRange(cidr: "104.210.140.128/28")
        XCTAssertTrue(range!.contains("104.210.140.128"))
        XCTAssertTrue(range!.contains("104.210.140.143"))
        XCTAssertFalse(range!.contains("104.210.140.144"))
        XCTAssertFalse(range!.contains("104.210.140.127"))
    }

    func testSingleHostAndFullRange() {
        XCTAssertTrue(IPRange(cidr: "107.20.236.150/32")!.contains("107.20.236.150"))
        XCTAssertFalse(IPRange(cidr: "107.20.236.150/32")!.contains("107.20.236.151"))
        XCTAssertTrue(IPRange(cidr: "0.0.0.0/0")!.contains("8.8.8.8"))
    }

    func testIPv6Matching() {
        let range = IPRange(cidr: "2600:1f1c::/32")
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains("2600:1f1c:0:1::5"))
        XCTAssertFalse(range!.contains("2600:1f1d::1"))
    }

    /// A dual-stack hop can hand us `::ffff:1.2.3.4`. Left unfolded, every such
    /// request would fall outside the vendors' IPv4 blocks and read as a spoof.
    func testIPv4MappedIPv6IsFoldedBack() {
        let range = IPRange(cidr: "20.171.207.0/24")
        XCTAssertTrue(range!.contains("::ffff:20.171.207.9"))
    }

    func testAddressFamiliesDoNotCross() {
        XCTAssertFalse(IPRange(cidr: "20.171.207.0/24")!.contains("2600:1f1c::1"))
        XCTAssertFalse(IPRange(cidr: "2600:1f1c::/32")!.contains("20.171.207.1"))
    }

    func testMalformedInputIsRejectedRatherThanCrashing() {
        XCTAssertNil(IPRange(cidr: "not-an-address/24"))
        XCTAssertNil(IPRange(cidr: "20.171.207.0"))
        XCTAssertNil(IPRange(cidr: "20.171.207.0/33"))
        XCTAssertNil(IPRange(cidr: ""))
        XCTAssertFalse(IPRange(cidr: "20.171.207.0/24")!.contains("garbage"))
    }
}

final class CrawlerFeedDecodingTests: XCTestCase {

    /// The shape of `chatgpt-user.json`, which OpenAI serves as
    /// `application/octet-stream`. Feeds are decoded from bytes, so the label
    /// cannot stop them; this is the body that used to 415.
    private let chatGPTUserFeed = Data("""
    {"creationTime": "2026-09-23T00:00:00.000000",
     "prefixes": [{"ipv4Prefix": "104.208.184.192/28"},
                  {"ipv4Prefix": "104.210.139.192/28"},
                  {"ipv6Prefix": "2a06:98c0:3600::/48"}]}
    """.utf8)

    func testFeedBodyDecodesWithoutAContentType() throws {
        let ranges = try CrawlerIPDirectory.ranges(fromFeed: chatGPTUserFeed)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertTrue(ranges.contains { $0.contains("104.208.184.200") })
        XCTAssertFalse(ranges.contains { $0.contains("104.208.184.208") })
    }

    /// An entry with neither prefix, or one that does not parse, is skipped
    /// rather than failing the whole feed.
    func testUnusableEntriesAreSkipped() throws {
        let body = Data(#"{"prefixes": [{}, {"ipv4Prefix": "not-a-cidr"}, {"ipv4Prefix": "216.73.216.0/22"}]}"#.utf8)
        let ranges = try CrawlerIPDirectory.ranges(fromFeed: body)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertTrue(ranges[0].contains("216.73.219.255"))
    }

    /// An HTML error page served with a 200 must fail loudly, so the refresh
    /// logs it and keeps the ranges it already holds.
    func testNonJSONBodyThrows() {
        XCTAssertThrowsError(try CrawlerIPDirectory.ranges(fromFeed: Data("<html>".utf8)))
    }
}

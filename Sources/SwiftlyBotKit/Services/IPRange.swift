import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif

/// One CIDR block, e.g. `20.171.207.0/24` or `2600:1f1c::/32`.
///
/// Deliberately hand-rolled rather than pulled in as a dependency: the vendor
/// feeds only ever contain plain CIDR.
///
/// Parsing is strict and identical on every platform. `inet_pton` alone is not:
/// Darwin and glibc disagree on IPv4 octets with leading zeros, and a Swift
/// string reaches it as a C string, so everything after an embedded NUL would
/// be silently ignored. So every address is checked here first, and only the
/// plain forms reach `inet_pton`:
///
/// - IPv4: exactly four dot-separated decimal octets, each `0` to `255`,
///   without leading zeros (`020.1.2.3` is rejected, since some parsers read
///   it as octal).
/// - IPv6: hex digits, `:` and, for an embedded IPv4 tail, `.` only. Zone ids
///   (`fe80::1%en0`), whitespace, NUL and any other character are rejected.
public struct IPRange: Sendable, Equatable {
    private let network: [UInt8]
    /// The number of leading bits that must match.
    let prefixLength: Int

    /// `true` for an IPv4 block, `false` for IPv6.
    var isIPv4: Bool { network.count == 4 }

    /// `nil` for anything that is not a well-formed CIDR block, so a vendor
    /// feed that changes shape degrades to "no ranges" rather than crashing.
    public init?(cidr: String) {
        let parts = cidr.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              (1...3).contains(parts[1].utf8.count),
              parts[1].utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let length = Int(parts[1]),
              let bytes = Self.parse(address: String(parts[0])),
              length >= 0, length <= bytes.count * 8
        else { return nil }
        // An IPv4-mapped block (`::ffff:1.2.3.0/120`) would fold to four bytes
        // with a prefix length meant for sixteen. Vendors never publish one.
        if bytes.count == 4, parts[0].contains(":") { return nil }
        self.network = bytes
        self.prefixLength = length
    }

    /// Whether `address` (IPv4, IPv6, or IPv4-mapped IPv6) falls inside this
    /// block. `false` for anything that does not parse, and across address
    /// families.
    public func contains(_ address: String) -> Bool {
        guard let bytes = Self.parse(address: address) else { return false }
        return contains(bytes)
    }

    func contains(_ address: [UInt8]) -> Bool {
        // An IPv4 address is never inside an IPv6 block, and vice versa.
        guard address.count == network.count else { return false }
        var remaining = prefixLength
        var index = 0
        while remaining >= 8 {
            if address[index] != network[index] { return false }
            index += 1
            remaining -= 8
        }
        guard remaining > 0 else { return true }
        let mask = UInt8(truncatingIfNeeded: Int(0xFF) << (8 - remaining))
        return (address[index] & mask) == (network[index] & mask)
    }

    /// 4 bytes for IPv4, 16 for IPv6, `nil` for anything else.
    ///
    /// An IPv4-mapped IPv6 address (`::ffff:1.2.3.4`) is folded back to its 4
    /// bytes, because the vendors publish IPv4 blocks and a dual-stack hop can
    /// hand us the mapped form. Left alone, every such request would look like
    /// a spoof. No other IPv6 form that embeds an IPv4 address is folded.
    static func parse(address: String) -> [UInt8]? {
        let utf8 = address.utf8
        guard !utf8.isEmpty, utf8.count <= 45 else { return nil }
        if !utf8.contains(UInt8(ascii: ":")) {
            return parseIPv4(address)
        }
        // IPv6: hex digits, colons, and dots for an embedded IPv4 tail only.
        guard utf8.allSatisfy({ isHexDigit($0) || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: ".") })
        else { return nil }
        if utf8.contains(UInt8(ascii: ".")) {
            // The tail after the last colon must itself be a strict IPv4.
            guard let lastColon = address.lastIndex(of: ":"),
                  parseIPv4(String(address[address.index(after: lastColon)...])) != nil
            else { return nil }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        guard bytes.count == 16 else { return nil }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return Array(bytes[12..<16])
        }
        return bytes
    }

    /// Four decimal octets, `0` to `255`, no leading zeros, nothing else.
    private static func parseIPv4(_ address: String) -> [UInt8]? {
        let octets = address.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for octet in octets {
            guard (1...3).contains(octet.count),
                  octet.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  octet.count == 1 || octet.first != UInt8(ascii: "0")
            else { return nil }
            let value = octet.reduce(0) { $0 * 10 + Int($1 - 0x30) }
            guard value <= 255 else { return nil }
            bytes.append(UInt8(value))
        }
        return bytes
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }
}

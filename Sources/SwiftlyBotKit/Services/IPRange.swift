import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// One CIDR block, e.g. `20.171.207.0/24` or `2600:1f1c::/32`.
///
/// Deliberately hand-rolled rather than pulled in as a dependency: it is forty
/// lines, and the vendor feeds only ever contain plain CIDR. Parsing goes through `inet_pton`, which
/// behaves the same on Darwin and on Linux.
public struct IPRange: Sendable, Equatable {
    private let network: [UInt8]
    private let prefixLength: Int

    /// `nil` for anything that is not a well-formed CIDR block, so a vendor
    /// feed that changes shape degrades to "no ranges" rather than crashing.
    public init?(cidr: String) {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let length = Int(parts[1]),
              let bytes = Self.parse(address: String(parts[0])),
              length >= 0, length <= bytes.count * 8
        else { return nil }
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

    /// 4 bytes for IPv4, 16 for IPv6.
    ///
    /// An IPv4-mapped IPv6 address (`::ffff:1.2.3.4`) is folded back to its 4
    /// bytes, because the vendors publish IPv4 blocks and a dual-stack hop can
    /// hand us the mapped form. Left alone, every such request would look like
    /// a spoof.
    static func parse(address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let raw = v4.s_addr.bigEndian
            return [
                UInt8(truncatingIfNeeded: raw >> 24),
                UInt8(truncatingIfNeeded: raw >> 16),
                UInt8(truncatingIfNeeded: raw >> 8),
                UInt8(truncatingIfNeeded: raw),
            ]
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
}

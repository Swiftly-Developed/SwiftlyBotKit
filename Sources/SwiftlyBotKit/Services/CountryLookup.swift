import Foundation

/// IP address to country, from a table held in memory.
///
/// The address is looked up and dropped: nothing about it is kept, logged or
/// sent anywhere. The table is a local file, so no third party ever sees the
/// address either, which is what keeps this inside the legitimate-interest
/// basis the page view dimensions rely on.
///
/// The file is written by `Scripts/update-country-database.py` from DB-IP's
/// free "IP to Country Lite" database (CC BY 4.0). Its layout, all integers
/// big-endian:
///
/// | Bytes | Holds |
/// |---|---|
/// | 4 | magic `BKCC` |
/// | 1 | format version, `1` |
/// | 2 | length of the attribution text, then that many bytes of UTF-8 |
/// | 4, 4 | number of IPv4 and IPv6 ranges |
/// | 4 each | IPv4 range starts, ascending |
/// | 2 each | their country codes, ASCII |
/// | 8 each | IPv6 range starts, upper 64 bits, ascending |
/// | 2 each | their country codes, ASCII |
///
/// Ranges are contiguous, so a start is all a range needs: an address belongs
/// to the last range starting at or below it. IPv6 is kept to its upper 64
/// bits, the routing prefix; no country boundary sits inside a /64 in
/// practice.
public struct CountryLookup: Sendable {

    /// The code for an address the table does not place: a private,
    /// reserved or unparseable one.
    public static let unknown = "ZZ"

    /// Who the data comes from, shown on the dashboard as the licence asks.
    public let attribution: String

    private let v4Starts: [UInt32]
    private let v4Codes: [UInt16]
    private let v6Starts: [UInt64]
    private let v6Codes: [UInt16]

    /// The number of ranges loaded, IPv4 and IPv6 together.
    public var rangeCount: Int { v4Starts.count + v6Starts.count }

    /// Why a country file could not be read.
    public enum LoadError: Error, CustomStringConvertible, Equatable {
        case unreadable(String)
        case malformed(String)

        public var description: String {
            switch self {
            case .unreadable(let detail): return "The country database could not be read: \(detail)"
            case .malformed(let detail): return "The country database is not in the expected format: \(detail)"
            }
        }
    }

    /// Loads the table at `path`.
    public init(contentsOfFile path: String) throws {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw LoadError.unreadable("\(path): \(error.localizedDescription)")
        }
        try self.init(data: data)
    }

    /// Reads a table in the layout above.
    public init(data: Data) throws {
        var reader = Reader(bytes: [UInt8](data))
        guard reader.take(4) == Array("BKCC".utf8) else { throw LoadError.malformed("missing BKCC header") }
        guard let version = reader.integer(UInt8.self), version == 1 else {
            throw LoadError.malformed("unsupported format version")
        }
        guard let attributionLength = reader.integer(UInt16.self),
              let attributionBytes = reader.take(Int(attributionLength)),
              let attribution = String(bytes: attributionBytes, encoding: .utf8),
              let v4Count = reader.integer(UInt32.self),
              let v6Count = reader.integer(UInt32.self)
        else { throw LoadError.malformed("truncated header") }
        guard let v4Starts = reader.integers(UInt32.self, count: Int(v4Count)),
              let v4Codes = reader.codes(count: Int(v4Count)),
              let v6Starts = reader.integers(UInt64.self, count: Int(v6Count)),
              let v6Codes = reader.codes(count: Int(v6Count))
        else { throw LoadError.malformed("truncated ranges or an invalid country code") }
        guard reader.isAtEnd else { throw LoadError.malformed("unexpected bytes after the ranges") }
        guard zip(v4Starts, v4Starts.dropFirst()).allSatisfy({ $0 <= $1 }),
              zip(v6Starts, v6Starts.dropFirst()).allSatisfy({ $0 <= $1 })
        else { throw LoadError.malformed("range starts are not in ascending order") }
        self.attribution = attribution
        self.v4Starts = v4Starts
        self.v4Codes = v4Codes
        self.v6Starts = v6Starts
        self.v6Codes = v6Codes
    }

    /// The ISO 3166-1 alpha-2 code for `address`, or ``unknown``.
    public func country(for address: String?) -> String {
        guard let address, let bytes = IPRange.parse(address: address) else { return Self.unknown }
        let code: UInt16?
        if bytes.count == 4 {
            let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            code = Self.lastIndex(atOrBelow: value, in: v4Starts).map { v4Codes[$0] }
        } else {
            let value = bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            code = Self.lastIndex(atOrBelow: value, in: v6Starts).map { v6Codes[$0] }
        }
        guard let code else { return Self.unknown }
        return String(decoding: [UInt8(code >> 8), UInt8(code & 0xFF)], as: UTF8.self)
    }

    /// The index of the last element of the ascending `starts` that is at
    /// most `value`.
    private static func lastIndex<T: Comparable>(atOrBelow value: T, in starts: [T]) -> Int? {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= value { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset == bytes.count }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, bytes.count - offset >= count else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }

        mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
            let width = T.bitWidth / 8
            guard bytes.count - offset >= width else { return nil }
            var value: T = 0
            for byte in bytes[offset..<offset + width] { value = value << 8 | T(byte) }
            offset += width
            return value
        }

        mutating func integers<T: FixedWidthInteger>(_ type: T.Type, count: Int) -> [T]? {
            guard count >= 0, (bytes.count - offset) / (T.bitWidth / 8) >= count else { return nil }
            var values: [T] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(integer(type)!) }
            return values
        }

        /// Two uppercase ASCII letters per entry.
        mutating func codes(count: Int) -> [UInt16]? {
            guard count >= 0, (bytes.count - offset) / 2 >= count else { return nil }
            var codes: [UInt16] = []
            codes.reserveCapacity(count)
            for _ in 0..<count {
                let first = bytes[offset], second = bytes[offset + 1]
                guard (0x41...0x5A).contains(first), (0x41...0x5A).contains(second) else { return nil }
                codes.append(UInt16(first) << 8 | UInt16(second))
                offset += 2
            }
            return codes
        }
    }
}

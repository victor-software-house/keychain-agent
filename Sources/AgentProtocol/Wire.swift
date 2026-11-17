import Foundation

// The SSH wire encoding (RFC 4251, section 5) of the field types the agent protocol uses.

extension Data {
    /// Appends `value` as a big-endian uint32.
    public mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// Appends `value` as an SSH string: its length as a uint32, then its bytes.
    public mutating func appendString(_ value: Data) {
        appendUInt32(UInt32(value.count))
        append(value)
    }
}

/// Reads SSH wire fields from the front of a message body.
public struct Reader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    public mutating func uint32() -> UInt32? {
        guard offset + 4 <= data.endIndex else { return nil }
        let value = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return value
    }

    public mutating func string() -> Data? {
        guard let length = uint32(), offset + Int(length) <= data.endIndex else { return nil }
        let value = Data(data[offset..<offset + Int(length)])
        offset += Int(length)
        return value
    }
}

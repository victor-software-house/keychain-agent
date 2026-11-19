import Foundation

// The SSH encoding of the field types the agent protocol uses (RFC 4251, section 5).

extension Data {
    /// Appends `value` as a big-endian uint32.
    public mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// Appends `value` as an SSH string: its length as a uint32, then its bytes.
    public mutating func appendString(_ value: some DataProtocol) {
        appendUInt32(UInt32(value.count))
        append(contentsOf: value)
    }

    /// Appends `value` as an SSH string.
    public mutating func appendString(_ value: String) {
        appendString(Data(value.utf8))
    }

    /// Appends an unsigned big-endian magnitude as an SSH mpint.
    /// The encoding is minimal.
    /// A zero byte goes in front when the top bit is set, so the number is not negative.
    public mutating func appendMPInt(unsigned magnitude: some DataProtocol) {
        var bytes = Data(magnitude.drop { $0 == 0 })
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0, at: bytes.startIndex)
        }
        appendString(bytes)
    }
}

/// Reads SSH fields from the front of a message body.
public struct Reader: Sendable {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = Data(data)
        offset = self.data.startIndex
    }

    /// Whether every byte has been read.
    public var isAtEnd: Bool { offset == data.endIndex }

    public mutating func readByte() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    public mutating func readUInt32() -> UInt32? {
        guard data.endIndex - offset >= 4 else { return nil }
        let value = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return value
    }

    public mutating func readString() -> Data? {
        guard let length = readUInt32().map(Int.init), data.endIndex - offset >= length else { return nil }
        defer { offset += length }
        return Data(data[offset..<offset + length])
    }

    /// An SSH string that contains UTF-8 text.
    public mutating func readText() -> String? {
        readString().flatMap { String(data: $0, encoding: .utf8) }
    }

    /// An SSH mpint that must not be negative, as its unsigned big-endian magnitude.
    public mutating func readUnsignedMPInt() -> Data? {
        guard let bytes = readString() else { return nil }
        if let first = bytes.first, first & 0x80 != 0 { return nil }
        return Data(bytes.drop { $0 == 0 })
    }

    /// The bytes not read yet.
    public mutating func readRest() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset...])
    }
}

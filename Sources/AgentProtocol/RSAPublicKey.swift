import Foundation

/// An RSA public key, read from the DER PKCS#1 `RSAPublicKey` that
/// `SecKeyCopyExternalRepresentation` returns for an RSA public key.
public struct RSAPublicKey: Sendable, Equatable {
    /// The modulus and exponent as DER INTEGER contents. DER writes an INTEGER in
    /// minimal two's complement, which is also how SSH writes an mpint.
    public let modulus: Data
    public let exponent: Data

    /// Reads `SEQUENCE { modulus INTEGER, publicExponent INTEGER }`; nil when `der` is anything else.
    public init?(pkcs1 der: Data) {
        var reader = DERReader(der)
        guard reader.sequenceHeader(), let modulus = reader.integer(), let exponent = reader.integer() else {
            return nil
        }
        self.modulus = modulus
        self.exponent = exponent
    }

    /// The SSH public key blob: the string "ssh-rsa", then the exponent and the modulus as mpints.
    public var sshBlob: Data {
        var blob = Data()
        blob.appendString(Data("ssh-rsa".utf8))
        blob.appendString(exponent)
        blob.appendString(modulus)
        return blob
    }
}

/// Reads the few DER elements an `RSAPublicKey` holds.
private struct DERReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func sequenceHeader() -> Bool {
        guard tag(0x30), length() != nil else { return false }
        return true
    }

    mutating func integer() -> Data? {
        guard tag(0x02), let count = length(), offset + count <= data.endIndex else { return nil }
        let value = Data(data[offset..<offset + count])
        offset += count
        return value
    }

    private mutating func tag(_ expected: UInt8) -> Bool {
        guard offset < data.endIndex, data[offset] == expected else { return false }
        offset += 1
        return true
    }

    /// A definite length, short or long form, of at most four bytes.
    private mutating func length() -> Int? {
        guard offset < data.endIndex else { return nil }
        let first = Int(data[offset])
        offset += 1
        if first < 0x80 { return first }
        let count = first & 0x7f
        guard count > 0, count <= 4, offset + count <= data.endIndex else { return nil }
        var value = 0
        for _ in 0..<count {
            value = value << 8 | Int(data[offset])
            offset += 1
        }
        return value
    }
}

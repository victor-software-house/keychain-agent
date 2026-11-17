import Foundation

/// Reads an armored `openssh-key-v1` private key file, as `ssh-keygen` writes it.
public enum OpenSSHKeyFile {
    public enum Contents: Sendable, Equatable {
        case key(PrivateKey, comment: String)
        /// The file is encrypted with a passphrase; signd does not decrypt it.
        case protected
    }

    public enum Failure: Error, Sendable, Equatable {
        case malformed
        /// A key type signd does not serve, such as `ssh-dss`.
        case unsupportedType(String)
    }

    static let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let footer = "-----END OPENSSH PRIVATE KEY-----"
    static let magic = Data("openssh-key-v1\0".utf8)

    /// Reads the armored text of one unencrypted or protected key file.
    public static func parse(_ text: String) throws(Failure) -> Contents {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(of: header), let end = lines.firstIndex(of: footer), start < end,
              let binary = Data(base64Encoded: lines[(start + 1)..<end].joined()) else { throw .malformed }
        return try parse(binary: binary)
    }

    static func parse(binary: Data) throws(Failure) -> Contents {
        guard binary.starts(with: magic) else { throw .malformed }
        var reader = Reader(binary.dropFirst(magic.count))
        guard let cipher = reader.text(), reader.text() != nil, reader.string() != nil,
              reader.uint32() == 1, let publicBlob = reader.string(), let section = reader.string(), reader.isAtEnd else { throw .malformed }
        guard cipher == "none" else { return .protected }

        var body = Reader(section)
        guard let check = body.uint32(), body.uint32() == check else { throw .malformed }
        var peek = body
        let type = peek.text()
        guard let key = PrivateKey.read(from: &body) else {
            if let type, !isSupported(type) { throw .unsupportedType(type) }
            throw .malformed
        }
        guard let comment = body.text(), key.publicKey.blob == publicBlob else { throw .malformed }
        // Padding fills the section to the cipher block size with the bytes 1, 2, 3 and so on.
        let padding = body.rest()
        guard padding.count < 8, padding.enumerated().allSatisfy({ $0.element == UInt8($0.offset + 1) }) else { throw .malformed }
        return .key(key, comment: comment)
    }

    private static func isSupported(_ type: String) -> Bool {
        type == "ssh-ed25519" || type == "ssh-rsa" || Curve.allCases.contains { $0.keyType == type }
    }
}

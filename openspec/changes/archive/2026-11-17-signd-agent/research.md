# Research

Retrieved 2026-11-17.
Measurements ran on an Apple M4 Pro with macOS 27.2.

## 1. Libraries by concern

| Concern | Candidate | Verdict | Reason |
|:--|:--|:--|:--|
| Agent protocol | [Secretive][secretive] SSHProtocolKit, v4.0.0 | ✘, read as reference | Three defects, listed below the table |
| | [swift-nio-ssh][nio-ssh] 0.15.1 | ✘ | No agent messages, no Rivest–Shamir–Adleman (RSA) keys, signature encoding internal |
| | [Citadel][citadel] 0.12.1 | ✘ | Depends on a [personal fork][citadel-fork] of swift-nio-ssh; RSA signs with SHA-1 only |
| | Own `SSHWire` and `AgentProtocol` | ✔ | [RFC 9987][rfc9987] and OpenSSH's `PROTOCOL.agent` |
| RSA, PEM, Public-Key Cryptography Standards (PKCS), part 8 | [swift-crypto][swift-crypto] 5.1.1 `CryptoExtras` | ✔ | RSA from n, e, d, p, q, [computing the Chinese remainder theorem (CRT) values][crt] that OpenSSH files lack |
| Socket | [swift-nio][swift-nio] 2.105.0 | ✔ | Framing and back-pressure; `ServerBootstrap.bind(_:)` can also [adopt a bound socket][nio-adopt] |
| Command line | [swift-argument-parser][argparser] 1.8.2 | ✔ | Standard choice |

Secretive's SSHProtocolKit has three defects:

- It reads [only the key and data][secretive-flags] of a sign request, so RSA always signs with SHA-512.
- It [traps][secretive-assert] in a debug build outside its inter-process communication (XPC) service.
- It [turns session-bind off][secretive-bind].

No maintained Swift package parses passphrase-protected OpenSSH key files: none implements `bcrypt_pbkdf` outside Citadel's vendored C.

## 2. Timings

| Operation | p50 |
|:--|:--|
| Login-keychain 3072-bit RSA sign through `securityd` (keychain-agent 0.0.1) | 36.5 ms |
| `SecKey` 3072-bit RSA PKCS#1 v1.5 SHA-512 sign, key in memory | 2.13 ms |
| OpenSSL 3.5.9 3072-bit RSA sign | 0.94 ms |
| Secure Enclave P-256 sign | 4.58 ms |
| Secure Enclave P-256 key agreement | 4.53 ms |
| Hybrid Public Key Encryption (HPKE) open with a Secure Enclave recipient | 4.78 ms |
| Ed25519 sign in memory | 0.043 ms |
| SSH login to a Git host, key file / 1Password agent / Secure Enclave agent / keychain-agent | 150.7 / 158.7 / 199.3 / 221 ms |

BoringSSL's RSA speed in `CryptoExtras` is not measured; OpenSSL stands in for it.

## 3. Secure Enclave and keychain

1. The Secure Enclave stores P-256 keys only and cannot import a key.
   A CryptoKit key's `dataRepresentation` made by one binary also signs in another binary on the same Mac.
   The handle alone therefore does not bind a key to signd.
2. The data-protection keychain binds items to an access group.
   `keychain-access-groups` is restricted on macOS ([TN3125][tn3125]), so a binary that claims it needs a provisioning profile and an app-like bundle ([TN3137][tn3137]).
   Every local macOS profile examined allows `TEAM.*`; a `MAC_APP_DIRECT` profile is created with `POST /v1/profiles` in the App Store Connect API.
3. A LaunchAgent in the user's GUI domain can use the data-protection keychain; a launchd daemon cannot.
4. Secretive keys use `WhenUnlockedThisDeviceOnly` and fail while the screen is locked ([issue 462][secretive-462]).
   Its open [pull request 819][secretive-819] and the derived project [keylet][keylet] use `AfterFirstUnlockThisDeviceOnly` with `.privateKeyUsage` and sign while locked.
   We have not tested this ourselves; the hardware test in the design covers it.
5. GitHub-hosted macOS runners are virtual machines and have no Secure Enclave.

## 4. Wrapping keys the Secure Enclave cannot hold

CryptoKit's HPKE with `P256_SHA256_AES_GCM_256` takes a `SecureEnclave.P256.KeyAgreement.PrivateKey` as the recipient.
A round trip in an unsigned binary worked, and the open took 4.78 ms.

[age-plugin-se][age-se] uses Secure Enclave key agreement the same way for file encryption.
[ssh-tpm-agent][ssh-tpm] imports RSA and Elliptic Curve Digital Signature Algorithm (ECDSA) keys into a Trusted Platform Module (TPM) on Linux.
No SSH agent found wraps Ed25519 or RSA keys under a Secure Enclave key.

Trade-off: a wrapped key is decrypted into signd's memory while in use.
It is therefore not hardware-bound at signing time, as a Secure Enclave key is.

[secretive]: https://github.com/maxgoedjen/Secretive/tree/56c2f841ed6400b43b60c4c94c36e172e3f7407d
[secretive-flags]: https://github.com/maxgoedjen/Secretive/blob/56c2f841ed6400b43b60c4c94c36e172e3f7407d/Sources/Packages/Sources/SSHProtocolKit/SSHAgentInputParser.swift#L76-L78
[secretive-assert]: https://github.com/maxgoedjen/Secretive/blob/56c2f841ed6400b43b60c4c94c36e172e3f7407d/Sources/Packages/Sources/SSHProtocolKit/SSHAgentInputParser.swift#L19
[secretive-bind]: https://github.com/maxgoedjen/Secretive/blob/56c2f841ed6400b43b60c4c94c36e172e3f7407d/Sources/Packages/Sources/SecretAgentKit/Agent.swift#L93-L106
[secretive-462]: https://github.com/maxgoedjen/Secretive/issues/462
[secretive-819]: https://github.com/maxgoedjen/Secretive/pull/819
[keylet]: https://github.com/NikitaKurpas/keylet/blob/afb608b5ede31fa0ee2b5d37f6420beac77370b9/Sources/KeyletCore/KeyStore.swift#L14-L18
[nio-ssh]: https://github.com/apple/swift-nio-ssh/tree/d1985926494b624e751b379009dc83f3395fd88a
[citadel]: https://github.com/orlandos-nl/Citadel/tree/ae8562f895de06ccb86fdb1cbb65fd99c8976e12
[citadel-fork]: https://github.com/orlandos-nl/Citadel/blob/ae8562f895de06ccb86fdb1cbb65fd99c8976e12/Package.swift#L20
[rfc9987]: https://www.rfc-editor.org/rfc/rfc9987
[swift-crypto]: https://github.com/apple/swift-crypto/tree/9f96b82711cc4ce5816343c02eccd5ad907972d3
[crt]: https://github.com/apple/swift-crypto/blob/9f96b82711cc4ce5816343c02eccd5ad907972d3/Sources/CryptoExtras/RSA/RSA_boring.swift#L668-L699
[swift-nio]: https://github.com/apple/swift-nio/tree/b440f7bae8894b5ec42e0f1842fcd77483ab3984
[nio-adopt]: https://github.com/apple/swift-nio/blob/b440f7bae8894b5ec42e0f1842fcd77483ab3984/Sources/NIOPosix/Bootstrap.swift#L669-L693
[argparser]: https://github.com/apple/swift-argument-parser
[tn3125]: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
[tn3137]: https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
[age-se]: https://github.com/remko/age-plugin-se/blob/57ccea12fc1a3d3bb81b8866745be4d2951c4eaf/Sources/HPKE.swift#L9-L22
[ssh-tpm]: https://github.com/Foxboron/ssh-tpm-agent

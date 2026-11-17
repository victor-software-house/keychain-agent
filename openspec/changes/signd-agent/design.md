# Design

## Context

keychain-agent 0.0.1 signs through `SecKeyCreateSignature` on a login-keychain RSA key.
Each signature runs inside `securityd` and takes about 36.5 ms at p50, against 0.9 ms for the same key in OpenSSL.
Its access rule is a keychain ACL with a team-ID partition, so any binary the release team signs can use the key.

[research.md](research.md) holds the library survey, Secretive's design, and the Secure Enclave and keychain facts this design relies on.
The specs hold the requirements; this file holds how they are met.

## Goals / Non-Goals

**Goals:**

- Signing from memory in about a millisecond for Ed25519 and a few milliseconds for RSA and Secure Enclave keys.
- Keys that only signd's own signed binary can use, and that no command can export.
- One self-contained app: no Homebrew dependency, no helper the user installs, no per-key setup outside signd.
- Reusing maintained libraries for transport, cryptography and argument parsing.

**Non-Goals:**

- A graphical interface. signd is a command-line tool and an agent; an app window can come later.
- Touch ID or user-presence prompts. Headless Macs must sign while locked or over SSH; a per-key prompt option can come later.
- Smart cards, certificates and FIDO keys.
- Linux. signd depends on the Secure Enclave and the data-protection keychain.

## Decisions

### 1. An app bundle with a provisioning profile

The data-protection keychain binds an item to an access group, and only a binary whose entitlements claim that group can read the item.
`keychain-access-groups` is a restricted entitlement on macOS, so the binary needs a Developer ID provisioning profile, which needs an app-like bundle.
`Signd.app/Contents/MacOS/signd` is both the agent and the command; one set of entitlements serves both.

The release job builds the entitlements from the profile it takes from the signing secrets, so the repository holds no team ID.
The App ID `com.victor-software-house.signd` and its `MAC_APP_DIRECT` profile are created once through the App Store Connect API.

Alternative: the login keychain with a team-ID partition, as now.
Rejected: slower, and it trusts every binary the team signs.

### 2. Two key kinds in one store

| Key type | Private key | Sign | Created by |
|:--|:--|:--|:--|
| Secure Enclave P-256 | inside the Secure Enclave; the item holds its opaque handle | about 4.6 ms, in the Secure Enclave | `signd key create` |
| Wrapped (`wrapped-keys` change) | encrypted to a Secure Enclave key-agreement key with HPKE | in memory after one unwrap of about 4.8 ms | import or create |

Each key is one generic-password item in the access group, with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and no user-presence flag.
The item holds a versioned property list: name, type, public key blob, comment, hosts, source, and the key data.
"This device only" keeps items out of iCloud Keychain and backups.

`AfterFirstUnlock` lets a headless Mac sign while its screen is locked; Secretive's `WhenUnlocked` keys fail there (its issue 462).

### 3. A resident agent registered with `SMAppService`

`signd service enable` registers `Contents/Library/LaunchAgents/com.victor-software-house.signd.plist` with `SMAppService.agent`, which runs `signd serve` at login and restarts it if it exits.
`signd serve` binds `~/.ssh/signd.sock` itself, with mode 0600, after removing a stale socket.

A resident process replaces socket activation for two reasons.
A bundled plist cannot name a path in the user's home, and the `onepassword-sync` change needs a timer that runs whether or not a client connects.
The agent drops decrypted keys after `key-lifetime` (default 1 hour after last use), so staying resident does not keep keys in memory.
Idle, it holds no timers but the sync timer and uses no CPU.

Alternative: a plist written to `~/Library/LaunchAgents` by the dotfiles.
Rejected: it needs configuration outside signd, which signd's goal excludes.

### 4. SwiftNIO for the socket

NIO frames each message by its 4-byte length with `ByteToMessageDecoder`, enforces the 256 KiB limit, and handles partial reads and back-pressure.
Signing runs on `NIOThreadPool`, so a Secure Enclave call never blocks the event loop.
Each connection checks `getpeereid` against the agent's own user, and logs the peer's pid from `LOCAL_PEERPID`.

Alternative: Foundation sockets, as Secretive uses.
Rejected: Secretive treats each read as one whole message, which breaks on partial reads.

### 5. Message format and protocol targets

No maintained Swift library implements the agent protocol.
Secretive's SSHProtocolKit ignores the RSA flags, reads requests partially, and traps in debug builds outside its XPC service.
The `SSHWire` target holds the SSH string and integer encoding, public key and signature blobs, and fingerprints.
The `AgentProtocol` target holds the RFC 9987 messages.
Both are pure Swift with no platform imports, tested with fixtures recorded from OpenSSH.

Cryptography comes from CryptoKit (Secure Enclave, P-256, Ed25519, HPKE) and swift-crypto's `CryptoExtras` (RSA).
Commands and flags come from swift-argument-parser.

### 6. Message coverage

| Message | Answer |
|:--|:--|
| request identities (11) | every key's blob and comment, from memory |
| sign (13) | the signature, with the hash the flags name for RSA |
| add identity (17, 25) | a memory-only key, as `ssh-add` expects; lifetime honoured, confirm refused |
| remove identity (18), remove all (19) | memory-only keys only; stored keys are removed with `signd key delete` |
| lock (22), unlock (23) | failure |
| extension (27) | `query` lists the supported extensions; `session-bind@openssh.com` is accepted and recorded |
| anything else | failure |

`ssh-add -D` therefore cannot erase stored keys.

### 7. Configuration

`signd config set key-lifetime 30m` and similar store settings in the user defaults domain `com.victor-software-house.signd`.
The `onepassword-sync` change adds a policy item in 1Password as a second source; a local setting wins over it.

### 8. Tests by place

| Place | Runs |
|:--|:--|
| GitHub-hosted runner, each pull request | unit tests; protocol end-to-end tests against a memory store in the test target, with `ssh-add -L` and `ssh-keygen -Y sign` and `-Y verify` |
| Physical Mac, before each release | `mise run e2e:hardware`: the signed build creates a Secure Enclave key, signs, restarts, signs again, and shows that an ad-hoc signed probe cannot read the access group |

GitHub-hosted macOS runners are virtual machines without a Secure Enclave, so the hardware test cannot run there.
The release checklist records its result as evidence under the release task.

## Risks / Trade-offs

- [`SMAppService` may refuse a registration started from a shell over SSH] → Test it on a headless Mac first.
  If it refuses, `service enable` writes the plist to `~/Library/LaunchAgents` and boots it with `launchctl`, and the decision is recorded here.
- [The linked `signd` command may not resolve its bundle or entitlements] → Test `codesign -d --entitlements -` and one keychain call through the link before release.
- [The `TEAM.*` wildcard in the profile lets any app of the same team claim the group] → Accepted: only the release team can sign such an app, and the team ships no other app that claims it.
- [Before first unlock after boot, no key is readable] → The agent lists no identities and logs the reason; it never crashes on a locked keychain.
- [The CLI and agent share one binary, so a CLI bug can crash the agent] → Each command runs in its own process and reaches the agent only through the keychain and the socket.

## Migration Plan

1. Release signd from this change. It runs beside keychain-agent; the two sockets differ.
2. After the `wrapped-keys` change, import each RSA key into signd, point the SSH configuration at `~/.ssh/signd.sock`, then uninstall keychain-agent and delete its login-keychain items.
3. Rollback: reinstall keychain-agent from the tap; its keychain items stay until step 2 deletes them.

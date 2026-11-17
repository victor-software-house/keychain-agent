# Tasks

## 1. Rename and targets

- [ ] 1.1 Rename the package, product, sources, socket and identifier from keychain-agent to signd, and update README.md and AGENTS.md; verify `rg -i keychain-agent` finds only CHANGELOG.md and the archived spec.
- [ ] 1.2 Split `Sources/` into `SSHWire`, `AgentProtocol`, `KeyStore`, `AgentServer` and the `signd` executable, and add swift-nio, swift-crypto and swift-argument-parser at exact versions; verify `mise run check` passes in CI.

## 2. Message format and protocol

- [ ] 2.1 Implement `SSHWire`: strings, `uint32`, `mpint`, public key and signature blobs, SHA-256 fingerprints; verify round-trip tests against OpenSSH-recorded fixtures for P-256, Ed25519 and RSA.
- [ ] 2.2 Implement the RFC 9987 messages of design decision 6 in `AgentProtocol`; verify one parse test and one encode test per message, and failure for truncated and unknown messages.

## 3. Key store

- [ ] 3.1 Define the store interface and the versioned item format, with a memory implementation in the test target only; verify unit tests for create, list, delete and duplicate names.
- [ ] 3.2 Implement the keychain store: Secure Enclave P-256 keys in generic-password items in the access group, `AfterFirstUnlockThisDeviceOnly`; verify on a physical Mac that a key survives a restart and an ad-hoc probe reads nothing.
- [ ] 3.3 Implement the in-memory key cache with the `key-lifetime` setting; verify a unit test with a 1-second lifetime.

## 4. Agent server

- [ ] 4.1 Serve the socket with SwiftNIO: length framing, the 256 KiB limit, the peer user check, signing on the thread pool. Verify the `agent-protocol` scenarios with `ssh-add` and `ssh-keygen -Y` in `mise run ci:e2e` on a GitHub-hosted runner, against the memory store.
- [ ] 4.2 Add the concurrency test of the "Signing never blocks other clients" requirement; verify it passes in CI with a software P-256 key standing in for the Secure Enclave.

## 5. Command line

- [ ] 5.1 Implement `key create|list|show|delete`, `status`, `config get|set|unset` and `serve`, each with `--json`; verify the `cli` scenarios in `mise run ci:e2e`.
- [ ] 5.2 Implement `service enable|disable` with `SMAppService.agent` and the bundled LaunchAgent plist; verify on a headless Mac over SSH that enabling twice leaves one agent, and record the result in design.md if `SMAppService` refuses.

## 6. Release

- [ ] 6.1 Create the App ID and the `MAC_APP_DIRECT` profile through the App Store Connect API, and add the profile to the release signing secrets; verify the profile's entitlements allow the access group.
- [ ] 6.2 Assemble, sign and notarize `Signd.app` and `signd.pkg` in the package job, generating the entitlements from the profile; verify a publish-off release run passes `spctl` for both.
- [ ] 6.3 Switch the cask to the app and the linked command; verify the `packaging` scenarios after `brew install` on a physical Mac.
- [ ] 6.4 Add `mise run e2e:hardware` for the physical-Mac checks of design decision 8; verify it passes and record the run as evidence here.

## 7. Integration

- [ ] 7.1 Release signd as 0.1.0, a breaking change after keychain-agent 0.0.1, then upgrade it to the next patch on a physical Mac. Verify that a key created under 0.1.0 still signs after the upgrade with no prompt.

## Workflow follow-up

- Archive this change once the `wrapped-keys` change has migrated the keychain-agent keys.

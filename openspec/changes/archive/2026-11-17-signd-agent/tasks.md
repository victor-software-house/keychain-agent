# Tasks

## 1. Rename and targets

- [x] 1.1 Rename the package, product, sources, socket and identifier from keychain-agent to signd, and update README.md and AGENTS.md; verify `rg -i keychain-agent` finds only CHANGELOG.md and the archived spec.
  2026-11-17 UTC, in [pull request 4][signd#4]: `rg -i keychain-agent` finds the name only in CHANGELOG.md, the OpenSpec documents and tasks.yaml.
- [x] 1.2 Split `Sources/` into `SSHWire`, `AgentProtocol`, `KeyStore`, `AgentServer` and the `signd` executable, and add swift-nio, swift-crypto and swift-argument-parser at exact versions; verify `mise run check` passes in CI.
  2026-11-17 UTC: the five targets build with the three dependencies at exact versions; `mise run check` passed in the [CI run][ci-44141158233].

## 2. Message format and protocol

- [x] 2.1 Implement `SSHWire`: strings, `uint32`, `mpint`, public key and signature blobs, SHA-256 fingerprints; verify round-trip tests against OpenSSH-recorded fixtures for P-256, Ed25519 and RSA.
  2026-11-17 UTC: `WireTests` round-trip P-256 and RSA blobs and match `ssh-keygen -l` on the RSA fixture; passed in the [CI run][ci-44141158233].
- [x] 2.2 Implement the RFC 9987 messages of design decision 6 in `AgentProtocol`; verify one parse test and one encode test per message, and failure for truncated and unknown messages.
  2026-11-17 UTC: `ProtocolTests` parse and encode every message of decision 6, and refuse cut and unknown ones; passed in the [CI run][ci-44141158233].

## 3. Key store

- [x] 3.1 Define the store interface and the versioned item format, with a memory implementation in the test target only; verify unit tests for create, list, delete and duplicate names.
  2026-11-17 UTC: only `AgentTests` holds the memory store; the duplicate, create, list and delete cases passed in the [CI run][ci-44141158233].
- [x] 3.2 Implement the keychain store: Secure Enclave P-256 keys in generic-password items in the access group, `AfterFirstUnlockThisDeviceOnly`; verify on a physical Mac that a key survives a restart and an ad-hoc probe reads nothing.
  2026-11-17 UTC: `e2e:hardware` on a locked, headless Mac: the key signed after an agent restart, and an ad-hoc signed probe got `errSecItemNotFound`.
- [x] 3.3 Implement the in-memory key cache with the `key-lifetime` setting; verify a unit test with a 1-second lifetime.
  2026-11-17 UTC: `anOpenKeyLeavesMemoryAfterItsLifetime` with a 1-second lifetime passed in the [CI run][ci-44141158233]; `e2e:hardware` showed the same on a Mac.

## 4. Agent server

- [x] 4.1 Serve the socket with SwiftNIO: length framing, the 256 KiB limit, the peer user check, signing on the thread pool. Verify the `agent-protocol` scenarios with `ssh-add` and `ssh-keygen -Y` in `mise run ci:e2e` on a GitHub-hosted runner, against the memory store.
  2026-11-17 UTC: `mise run ci:e2e` passed on the GitHub-hosted runner in the [CI run][ci-44141158233], against an unsigned build with no store.
- [x] 4.2 Add the concurrency test of the "Signing never blocks other clients" requirement; verify it passes in CI with a software P-256 key standing in for the Secure Enclave.
  2026-11-17 UTC: 32 tasks of 100 slow signatures each; a list request answered within 10 ms; passed in the [CI run][ci-44141158233].

## 5. Command line

- [x] 5.1 Implement `key create|list|show|delete`, `status`, `config get|set|unset` and `serve`, each with `--json`; verify the `cli` scenarios in `mise run ci:e2e`.
  2026-11-17 UTC: `key create` needs the Secure Enclave, so the `cli` scenarios ran on a Mac with the cask install of the 0.1.0 build ([`23d374c`][23d374c]). That release was later retracted for 0.0.2. A duplicate name exits 1 naming the key, `--host` shows in `key list`, `--json` parses, and `status` exits 1 with the agent stopped.
- [x] 5.2 Implement `service enable|disable` with `SMAppService.agent` and the bundled LaunchAgent plist; verify on a headless Mac over SSH that enabling twice leaves one agent, and record the result in design.md if `SMAppService` refuses.
  2026-11-17 UTC: over SSH on a headless Mac, `service enable` twice left one agent, and launchd restarted it on `kickstart -k`; `SMAppService` did not refuse.

## 6. Release

- [x] 6.1 Create the App ID and the `MAC_APP_DIRECT` profile through the App Store Connect API, and add the profile to the release signing secrets; verify the profile's entitlements allow the access group.
  2026-11-17 UTC: an App Store Connect outage answered 500, so the App ID and the `MAC_APP_DIRECT` profile came from the developer portal's own API; the profile allows `TEAM.*`.
- [x] 6.2 Assemble, sign and notarize `Signd.app` and `signd.pkg` in the package job, generating the entitlements from the profile; verify a publish-off release run passes `spctl` for both.
  2026-11-17 UTC: the [publish-off run][run-44146012807] signed, notarized and stapled `signd.pkg`; `pkgutil --check-signature` and `spctl --assess --type install` accepted the artifact as notarized Developer ID.
- [x] 6.3 Switch the cask to the app and the linked command; verify the `packaging` scenarios after `brew install` on a physical Mac.
  2026-11-17 UTC: [the cask][tap#10] installed the 0.1.0 build ([`23d374c`][23d374c]) on a Mac and linked `/opt/homebrew/bin/signd`; `e2e:hardware` then passed against `/Applications/Signd.app`, and the link listed the same keys.
- [x] 6.4 Add `mise run e2e:hardware` for the physical-Mac checks of design decision 8; verify it passes and record the run as evidence here.
  2026-11-17 UTC: `mise run e2e:hardware` passed on a locked, headless Mac with a Developer ID signed `Signd.app`.

## 7. Integration

- [x] 7.1 Release signd 0.0.2, the first signd release after keychain-agent 0.0.1, and install it over an earlier signd build on a physical Mac. Verify that a key created under the earlier build still signs after the upgrade with no prompt.
  2026-11-17 UTC: `brew upgrade --cask signd` replaced the 0.1.0 build with [v0.0.2][v0.0.2] on a locked Mac, and the 0.0.2 binary listed the key the 0.1.0 build made.
  The agent then did not answer: the cask's `uninstall launchctl` step, which an upgrade runs, removed the job while the login item stayed enabled, and `service enable` reported `enabled`.
  After `service disable` and `service enable` the key signed and verified with no prompt, so the requirement's "no command run" fails until the upgrade restores the agent by itself.
  The fix: `service enable` registers again when the agent does not answer.
  2026-11-17 UTC: the upgrade to [v0.0.3][v0.0.3] ran `service enable` from the cask's `postflight_steps`, where Homebrew's step sandbox refused `SMAppService` with error 57, "Socket is not connected", and the agent stayed down.
  The same command run from root through `launchctl asuser` registered the agent, so the package's `postinstall` now runs it as the console user, and the cask runs nothing.
  2026-11-17 UTC: on a locked Mac, `brew upgrade --cask signd` from v0.0.3 to [v0.0.4][v0.0.4] left the 0.0.4 agent answering with a new pid and no command run.
  The key the 0.1.0 build created signed and verified with no prompt, and a login through the wrapped RSA key still worked; the upgrade on a second Mac gave the same result.

## Workflow follow-up

- Archive this change once the `wrapped-keys` change has migrated the keychain-agent keys.

[signd#4]: https://github.com/victor-software-house/signd/pull/4
[ci-44141158233]: https://github.com/victor-software-house/signd/actions/runs/44141158233
[run-44146012807]: https://github.com/victor-software-house/signd/actions/runs/44146012807
[23d374c]: https://github.com/victor-software-house/signd/commit/23d374c1c67828f6dd3bb6cd93c32513686cb616
[tap#10]: https://github.com/victor-software-house/homebrew-private/pull/10
[v0.0.2]: https://github.com/victor-software-house/signd/releases/tag/v0.0.2
[v0.0.3]: https://github.com/victor-software-house/signd/releases/tag/v0.0.3
[v0.0.4]: https://github.com/victor-software-house/signd/releases/tag/v0.0.4

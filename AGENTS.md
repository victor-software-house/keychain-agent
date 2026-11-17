# AGENTS.md

keychain-agent is an SSH agent for macOS that signs with non-extractable keychain keys.  
It is a Swift 6.4 package: the `AgentProtocol` library for the SSH agent message format, and the `keychain-agent` executable that serves a launchd socket and signs through the Security framework.  
`README.md` says what it does and why.

## 1. Critical invariants

1. The agent never holds key material: it signs with `SecKeyCreateSignature` on a keychain key reference, and never asks for the key's data.
2. It answers only "list identities" and "sign", and sends `SSH_AGENT_FAILURE` for every other request.
3. It reads at most one bounded message at a time from a client, and a malformed message ends that connection only.
4. The release binary is signed with a Developer ID, with the hardened runtime and identifier `com.victor-software-house.keychain-agent`; the keys' partition lists depend on that team.

## 2. Work in this repository

1. This repository is public: no host names, client names, private repository links, account IDs or personal details in files, commits or pull requests.
2. Changes are planned as OpenSpec changes under `openspec/`; record each task's evidence under it, dated in UTC.
3. Small work items go in the qctl queue, `tasks.yaml`.
4. Builds and tests run in CI, on GitHub-hosted runners.
5. A pull request that changes behaviour adds a `.changeset` fragment; the Release workflow opens the Version PR and releases each merged version.
6. The shared template owns the files `.copier-answers.yml` records; change them through `copier update`, not by hand.

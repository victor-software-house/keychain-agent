# AGENTS.md

signd is an SSH agent for macOS whose keys only its signed app can use.  
It is a Swift 6.4 package. `SSHWire` and `AgentProtocol` hold the SSH encoding and the agent messages, with no platform code.  
`KeyStore` holds keys and signing, `Sync` shares keys between devices through CloudKit, `AgentServer` holds the agent's state and the SwiftNIO socket server, and the `signd` executable is both the command line and the agent.  
`README.md` says what it does; `openspec/` says what it must do.

## 1. Critical invariants

1. No command and no message exports a private key.
2. Stored keys live in the data-protection keychain, readable after first unlock, on this device only, in signd's access group; the code names no team, and the entitlements come from the provisioning profile at release time.
3. A signature never runs on the event loop or inside the agent actor: it runs on the thread pool, so a slow Secure Enclave call delays no other client.
4. The agent reads at most one bounded message (256 KiB) at a time from a client, answers failure to anything it does not support or cannot parse, and closes only that connection on an oversized message.
5. `ssh-add -D` and remove requests touch memory-only keys, never stored ones.
6. signd never uses `Bundle.main`: through the cask's link it has no bundle identifier.
7. Only the agent calls CloudKit, and only when its own signature lists signd's iCloud container; the command line asks the agent. A shared key leaves a device only sealed to each device's Secure Enclave key.

## 2. Work in this repository

1. This repository is public: no host names, client names, private repository links, account IDs or personal details in files, commits or pull requests.
2. Changes are planned as OpenSpec changes under `openspec/`; record each task's evidence under it, dated in UTC.
3. Small work items go in the qctl queue, `tasks.yaml`.
4. Builds and tests run in CI, on GitHub-hosted runners; Secure Enclave and keychain checks run with `mise run e2e:hardware` on a Mac, since the runners have no Secure Enclave.
5. A pull request that changes behaviour adds a `.changeset` fragment; the Release workflow opens the Version PR and releases each merged version.
6. Installer scripts are one line that runs a `signd` command; their logic is Swift.
7. The iCloud container is named only in the App ID; the profile carries it into the signature, and the code reads it from there. `cloudkit/schema.ckdb` declares the CloudKit schema, and `mise run cloudkit:schema` imports it into development.
8. The shared template owns the files `.copier-answers.yml` records; change them through `copier update`, not by hand.

# Tasks

Unit tests run in CI with a software key-agreement key standing in for the Secure Enclave.  
The command-line scenarios need signd's keychain access group, which an unsigned CI build lacks, so they run in `mise run e2e:hardware` on a Mac.

## 1. Formats

- [x] 1.1 Parse the unencrypted `openssh-key-v1` private key file in `SSHWire` for Ed25519, ECDSA and RSA, and report an encrypted one as protected; verify against files `ssh-keygen` writes at test time, comparing each public key with its `.pub` file.
  2026-11-17 UTC: `mise run test` on a Mac passed `readsEachUnencryptedFormat` for OpenSSH Ed25519, ECDSA 256, 384 and 521 and RSA 3072.  
  Each public blob equals the `.pub` file, and a protected OpenSSH file reads as protected.
- [x] 1.2 Parse unencrypted PKCS#1, PKCS#8 and SEC1 PEM keys, and refuse unsupported types and RSA under 2048 bits; verify per type in unit tests, including the refusals.
  2026-11-17 UTC: on a Mac, the same test passed for PKCS#1, SEC1 and PKCS#8 RSA and ECDSA, and `readsAnEd25519PKCS8Key` passed.  
  RSA 1024 and a DSA label are refused by name, and protected PEM and PKCS#8 files read as protected.

## 2. Wrapping

- [x] 2.1 Seal and open private keys with HPKE to a per-key key-agreement key, with the `info` and AAD of design decision 1. Verify the round trip and the tampered-item scenario in unit tests, and a Secure Enclave seal and open in `mise run e2e:hardware`.
  2026-11-17 UTC: `WrappingRoundTrip` passed on a Mac with a software key-agreement key, and `aTamperedKeyFailsOnceThenLeavesTheList` passed.  
  2026-11-17 UTC: `mise run e2e:hardware` passed on a locked Mac against the [v0.0.3][v0.0.3] cask install: `key create --type` and `key import` sealed keys to Secure Enclave keys, and each opened on its first signature, which verified.
- [x] 2.2 Add the wrapped kind to the keychain store and open keys on first signature into the key cache; verify the warm-signature scenario in a unit test through the socket.
  2026-11-17 UTC: `Agent.openStored` opens the wrapped kind; `aWrappedKeySignsFastOnceOpen` signed 1000 times over a real socket from one connection, p50 0.12 ms on a Mac.

## 3. Command line

- [x] 3.1 Implement `key import NAME FILE|-` for unencrypted keys; verify the stdin scenario in `mise run e2e:hardware`.
  2026-11-17 UTC: `mise run e2e:hardware` passed on a locked Mac against the [v0.0.3][v0.0.3] cask install: an Ed25519 key piped into `key import NAME -` showed the file's public key, and a signature through the socket verified.
- [x] 3.2 Implement the `ssh-add` path for passphrase-protected files on a private socket; verify it in a unit test with `SSH_ASKPASS` and `SSH_ASKPASS_REQUIRE=force`, and the protected-key scenarios in `mise run e2e:hardware`.
  2026-11-17 UTC: `importsAProtectedFileAndLeavesNoFile` passed on a Mac with `SSH_ASKPASS` and `SSH_ASKPASS_REQUIRE=force`.  
  2026-11-17 UTC: `mise run e2e:hardware` passed on a locked Mac against the [v0.0.3][v0.0.3] cask install: a protected Ed25519 file imported through `ssh-add` with `SSH_ASKPASS` was listed and signed.  
  The same key on stdin was refused with a message naming a file, and an RSA 1024 key was refused by name.
- [x] 3.3 Add `--type ed25519|rsa-3072|rsa-4096` to `key create`; verify the generation scenario in `mise run e2e:hardware`.
  2026-11-17 UTC: `mise run e2e:hardware` passed on a locked Mac against the [v0.0.3][v0.0.3] cask install: `--type ed25519` and `--type rsa-3072` each printed one public key line, and each key signed.
- [x] 3.4 Document importing, generating and wrapping in README.md; verify each documented command runs as written.
  2026-11-17 UTC: on a Mac with the v0.0.3 cask install, each `key create`, `key import` and `key list` example in README.md ran as written with throwaway names, and the keys were deleted afterwards.

## 4. Migration

- [x] 4.1 Import the keychain-agent RSA keys on each Mac, move their hosts to signd's socket, and remove keychain-agent; verify a login to each host through signd and that `security find-key` finds no keychain-agent item.
  2026-11-17 UTC: on both Macs, the dotfiles imported an RSA key from 1Password with `signd key import NAME - --host HOST` and pointed that host at `~/.ssh/signd.sock`.  
  With every proxy variable unset, `ssh -v -T` to the host had the key accepted through signd, and `git ls-remote` of a repository on it returned `HEAD`.  
  keychain-agent and its LaunchAgent were removed; `security find-certificate` for its label exits 44 and `security find-identity` lists no keychain-agent item.

## Workflow follow-up

- Archive this change after the `signd-agent` change.

[v0.0.3]: https://github.com/victor-software-house/signd/releases/tag/v0.0.3

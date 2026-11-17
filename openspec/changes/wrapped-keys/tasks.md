# Tasks

## 1. Formats

- [ ] 1.1 Parse and write the unencrypted `openssh-key-v1` private layout in `SSHWire` for Ed25519, ECDSA and RSA; verify round trips against `ssh-keygen`-generated fixtures.
- [ ] 1.2 Parse unencrypted PKCS#1 and PKCS#8 PEM with `CryptoExtras`, and refuse unsupported types and RSA under 2048 bits; verify fixture tests per type, including the refusals.

## 2. Wrapping

- [ ] 2.1 Seal and open private keys with HPKE to a per-key Secure Enclave key-agreement key, with the `info` and AAD of design decision 1; verify on a physical Mac in `mise run e2e:hardware`, including the tampered-item scenario.
- [ ] 2.2 Add the wrapped kind to the keychain store and open keys on first signature into the key cache; verify the warm-signature scenario in `mise run e2e:hardware`.

## 3. Command line

- [ ] 3.1 Implement `key import NAME FILE|-` for unencrypted keys; verify the stdin scenario in `mise run ci:e2e`, with a software key standing in for the Secure Enclave.
- [ ] 3.2 Implement the `ssh-add` path for passphrase-protected files on a private socket; verify the protected-key scenarios with `SSH_ASKPASS` and `SSH_ASKPASS_REQUIRE=force` in `mise run ci:e2e`.
- [ ] 3.3 Add `--type ed25519|rsa-3072|rsa-4096` to `key create`; verify the generation scenario in `mise run ci:e2e`.
- [ ] 3.4 Document importing, generating and wrapping in README.md; verify each documented command runs as written.

## 4. Migration

- [ ] 4.1 Import the keychain-agent RSA keys on each Mac, move their hosts to signd's socket, and remove keychain-agent; verify a login to each host through signd and that `security find-key` finds no keychain-agent item.

## Workflow follow-up

- Archive this change after the `signd-agent` change.

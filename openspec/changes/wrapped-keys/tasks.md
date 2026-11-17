# Tasks

Unit tests run in CI with a software key-agreement key standing in for the Secure Enclave.  
The command-line scenarios need signd's keychain access group, which an unsigned CI build lacks, so they run in `mise run e2e:hardware` on a Mac.

## 1. Formats

- [ ] 1.1 Parse the unencrypted `openssh-key-v1` private key file in `SSHWire` for Ed25519, ECDSA and RSA, and report an encrypted one as protected; verify against files `ssh-keygen` writes at test time, comparing each public key with its `.pub` file.
- [ ] 1.2 Parse unencrypted PKCS#1, PKCS#8 and SEC1 PEM keys, and refuse unsupported types and RSA under 2048 bits; verify per type in unit tests, including the refusals.

## 2. Wrapping

- [ ] 2.1 Seal and open private keys with HPKE to a per-key key-agreement key, with the `info` and AAD of design decision 1. Verify the round trip and the tampered-item scenario in unit tests, and a Secure Enclave seal and open in `mise run e2e:hardware`.
- [ ] 2.2 Add the wrapped kind to the keychain store and open keys on first signature into the key cache; verify the warm-signature scenario in a unit test through the socket.

## 3. Command line

- [ ] 3.1 Implement `key import NAME FILE|-` for unencrypted keys; verify the stdin scenario in `mise run e2e:hardware`.
- [ ] 3.2 Implement the `ssh-add` path for passphrase-protected files on a private socket; verify it in a unit test with `SSH_ASKPASS` and `SSH_ASKPASS_REQUIRE=force`, and the protected-key scenarios in `mise run e2e:hardware`.
- [ ] 3.3 Add `--type ed25519|rsa-3072|rsa-4096` to `key create`; verify the generation scenario in `mise run e2e:hardware`.
- [ ] 3.4 Document importing, generating and wrapping in README.md; verify each documented command runs as written.

## 4. Migration

- [ ] 4.1 Import the keychain-agent RSA keys on each Mac, move their hosts to signd's socket, and remove keychain-agent; verify a login to each host through signd and that `security find-key` finds no keychain-agent item.

## Workflow follow-up

- Archive this change after the `signd-agent` change.

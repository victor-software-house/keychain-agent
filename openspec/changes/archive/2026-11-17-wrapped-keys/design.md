# Design

## Context

The `signd-agent` change stores Secure Enclave P-256 keys as data-protection keychain items in signd's access group.
Its [research](../2026-11-17-signd-agent/research.md) found no Swift library for passphrase-protected OpenSSH keys, and measured an HPKE open with a Secure Enclave recipient at 4.78 ms.

## Goals / Non-Goals

**Goals:**

- Ed25519, ECDSA (P-256, P-384, P-521) and RSA (2048 to 8192 bits) keys, imported or generated, usable only by signd.
- A decrypted key reaches memory only inside signd, and never touches the disk.

**Non-Goals:**

- Export. No command writes a private key out, wrapped or not.
- RSA keys under 2048 bits, DSA keys and certificates.

## Decisions

### 1. HPKE to a Secure Enclave key per wrapped key

Each wrapped key gets its own `SecureEnclave.P256.KeyAgreement.PrivateKey`, created with `.privateKeyUsage` and no user-presence flag.
The private key is sealed with HPKE `P256_SHA256_AES_GCM_256` to that key's public half.

| HPKE input | Value |
|:--|:--|
| `info` | `signd wrapped key v1` |
| AAD | the key's public blob and its type name |

The item stores the Secure Enclave key's handle, the 65-byte encapsulated key and the ciphertext.
The AAD binds the ciphertext to its public key, so a swapped blob fails to open.

One Secure Enclave key per wrapped key, rather than one for all, lets a later change give a key its own access policy, such as Touch ID.
It costs nothing extra: each first use opens one HPKE message either way.

Alternative: `SecKeyCreateEncryptedData` with ECIES.
Rejected: it needs a second, `SecKey`-based way to handle Secure Enclave keys, while HPKE stays in CryptoKit and follows RFC 9180.

### 2. One plaintext format

The sealed plaintext is the private part of an OpenSSH key in the unencrypted `openssh-key-v1` layout: type name, public fields, private fields, comment.
Import, generation and 1Password sync all produce that layout, and one parser in `SSHWire` reads it back.
RSA keys are rebuilt with `CryptoExtras`, which computes the CRT values the layout omits.

### 3. Import paths

| Input | Path |
|:--|:--|
| Unencrypted `openssh-key-v1` file or stdin | parsed by `SSHWire` |
| Unencrypted PKCS#1 or PKCS#8 PEM file or stdin | parsed by `CryptoExtras` |
| Passphrase-protected OpenSSH or PEM file | `ssh-add` path below |

The `ssh-add` path: `signd key import` creates a private socket in a fresh 0700 directory and serves only "add identity" on it.
It runs `/usr/bin/ssh-add FILE` with `SSH_AUTH_SOCK` set to that socket, so ssh-add prompts for the passphrase and parses the file with OpenSSH's own code.
The import receives the key's parts, wraps and stores them, then removes the socket.
Stdin with a passphrase-protected key is refused, because ssh-add needs the terminal for the prompt.

Alternative: our own `bcrypt_pbkdf` and cipher code.
Rejected for now: new cryptographic code to maintain, for a path ssh-add already covers.

### 4. Generation

`--type ed25519` uses CryptoKit; `--type rsa-3072` and `rsa-4096` use `CryptoExtras`.
The key is wrapped before the command returns, and its plaintext lives only in that process's memory.

### 5. Memory

The agent opens a wrapped key on its first signature and keeps it for the key lifetime from the `key-store` capability.
Swift cannot guarantee that a buffer is erased, so signd keeps each decrypted key in one `Data` value it overwrites before release, and accepts that copies made by libraries may remain until the memory is reused.

## Risks / Trade-offs

- [A wrapped key is in signd's memory while in use] → Accepted and documented: a Secure Enclave key avoids it, and the key lifetime bounds it.
- [A future macOS changes `ssh-add`'s output or prompt] → signd parses only the agent protocol messages ssh-add sends, which RFC 9987 fixes.
- [A Secure Enclave key handle is lost, for example by erasing the Mac] → Its wrapped key is lost with it; a key must have another source, such as 1Password or the original file, to be restored.

## Migration Plan

1. On each Mac, import every keychain-agent RSA key from its source with `signd key import NAME - --host PATTERN`.
2. Point SSH at `~/.ssh/signd.sock` for those hosts, check a login, then uninstall keychain-agent and delete its login-keychain items.
3. Rollback before step 2's deletion: switch SSH back to keychain-agent's socket.

# signd

An SSH agent for macOS whose keys only signd can use.  
Keys live in signd's own data-protection keychain access group, either inside the Secure Enclave or sealed to it, and no command exports them.  
The agent answers from memory: listing keys reads no keychain, and a Secure Enclave signature takes about 5 ms.

## Use

```sh
signd service enable                         # run the agent at login, on ~/.ssh/signd.sock
signd key create work --host github.com      # a Secure Enclave P-256 key; prints its public key
signd key create ci --type ed25519           # an Ed25519 key, sealed to the Secure Enclave; also rsa-3072 and rsa-4096
signd key import old ~/.ssh/id_rsa           # an existing OpenSSH, PKCS#1, PKCS#8 or SEC1 private key file
signd key import ci - < ci_ed25519           # the same from stdin, for a key that has no passphrase
signd key list
signd status
export SSH_AUTH_SOCK=~/.ssh/signd.sock       # or IdentityAgent ~/.ssh/signd.sock in ~/.ssh/config
```

Keys added with `ssh-add` stay in memory only, honour `ssh-add -t`, and leave with `ssh-add -D`; stored keys leave only with `signd key delete`.  
Every command that prints data takes `--json`.

## Keys beyond the Secure Enclave

The Secure Enclave holds only P-256 keys, so signd keeps Ed25519, ECDSA and RSA keys as wrapped keys.  
`signd key create NAME --type ed25519|rsa-3072|rsa-4096` generates one.  
`signd key import NAME FILE` brings in an existing one: Ed25519, ECDSA on P-256, P-384 and P-521, or RSA of 2048 to 8192 bits.  
A key that signd cannot serve, such as RSA under 2048 bits or a DSA key, is refused with a message naming the type.

A wrapped key is sealed with HPKE to its own Secure Enclave key, so the keychain item holds only ciphertext.  
The agent opens it into memory on its first signature and drops it after `key-lifetime`, as it does for every open key.  
No command writes a private key out.

A passphrase-protected file must be given as a file, not on stdin.  
`signd key import` then runs the system `ssh-add` for the passphrase prompt and the decryption.  
The key reaches signd over a private socket that only this user can reach, and no decrypted copy touches the disk.

## Operation

1. `signd service enable` registers the agent's LaunchAgent with `SMAppService`; launchd runs `signd serve` at login and restarts it if it exits.
2. The agent serves the SSH agent protocol (RFC 9987): list, sign, add, remove and the `query` and `session-bind@openssh.com` extensions, and refuses lock, confirm and every other request.
3. Keys are readable after the first unlock after boot, with no prompt, so a locked or headless Mac signs over SSH.
4. A private key the agent opened leaves memory after `key-lifetime` without a signature, one hour by default: `signd config set key-lifetime 30m`.

## Install

Each release attaches `signd.pkg`, signed with a Developer ID, notarized and stapled, which installs `/Applications/Signd.app`.  
The app carries a Developer ID provisioning profile, which grants its keychain access group; the Homebrew cask links `signd` onto the PATH.

## Development

`openspec/` holds the requirements and the planned changes; `tasks.yaml` holds the queue.  
CI builds and tests on GitHub-hosted runners, which have no Secure Enclave, so `mise run e2e:hardware` checks Secure Enclave keys on a Mac before each release.

## License

[GNU Affero General Public License v3.0](LICENSE).

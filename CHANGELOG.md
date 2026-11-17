# Changelog

## signd 0.0.3

- `signd service enable` starts the agent again when its login item is enabled but launchd no longer runs it, as after a cask upgrade ([`c4afb96`](https://github.com/victor-software-house/signd/commit/c4afb96a43544f39f764d1005235f30db744672d)).
- `signd key import NAME FILE` brings an existing Ed25519, ECDSA or RSA private key into signd, from a file or from stdin, and asks for the passphrase of a protected file through `ssh-add`.
  `signd key create NAME --type ed25519|rsa-3072|rsa-4096` makes such a key, and both seal it to its own Secure Enclave key so that only signd can use it ([`5e54fb9`](https://github.com/victor-software-house/signd/commit/5e54fb9c84d580a4da22866d709448b0c5640783)).

## signd 0.0.2

- signd is licensed under the GNU Affero General Public License, version 3 ([`8249951`](https://github.com/victor-software-house/signd/commit/82499516f3096ae3c509059b5a756ab17fed6dbe)).
- keychain-agent becomes signd, an SSH agent for keys only its signed app can use.
  `signd key create` makes Secure Enclave P-256 keys, held in signd's data-protection keychain access group, and `signd service enable` runs the agent at login on `~/.ssh/signd.sock`.
  The agent also accepts memory-only keys from `ssh-add`, with lifetimes, and never lets `ssh-add -D` remove a stored key ([`4ff038c`](https://github.com/victor-software-house/signd/commit/4ff038c2ccbccd6beeb832de96ba4741aa7291ca)).

## keychain-agent 0.0.1

- The first release of keychain-agent, an SSH agent for RSA keys held non-extractable in the login keychain, as a signed and notarized `keychain-agent.pkg` that installs `/usr/local/bin/keychain-agent`.


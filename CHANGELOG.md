# Changelog

## signd 0.0.2

- signd is licensed under the GNU Affero General Public License, version 3 ([`8249951`](https://github.com/victor-software-house/signd/commit/82499516f3096ae3c509059b5a756ab17fed6dbe)).
- keychain-agent becomes signd, an SSH agent for keys only its signed app can use.
  `signd key create` makes Secure Enclave P-256 keys, held in signd's data-protection keychain access group, and `signd service enable` runs the agent at login on `~/.ssh/signd.sock`.
  The agent also accepts memory-only keys from `ssh-add`, with lifetimes, and never lets `ssh-add -D` remove a stored key ([`4ff038c`](https://github.com/victor-software-house/signd/commit/4ff038c2ccbccd6beeb832de96ba4741aa7291ca)).

## keychain-agent 0.0.1

- The first release of keychain-agent, an SSH agent for RSA keys held non-extractable in the login keychain, as a signed and notarized `keychain-agent.pkg` that installs `/usr/local/bin/keychain-agent`.


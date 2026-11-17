# Changelog

## signd 0.1.0

- keychain-agent becomes signd, an SSH agent for keys only its signed app can use.
  `signd key create` makes Secure Enclave P-256 keys, held in signd's data-protection keychain access group, and `signd service enable` runs the agent at login on `~/.ssh/signd.sock`.
  The agent also accepts memory-only keys from `ssh-add`, with lifetimes, and never lets `ssh-add -D` remove a stored key ([`60c9628`](https://github.com/victor-software-house/signd/commit/60c9628a06910a1c5f2c9a8d5c844ed311827c5a)).

## keychain-agent 0.0.1

- The first release of keychain-agent, an SSH agent for RSA keys held non-extractable in the login keychain, as a signed and notarized `keychain-agent.pkg` that installs `/usr/local/bin/keychain-agent`.

